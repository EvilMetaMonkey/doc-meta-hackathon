/// The TUI's controller: keys in, state changes out, and the actions that
/// run Doc's own commands in-process. The terminal ([TuiHost]) and the
/// data sources ([TuiBackend]) are interfaces, so tests can script both.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../doctor_command.dart';
import '../talk_command.dart';
import 'keys.dart';
import 'model.dart';
import 'render.dart';
import 'text.dart';

/// What the TUI needs from the terminal.
abstract class TuiHost {
  Stream<KeyEvent> get keys;
  (int, int) get size;
  bool get color;
  void draw(List<String> lines);

  /// Gives the real terminal to [run] (an agent, an editor) and takes it
  /// back afterwards.
  Future<int> handOver(Future<int> Function() run);
}

/// Callbacks a Doc command run in-process gets from the TUI.
class DocRunIo {
  final StringSink out;
  final Future<String?> Function() ask;
  final void Function(Map<String, Object?> event) progress;
  final Future<int> Function(Future<int> Function() run) handOver;
  final VoiceDeps? voice;

  const DocRunIo({
    required this.out,
    required this.ask,
    required this.progress,
    required this.handOver,
    this.voice,
  });
}

/// Where the TUI's data comes from. The real one ([DocBackend]) uses dmc's
/// JSON and runs Doc's commands in-process.
abstract class TuiBackend {
  String get workspaceName;

  /// The quoted dmc path for fix lines.
  String get dmcCommand;

  /// Where action logs go.
  String get logDirectory;

  Future<List<DoctorLine>> doctor();

  /// `dmc checkpoint list --json` (throws when dmc or the workspace is
  /// missing).
  Future<Map<String, Object?>> checkpointList();

  /// The last `doc bisect` result for this workspace, if any.
  Map<String, Object?>? lastBisect();

  /// The turn's before → after diff (as lesson drafts use it).
  Future<String?> diff(
    String checkpointId,
    List<({String path, String change})> files,
  );

  /// `dmc checkpoint show <id> --json` data.
  Future<Map<String, Object?>> show(String checkpointId);

  /// Any dmc command through its JSON (`--json` is added).
  Future<Map<String, Object?>> dmcJson(List<String> args);

  /// Runs `doc <args>` in-process; returns its exit code.
  Future<int> runDoc(List<String> args, DocRunIo io);

  Future<List<LessonItem>> lessons();

  String? cachedSummary(String checkpointId);
  void saveSummary(String checkpointId, String text, String? footer);

  /// The workspace's `bisectTest` setting, else the last bisect's test.
  String? defaultTest();

  /// The last bisect's setup, else Doc's suggestion for the project.
  String? defaultSetup();

  /// Whether the summary role runs on Modal (Glimmer may be cold).
  bool get summaryOnModal;
}

/// A sink for one action: everything goes to its log file and to the
/// text Doc keeps for the result; lines are reported as they complete.
class ActionSink implements StringSink {
  final StringSink log;
  final void Function(String line)? onLine;
  final StringBuffer _all = StringBuffer();
  final StringBuffer _partial = StringBuffer();

  /// Lines since the last question was answered.
  final List<String> recent = [];

  ActionSink(this.log, {this.onLine});

  String get text => _all.toString();

  /// Text written after the last newline (a question waiting for input).
  String get pending => _partial.toString();

  @override
  void write(Object? object) {
    final text = '$object';
    log.write(text);
    _all.write(text);
    for (final char in text.split('')) {
      if (char == '\n') {
        final line = _partial.toString();
        _partial.clear();
        recent.add(line);
        onLine?.call(line);
      } else {
        _partial.write(char);
      }
    }
  }

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  /// The question being asked: the pending text, or the last line.
  ({List<String> context, String prompt}) takeQuestion() {
    var prompt = pending;
    final lines = [...recent];
    if (prompt.trim().isEmpty && lines.isNotEmpty) prompt = lines.removeLast();
    // A question written with a newline inside ("I heard … \nRun it?").
    recent.clear();
    _all.write('\n');
    _partial.clear();
    final context = [
      for (final line in lines)
        if (!isProgressLine(line)) line,
    ];
    return (
      context: context.length > 14
          ? context.sublist(context.length - 14)
          : context,
      prompt: prompt,
    );
  }
}

/// The TUI. [run] returns when the user quits.
class TuiApp {
  final TuiHost host;
  final TuiBackend backend;
  final TuiState state;
  final Duration pollEvery;
  final Duration summaryDelay;
  final Duration splashFor;

  /// Opens the log file for an action; returns the sink and its path.
  final ({StringSink sink, String path, Future<void> Function() close})
  Function(String name)
  openLog;

  final Completer<int> _done = Completer<int>();
  StreamSubscription<KeyEvent>? _keys;
  Completer<String?>? _answer;
  Timer? _poll;
  Timer? _summaryTimer;
  bool _busy = false;
  final Map<String, String> _logs = {};

  /// Keys for a running voice turn (Space/Enter/Esc while recording).
  StreamController<TalkKey>? _talkKeys;
  _TuiTalkTerminal? _talkTerminal;

  TuiApp({
    required this.host,
    required this.backend,
    required this.openLog,
    this.pollEvery = const Duration(seconds: 3),
    this.summaryDelay = const Duration(milliseconds: 300),
    this.splashFor = const Duration(milliseconds: 1200),
    bool splash = true,
    String? dmcVersion,
  }) : state = TuiState(HeaderStatus(workspaceName: backend.workspaceName)) {
    state.splash = splash;
    state.dmcVersionForSplash = dmcVersion;
  }

