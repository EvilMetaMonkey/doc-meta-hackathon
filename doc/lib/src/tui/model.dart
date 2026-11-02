/// The TUI's state: what is on screen. Plain data plus pure helpers that
/// build it from dmc's JSON and from Doc's command output.
library;

import '../doctor_command.dart';
import 'text.dart';

/// One checkpoint in the turns list, from `dmc checkpoint list --json`.
class TuiTurn {
  final String id;

  /// dmc's status: `closed`, `open`, `creating`, `closing`, `invalid`, …
  final String status;
  final String? agent;
  final String source;
  final String? label;
  final int createdAt;
  final int? closedAt;

  /// Its latest completed operation is a restore no later redo reapplied.
  final bool undone;

  const TuiTurn({
    required this.id,
    required this.status,
    required this.agent,
    required this.source,
    required this.label,
    required this.createdAt,
    required this.closedAt,
    required this.undone,
  });

  factory TuiTurn.fromDmc(Map item) {
    final agent = item['agent'];
    final operations =
        [
          for (final o
              in (item['operations'] as List? ?? const []).whereType<Map>())
            if (o['status'] == 'completed') o,
        ]..sort(
          (a, b) => ((a['completedAt'] as num?) ?? 0).compareTo(
            (b['completedAt'] as num?) ?? 0,
          ),
        );
    return TuiTurn(
      id: item['id'] as String,
      status: item['status'] as String? ?? 'closed',
      agent: agent is Map ? agent['name'] as String? : null,
      source: item['source'] as String? ?? 'manual',
      label: item['label'] as String?,
      createdAt: (item['createdAt'] as num).toInt(),
      closedAt: (item['closedAt'] as num?)?.toInt(),
      undone:
          operations.isNotEmpty && operations.last['direction'] == 'restore',
    );
  }

  /// `claude`, `muse`, or the source for manual checkpoints.
  String get who => switch (agent ?? source) {
    'claude-code' => 'claude',
    'muse-code' => 'muse',
    final other => other,
  };

  bool get open => const {'open', 'creating', 'closing'}.contains(status);

  DateTime get time =>
      DateTime.fromMillisecondsSinceEpoch(closedAt ?? createdAt);
}

/// Turns newest first (dmc's list order is not guaranteed).
List<TuiTurn> turnsFromList(Map<String, Object?> listed) {
  final items =
      ((listed['data'] as Map?)?['checkpoints'] as List? ?? const [])
          .whereType<Map>()
          .map(TuiTurn.fromDmc)
          .toList()
        ..sort((a, b) {
          final byTime = b.createdAt.compareTo(a.createdAt);
          return byTime != 0 ? byTime : b.id.compareTo(a.id);
        });
  return items;
}

enum TurnGlyph {
  /// ● a closed turn.
  ok('●', Tone.good),

  /// ✗ the first bad turn from the last bisect.
  broke('✗', Tone.bad),

  /// ↺ undone by a restore.
  undone('↺', Tone.dim),

  /// ○ still open.
  open('○', Tone.warn);

  final String symbol;
  final Tone tone;
  const TurnGlyph(this.symbol, this.tone);
}

TurnGlyph glyphFor(TuiTurn turn, {String? firstBad}) {
  if (turn.open) return TurnGlyph.open;
  if (turn.undone) return TurnGlyph.undone;
  if (turn.id == firstBad) return TurnGlyph.broke;
  return TurnGlyph.ok;
}

/// One changed file with its line counts.
class FileChange {
  final String path;
  final String change;
  final int added;
  final int removed;

  const FileChange(this.path, this.change, this.added, this.removed);
}

/// The files and +/− counts in an [abandonedDiff]-style text (`--- path
/// (change)` headers, then `+`/`-`/` ` lines).
List<FileChange> filesFromDiff(String diff) {
  final files = <FileChange>[];
  String? path;
  String change = '';
  var added = 0;
  var removed = 0;
  void flush() {
    if (path != null) files.add(FileChange(path, change, added, removed));
  }

  final header = RegExp(r'^--- (.+) \(([^)]+)\)$');
  for (final line in diff.split('\n')) {
    final match = header.firstMatch(line);
    if (match != null) {
      flush();
      path = match[1];
      change = match[2]!;
      added = 0;
      removed = 0;
    } else if (line.startsWith('+') && !line.startsWith('+++')) {
      added++;
    } else if (line.startsWith('-') && !line.startsWith('---')) {
      removed++;
    }
  }
  flush();
  return files;
}

