import 'dart:convert';
import 'dart:io';

import 'package:dmc_doc/doc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_tui.dart';

const _readme = 'cp_mvyyf4t6_d78c1ed9acf8457c62a577cd9a57e707';
const _docs = 'cp_mvyyd2k1_aaaa0000';
const _bug = 'cp_mvyya1b2_bbbb1111';
const _price = 'cp_mvyy9z9z_cccc2222';

List<Map<String, Object?>> demoTurns() => [
  turnJson(
    _readme,
    400,
    agent: 'muse-code',
    label:
        'In README.md, add a short Usage section with one example call of checkout_total.',
  ),
  turnJson(
    _docs,
    300,
    label:
        'Add a short docstring to cart_subtotal and checkout_total in checkout.py.',
  ),
  turnJson(
    _bug,
    200,
    agent: 'muse-code',
    label:
        'In money.py, change apply_discount to take the discount as a fraction between 0 and 1 (0.25 for 25%…',
  ),
  turnJson(
    _price,
    100,
    label: 'Add a function format_price(amount) to money.py',
    undone: true,
  ),
];

/// A fake `doc` that prints [lines], then asks [question] (if any) and
/// records the answer.
Future<int> Function(List<String>, DocRunIo) script(
  List<String> lines, {
  String? question,
  List<String> after = const [],
  List<String?>? answers,
}) => (args, io) async {
  for (final line in lines) {
    io.out.writeln(line);
  }
  if (question != null) {
    io.out.write(question);
    final answer = await io.ask();
    answers?.add(answer);
  }
  for (final line in after) {
    io.out.writeln(line);
  }
  return 0;
};