  void redraw() {
    final (width, height) = host.size;
    host.draw(renderTui(state, width, height, color: host.color));
  }

  Future<int> run() async {
    _keys = host.keys.listen(_onKey);
    redraw();
    if (state.splash) {
      Timer(splashFor, () {
        if (state.splash) {
          state.splash = false;
          redraw();
        }
      });
    }
    unawaited(_loadHeader());
    await refreshTurns();
    _poll = Timer.periodic(pollEvery, (_) {
      if (!_busy && state.question == null) unawaited(refreshTurns());
    });
    final code = await _done.future;
    _poll?.cancel();
    _summaryTimer?.cancel();
    await _keys?.cancel();
    return code;
  }

  void quit([int code = 0]) {
    if (!_done.isCompleted) _done.complete(code);
  }

  Future<void> _loadHeader() async {
    try {
      final lines = await backend.doctor();
      state.header = HeaderStatus.fromDoctor(backend.workspaceName, lines);
    } on Object catch (error) {
      state.header = HeaderStatus(
        workspaceName: backend.workspaceName,
        loaded: true,
        problems: [DoctorLine(DoctorLevel.fail, 'checks failed: $error')],
      );
    }
    redraw();
  }

  /// Reloads the turns, keeping the selection on the same checkpoint.
  Future<void> refreshTurns() async {
    final selectedId = state.currentTurn?.id;
    try {
      final listed = await backend.checkpointList();
      if (listed['ok'] != true) {
        _empty([
          'No dmc workspace here.',
          'Run dmc init here, or open Doc in a project with a vault:',
          '  ${backend.dmcCommand} init',
        ]);
        return;
      }
      state.emptyReason = null;
      final turns = turnsFromList(listed);
      state.turns = turns;
      state.turnsLoaded = true;
      state.firstBad =
          (backend.lastBisect()?['firstBad'] as Map?)?['id'] as String?;
      final index = turns.indexWhere((t) => t.id == selectedId);
      state.selected = index >= 0
          ? index
          : state.selected.clamp(0, turns.isEmpty ? 0 : turns.length - 1);
      _scheduleDetail();
    } on Object catch (error) {
      _empty([
        'Doc cannot read dmc here: $error',
        'Run dmc init here, or open Doc in a project with a vault:',
        '  ${backend.dmcCommand} init',
      ]);
      return;
    }
    redraw();
  }

  void _empty(List<String> reason) {
    state.emptyReason = reason;
    state.turnsLoaded = true;
    state.turns = const [];
    redraw();
  }

  // ---- keys -------------------------------------------------------------

  void _onKey(KeyEvent key) {
    if (key.kind == KeyKind.ctrlC) {
      quit(130);
      return;
    }
    if (state.splash) {
      state.splash = false;
      redraw();
      return;
    }
    if (state.question != null) {
      _questionKey(key);
    } else if (state.pager != null || state.help) {
      _pagerKey(key);
    } else if (state.command != null) {
      _commandKey(key);
    } else if (_talkKeys != null && (_talkTerminal?.waiting ?? false)) {
      final talk = switch (key.kind) {
        KeyKind.space || KeyKind.enter => TalkKey.toggle,
        KeyKind.escape => TalkKey.cancel,
        _ => TalkKey.other,
      };
      _talkKeys!.add(talk);
    } else {
      _paneKey(key);
    }
    redraw();
  }

  void _questionKey(KeyEvent key) {
    final question = state.question!;
    String? answer;
    var done = false;
    if (question.yesNo) {
      if (key.isChar('y') || key.isChar('Y')) {
        answer = 'y';
        done = true;
      } else if (key.isChar('n') ||
          key.isChar('N') ||
          key.kind == KeyKind.enter ||
          key.kind == KeyKind.escape) {
        answer = 'n';
        done = true;
      }
    } else {
      switch (key.kind) {
        case KeyKind.enter:
          answer = question.value;
          done = true;
        case KeyKind.escape:
          answer = '';
          done = true;
        case KeyKind.backspace:
          if (question.value.isNotEmpty) {
            final runes = question.value.runes.toList()..removeLast();
            question.value = String.fromCharCodes(runes);
          }
        case KeyKind.space:
          question.value += ' ';
        case KeyKind.char:
          question.value += key.char;
        default:
          break;
      }
    }
    if (done) {
      state.question = null;
      final completer = _answer;
      _answer = null;
      completer?.complete(answer);
    }
  }

  void _pagerKey(KeyEvent key) {
    final pager = state.pager;
    switch (key.kind) {
      case KeyKind.escape || KeyKind.enter:
        state.pager = null;
        state.help = false;
      case KeyKind.char
          when key.char == 'q' ||
              key.char == 'd' ||
              key.char == 'o' ||
              key.char == '?':
        state.pager = null;
        state.help = false;
      case KeyKind.up:
        pager?.offset--;
      case KeyKind.down:
        pager?.offset++;
      case KeyKind.pageUp:
        pager?.offset -= 10;
      case KeyKind.pageDown || KeyKind.space:
        pager?.offset += 10;
      case KeyKind.home:
        pager?.offset = 0;
      case KeyKind.end:
        pager?.offset = 1 << 20;
      default:
        break;
    }
  }

  void _commandKey(KeyEvent key) {
    switch (key.kind) {
      case KeyKind.escape:
        state.command = null;
      case KeyKind.enter:
        final line = state.command!.trim();
        state.command = null;
        if (line.isNotEmpty) unawaited(runCommandLine(line));
      case KeyKind.backspace:
        final runes = state.command!.runes.toList();
        if (runes.isEmpty) {
          state.command = null;
        } else {
          state.command = String.fromCharCodes(runes..removeLast());
        }
      case KeyKind.space:
        state.command = '${state.command} ';
      case KeyKind.char:
        state.command = '${state.command}${key.char}';
      default:
        break;
    }
  }