/// A diff line coloured: red `-`, green `+`, dim headers and context.
Line diffLine(String line) {
  if (line.startsWith('--- ') || line.startsWith('@@')) {
    return plain(line, Tone.dim);
  }
  if (line.startsWith('+')) return plain(line, Tone.good);
  if (line.startsWith('-')) return plain(line, Tone.bad);
  return plain(line, Tone.dim);
}

/// What the detail pane knows about one turn.
class TurnDetail {
  String? summary;

  /// The model/tokens/cost line (shown under `d`).
  String? summaryFooter;
  bool summarizing = false;
  String? summaryError;
  String? diff;
  bool loadingDiff = false;
  String? diffError;

  TurnDetail();

  List<FileChange> get files => diff == null ? const [] : filesFromDiff(diff!);
}

/// The summary text and its footer from `doc summarize` output: the
/// answer, a blank line, then "(provider model; … )".
({String text, String? footer}) parseSummaryOutput(String output) {
  final lines = output.trimRight().split('\n');
  String? footer;
  if (lines.isNotEmpty &&
      lines.last.startsWith('(') &&
      lines.last.endsWith(')')) {
    footer = lines.removeLast();
  }
  return (text: lines.join('\n').trim(), footer: footer);
}

/// Header facts, from the same checks as `doc doctor` (no model calls).
class HeaderStatus {
  final String workspaceName;
  final bool loaded;
  final bool? dmcOk;
  final String? dmcVersion;

  /// `claude` / `muse` → installed (null: not checked).
  final Map<String, bool?> hooks;

  /// Every doctor line that is not ok, with its fix (under `d`).
  final List<DoctorLine> problems;

  const HeaderStatus({
    required this.workspaceName,
    this.loaded = false,
    this.dmcOk,
    this.dmcVersion,
    this.hooks = const {},
    this.problems = const [],
  });

  /// From the doctor's lines (see [doctorChecks]).
  factory HeaderStatus.fromDoctor(
    String workspaceName,
    List<DoctorLine> lines,
  ) {
    bool? hook(String name) {
      for (final line in lines) {
        if (line.text.startsWith('Hooks ($name')) {
          return line.level == DoctorLevel.ok;
        }
      }
      return null;
    }

    final dmcLine = lines.where((l) => l.text.startsWith('dmc')).firstOrNull;
    final version = dmcLine == null
        ? null
        : RegExp(r'\(dmc ([^) ]+)').firstMatch(dmcLine.text)?[1];
    return HeaderStatus(
      workspaceName: workspaceName,
      loaded: true,
      dmcOk: dmcLine == null ? null : dmcLine.level == DoctorLevel.ok,
      dmcVersion: version,
      hooks: {'claude': hook('Claude Code'), 'muse': hook('Muse Code')},
      problems: [
        for (final line in lines)
          if (line.level != DoctorLevel.ok) line,
      ],
    );
  }
}

/// A command's result, shown with the noise rules: a summary line or two,
/// details under `d`, the raw log under `o`.
class ActionResult {
  final String title;
  final bool running;
  final int? exitCode;
  final List<String> summary;

  /// The full output (for `d`).
  final List<String> details;
  final String? logPath;

  const ActionResult({
    required this.title,
    this.running = false,
    this.exitCode,
    this.summary = const [],
    this.details = const [],
    this.logPath,
  });

  bool get failed => exitCode != null && exitCode != 0;
}

/// The one or two lines of a command's output worth showing: Doc's own
/// result lines, never progress, probe, setup or model-footer lines.
List<String> summarizeOutput(String output, {int max = 2}) {
  final keep = <String>[];
  for (final raw in output.split('\n')) {
    final line = raw.trimRight();
    final text = line.trim();
    if (text.isEmpty) continue;
    if (text.startsWith('[probe ') ||
        text.startsWith('… ') ||
        text.startsWith('|') ||
        text.startsWith('(') && text.endsWith(')') ||
        text.startsWith('[doc] ')) {
      continue;
    }
    keep.add(text);
  }
  // The end of a command's output says what happened.
  return keep.length <= max ? keep : keep.sublist(keep.length - max);
}

/// Probe states in the bisect strip.
enum ProbeCell {
  waiting('…', Tone.dim),
  notNeeded('not needed', Tone.dim),
  pass('PASS', Tone.good),
  fail('FAIL', Tone.bad);