void main() {
  group('keys', () {
    test('arrows, Enter, Esc, Space, letters and UTF-8', () {
      expect(decodeKeys([0x1b, 0x5b, 0x41, 0x1b, 0x5b, 0x42]), [
        const KeyEvent(KeyKind.up),
        const KeyEvent(KeyKind.down),
      ]);
      expect(decodeKeys([0x1b]), [const KeyEvent(KeyKind.escape)]);
      expect(decodeKeys([0x0d, 0x0a]), [const KeyEvent(KeyKind.enter)]);
      expect(decodeKeys([0x20, 0x73]), [
        const KeyEvent(KeyKind.space),
        const KeyEvent.char('s'),
      ]);
      expect(decodeKeys([0x1b, 0x5b, 0x35, 0x7e]), [
        const KeyEvent(KeyKind.pageUp),
      ]);
      expect(decodeKeys([0x7f, 0x03]), [
        const KeyEvent(KeyKind.backspace),
        const KeyEvent(KeyKind.ctrlC),
      ]);
      expect(decodeKeys(utf8.encode('é')), [const KeyEvent.char('é')]);
      // ESC then a letter (Alt+x) is Esc, then x.
      expect(decodeKeys([0x1b, 0x78]), [
        const KeyEvent(KeyKind.escape),
        const KeyEvent.char('x'),
      ]);
    });
  });

  group('text', () {
    test('widths, fitting and short ids', () {
      expect(displayWidth('abc'), 3);
      expect(displayWidth('■ ✓ ✗ ● ↺ ○ ▶'), 13);
      expect(displayWidth('日本'), 4);
      expect(displayWidth('🎙'), 2);
      expect(fit('In money.py, change apply_discount', 12), 'In money.py…');
      expect(displayWidth(pad('日本語', 5)), 5);
      expect(shortId(_readme), 'cp_mvyyf4t6');
      expect(screenLabel('Rewrite it…'), 'Rewrite it…');
      expect(wrap('one two three four', 9), ['one two', 'three', 'four']);
    });

    test('colour: auto, always, never and NO_COLOR', () {
      expect(useColor(null, const {}, tty: true), isTrue);
      expect(useColor('auto', const {'NO_COLOR': '1'}, tty: true), isFalse);
      expect(useColor('auto', const {}, tty: false), isFalse);
      expect(useColor('always', const {'NO_COLOR': '1'}, tty: false), isTrue);
      expect(useColor('never', const {}, tty: true), isFalse);
      expect(
        renderLine([
          const Span('PASS', Tone.good),
          const Span(' x'),
        ], color: true),
        '\x1b[32mPASS\x1b[0m x',
      );
      expect(renderLine([const Span('PASS', Tone.good)], color: false), 'PASS');
    });
  });

  group('pure helpers', () {
    test('a failing test\'s name and expected/actual lines only', () {
      const tail = '''
Resolving dependencies...
+ async 2.11.0
Got dependencies!
00:02 +5 -1: test/critic_test.dart: critic flags a 2 cent mismatch [E]
  Expected: <true>
    Actual: <false>
package:test_api           expect
''';
      expect(failureEssentials(tail), [
        '00:02 +5 -1: test/critic_test.dart: critic flags a 2 cent mismatch [E]',
        'Expected: <true>',
        'Actual: <false>',
      ]);
      expect(
        failureEssentials(
          'ERROR: test_checkout_total (test_checkout.CheckoutTest)\nTraceback (most recent call last):\n  File "x"\nValueError: discount must be between 0 and 1\n',
        ),
        [
          'ERROR: test_checkout_total (test_checkout.CheckoutTest)',
          'ValueError: discount must be between 0 and 1',
        ],
      );
    });

    test('summaries skip progress, probes and model footers', () {
      expect(
        summarizeOutput(
          '[probe 1] after cp_x PASS\nRestoring…\n(meta muse; 10 in / 2 out)\nRestored cp_x: 1 file.\n',
        ),
        ['Restoring…', 'Restored cp_x: 1 file.'],
      );
      final parsed = parseSummaryOutput(
        'It renamed a field.\n\n(meta x; 1 in / 2 out)\n',
      );
      expect(parsed.text, 'It renamed a field.');
      expect(parsed.footer, '(meta x; 1 in / 2 out)');
    });

    test('command lines, dmc refusals and envelopes', () {
      expect(splitCommandLine('restore "before it touched auth" --diff'), [
        'restore',
        'before it touched auth',
        '--diff',
      ]);
      expect(dmcCommandRefusal(['checkpoint', 'list']), isNull);
      expect(dmcCommandRefusal(['checkpoint', 'restore', 'cp_x']), isNull);
      expect(
        dmcCommandRefusal(['checkpoint', 'restore', 'cp_x', '--apply']),
        contains('previews only'),
      );
      expect(dmcCommandRefusal(['init']), contains('read-only or preview'));
      expect(
        dmcEnvelopeSummary({
          'ok': true,
          'data': {
            'checkpoints': [1, 2],
          },
        }),
        'ok: 2 checkpoints (d for everything)',
      );
    });

    test('full checkpoint ids in model text are shortened on screen', () {
      expect(
        shortenIds(
          'Checkpoint cp_mvzr1xvq_42356a45ecccb6128898ede8f44d80af changed money.py.',
        ),
        'Checkpoint cp_mvzr1xvq changed money.py.',
      );
      expect(isProgressLine('Recording with rec (SoX)… press Space'), isTrue);
      expect(
        isProgressLine('I heard: "status" → I\'ll run: doc status'),
        isFalse,
      );
    });

    test('timelines lanes: the lesson once, live clocks, one failing test '
        'named once for all lanes', () {
      const tail =
          'ERROR: test_checkout_total (test_checkout.CheckoutTest)\nValueError: discount must be between 0 and 1';
      Timeline lane(int k, TimelineStatus status, {String? reason}) => Timeline(
        k: k,
        approach: TimelineApproach('Approach $k', 'Plan $k.', const []),
        branch: 'doc/timeline/tl-1/$k',
        worktree: '/tmp/tl-1/$k',
        status: status,
        reason: reason,
        steps: k,
        seconds: 70,
        test: status == TimelineStatus.running
            ? null
            : const TimelineTest(
                passed: false,
                timedOut: false,
                setupFailed: false,
                seconds: 1,
                tail: tail,
              ),
      );
      final run = TimelineRun(
        id: 'tl-1',
        createdAt: '2026-11-02T00:00:00Z',
        task: 'Fix the tests broken by: Discount takes a fraction',
        test: 'python3 -m unittest -q',
        setup: null,
        links: const [],
        maxSteps: 20,
        timeoutMinutes: 10,
        repo: '/tmp/shop',
        workspaceFingerprint: 'f',
        baseCheckpoint: _bug,
        baseState: 'after',
        baseLabel: null,
        baseCommit: null,
        brief: 'Before you start: keep percents.',
        planner: const {},
        timelines: [
          lane(1, TimelineStatus.done),
          lane(2, TimelineStatus.stalled, reason: 'no progress for 90 s'),
          lane(
            3,
            TimelineStatus.failed,
            reason: 'did not finish within 8 step(s)',
          ),
        ],
      );
      final now = DateTime(2026, 11, 2, 12);
      final pane = TimelinesPane(run.task)
        ..update({
          'type': 'timelines.run',
          'phase': 'done',
          'lessonTitles': ['Keep percent inputs'],
          'run': run.toJson(),
        }, now);
      final text = timelinesColumn(pane, 116, now).map(lineText).join('\n');
      expect(
        RegExp('Using lesson: Keep percent inputs').allMatches(text),
        hasLength(1),
      );
      expect(text, contains('done · 1 step · 1:10  tests FAIL'));
      expect(text, contains('stalled · 2 steps'));
      expect(text, contains('no progress for 90 s'));
      expect(text, contains('step limit · 3 steps'));
      expect(text, contains('did not finish within 8 steps'));
      expect(text, contains('All 3 fail the same test: test_checkout_total'));
      expect(RegExp('test_checkout_total').allMatches(text), hasLength(1));
      expect(text, contains('ValueError: discount must be between 0 and 1'));

      // Judged: the ranking in the lanes, and Wonder's summary in full.
      final summary = List.filled(30, 'word').join(' ');
      run.judgment = {
        'ranking': [
          {
            'k': 2,
            'score': 7,
            'rationale': 'r',
            'followedPlan': 'no',
            'actualChange': 'Changed checkout.py instead.',
          },
          {'k': 1, 'score': 4, 'rationale': 'r', 'followedPlan': 'yes'},
        ],
        'recommended': 2,
        'summary': summary,
      };
      final judged = TimelinesPane(run.task)
        ..update({
          'type': 'timelines.run',
          'phase': 'done',
          'run': run.toJson(),
        }, now);
      final ranked = timelinesColumn(judged, 116, now).map(lineText).join('\n');
      expect(ranked, contains('#1 [2] Approach 2'));
      expect(ranked, contains('7/10  ★ recommended'));
      expect(ranked, contains('Planned: Plan 2.'));
      expect(ranked, contains('Did: Changed checkout.py instead.'));
      expect(ranked, contains("didn't follow its plan"));
      expect(ranked, contains('Wonder recommends [2]'));
      expect(ranked.replaceAll(RegExp(r'\s+'), ' '), contains(summary));

      // A running lane's clock is live.
      final live = run.toJson();
      ((live['timelines'] as List)[0] as Map)
        ..['status'] = 'running'
        ..['test'] = null;
      final running = TimelinesPane(run.task)
        ..update({
          'type': 'timelines.run',
          'phase': 'running',
          'run': live,
        }, now);
      expect(
        timelinesColumn(
          running,
          116,
          now.add(const Duration(seconds: 75)),
        ).map(lineText).join('\n'),
        contains('running · 1 step · 1:15'),
      );
    });

    test('the detail diff: a dim header per file, from the first change', () {
      final lines = diffPreview(
        '--- money.py (modified)\n'
        '@@ -1,4 +1,4 @@\n'
        ' def apply_discount(price, d):\n'
        '     """Docs."""\n'
        '-    return price * (100 - d) / 100\n'
        '+    return price * (1 - d)\n'
        ' # end\n'
        '--- notes.md (created)\n'
        '+new\n',
        12,
      ).map(lineText).toList();
      expect(lines, [
        'money.py',
        '-    return price * (100 - d) / 100',
        '+    return price * (1 - d)',
        ' # end',
        'notes.md',
        '+new',
      ]);
      expect(diffPreview('--- a (modified)\n-x\n+y\n-z', 2), hasLength(2));
    });

    test('files and +/- counts from a turn\'s diff', () {
      final files = filesFromDiff(
        '--- a.py (modified)\n-x\n+y\n+z\n--- b.py (created)\n+new\n',
      );
      expect(
        [for (final f in files) '${f.path} +${f.added} −${f.removed}'],
        ['a.py +2 −1', 'b.py +1 −0'],
      );
    });

    test('Flutter projects get flutter pub get as the setup suggestion', () {
      const flutter =
          'name: bill\ndependencies:\n  flutter:\n    sdk: flutter\n  http: ^1.0.0\nflutter:\n  uses-material-design: true\n';
      const dart = 'name: tool\ndependencies:\n  path: ^1.9.0\n';
      expect(isFlutterPubspec(flutter), isTrue);
      expect(isFlutterPubspec(dart), isFalse);
      expect(isFlutterPubspec('name: x\nflutter:\n  assets: []\n'), isFalse);
      final dir = Directory.systemTemp.createTempSync('doc_flutter_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(flutter);
      expect(suggestSetup(dir.path), 'flutter pub get');
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(dart);
      expect(suggestSetup(dir.path), 'dart pub get');
    });
  });

  group('rendering', () {
    TuiState demo() {
      final state =
          TuiState(
              HeaderStatus.fromDoctor('shop', const [
                DoctorLine(DoctorLevel.ok, 'dmc: /x/dmc (dmc 1.1.0)'),
                DoctorLine(
                  DoctorLevel.ok,
                  'Hooks (Claude Code, local): installed (4 events)',
                ),
                DoctorLine(
                  DoctorLevel.warn,
                  'Hooks (Muse Code, user): not installed',
                  'fix it',
                ),
              ]),
            )
            ..turns = turnsFromList({
              'data': {'checkpoints': demoTurns()},
            })
            ..turnsLoaded = true
            ..firstBad = _bug;
      return state;
    }

    test('every frame is exactly the window size', () {
      for (final (w, h) in [(80, 24), (120, 36), (200, 50)]) {
        final frame = renderTui(demo(), w, h, color: false);
        expect(frame, hasLength(h));
        for (final line in frame) {
          expect(displayWidth(line), w, reason: '$w×$h: "$line"');
        }
      }
    });

    test('the header and glyphs: ● ok, ✗ broke the tests, ↺ undone', () {
      final frame = renderTui(demo(), 120, 36, color: false).join('\n');
      expect(
        frame,
        contains('┌ Doc · shop · dmc ok · hooks: claude ✓ muse ✗ · 1 to check'),
      );
      expect(frame, contains('▶ ● muse   In README.md, add a short Usage'));
      expect(frame, contains('  ✗ muse   In money.py, change apply_discount'));
      expect(frame, contains('  ↺ claude Add a function format_price'));
      expect(frame, contains(' undone'));
      // The turn's local time (the fixture's epoch milliseconds; CI runs in UTC).
      final at = DateTime.fromMillisecondsSinceEpoch(401);
      String two(int v) => v.toString().padLeft(2, '0');
      expect(
        frame,
        contains(
          'muse · ${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}',
        ),
      );
      expect(frame, contains('cp_mvyyf4t6'));
      // Never the full id, never dmc's "(truncated by dmc)".
      expect(frame, isNot(contains(_readme)));
      expect(frame, isNot(contains('truncated by dmc')));
      expect(frame, contains('◉ Space: talk to Doc'));
    });

    test('a small window shows one line', () {
      final frame = renderTui(demo(), 70, 20, color: false);
      expect(
        frame.first.trimRight(),
        'Make the window at least 80×24 (now 70×20).',
      );
      expect(frame.skip(1).every((l) => l.trim().isEmpty), isTrue);
    });

    test('colour: green good, red bad, yellow warnings', () {
      final frame = renderTui(demo(), 120, 36, color: true).join('\n');
      expect(frame, contains('\x1b[31m✗\x1b[0m'));
      expect(frame, contains('\x1b[32m●\x1b[0m'));
      expect(frame, contains('\x1b[33m✗\x1b[0m'));
    });

    test(
      'the splash: centred car, title, dmc version; only in tall windows',
      () {
        final state = demo()
          ..splash = true
          ..dmcVersionForSplash = '1.1.0';
        final frame = renderTui(state, 120, 36, color: false);
        final text = frame.join('\n');
        expect(text, contains(splashTitle));
        expect(text, contains('dmc 1.1.0'));
        final row = frame.firstWhere((l) => l.contains('DMC'));
        final left = row.length - row.trimLeft().length;
        final right = row.length - row.trimRight().length;
        expect((left - right).abs(), lessThanOrEqualTo(1));
        for (final banned in ['DeLorean', 'De Lorean', 'Back to the Future']) {
          expect(text, isNot(contains(banned)));
        }
        // Below 30 rows: no splash, the normal screen.
        expect(
          renderTui(state, 120, 28, color: false).join('\n'),
          contains('AGENT TURNS'),
        );
      },
    );

    test('each splash row is a mirror image', () {
      const swap = {
        '/': r'\',
        r'\': '/',
        '[': ']',
        ']': '[',
        '(': ')',
        ')': '(',
      };
      for (final row in splashCar) {
        // The badge text reads left to right; only the art mirrors.
        final art = row.replaceAll(RegExp('[A-Za-z0-9]'), 'A');
        final mirrored = art.split('').reversed.map((c) => swap[c] ?? c).join();
        expect(mirrored, art, reason: row);
        expect(row.length, splashCar.first.length);
      }
    });

    test('a long brief wraps inside the question', () {
      final state = demo()
        ..question = Question(
          context: [
            'Before you start: ${'keep apply_discount taking percents ' * 6}and add bulk_discount.',
          ],
          prompt: "Add this to the agent's first prompt? [y/N]",
          yesNo: true,
        );
      final frame = renderTui(state, 120, 36, color: false).join('\n');
      expect(frame, contains('and add bulk_discount.'));
      expect(frame, isNot(contains('…  │')));
    });

    test('a question: what will change, then one [y/N] line', () {
      final state = demo()
        ..question = Question(
          context: [
            'Restore cp_mvyya1b2 (muse): 1 file',
            '  money.py: put back the version from before the turn',
          ],
          prompt: 'Apply this restore (1 step, 1 file)? [y/N]',
          yesNo: true,
        );
      final frame = renderTui(state, 120, 36, color: false).join('\n');
      expect(frame, contains('Restore cp_mvyya1b2 (muse): 1 file'));
      expect(frame, contains('Apply this restore (1 step, 1 file)? [y/N]'));
      expect(frame, contains('y yes · n / Enter / Esc no'));
    });
  });

  group('the app', () {
    late FakeHost host;
    late FakeBackend backend;
    late ({TuiApp app, Future<int> running}) started;

    Future<void> open({
      bool splash = false,
      Duration noteFor = const Duration(seconds: 5),
    }) async {
      started = startApp(host, backend, splash: splash, noteFor: noteFor);
      await until(
        () =>
            host.screen.contains('AGENT TURNS') ||
            host.screen.contains('No dmc workspace'),
        what: 'the first screen',
      );
      await pump();
    }

    setUp(() {
      host = FakeHost();
      backend = FakeBackend(
        turns: demoTurns(),
        bisect: {
          'firstBad': {'id': _bug},
          'test': 'python3 -m unittest -q',
        },
      );
    });

    tearDown(() async {
      started.app.quit();
      await started.running;
    });

    test(
      'a selected turn is summarized once, in plain English, and cached',
      () async {
        backend.onRun = script([
          'Muse Code added a Usage section to README.md.',
          '',
          '(meta muse-spark; 10 in / 20 out; \$0.0001)',
        ]);
        await open();
        await until(
          () => host.screen.contains('Muse Code added a Usage section'),
          what: 'the summary',
        );
        expect(backend.runs.single, ['summarize', _readme]);
        expect(host.screen, contains('files: money.py +1 −1'));
        expect(host.screen, contains('+    return 1'));
        // The footer is only in details.
        expect(host.screen, isNot(contains('10 in / 20 out')));
        await host.press('d');
        expect(
          host.screen,
          contains('(meta muse-spark; 10 in / 20 out; \$0.0001)'),
        );
        expect(host.screen, contains(_readme));
        await host.escape();
        expect(
          backend.summaries[_readme],
          startsWith('Muse Code added a Usage section'),
        );
        // Back to it: no new call.
        await host.press(const KeyEvent(KeyKind.down));
        await pump(10);
        await host.press(const KeyEvent(KeyKind.up));
        await pump(10);
        expect(backend.runs.where((r) => r.last == _readme), hasLength(1));
      },
    );

    test('"try three different fixes" by voice opens the lanes', () async {
      backend.onRun = (args, io) async {
        if (args.first != 'talk') return 1;
        expect(await io.voice!.terminal.readKey(), TalkKey.toggle);
        expect(await io.voice!.terminal.readKey(), TalkKey.toggle);
        io.out.write(
          'I heard: "try three different fixes" → I\'ll run: doc timelines "try three different fixes" --from-bisect\nRun it? [y/N] ',
        );
        if (await io.ask() != 'y') return 0;
        final lane = {
          'k': 1,
          'approach': {'title': 'Convert at the call site', 'plan': 'p'},
          'branch': 'doc/timeline/tl-1/1',
          'worktree': '/tmp/tl-1/1',
          'status': 'running',
          'steps': 2,
        };
        io.progress({
          'type': 'timelines.run',
          'phase': 'running',
          'dir': '/tmp/tl-1',
          'lessonTitles': ['Keep percent inputs'],
          'run': {
            'id': 'tl-1',
            'createdAt': '2026-11-02T00:00:00Z',
            'task': 'try three different fixes',
            'test': 'python3 -m unittest -q',
            'maxSteps': 20,
            'timeoutMinutes': 10,
            'repo': '/tmp/shop',
            'workspaceFingerprint': 'f',
            'base': {'checkpointId': _bug, 'state': 'after'},
            'timelines': [lane],
          },
        });
        await pump(4);
        expect(host.screen, contains('TIMELINES · try three different fixes'));
        expect(host.screen, contains('Using lesson: Keep percent inputs'));
        expect(host.screen, contains('running · 2 steps'));
        return 0;
      };
      await open();
      await host.press(' ');
      await host.press(' ');
      await until(() => host.screen.contains('Run it? [y/N]'));
      await host.press('y');
      await until(() => host.screen.contains('Convert at the call site'));
      await until(() => !host.screen.contains('Run it?'));
      await pump(10);
      expect(host.screen, contains('TIMELINES'));
      expect(host.screen, contains('p pick'));
    });

    test('r: dmc\'s preview in a dialog, y applies, the list refreshes', () async {
      final answers = <String?>[];
      backend.onRun = (args, io) async {
        if (args.first == 'summarize') return 1;
        return script(
          [
            'Restore would change 3 files:',
            '  - money.py: put back the version from before the turn',
            '  - checkout.py: put back the version from before the turn',
            '  - notes.md: delete it (the turn created it)',
          ],
          question:
              'Undo this muse turn? 3 files change (money.py, checkout.py, +1)  [y/N] ',
          after: ['Restored $_readme.'],
          answers: answers,
        )(args, io);
      };
      await open();
      await host.press('r');
      await until(
        () => host.screen.contains(
          'Undo this muse turn? 3 files change (money.py, checkout.py, +1)  [y/N]',
        ),
      );
      // One line; the per-file list is under d.
      expect(host.screen, isNot(contains('notes.md: delete it')));
      expect(host.screen, contains('d: every file'));
      await host.press('d');
      expect(host.screen, contains('  - notes.md: delete it'));
      expect(answers, isEmpty);
      expect(backend.runs.last, ['restore', _readme]);
      await host.press('y');
      await until(() => host.screen.contains('Restored $_readme.'));
      expect(answers, ['y']);
    });

    test(
      'titles replace prompts in the list; the prompt is in details',
      () async {
        backend.summaries[_bug] =
            'Title: Discount takes a fraction\n'
            'apply_discount in money.py now takes 0.25 for 25%.\n\n(meta m; 1 in / 2 out)';
        backend.onRun = (args, io) async => 1;
        await open();
        expect(host.screen, contains('✗ muse   Discount takes a fraction'));
        expect(
          host.screen,
          isNot(contains('In money.py, change apply_discount')),
        );
        // Turns without a cached title keep their prompt.
        expect(host.screen, contains('In README.md, add a short Usage'));
        await host.press(const KeyEvent(KeyKind.down));
        await host.press(const KeyEvent(KeyKind.down));
        await pump(10);
        expect(host.screen, contains('apply_discount in money.py now takes'));
        expect(
          backend.runs.where((r) => r.first == 'summarize' && r.last == _bug),
          isEmpty,
        );
        await host.press('d');
        expect(
          host.screen,
          contains('Prompt: In money.py, change apply_discount'),
        );
      },
    );

    test('the bar note clears on the next key, after a while, and never '
        'shows on another pane', () async {
      backend.onRun = (args, io) async => args.first == 'restore'
          ? script(
              const [],
              question:
                  'Undo this muse turn? README.md: put back the version from before it  [y/N] ',
              after: ['Nothing was changed.'],
            )(args, io)
          : 1;
      await open(noteFor: const Duration(milliseconds: 300));
      await host.press('r');
      await until(() => host.screen.contains('[y/N]'));
      await host.press('n');
      await until(() => host.screen.contains('◉ Nothing was changed.'));
      await host.press('l');
      await until(() => host.screen.contains('LESSONS'));
      expect(host.screen, isNot(contains('Nothing was changed.')));
      await host.escape();
      await host.press('r');
      await until(() => host.screen.contains('[y/N]'));
      await host.press('n');
      await until(() => host.screen.contains('◉ Nothing was changed.'));
      await host.press('?');
      expect(host.screen, isNot(contains('Nothing was changed.')));
      await host.escape();
      await host.press('r');
      await until(() => host.screen.contains('[y/N]'));
      await host.press('n');
      await until(() => host.screen.contains('◉ Nothing was changed.'));
      await until(
        () => !host.screen.contains('Nothing was changed.'),
        what: 'the note to time out',
      );
      expect(host.screen, contains('Space: talk to Doc'));
    });

    test('n or Esc answers no', () async {
      final answers = <String?>[];
      backend.onRun = (args, io) async => args.first == 'restore'
          ? script(
              const [],
              question: 'Apply this restore? [y/N] ',
              answers: answers,
            )(args, io)
          : 1;
      await open();
      await host.press('r');
      await until(() => host.screen.contains('[y/N]'));
      await host.escape();
      await until(() => answers.isNotEmpty);
      expect(answers, ['n']);
    });

    test(
      '/ restores by words: a text field, then the command\'s own questions',
      () async {
        backend.onRun = (args, io) async => args.first == 'restore'
            ? script([
                'Turn 3 of 4 · muse · In money.py, change apply_discount… · files: money.py',
              ], question: 'Apply this restore (1 step, 1 file)? [y/N] ')(
                args,
                io,
              )
            : 1;
        await open();
        await host.press('/');
        await host.type('before the discount change');
        await host.enter();
        await until(() => host.screen.contains('Turn 3 of 4 · muse'));
        expect(backend.runs.last, ['restore', 'before the discount change']);
        await host.press('n');
      },
    );

    test('u redoes an undone turn: dmc preview, y, apply', () async {
      backend.onRun = (args, io) async => 1;
      backend.onDmc = (args) => {
        'ok': true,
        'data': {
          'actions': [
            {'path': 'money.py'},
          ],
          'conflicts': [],
        },
      };
      await open();
      for (var i = 0; i < 3; i++) {
        await host.press(const KeyEvent(KeyKind.down));
      }
      await host.press('u');
      await until(
        () => host.screen.contains(
          "Redo this claude turn? money.py: put back the turn's version  [y/N]",
        ),
      );
      expect(backend.dmcCalls.last, ['checkpoint', 'redo', _price]);
      await host.press('y');
      await until(() => backend.dmcCalls.last.contains('--apply'));
      expect(backend.dmcCalls.last, ['checkpoint', 'redo', _price, '--apply']);
    });

    test('b: test and setup asked once, the strip fills in, the bad turn, '
        'then a restore offer', () async {
      backend.onRun = (args, io) async {
        if (args.first == 'restore') {
          return script(
            const [],
            question:
                'Undo this muse turn? money.py: put back the version from before it  [y/N] ',
            after: ['Nothing was changed.'],
          )(args, io);
        }
        if (args.first != 'bisect') return 1;
        io.out.writeln('[probe 1] noise that never shows');
        for (final (id, state, passed) in [
          (_price, 'before', true),
          (_bug, 'after', false),
          (_price, 'after', true),
        ]) {
          io.progress({
            'type': 'bisect.probe',
            'checkpoint': id,
            'state': state,
            'passed': passed,
          });
          await pump(2);
        }
        io.out.writeln(
          jsonEncode({
            'result': {
              'status': 'found',
              'firstBad': {
                'id': _bug,
                'label':
                    'In money.py, change apply_discount to take a fraction',
                'changedFiles': [
                  {'path': 'money.py', 'change': 'modified'},
                ],
              },
              'failingOutputTail':
                  'Got dependencies!\nERROR: test_checkout_total (test_checkout.CheckoutTest)\nValueError: discount must be between 0 and 1',
            },
            'explanation':
                'The turn changed apply_discount to fractions while checkout still passes percents.',
          }),
        );
        return 0;
      };
      await open();
      await host.press('b');
      await until(() => host.screen.contains('Test command'));
      expect(host.screen, contains('> python3 -m unittest -q'));
      await host.enter();
      await until(() => host.screen.contains('Setup command'));
      await host.enter();
      await until(() => host.screen.contains('Undo this muse turn? money.py'));
      expect(backend.runs.last, ['restore', _bug]);
      final text = host.screen;
      expect(backend.runs[backend.runs.length - 2], [
        'bisect',
        '--test',
        'python3 -m unittest -q',
        '--json',
      ]);
      expect(
        text,
        contains('Turn 2 broke the tests: In money.py, change apply_discount'),
      );
      expect(text, contains('files: money.py'));
      expect(
        text,
        contains('ERROR: test_checkout_total (test_checkout.CheckoutTest)'),
      );
      expect(text, contains('ValueError: discount must be between 0 and 1'));
      expect(text, contains('fractions while checkout still passes percents'));
      expect(text, contains('PASS'));
      expect(text, contains('FAIL'));
      expect(text, contains('not needed'));
      expect(text, isNot(contains('[probe 1]')));
      expect(text, isNot(contains('Got dependencies')));
      await host.press('n');
      await pump(10);
      expect(host.screen, contains('BISECT'));
    });

    test(
      'Space talks: live partial text, "I heard … Run it? [y/N]", then the pane',
      () async {
        backend.onRun = (args, io) async {
          if (args.first != 'talk') return 1;
          expect(io.voice!.watchInterrupts, isFalse);
          // The Space that started it is the first key.
          expect(await io.voice!.terminal.readKey(), TalkKey.toggle);
          io.out.writeln(
            'Recording with rec (SoX)… press Space or Enter to stop.',
          );
          io.out.writeln('  … what is');
          await pump(4);
          expect(host.screen, contains('● REC … what is'));
          io.out.writeln('  … what is the status');
          expect(await io.voice!.terminal.readKey(), TalkKey.toggle);
          io.out.writeln(
            '(meta muse-voice-transcribe-1.0; 1.8 s of audio sent)',
          );
          io.out.write(
            'I heard: "what is the status" → I\'ll run: doc status\nRun it? [y/N] ',
          );
          final answer = await io.ask();
          if (answer == 'y') {
            io.out.writeln('Workspace /tmp/shop: 4 checkpoints.');
          }
          return 0;
        };
        await open();
        await host.press(' ');
        await until(() => host.screen.contains('● REC … what is'));
        await host.press(' ');
        await until(() => host.screen.contains('Run it? [y/N]'));
        expect(
          host.screen,
          contains('I heard: "what is the status" → I\'ll run: doc status'),
        );
        // The question shows what was heard, not the recording's progress.
        expect(host.screen, isNot(contains('Recording with')));
        expect(host.screen, isNot(contains('1.8 s of audio sent')));
        await host.press('y');
        await until(
          () => host.screen.contains('Workspace /tmp/shop: 4 checkpoints.'),
        );
        expect(host.screen, contains('AGENT TURNS'));
      },
    );

    test(
      ': runs any doc command into a result pane; dmc only read-only',
      () async {
        backend.onRun = (args, io) async {
          if (args.first == 'usage') {
            io.out.writeln('Usage file: /x/usage.json');
            io.out.writeln('meta      12 calls   \$0.0412');
            return 0;
          }
          return 1;
        };
        await open();
        await host.press(':');
        await host.type('doc usage');
        expect(host.screen, contains(': doc usage'));
        await host.enter();
        await until(() => host.screen.contains('doc usage · done'));
        expect(host.screen, contains('meta      12 calls'));
        await host.press('d');
        expect(host.screen, contains('Usage file: /x/usage.json'));
        await host.escape();
        await host.press('o');
        expect(host.screen, contains('\$ doc usage'));
        await host.escape();
        await host.press(':');
        await host.type('dmc checkpoint restore $_bug --apply');
        await host.enter();
        expect(host.screen, contains('previews only'));
        expect(backend.dmcCalls, isEmpty);
      },
    );

    test(
      'l: lessons and drafts; y approves and shows the clear refusal',
      () async {
        backend.lessonItems = const [
          LessonItem(
            id: 'why-1',
            title: 'Undid the fraction change',
            files: ['money.py'],
            draft: true,
            text: 'draft text',
          ),
          LessonItem(
            id: 'keep-a',
            title: 'Keep percents',
            files: ['money.py'],
            draft: false,
            text: 'lesson text',
          ),
        ];
        backend.onRun = (args, io) async {
          if (args.take(2).join(' ') == 'lesson approve') {
            io.out.writeln(
              "[doc] Not approved. This draft has no reason for the undo. Add one with: doc lesson edit why-1 (replace the 'Not stated' line)",
            );
            return 1;
          }
          return 1;
        };
        await open();
        await host.press('l');
        await until(() => host.screen.contains('LESSONS'));
        expect(host.screen, contains('◌ Undid the fraction change (draft)'));
        expect(host.screen, contains('✓ Keep percents'));
        await host.press('y');
        await until(
          () => host.screen.contains('This draft has no reason for the undo'),
        );
        expect(backend.runs.last, ['lesson', 'approve', 'why-1']);
        await host.enter();
        expect(host.screen, contains('draft text'));
      },
    );

    test('a: agent, task and files asked, then doc start runs', () async {
      backend.onRun = (args, io) async {
        if (args.first == 'start') {
          io.out.write(
            'No lesson matched money.py. Start muse-code with the task alone? [y/N] ',
          );
          await io.ask();
          return 0;
        }
        return 1;
      };
      await open();
      await until(() => host.screen.contains('files: money.py'));
      await host.press('a');
      await host.enter(); // muse-code
      await host.type('Add bulk discounts');
      await host.enter();
      await until(() => host.screen.contains('> money.py'));
      await host.enter();
      await until(
        () =>
            host.screen.contains('Start muse-code with the task alone? [y/N]'),
      );
      expect(backend.runs.last, [
        'start',
        'muse-code',
        'Add bulk discounts',
        '--files',
        'money.py',
      ]);
      await host.press('y');
    });

    test('no workspace: the exact command to fix it', () async {
      backend.workspace = false;
      await open();
      expect(host.screen, contains('No dmc workspace here.'));
      expect(host.screen, contains('"/x/dmc" init'));
    });

    test('? lists every key; q quits; Ctrl-C quits with 130', () async {
      await open();
      await host.press('?');
      for (final (key, _) in tuiKeyHelp) {
        expect(host.screen, contains(key));
      }
      await host.escape();
      await host.press(const KeyEvent(KeyKind.ctrlC));
      expect(await started.running, 130);
    });

    test('the splash shows first and any key skips it', () async {
      backend.onRun = (args, io) async => 1;
      await open(splash: true);
      // open() waits for the turns, so the splash timer may have passed;
      // the first frame was the splash.
      expect(host.frames.first.join('\n'), contains(splashTitle));
    });
  });

  test('every CLI command is reachable from the TUI', () {
    final commands = <String>{
      for (final match in RegExp(
        r'^  ([a-z]+)\b',
        multiLine: true,
      ).allMatches(docUsage.split('Options:').first))
        match[1]!,
    };
    expect(
      commands,
      containsAll(['models', 'bisect', 'restore', 'lesson', 'start', 'ui']),
    );
    for (final command in commands) {
      expect(tuiCommandCoverage.keys, contains(command), reason: command);
    }
    // And the command bar runs any of them.
    expect(splitCommandLine('doc lesson show keep-a'), [
      'doc',
      'lesson',
      'show',
      'keep-a',
    ]);
  });
}