  void _paneKey(KeyEvent key) {
    if (key.kind == KeyKind.space) {
      unawaited(talk());
      return;
    }
    if (key.isChar(':')) {
      state.command = '';
      return;
    }
    if (key.isChar('?')) {
      state.help = true;
      return;
    }
    if (key.isChar('q')) {
      quit();
      return;
    }
    if (key.kind == KeyKind.escape) {
      if (state.pane != PaneKind.turns) {
        state.pane = PaneKind.turns;
      } else {
        state.note = null;
      }
      return;
    }
    if (key.isChar('o')) {
      _openLog();
      return;
    }
    if (key.isChar('d')) {
      _openDetails();
      return;
    }
    if (_busy && !key.isChar('?')) {
      state.note = 'Doc is busy with the last action; one moment.';
      state.noteTone = Tone.warn;
      return;
    }
    switch (state.pane) {
      case PaneKind.turns:
        _turnsKey(key);
      case PaneKind.lessons:
        _lessonsKey(key);
      case PaneKind.bisect:
        if (key.isChar('r') && state.bisect?.firstBad != null) {
          unawaited(restoreTurn(state.bisect!.firstBad!));
        } else {
          _globalKey(key);
        }
      case PaneKind.result:
        _globalKey(key);
    }
  }

  /// Keys that open panes from anywhere.
  void _globalKey(KeyEvent key) {
    if (key.isChar('b')) {
      unawaited(bisect());
    } else if (key.isChar('l')) {
      unawaited(openLessons());
    } else if (key.isChar('a')) {
      unawaited(startAgent());
    } else if (key.isChar('t')) {
      unawaited(timelines());
    } else if (key.isChar('/')) {
      unawaited(restoreByWords());
    }
  }

  void _turnsKey(KeyEvent key) {
    final turn = state.currentTurn;
    switch (key.kind) {
      case KeyKind.up:
        if (state.selected > 0) state.selected--;
        _scheduleDetail();
      case KeyKind.down:
        if (state.selected < state.turns.length - 1) state.selected++;
        _scheduleDetail();
      case KeyKind.pageUp:
        state.selected = (state.selected - 10).clamp(0, state.turns.length);
        _scheduleDetail();
      case KeyKind.pageDown:
        state.selected = (state.selected + 10).clamp(
          0,
          state.turns.isEmpty ? 0 : state.turns.length - 1,
        );
        _scheduleDetail();
      case KeyKind.char when key.char == 's' && turn != null:
        unawaited(summarize(turn.id, force: true));
      case KeyKind.char when key.char == 'r' && turn != null:
        unawaited(restoreTurn(turn.id));
      case KeyKind.char when key.char == 'u' && turn != null:
        unawaited(redoTurn(turn));
      default:
        _globalKey(key);
    }
  }

  void _lessonsKey(KeyEvent key) {
    final pane = state.lessons;
    if (pane == null) return;
    final item = pane.current;
    switch (key.kind) {
      case KeyKind.up:
        if (pane.selected > 0) pane.selected--;
      case KeyKind.down:
        if (pane.selected < pane.items.length - 1) pane.selected++;
      case KeyKind.enter when item != null:
        state.pager = Pager('${item.draft ? 'Draft' : 'Lesson'} · ${item.id}', [
          for (final line in item.text.split('\n')) plain(line),
        ]);
      case KeyKind.char when key.char == 'y' && item != null:
        unawaited(_lessonAction('approve', item));
      case KeyKind.char when key.char == 'e' && item != null:
        unawaited(_lessonAction('edit', item));
      case KeyKind.char when key.char == 'x' && item != null:
        unawaited(_lessonAction('reject', item));
      default:
        _globalKey(key);
    }
  }

  // ---- questions ---------------------------------------------------------

  /// Shows [question] and waits for the answer (null if the TUI quits).
  Future<String?> askUser(Question question) {
    state.question = question;
    final completer = Completer<String?>();
    _answer = completer;
    redraw();
    return completer.future;
  }

  Future<bool> confirm(List<String> context, String prompt) async =>
      (await askUser(
        Question(context: context, prompt: prompt, yesNo: true),
      )) ==
      'y';

  Future<String?> askText(
    String prompt, {
    String value = '',
    List<String> context = const [],
  }) async {
    final answer = await askUser(
      Question(context: context, prompt: prompt, yesNo: false, value: value),
    );
    return answer == null || answer.trim().isEmpty ? null : answer.trim();
  }

  // ---- running Doc's commands --------------------------------------------

  /// Runs `doc <args>` in-process: output to the action's log, questions
  /// to the dialog, progress to [onProgress].
  Future<({int code, String output, String logPath})> runDocAction(
    String name,
    List<String> args, {
    void Function(Map<String, Object?> event)? onProgress,
    void Function(String line)? onLine,
    VoiceDeps? voice,
  }) async {
    final log = openLog(name);
    final sink = ActionSink(log.sink, onLine: onLine);
    log.sink.writeln('\$ doc ${args.join(' ')}');
    _busy = true;
    int code;
    try {
      code = await backend.runDoc(
        args,
        DocRunIo(
          out: sink,
          voice: voice,
          progress: (event) {
            onProgress?.call(event);
            redraw();
          },
          handOver: host.handOver,
          ask: () async {
            final q = sink.takeQuestion();
            final yesNo = RegExp(r'\[y/N\]|\[Y/n\]').hasMatch(q.prompt);
            final answer = await askUser(
              Question(
                context: q.context,
                prompt: q.prompt.trim(),
                yesNo: yesNo,
              ),
            );
            log.sink.writeln(answer ?? '');
            return answer;
          },
        ),
      );
    } on Object catch (error) {
      sink.writeln('[doc] $error');
      code = 1;
    } finally {
      _busy = false;
    }
    await log.close();
    return (code: code, output: sink.text, logPath: log.path);
  }