  final String text;
  final Tone tone;
  const ProbeCell(this.text, this.tone);
}

/// One point in the bisect strip: a turn's after-state (and the first
/// turn's before-state).
class BisectStripPoint {
  final String checkpoint;
  final String state;
  final String label;
  ProbeCell cell = ProbeCell.waiting;

  BisectStripPoint(this.checkpoint, this.state, this.label);
}

class BisectPane {
  final String test;
  final String? setup;
  final List<BisectStripPoint> strip;
  bool running = true;

  /// "Turn 2 broke the tests: <label>", or why nothing was found.
  String? headline;
  bool found = false;
  String? firstBad;
  List<String> files = const [];

  /// The failing test's name and its expected / actual lines only.
  List<String> failure = const [];
  String? explanation;
  String? modelLine;
  String? logPath;

  BisectPane(this.test, this.setup, this.strip);
}

/// A failing test's name and its expected/actual lines, without setup or
/// runner noise. Understands unittest/pytest tracebacks, `flutter test`
/// and `dart test` output; falls back to the last error line.
List<String> failureEssentials(String tail, {int max = 6}) {
  final lines = tail.split('\n').map((l) => l.trimRight()).toList();
  final keep = <String>[];
  for (final line in lines) {
    final text = line.trim();
    if (text.isEmpty) continue;
    final isName = RegExp(
      r'^(FAIL|ERROR): |^\d\d:\d\d \+\d+.*-\d+: |^✗ |^FAILED ',
    ).hasMatch(text);
    final isExpectation = RegExp(
      r'^(Expected|Actual|Which):|^AssertionError|^[A-Za-z]*Error: |^E\s+',
    ).hasMatch(text);
    if (isName || isExpectation) keep.add(text);
  }
  if (keep.isEmpty) {
    final last = lines.lastWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    if (last.isNotEmpty) keep.add(last.trim());
  }
  final seen = <String>{};
  return [
    for (final line in keep)
      if (seen.add(line)) line,
  ].take(max).toList();
}

/// One lesson in the lessons pane.
class LessonItem {
  final String id;
  final String title;
  final List<String> files;
  final bool draft;
  final String text;

  const LessonItem({
    required this.id,
    required this.title,
    required this.files,
    required this.draft,
    required this.text,
  });
}

class LessonsPane {
  List<LessonItem> items;
  int selected = 0;
  String? message;
  Tone messageTone = Tone.normal;

  LessonsPane(this.items);

  LessonItem? get current =>
      items.isEmpty ? null : items[selected.clamp(0, items.length - 1)];
}

enum PaneKind { turns, result, bisect, lessons }

/// A question from a command: the lines that led up to it, then one line.
class Question {
  /// What will change (the command's last output lines before asking).
  final List<String> context;
  final String prompt;

  /// `[y/N]` questions take y/n; others take a line of text.
  final bool yesNo;
  String value;

  Question({
    required this.context,
    required this.prompt,
    required this.yesNo,
    this.value = '',
  });
}

/// A scrollable text overlay: details (`d`), a log (`o`), a lesson, help.
class Pager {
  final String title;
  final List<Line> lines;
  int offset = 0;

  Pager(this.title, this.lines);
}

/// The bottom bar's voice line.
class VoiceBar {
  /// `idle`, `recording`, `thinking`.
  String state = 'idle';
  String text = '';

  VoiceBar();
}

class TuiState {
  HeaderStatus header;
  List<TuiTurn> turns = const [];
  bool turnsLoaded = false;

  /// Why there are no turns (no workspace, dmc missing), with the fix.
  List<String>? emptyReason;
  int selected = 0;
  String? firstBad;
  final Map<String, TurnDetail> details = {};

  PaneKind pane = PaneKind.turns;
  ActionResult? result;
  BisectPane? bisect;
  LessonsPane? lessons;

  Question? question;
  Pager? pager;
  bool help = false;
  bool splash = false;
  String? dmcVersionForSplash;

  /// The command bar (`:`), when open.
  String? command;
  final VoiceBar voice = VoiceBar();

  /// A one-line note in the bar (what just happened).
  String? note;
  Tone noteTone = Tone.normal;

  /// Said once: Glimmer may need two minutes to wake up.
  bool coldNoteShown = false;

  TuiState(this.header);

  TuiTurn? get currentTurn =>
      turns.isEmpty ? null : turns[selected.clamp(0, turns.length - 1)];
}