  void _showResult(
    String title,
    ({int code, String output, String logPath}) run,
  ) {
    final lines = const LineSplitter().convert(run.output);
    state.result = ActionResult(
      title: title,
      exitCode: run.code,
      summary: summarizeOutput(run.output),
      details: lines,
      logPath: run.logPath,
    );
    state.pane = PaneKind.result;
    redraw();
  }

  void _note(String text, [Tone tone = Tone.normal]) {
    state.note = text;
    state.noteTone = tone;
    redraw();
  }

  /// The command bar: `doc …` (or a bare Doc command), or a read-only /
  /// preview-first `dmc …` command.
  Future<void> runCommandLine(String line) async {
    final words = splitCommandLine(line);
    if (words.isEmpty) return;
    if (words.first == 'dmc') {
      await _dmcCommand(words.skip(1).toList());
      return;
    }
    final args = words.first == 'doc' ? words.skip(1).toList() : words;
    if (args.isEmpty) return;
    switch (args.first) {
      case 'ui':
        _note('You are in doc ui.');
        return;
      case 'talk' || 'hey' when !args.contains('--file'):
        await talk();
        return;
    }
    state.result = ActionResult(title: 'doc ${args.join(' ')}', running: true);
    state.pane = PaneKind.result;
    redraw();
    final run = await runDocAction(args.first, args);
    _showResult('doc ${args.join(' ')}', run);
    await refreshTurns();
  }

  Future<void> _dmcCommand(List<String> args) async {
    final refusal = dmcCommandRefusal(args);
    if (refusal != null) {
      _note(refusal, Tone.warn);
      return;
    }
    final log = openLog('dmc');
    Map<String, Object?> envelope;
    try {
      envelope = await backend.dmcJson(args);
    } on Object catch (error) {
      envelope = {
        'ok': false,
        'errors': [
          {'message': '$error'},
        ],
      };
    }
    final pretty = const JsonEncoder.withIndent('  ').convert(envelope);
    log.sink.writeln(pretty);
    await log.close();
    state.result = ActionResult(
      title: 'dmc ${args.join(' ')}',
      exitCode: envelope['ok'] == true ? 0 : 1,
      summary: [dmcEnvelopeSummary(envelope)],
      details: pretty.split('\n'),
      logPath: log.path,
    );
    state.pane = PaneKind.result;
    redraw();
  }

  // ---- turns: summary and diff -------------------------------------------

  void _scheduleDetail() {
    _summaryTimer?.cancel();
    final turn = state.currentTurn;
    if (turn == null) return;
    final detail = state.details.putIfAbsent(turn.id, TurnDetail.new);
    final cached = backend.cachedSummary(turn.id);
    if (detail.summary == null && cached != null) {
      final parsed = parseSummaryOutput(cached);
      detail
        ..summary = parsed.text
        ..summaryFooter = parsed.footer;
    }
    _summaryTimer = Timer(summaryDelay, () {
      if (state.currentTurn?.id != turn.id) return;
      unawaited(_loadDiff(turn));
      if (!turn.open && detail.summary == null) unawaited(summarize(turn.id));
    });
  }

  Future<void> _loadDiff(TuiTurn turn) async {
    final detail = state.details.putIfAbsent(turn.id, TurnDetail.new);
    if (detail.diff != null || detail.loadingDiff || turn.open) return;
    detail.loadingDiff = true;
    redraw();
    try {
      final show = await backend.show(turn.id);
      final files = [
        for (final f
            in ((show['data'] as Map?)?['files'] as List? ?? const [])
                .whereType<Map>())
          if ((f['change'] != null && f['change'] != 'unchanged') ||
              f['scope'] != null)
            (
              path: f['path'] as String,
              change: (f['scope'] ?? f['change']) as String,
            ),
      ];
      detail.diff = await backend.diff(turn.id, files) ?? '';
    } on Object catch (error) {
      detail.diffError = 'Could not read the change: $error';
    } finally {
      detail.loadingDiff = false;
    }
    redraw();
  }

  /// The plain-English summary of a turn (`doc summarize`), cached.
  Future<void> summarize(String id, {bool force = false}) async {
    final detail = state.details.putIfAbsent(id, TurnDetail.new);
    if (detail.summarizing || (detail.summary != null && !force)) return;
    detail
      ..summarizing = true
      ..summaryError = null;
    if (backend.summaryOnModal && !state.coldNoteShown) {
      state.coldNoteShown = true;
      _note(
        'Muse Glimmer may take about 2 minutes to wake up the first time.',
        Tone.dim,
      );
    }
    redraw();
    final run = await runDocAction('summarize-${shortId(id)}', [
      'summarize',
      id,
    ]);
    _logs[id] = run.logPath;
    detail.summarizing = false;
    if (run.code == 0) {
      final parsed = parseSummaryOutput(run.output);
      detail
        ..summary = parsed.text
        ..summaryFooter = parsed.footer;
      backend.saveSummary(id, parsed.text, parsed.footer);
    } else {
      detail.summaryError = 'No summary (o shows why).';
    }
    redraw();
  }

  // ---- restore / redo -----------------------------------------------------

  Future<void> restoreTurn(String id) async {
    _note('Restore ${shortId(id)}: dmc preview…', Tone.warn);
    final run = await runDocAction('restore-${shortId(id)}', ['restore', id]);
    _logs[id] = run.logPath;
    final summary = summarizeOutput(run.output, max: 1);
    _note(
      summary.isEmpty ? 'Restore finished.' : summary.single,
      run.code == 0 ? Tone.good : Tone.bad,
    );
    state.pane = PaneKind.turns;
    await refreshTurns();
  }

  /// `/`: natural-language restore.
  Future<void> restoreByWords([String? request]) async {
    request ??= await askText('Go back to before… (in your own words)');
    if (request == null) return;
    final run = await runDocAction('restore-words', ['restore', request]);
    final summary = summarizeOutput(run.output, max: 1);
    _note(
      summary.isEmpty ? 'Nothing was changed.' : summary.single,
      run.code == 0 ? Tone.good : Tone.bad,
    );
    _logs['restore-words'] = run.logPath;
    state.pane = PaneKind.turns;
    await refreshTurns();
  }

  /// `u`: redo an undone turn through dmc's preview, then y.
  Future<void> redoTurn(TuiTurn turn) async {
    if (!turn.undone) {
      _note('${shortId(turn.id)} is not undone; nothing to redo.', Tone.dim);
      return;
    }
    final preview = await backend.dmcJson(['checkpoint', 'redo', turn.id]);
    final actions = ((preview['data'] as Map?)?['actions'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final conflicts =
        ((preview['data'] as Map?)?['conflicts'] as List? ?? const [])
            .whereType<Map>()
            .toList();
    if (preview['ok'] != true || conflicts.isNotEmpty) {
      final why = [
        for (final c in conflicts) '${c['path']}: ${c['message'] ?? c['code']}',
        for (final e
            in (preview['errors'] as List? ?? const []).whereType<Map>())
          '${e['message'] ?? e['code']}',
      ];
      _note(
        'dmc will not redo ${shortId(turn.id)}: ${why.isEmpty ? 'see o' : why.first}',
        Tone.bad,
      );
      return;
    }
    final yes = await confirm([
      'Redo ${shortId(turn.id)} (${turn.who}): ${screenLabel(turn.label)}',
      for (final a in actions) '  ${a['path']}: put back the turn\'s version',
    ], 'Redo this turn (${actions.length} file(s))? [y/N]');
    if (!yes) {
      _note('Nothing was changed.', Tone.dim);
      return;
    }
    final applied = await backend.dmcJson([
      'checkpoint',
      'redo',
      turn.id,
      '--apply',
    ]);
    _note(
      applied['ok'] == true
          ? 'Redone: ${shortId(turn.id)} is back.'
          : 'dmc could not redo it: ${dmcEnvelopeSummary(applied)}',
      applied['ok'] == true ? Tone.good : Tone.bad,
    );
    await refreshTurns();
  }

  // ---- bisect -------------------------------------------------------------

  Future<void> bisect() async {
    final test = await askText(
      'Test command (run in each turn\'s files):',
      value: backend.defaultTest() ?? '',
    );
    if (test == null) {
      _note('Bisect needs a test command; nothing ran.', Tone.dim);
      return;
    }
    final setupAnswer = await askUser(
      Question(
        context: const [
          'Dependencies are not in dmc\'s exports; a setup command installs them in each probe.',
        ],
        prompt: 'Setup command (Enter to accept, delete it for none):',
        yesNo: false,
        value: backend.defaultSetup() ?? '',
      ),
    );
    if (setupAnswer == null) return;
    final setup = setupAnswer.trim().isEmpty ? null : setupAnswer.trim();
    final candidates = [
      for (final turn in state.turns.reversed)
        if (turn.agent != null && turn.status == 'closed') turn,
    ];
    final strip = [
      if (candidates.isNotEmpty)
        BisectStripPoint(
          candidates.first.id,
          'before',
          'before the first turn',
        ),
      for (final turn in candidates)
        BisectStripPoint(turn.id, 'after', screenLabel(turn.label)),
    ];
    final pane = BisectPane(test, setup, strip);
    state.bisect = pane;
    state.pane = PaneKind.bisect;
    redraw();
    final run = await runDocAction(
      'bisect',
      [
        'bisect',
        '--test',
        test,
        if (setup != null) ...['--setup', setup],
        '--json',
      ],
      onProgress: (event) {
        if (event['type'] != 'bisect.probe') return;
        for (final point in pane.strip) {
          if (point.checkpoint == event['checkpoint'] &&
              point.state == event['state']) {
            point.cell = event['passed'] == true
                ? ProbeCell.pass
                : ProbeCell.fail;
          }
        }
      },
    );
    pane
      ..running = false
      ..logPath = run.logPath;
    for (final point in pane.strip) {
      if (point.cell == ProbeCell.waiting) point.cell = ProbeCell.notNeeded;
    }
    _fillBisect(pane, run.output, candidates);
    redraw();
    if (pane.found && pane.firstBad != null) {
      final yes = await confirm(
        const [],
        'Restore to before this turn? It undoes ${shortId(pane.firstBad!)} through dmc. [y/N]',
      );
      if (yes) await restoreTurn(pane.firstBad!);
    }
    await refreshTurns();
  }

  void _fillBisect(BisectPane pane, String output, List<TuiTurn> candidates) {
    Map? envelope;
    for (final line in output.split('\n').reversed) {
      if (line.trimLeft().startsWith('{')) {
        try {
          envelope = jsonDecode(line) as Map;
          break;
        } on FormatException {
          continue;
        }
      }
    }
    final result = envelope?['result'] as Map?;
    if (envelope == null || result == null) {
      final lines = summarizeOutput(output, max: 1);
      pane.headline = lines.isEmpty
          ? 'Bisect stopped (o shows why).'
          : lines.single;
      return;
    }
    if (result['status'] != 'found') {
      pane.headline = '${result['message']}';
      pane.failure = failureEssentials('${result['failingOutputTail'] ?? ''}');
      return;
    }
    final bad = result['firstBad'] as Map;
    final id = bad['id'] as String;
    final index = candidates.indexWhere((t) => t.id == id);
    pane
      ..found = true
      ..firstBad = id
      ..headline =
          'Turn ${index + 1} broke the tests: ${screenLabel(bad['label'] as String?)}'
      ..files = [
        for (final f
            in (bad['changedFiles'] as List? ?? const []).whereType<Map>())
          '${f['path']}',
      ]
      ..failure = failureEssentials('${result['failingOutputTail'] ?? ''}')
      ..explanation = envelope['explanation'] as String?;
    state.firstBad = id;
  }

  // ---- voice --------------------------------------------------------------

  /// Space: push-to-talk, exactly `doc talk`; only the terminal differs.
  Future<void> talk() async {
    if (_talkKeys != null || _busy) return;
    final keys = StreamController<TalkKey>();
    _talkKeys = keys;
    final terminal = _TuiTalkTerminal(keys.stream, alreadyPressed: true);
    _talkTerminal = terminal;
    state.voice
      ..state = 'recording'
      ..text = '';
    if (!state.coldNoteShown) {
      state.note = null;
    }
    redraw();
    String? routed;
    final run = await runDocAction(
      'talk',
      ['talk'],
      voice: VoiceDeps(terminal: terminal, watchInterrupts: false),
      onLine: (line) {
        final text = line.trim();
        if (text.startsWith('… ')) {
          state.voice
            ..state = 'recording'
            ..text = text.substring(2);
        } else if (text.startsWith('(') && state.voice.state == 'recording') {
          state.voice
            ..state = 'thinking'
            ..text = 'Working out what you meant…';
        } else if (text.startsWith('I heard: ')) {
          final match = RegExp(r"I'll run: doc (\S+)").firstMatch(text);
          routed = match?[1];
          state.voice
            ..state = 'thinking'
            ..text = text;
        }
        redraw();
      },
    );
    _talkKeys = null;
    _talkTerminal = null;
    // Not awaited: the talk terminal's reader may be paused, and close()
    // would wait for it forever.
    unawaited(keys.close());
    state.voice
      ..state = 'idle'
      ..text = '';
    // The matching pane, with the result.
    switch (routed) {
      case 'bisect':
        final last = backend.lastBisect();
        if (last != null) {
          final pane = BisectPane(
            '${last['test']}',
            last['setup'] as String?,
            const [],
          );
          _fillBisect(
            pane,
            jsonEncode({'result': last, 'explanation': last['explanation']}),
            [
              for (final turn in state.turns.reversed)
                if (turn.agent != null && turn.status == 'closed') turn,
            ],
          );
          pane
            ..running = false
            ..logPath = run.logPath;
          state.bisect = pane;
          state.pane = PaneKind.bisect;
        }
      case 'summarize':
        await refreshTurns();
        _summaryFromTalk(run.output);
      case 'lessons' || 'lesson':
        await openLessons();
      case 'status':
        state.pane = PaneKind.turns;
        final after = run.output
            .split(RegExp(r'Run it\? \[y/N\][^\n]*\n'))
            .last;
        final first = after
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .firstOrNull;
        if (first != null) _note(first.trim(), Tone.good);
      case 'restore':
        state.pane = PaneKind.turns;
        final summary = summarizeOutput(run.output, max: 1);
        if (summary.isNotEmpty) {
          _note(summary.single, run.code == 0 ? Tone.good : Tone.bad);
        }
      case null:
        final summary = summarizeOutput(run.output, max: 1);
        if (summary.isNotEmpty) {
          _note(summary.single, run.code == 0 ? Tone.normal : Tone.warn);
        }
      default:
        _showResult('doc $routed (by voice)', run);
    }
    _logs['talk'] = run.logPath;
    await refreshTurns();
  }

  void _summaryFromTalk(String output) {
    final id = RegExp(r"I'll run: doc summarize (\S+)").firstMatch(output)?[1];
    if (id == null) return;
    final index = state.turns.indexWhere((t) => t.id == id);
    if (index >= 0) state.selected = index;
    final after = output.split(RegExp(r'Run it\? \[y/N\][^\n]*\n')).last;
    final parsed = parseSummaryOutput(after);
    if (parsed.text.isNotEmpty) {
      state.details.putIfAbsent(id, TurnDetail.new)
        ..summary = parsed.text
        ..summaryFooter = parsed.footer;
      backend.saveSummary(id, parsed.text, parsed.footer);
    }
    state.pane = PaneKind.turns;
  }

  // ---- lessons and agents -------------------------------------------------

  Future<void> openLessons() async {
    final items = await backend.lessons();
    final previous = state.lessons?.current?.id;
    final pane = LessonsPane(items);
    final index = items.indexWhere((i) => i.id == previous);
    if (index >= 0) pane.selected = index;
    state.lessons = pane;
    state.pane = PaneKind.lessons;
    redraw();
  }

  Future<void> _lessonAction(String action, LessonItem item) async {
    if (action != 'edit' && !item.draft) {
      _note('${item.id} is already in the library.', Tone.dim);
      return;
    }
    if (action == 'reject' &&
        !await confirm([
          'Delete the draft ${item.id}: ${item.title}',
        ], 'Reject this draft? [y/N]')) {
      return;
    }
    if (action == 'edit' && !item.draft) {
      _note(
        'Only drafts are edited here; approved lessons live in the library.',
        Tone.dim,
      );
      return;
    }
    final run = await runDocAction('lesson-$action', [
      'lesson',
      action,
      item.id,
    ]);
    await openLessons();
    final lines = summarizeOutput(run.output.replaceAll('[doc] ', ''), max: 3);
    state.lessons!
      ..message = lines.isEmpty
          ? (run.code == 0 ? 'Done.' : 'Failed (o).')
          : lines.join('\n')
      ..messageTone = run.code == 0 ? Tone.good : Tone.bad;
    _logs['lessons'] = run.logPath;
    redraw();
  }

  /// `a`: start an agent with the matching lessons, like `doc start`.
  Future<void> startAgent() async {
    final agent = await askText(
      'Agent (muse-code or claude-code):',
      value: 'muse-code',
    );
    if (agent == null) return;
    if (agent != 'muse-code' && agent != 'claude-code') {
      _note('Doc starts muse-code or claude-code.', Tone.warn);
      return;
    }
    final task = await askText('Task for $agent:');
    if (task == null) return;
    final turnFiles = state.currentTurn == null
        ? const <String>[]
        : [
            for (final f
                in state.details[state.currentTurn!.id]?.files ??
                    const <FileChange>[])
              f.path,
          ];
    final files = await askUser(
      Question(
        context: const [
          'Lessons are matched on these files (and paths in the task).',
        ],
        prompt: 'Files (comma-separated, Enter to accept):',
        yesNo: false,
        value: turnFiles.join(', '),
      ),
    );
    if (files == null) return;
    final run = await runDocAction('start', [
      'start',
      agent,
      task,
      for (final f
          in files
              .split(',')
              .map((f) => f.trim())
              .where((f) => f.isNotEmpty)) ...['--files', f],
    ]);
    final summary = summarizeOutput(run.output, max: 1);
    _note(
      summary.isEmpty ? '$agent exited.' : summary.single,
      run.code == 0 ? Tone.normal : Tone.warn,
    );
    _logs['start'] = run.logPath;
    state.pane = PaneKind.turns;
    await refreshTurns();
  }

  /// `t`: `doc timelines` in the result pane (lanes come later).
  Future<void> timelines() async {
    final task = await askText(
      'Task for the timelines (three agents, three approaches):',
      value: 'fix the failing tests without changing the tests',
    );
    if (task == null) return;
    final last = backend.lastBisect();
    final args = <String>['timelines', task];
    if (last != null) {
      args.add('--from-bisect');
    } else {
      final test = await askText(
        'Test command:',
        value: backend.defaultTest() ?? '',
      );
      if (test == null) return;
      args.addAll(['--test', test]);
    }
    state.result = ActionResult(title: 'doc timelines', running: true);
    state.pane = PaneKind.result;
    redraw();
    final run = await runDocAction('timelines', args);
    _showResult('doc timelines', run);
  }

  // ---- details and logs ---------------------------------------------------

  void _openDetails() {
    switch (state.pane) {
      case PaneKind.turns:
        final turn = state.currentTurn;
        final lines = <Line>[];
        if (state.header.problems.isNotEmpty) {
          lines.add(plain('Setup', Tone.strong));
          for (final p in state.header.problems) {
            lines.add(
              plain(
                '${p.level == DoctorLevel.fail ? 'FAIL' : 'warn'}  ${p.text}',
                p.level == DoctorLevel.fail ? Tone.bad : Tone.warn,
              ),
            );
            if (p.fix != null) {
              lines.add(plain('      Fix: ${p.fix}', Tone.dim));
            }
          }
          lines.add(const []);
        }
        if (turn != null) {
          final detail = state.details[turn.id];
          lines
            ..add(plain('Turn ${turn.id}', Tone.strong))
            ..add(
              plain(
                '${turn.who} · ${turn.status} · created ${DateTime.fromMillisecondsSinceEpoch(turn.createdAt).toIso8601String()}'
                '${turn.closedAt == null ? '' : ' · closed ${DateTime.fromMillisecondsSinceEpoch(turn.closedAt!).toIso8601String()}'}',
                Tone.dim,
              ),
            )
            ..add(
              plain(
                'Prompt: ${turn.label ?? '(none)'}${(turn.label ?? '').endsWith('…') ? ' (truncated by dmc)' : ''}',
              ),
            );
          if (detail?.summary != null) {
            lines
              ..add(const [])
              ..add(plain(detail!.summary!));
            if (detail.summaryFooter != null) {
              lines.add(plain(detail.summaryFooter!, Tone.dim));
            }
          }
          if (detail?.diff != null) {
            lines.add(const []);
            for (final line in detail!.diff!.split('\n')) {
              lines.add(diffLine(line));
            }
          }
        }
        state.pager = Pager('Details', lines);
      case PaneKind.result:
        final result = state.result;
        if (result != null) {
          state.pager = Pager(result.title, [
            for (final l in result.details) diffLineOrPlain(l),
          ]);
        }
      case PaneKind.bisect:
        final pane = state.bisect;
        if (pane != null) {
          state.pager = Pager('Bisect details', [
            plain('Test: ${pane.test}'),
            plain('Setup: ${pane.setup ?? '(none)'}'),
            if (pane.firstBad != null)
              plain('First bad turn: ${pane.firstBad}'),
            for (final point in pane.strip)
              plain(
                '${point.state} ${point.checkpoint}: ${point.cell.text}  ${point.label}',
                point.cell.tone,
              ),
            if (pane.explanation != null) ...[
              const [],
              plain(pane.explanation!),
            ],
          ]);
        }
      case PaneKind.lessons:
        final item = state.lessons?.current;
        if (item != null) {
          state.pager = Pager(item.id, [
            for (final line in item.text.split('\n')) plain(line),
          ]);
        }
    }
  }

  void _openLog() {
    final path = switch (state.pane) {
      PaneKind.turns =>
        _logs[state.currentTurn?.id] ?? _logs['restore-words'] ?? _logs['talk'],
      PaneKind.result => state.result?.logPath,
      PaneKind.bisect => state.bisect?.logPath,
      PaneKind.lessons => _logs['lessons'],
    };
    if (path == null) {
      _note('No log for this item yet.', Tone.dim);
      return;
    }
    final text = readLogFile(path);
    state.pager = Pager('Log · $path', [
      for (final line in text.split('\n')) diffLineOrPlain(line),
    ]);
  }

  /// Reads a log (tests replace it).
  String Function(String path) readLogFile = (path) {
    try {
      return File(path).readAsStringSync();
    } on FileSystemException catch (error) {
      return 'Cannot read the log: ${error.message}';
    }
  };
}

/// A talk terminal over the TUI's key stream: raw mode is the TUI's
/// already; the first key (the Space that started it) is given.
class _TuiTalkTerminal implements TalkTerminal {
  final StreamIterator<TalkKey> _keys;
  bool _first;

  /// Whether the voice turn is waiting for a key now; other keys go to
  /// the TUI.
  bool waiting = false;

  _TuiTalkTerminal(Stream<TalkKey> keys, {required bool alreadyPressed})
    : _keys = StreamIterator(keys),
      _first = alreadyPressed;

  @override
  bool get hasTerminal => true;

  @override
  void enterRaw() {}

  @override
  void restore() {}

  @override
  Future<TalkKey> readKey() async {
    if (_first) {
      _first = false;
      return TalkKey.toggle;
    }
    waiting = true;
    try {
      return await _keys.moveNext() ? _keys.current : TalkKey.cancel;
    } finally {
      waiting = false;
    }
  }
}

/// Words of a command line, with "…" and '…' quoting.
List<String> splitCommandLine(String line) {
  final words = <String>[];
  final current = StringBuffer();
  String? quote;
  var inWord = false;
  for (final char in line.split('')) {
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        current.write(char);
      }
    } else if (char == '"' || char == "'") {
      quote = char;
      inWord = true;
    } else if (char.trim().isEmpty) {
      if (inWord) {
        words.add(current.toString());
        current.clear();
        inWord = false;
      }
    } else {
      current.write(char);
      inWord = true;
    }
  }
  if (inWord) words.add(current.toString());
  return words;
}

/// Why the command bar will not run a dmc command, or null. Allowed:
/// read-only commands, and restore/redo/disable previews (never
/// `--apply`: restores go through Doc's own flow).
String? dmcCommandRefusal(List<String> args) {
  if (args.isEmpty) return 'dmc what? For example: dmc checkpoint list';
  if (args.contains('--apply')) {
    return 'The command bar runs dmc previews only. Restore with r or /, redo with u.';
  }
  final first = args.first;
  final second = args.length > 1 ? args[1] : '';
  final allowed =
      const {
        'status',
        'doctor',
        'capabilities',
        'disable',
        'version',
      }.contains(first) ||
      (first == 'checkpoint' &&
          const {'list', 'show', 'diff', 'restore', 'redo'}.contains(second)) ||
      (first == 'hooks' && second == 'status');
  return allowed
      ? null
      : 'The command bar runs read-only or preview dmc commands: status, doctor, capabilities, disable (preview), hooks status, checkpoint list|show|diff|restore|redo (previews).';
}

/// One line for a dmc JSON envelope.
String dmcEnvelopeSummary(Map<String, Object?> envelope) {
  if (envelope['ok'] != true) {
    final errors = (envelope['errors'] as List? ?? const []).whereType<Map>();
    return 'failed: ${errors.map((e) => e['message'] ?? e['code']).join('; ')}';
  }
  final data = envelope['data'];
  if (data is Map) {
    final parts = <String>[];
    for (final entry in data.entries) {
      final value = entry.value;
      if (value is List) parts.add('${value.length} ${entry.key}');
    }
    if (parts.isNotEmpty) return 'ok: ${parts.join(', ')} (d for everything)';
  }
  return 'ok (d for everything)';
}

/// Every CLI command and how the TUI reaches it (the coverage test checks
/// this against [docUsage]).
const Map<String, String> tuiCommandCoverage = {
  'models': 'command bar',
  'summarize': 's on a turn (and automatically after 300 ms)',
  'usage': 'command bar',
  'status': 'the turns list (and the command bar)',
  'doctor': 'the header (and the command bar)',
  'timelines': 't (and the command bar)',
  'talk': 'Space',
  'hey': 'Space',
  'bisect': 'b',
  'restore': 'r on a turn, / for words',
  'lesson': 'l (approve y, edit e, reject x; the rest in the command bar)',
  'lessons': 'l',
  'start': 'a',
  'ui': 'this screen',
};
