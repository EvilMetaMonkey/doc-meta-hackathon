import 'dart:convert';

import 'package:dmc_doc/doc.dart';
import 'package:test/test.dart';

String approaches(List<(String, String, List<String>)> items) => jsonEncode({
  'approaches': [
    for (final (title, plan, files) in items)
      {'title': title, 'plan': plan, 'files_likely': files},
  ],
});

const plans = [
  (
    'Fix the rounding helper',
    'Change round_money in money.py to round to two decimals again and keep its signature.',
    ['money.py'],
  ),
  (
    'Round at the call sites',
    'Leave round_money alone and round the results inside add_tax and subtract_discount instead.',
    ['money.py'],
  ),
  (
    'Use Decimal arithmetic',
    'Replace float math with decimal.Decimal and quantize to cents before returning values.',
    ['money.py', 'nope.py'],
  ),
];

void main() {
  group('parseTimelineApproaches', () {
    test('accepts exactly N clearly different approaches', () {
      final parsed = parseTimelineApproaches(
        approaches(plans),
        3,
        files: {'money.py', 'test_money.py'},
      );
      expect(parsed.map((a) => a.title), [
        'Fix the rounding helper',
        'Round at the call sites',
        'Use Decimal arithmetic',
      ]);
      // Paths not in the base are dropped.
      expect(parsed[2].filesLikely, ['money.py']);
    });

    test('rejects the wrong count, long plans, duplicates and near copies', () {
      void refused(String content, String why) => expect(
        () => parseTimelineApproaches(content, 3),
        throwsA(
          isA<TimelinePlanRefused>().having(
            (e) => e.message,
            'message',
            contains(why),
          ),
        ),
      );
      refused(approaches(plans.take(2).toList()), 'Expected exactly 3');
      refused('not json', 'not a JSON object');
      refused(jsonEncode({'plans': []}), 'no "approaches"');
      refused(
        approaches([
          plans[0],
          plans[1],
          ('Long', List.filled(121, 'word').join(' '), <String>[]),
        ]),
        'at most 120',
      );
      refused(
        approaches([
          plans[0],
          plans[1],
          (
            'fix the ROUNDING helper',
            'Something else entirely here.',
            <String>[],
          ),
        ]),
        'same title',
      );
      refused(
        approaches([
          plans[0],
          plans[1],
          (
            'Another title',
            'Change round_money in money.py to round to two decimals again, keeping its signature.',
            <String>[],
          ),
        ]),
        'not clearly different',
      );
      refused(
        jsonEncode({
          'approaches': [
            {'title': 'x', 'plan': 3, 'files_likely': []},
            ...[
              for (final (t, pl, f) in plans.skip(1))
                {'title': t, 'plan': pl, 'files_likely': f},
            ],
          ],
        }),
        'needs a string',
      );
    });

    test('the schema asks for exactly N', () {
      final schema =
          (timelineApproachesFormat(4)['json_schema'] as Map)['schema'] as Map;
      final list = (schema['properties'] as Map)['approaches'] as Map;
      expect(list['minItems'], 4);
      expect(list['maxItems'], 4);
    });
  });

  test('treeSyncActions copies every export file and deletes the rest', () {
    final actions = treeSyncActions(
      {'state.txt', 'feature1.txt', 'src/new.py'},
      {'state.txt', 'old.txt', 'src/gone.py', '.dmc/x', '.git'},
    );
    expect(actions, const [
      SyncAction('copy', 'feature1.txt'),
      SyncAction('copy', 'src/new.py'),
      SyncAction('copy', 'state.txt'),
      SyncAction('delete', 'old.txt'),
      SyncAction('delete', 'src/gone.py'),
    ]);
  });

  test('parseMuseEvents reads usage and the terminal event', () {
    String line(String type, Map<String, Object?> payload) =>
        jsonEncode({'payload_type': type, 'payload': payload});
    final done = parseMuseEvents([
      'not json',
      line('run.lifecycle.started', {'prompt': 'x'}),
      line('run.usage', {
        'calls': 6,
        'models': [
          {
            'model': 'muse-spark-1.3-contributor',
            'input_tokens': 167108,
            'cached_tokens': 138421,
            'output_tokens': 539,
          },
        ],
      }),
      line('run.terminal.completed', {
        'terminal': 'completed',
        'text': 'Done.',
        'reason': null,
      }),
    ]);
    expect(done.terminal, 'completed');
    expect(done.steps, 6);
    expect(done.model, 'muse-spark-1.3-contributor');
    expect(done.finalText, 'Done.');
    // (28687 × 0.10 + 138421 × 0.002 + 539 × 0.20) / 1e6
    expect(museCostUsd(done), closeTo(0.0032543, 1e-6));

    final limited = parseMuseEvents([
      line('run.terminal.failed', {
        'terminal': 'failed',
        'reason': 'model did not reach a terminal state within 2 step(s)',
      }),
    ]);
    expect(limited.terminal, 'failed');
    expect(limited.stepLimit, isTrue);
    expect(museCostUsd(limited), isNull);
    expect(parseMuseEvents(const []).terminal, isNull);
  });

  test('the cost estimate states its basis', () {
    final estimate = estimateTimelineCost(3, 10);
    expect(
      estimate.contributor,
      closeTo(3 * 10 * (30000 * 0.10 + 600 * 0.20) / 1e6, 1e-9),
    );
    expect(
      estimate.standard,
      closeTo(3 * 10 * (30000 * 1.25 + 600 * 4.25) / 1e6, 1e-9),
    );
  });

  test('the estimate uses the agents\' real model', () {
    expect(
      estimateTimelineCostFor(3, 10, 'muse-wonder-1.0'),
      closeTo(3 * 10 * (30000 * 4.00 + 600 * 20.00) / 1e6, 1e-9),
    );
    expect(estimateTimelineCostFor(3, 10, 'some-new-model'), isNull);
    expect(
      museConfiguredModel('{"provider":"meta","model":"muse-wonder-1.0"}'),
      'muse-wonder-1.0',
    );
    expect(museConfiguredModel('{"provider":"meta"}'), isNull);
    expect(museConfiguredModel('not json'), isNull);
    expect(museConfiguredModel(null), isNull);
  });

  test('parseNumstat', () {
    expect(
      parseNumstat(
        '1\t1\tstate.txt\n-\t-\timage.png\n12\t0\tsrc/new.py\n',
      ).map((f) => f.toJson()),
      [
        {'path': 'state.txt', 'added': 1, 'removed': 1},
        {'path': 'image.png', 'added': null, 'removed': null},
        {'path': 'src/new.py', 'added': 12, 'removed': 0},
      ],
    );
  });

  TimelineRun sampleRun() => TimelineRun(
    id: 'tl-1',
    createdAt: '2026-10-29T00:00:00Z',
    task: 'fix it',
    test: 'make test',
    setup: null,
    links: const [],
    maxSteps: 8,
    timeoutMinutes: 10,
    repo: '/repo',
    workspaceFingerprint: 'fp',
    baseCheckpoint: 'cp_a',
    baseState: 'before',
    baseLabel: 'turn',
    baseCommit: 'abc123',
    brief: null,
    planner: const {'model': 'muse-wonder-1.0'},
    timelines: [
      Timeline(
        k: 1,
        approach: const TimelineApproach('Fix helper', 'plan one', [
          'money.py',
        ]),
        branch: 'doc/timeline/tl-1/1',
        worktree: '/data/tl-1/1',
        status: TimelineStatus.done,
        steps: 5,
        seconds: 72,
        costUsd: 0.0031,
        files: const [TimelineFileChange('money.py', 1, 1)],
        test: const TimelineTest(
          passed: true,
          timedOut: false,
          setupFailed: false,
          seconds: 0.2,
          tail: 'OK',
        ),
      ),
      Timeline(
        k: 2,
        approach: const TimelineApproach('Round callers', 'plan two', []),
        branch: 'doc/timeline/tl-1/2',
        worktree: '/data/tl-1/2',
        status: TimelineStatus.failed,
        reason: 'model did not reach a terminal state within 8 step(s)',
        steps: 8,
        seconds: 130,
        files: const [
          TimelineFileChange('money.py', 4, 0),
          TimelineFileChange('b.png', null, null),
        ],
        test: const TimelineTest(
          passed: false,
          timedOut: false,
          setupFailed: false,
          seconds: 0.3,
          tail: 'line 1\nAssertionError: 20.0 != 19.99\nFAILED (failures=1)',
        ),
      ),
      Timeline(
        k: 3,
        approach: const TimelineApproach('Decimal', 'plan three', []),
        branch: 'doc/timeline/tl-1/3',
        worktree: '/data/tl-1/3',
        status: TimelineStatus.timedOut,
        reason: 'no result within 10 min',
        seconds: 600,
      ),
    ],
    status: 'done',
  );

  test(
    'the run state round-trips through JSON and marks archived timelines',
    () {
      final run = sampleRun();
      final json = jsonDecode(jsonEncode(run.toJson())) as Map;
      final back = TimelineRun.fromJson(json);
      expect(back.toJson(), run.toJson());
      expect(json['command'], 'doc.timelines');
      expect((json['timelines'] as List).map((t) => (t as Map)['pick']), [
        'not picked yet',
        'not picked yet',
        'not picked yet',
      ]);
      back.picked = 1;
      expect(back.toJson()['timelines'], [
        containsPair('pick', 'picked'),
        containsPair('pick', 'archived'),
        containsPair('pick', 'archived'),
      ]);
    },
  );

  test('the comparison shows each timeline side by side', () {
    final lines = timelineComparison(sampleRun());
    expect(lines, [
      '[1] Fix helper',
      '    agent: done, 5 steps, 1:12, \$0.0031',
      '    files: money.py +1 −1',
      '    tests: PASS (0.2s)',
      '    branch: doc/timeline/tl-1/1  (not picked yet)',
      '[2] Round callers',
      '    agent: step limit, 8 steps, 2:10 (model did not reach a terminal state within 8 steps)',
      '    files: money.py +4 −0, b.png (binary)  (total +4 −0)',
      '    tests: FAIL (0.3s)',
      '    branch: doc/timeline/tl-1/2  (not picked yet)',
      '      | line 1',
      '      | AssertionError: 20.0 != 19.99',
      '      | FAILED (failures=1)',
      '[3] Decimal',
      '    agent: timed out, 0 steps, 10:00 (no result within 10 min)',
      '    files: no changes',
      '    tests: not run',
      '    branch: doc/timeline/tl-1/3  (not picked yet)',
    ]);
  });

  group('judging', () {
    String judged(List<(int, num, String)> ranking, Object? recommended) =>
        jsonEncode({
          'ranking': [
            for (final (k, score, why) in ranking)
              {
                'k': k,
                'score': score,
                'rationale': why,
                'risks': ['a risk'],
                'followed_plan': k == 2 ? 'no' : 'yes',
                'actual_change': 'Did thing $k.',
              },
          ],
          'recommended': recommended,
          'summary': 'Timeline one is the smallest correct fix.',
        });

    test('a valid judgment is parsed and shown as advice', () {
      final run = sampleRun();
      final judgment = parseTimelineJudgment(
        judged([
          (1, 9, 'Minimal and correct.'),
          (2, 4, 'Bigger.'),
          (3, 1, 'Nothing.'),
        ], 1),
        run,
      );
      expect(judgment.recommended, 1);
      expect(judgment.ranking.map((e) => e.k), [1, 2, 3]);
      expect(judgment.ranking[1].followedPlan, 'no');
      expect(timelineJudgmentLines(run, judgment), [
        'Wonder recommends timeline 1: Fix helper — Timeline one is the smallest correct fix.',
        'Ranking (advice only; you pick):',
        '  1. [1] Fix helper  9/10',
        '     Planned: Fix helper',
        '     Did: Did thing 1.',
        '     Minimal and correct.',
        '     Risks: a risk',
        "  2. [2] Round callers  4/10  — DIDN'T FOLLOW ITS PLAN",
        '     Planned: Round callers',
        '     Did: Did thing 2.',
        '     Bigger.',
        '     Risks: a risk',
        '  3. [3] Decimal (no changes)  1/10',
        '     Planned: Decimal',
        '     Did: Did thing 3.',
        '     Nothing.',
        '     Risks: a risk',
      ]);
      // The comparison shows what each diff did, and flags the stray one.
      run.judgment = judgment.toJson();
      final table = timelineComparison(run);
      expect(table, contains('    did (per Wonder): Did thing 1.'));
      expect(
        table,
        contains(
          "    did (per Wonder): Did thing 2.  ← didn't follow its plan",
        ),
      );
    });

    test('a recommended timeline that strayed from its plan is noted; plan '
        'fields are validated; old judgments still show', () {
      final run = sampleRun();
      String one(Map<String, Object?> extra) => jsonEncode({
        'ranking': [
          for (final k in [1, 2, 3])
            {
              'k': k,
              'score': 5,
              'rationale': 'r',
              'risks': <String>[],
              'followed_plan': 'yes',
              'actual_change': 'Changed it.',
              if (k == 1) ...extra,
            },
        ],
        'recommended': 1,
        'summary': 's',
      });
      final judgment = parseTimelineJudgment(
        one({
          'followed_plan': 'partly',
          'actual_change': 'Restored percents in apply_discount instead.',
        }),
        run,
      );
      expect(
        timelineJudgmentLines(run, judgment)[1],
        'Note: timeline 1 only partly followed its plan. Planned: Fix helper. Did: Restored percents in apply_discount instead.',
      );
      expect(
        () => parseTimelineJudgment(one({'followed_plan': 'maybe'}), run),
        throwsA(
          isA<TimelineJudgeRefused>().having(
            (e) => e.message,
            'm',
            contains('"followed_plan"'),
          ),
        ),
      );
      expect(
        () => parseTimelineJudgment(
          one({'actual_change': List.filled(26, 'w').join(' ')}),
          run,
        ),
        throwsA(
          isA<TimelineJudgeRefused>().having(
            (e) => e.message,
            'm',
            contains('at most 25'),
          ),
        ),
      );
      expect(
        () => parseTimelineJudgment(one({'actual_change': ' '}), run),
        throwsA(isA<TimelineJudgeRefused>()),
      );
      // A judgment saved before plan adherence was asked has no Planned/Did.
      final old = TimelineJudgment.fromJson({
        'ranking': [
          {'k': 1, 'score': 9, 'rationale': 'ok', 'risks': []},
        ],
        'recommended': 1,
        'summary': 's',
      });
      expect(
        timelineJudgmentLines(run, old).join('\n'),
        isNot(contains('Did:')),
      );
    });

    test(
      'unknown, duplicate or missing timelines and bad fields are refused',
      () {
        final run = sampleRun();
        void refused(String content, String why) => expect(
          () => parseTimelineJudgment(content, run),
          throwsA(
            isA<TimelineJudgeRefused>().having(
              (e) => e.message,
              'message',
              contains(why),
            ),
          ),
        );
        refused(
          judged([(1, 9, 'a'), (2, 4, 'b'), (9, 1, 'c')], 1),
          'Timeline 9 does not exist',
        );
        refused(
          judged([(1, 9, 'a'), (1, 4, 'b'), (3, 1, 'c')], 1),
          'ranked twice',
        );
        refused(judged([(1, 9, 'a'), (2, 4, 'b')], 1), 'leaves out timeline 3');
        refused(
          judged([(1, 11, 'a'), (2, 4, 'b'), (3, 1, 'c')], 1),
          'from 0 to 10',
        );
        refused(
          judged([
            (1, 9, List.filled(61, 'w').join(' ')),
            (2, 4, 'b'),
            (3, 1, 'c'),
          ], 1),
          'at most 60',
        );
        refused(
          judged([(1, 9, 'a'), (2, 4, 'b'), (3, 1, 'c')], 7),
          'does not exist',
        );
        refused('nope', 'not a JSON object');
      },
    );

    test('recommending a timeline whose tests failed is refused, with the '
        'ranking kept for a fallback', () {
      final run = sampleRun();
      try {
        parseTimelineJudgment(
          judged([(2, 8, 'a'), (1, 7, 'b'), (3, 1, 'c')], 2),
          run,
        );
        fail('accepted a failed recommendation');
      } on TimelineJudgeRefused catch (error) {
        expect(error.failedRecommendation, isTrue);
        expect(error.message, contains('tests did not pass'));
        expect(error.ranking!.recommended, isNull);
        expect(error.ranking!.ranking.map((e) => e.k), [2, 1, 3]);
      }
      // Timeline 3 never ran its tests: also not recommendable.
      expect(
        () => parseTimelineJudgment(
          judged([(3, 8, 'a'), (1, 7, 'b'), (2, 1, 'c')], 3),
          run,
        ),
        throwsA(isA<TimelineJudgeRefused>()),
      );
      // No recommendation is fine.
      expect(
        parseTimelineJudgment(
          judged([(1, 3, 'a'), (2, 2, 'b'), (3, 1, 'c')], null),
          run,
        ).recommended,
        isNull,
      );
    });

    test('timelines with no changes are ranked last unless all are empty', () {
      final run = sampleRun();
      final judgment = parseTimelineJudgment(
        judged([(3, 9, 'empty'), (1, 8, 'fix'), (2, 2, 'big')], 1),
        run,
      );
      expect(judgment.ranking.map((e) => e.k), [1, 2, 3]);
      for (final t in run.timelines) {
        t.files = const [];
      }
      expect(
        parseTimelineJudgment(
          judged([(3, 9, 'a'), (1, 8, 'b'), (2, 2, 'c')], 1),
          run,
        ).ranking.map((e) => e.k),
        [3, 1, 2],
      );
    });

    test('the judge prompt carries plans, diffs and failing tails', () {
      final run = sampleRun();
      final message = timelineJudgeMessage(run, {
        1: '-    return round(amount, 1)\n+    return round(amount, 2)',
        2: 'x' * (judgeDiffLimitChars + 10),
      });
      expect(message, contains('Task: fix it'));
      expect(message, contains('=== Timeline 1: Fix helper\nPlan: plan one'));
      expect(message, contains('+    return round(amount, 2)'));
      expect(
        message,
        contains(
          'Tests: FAILED\nTest files changed: none\nFailing output (tail):',
        ),
      );
      expect(message, contains('The task allows test changes: no'));
      expect(message, contains('AssertionError: 20.0 != 19.99'));
      expect(message, contains('diff cut at $judgeDiffLimitChars characters'));
      expect(message, contains('=== Timeline 3: Decimal'));
      expect(message, contains('Diff: (no changes)'));
      final schema =
          (timelineJudgeFormat([1, 2, 3])['json_schema'] as Map)['schema']
              as Map;
      expect(((schema['properties'] as Map)['ranking'] as Map)['minItems'], 3);
    });

    test('the judgment is saved in the run JSON', () {
      final run = sampleRun()
        ..judgment = {'recommended': 1, 'summary': 's', 'ranking': []};
      final back = TimelineRun.fromJson(
        jsonDecode(jsonEncode(run.toJson())) as Map,
      );
      expect(back.judgment, {'recommended': 1, 'summary': 's', 'ranking': []});
    });
  });

  group('Muse Code progress (event shapes from the 2026-11-01 logs)', () {
    // One real line, trimmed of ids: a proposed shell command.
    const bashProposed =
        '{"schema_version": 1, "sequence": 312, "record_type": "event", "payload_type": "task.lifecycle.proposed", "payload_schema_version": 1, "payload": {"kind": "task_lifecycle", "task_id": "t9", "event": {"kind": "proposed", "task_id": "t9", "task_kind": "tool.bash"}}}';
    String task(String lifecycle, String kind) => jsonEncode({
      'payload_type': 'task.lifecycle.$lifecycle',
      'payload': {
        'kind': 'task_lifecycle',
        'event': {'kind': lifecycle, 'task_kind': kind},
      },
    });
    List<String> step() => [
      task('proposed', 'model.meta.response'),
      task('accepted', 'model.meta.response'),
      task('completed', 'model.meta.response'),
    ];

    test('steps are counted from model.meta.response proposals', () {
      final progress = MuseProgress();
      for (final line in [...step(), ...step(), 'not json', ...step()]) {
        progress.add(line);
      }
      expect(progress.steps, 3);
      expect(progress.awaitingApproval, isNull);
    });

    test('a proposed tool with nothing after it is awaiting approval', () {
      final progress = MuseProgress();
      for (final line in [...step(), bashProposed]) {
        progress.add(line);
      }
      expect(progress.awaitingApproval, 'tool.bash');
      progress.add(task('accepted', 'tool.bash'));
      expect(progress.awaitingApproval, isNull);
    });

    test('a run killed before run.usage reports the steps it took', () {
      final outcome = parseMuseEvents([...step(), ...step(), bashProposed]);
      expect(outcome.steps, 2);
      expect(outcome.terminal, isNull);
      // run.usage wins when it arrives.
      expect(
        parseMuseEvents([
          ...step(),
          jsonEncode({
            'payload_type': 'run.usage',
            'payload': {'calls': 5, 'models': []},
          }),
        ]).steps,
        5,
      );
    });

    test('the stall reason says what the agent was waiting for', () {
      const stall = Duration(seconds: 90);
      expect(
        timelineStallReason('tool.bash', stall),
        'waiting for approval to run a shell command (Doc runs agents without a shell)',
      );
      expect(
        timelineStallReason('tool.edit_file', stall),
        'waiting for approval to use edit_file (nobody can approve it here)',
      );
      expect(timelineStallReason(null, stall), 'no progress for 90 s');
    });

    test('a stalled timeline round-trips and shows as stalled', () {
      final run = sampleRun();
      run.timelines.first
        ..status = TimelineStatus.stalled
        ..reason = 'no progress for 90 s';
      final back = TimelineRun.fromJson(
        jsonDecode(jsonEncode(run.toJson())) as Map,
      );
      expect(back.timelines.first.status, TimelineStatus.stalled);
      expect(
        timelineComparison(back).join('\n'),
        contains(
          'agent: stalled, 5 steps, 1:12, \$0.0031 (no progress for 90 s)',
        ),
      );
    });
  });

  test('the planner hears about bisect, the shell and the smallest change', () {
    final message = timelinePlannerMessage(
      task: 'fix it',
      n: 3,
      brief: null,
      baseDescription: 'after state of checkpoint cp_x (claude-code)',
      baseLabel: 'Raise the tolerance',
      baseChanged: const ['lib/critic.dart (modified)'],
      files: const ['lib/critic.dart'],
      test: 'flutter test',
      bisect: const TimelineBisectFacts(
        label: 'Raise the tolerance',
        changedFiles: ['lib/critic.dart (modified)'],
        diff:
            '--- lib/critic.dart (modified)\n-  toleranceCents = 1;\n+  toleranceCents = 200;',
        explanation: 'The tolerance hides real mismatches.',
      ),
    );
    expect(message, contains("That turn's prompt: Raise the tolerance"));
    expect(message, contains('+  toleranceCents = 200;'));
    expect(
      message,
      contains("Bisect's explanation: The tolerance hides real mismatches."),
    );
    expect(timelinePlannerSystemPrompt, contains('they have no shell'));
    expect(
      timelineAgentTestLine('flutter test'),
      'Work only in this folder. You cannot run commands. Doc runs the tests here after you finish with: flutter test',
    );
    // Without bisect facts, no bisect lines.
    expect(
      timelinePlannerMessage(
        task: 'fix it',
        n: 3,
        brief: null,
        baseDescription: 'b',
        baseLabel: null,
        baseChanged: const [],
        files: const [],
        test: 't',
      ),
      isNot(contains('Bisect')),
    );
  });

  test('the last bisect is stored under a name valid on every platform', () {
    final file = lastBisectFile(const {
      'DOC_DATA_DIR': '/data',
    }, 'sha256:ea9ff4b975655c30c1234567890abcdef');
    expect(
      file.path.split(RegExp(r'[/\\]')).last,
      'ea9ff4b975655c30c1234567.json',
    );
    expect(file.path, isNot(contains(':')));
    expect(
      () => lastBisectFile(const {'DOC_DATA_DIR': '/d'}, 'nonsense'),
      throwsFormatException,
    );
  });

  group('timelines must not win by editing the tests', () {
    test('test files by the usual conventions', () {
      for (final path in [
        'test/money_test.dart',
        'tests/check.txt',
        'src/__tests__/a.js',
        'spec/a.rb',
        'money_test.py',
        'test_money.py',
        'app.test.ts',
        'app.spec.js',
        'src/MoneyTest.java',
      ]) {
        expect(isTestPath(path), isTrue, reason: path);
      }
      for (final path in [
        'money.py',
        'contest.py',
        'latest/notes.md',
        'testing.md',
        'src/Tester.java',
      ]) {
        expect(isTestPath(path), isFalse, reason: path);
      }
    });

    test('only an explicit ask allows test changes', () {
      for (final task in [
        'Fix the tests broken by: Discount takes a fraction, without changing the tests',
        'fix the failing tests',
        'try three different fixes for the failing tests',
        'make the tests pass, do not edit the tests',
      ]) {
        expect(taskAllowsTestEdits(task), isFalse, reason: task);
      }
      for (final task in [
        'update the tests for the new fraction API',
        'add a test for bulk discounts',
        'change apply_discount and rewrite its tests',
      ]) {
        expect(taskAllowsTestEdits(task), isTrue, reason: task);
      }
    });

    test('the prompts say so', () {
      expect(
        timelineAgentNoTestEditsLine,
        'Do not modify test files unless the task explicitly asks you to.',
      );
      expect(
        timelineJudgeSystemPrompt,
        contains('Changing tests to make them pass is a serious flaw'),
      );
      expect(
        timelineJudgeSystemPrompt,
        contains(
          'never recommend a timeline that changed test files unless the task explicitly allows test changes',
        ),
      );
    });

    TimelineRun editingRun(String task) {
      final run = sampleRun();
      return TimelineRun.fromJson({
        ...run.toJson(),
        'task': task,
        'timelines': [
          for (final t in run.toJson()['timelines'] as List)
            if ((t as Map)['k'] == 1)
              {
                ...t,
                'files': [
                  {'path': 'money.py', 'added': 1, 'removed': 1},
                  {'path': 'test_money.py', 'added': 2, 'removed': 2},
                ],
              }
            else
              t,
        ],
      });
    }

    String answer(int? recommended) => jsonEncode({
      'ranking': [
        for (final k in [1, 2, 3])
          {
            'k': k,
            'score': 10 - k,
            'rationale': 'r',
            'risks': <String>[],
            'followed_plan': 'yes',
            'actual_change': 'd',
          },
      ],
      'recommended': recommended,
      'summary': 's',
    });

    test(
      'a timeline that edited tests is flagged and cannot be recommended',
      () {
        final run = editingRun('fix it');
        expect(run.timelines.first.editedTests, ['test_money.py']);
        expect(
          () => parseTimelineJudgment(answer(1), run),
          throwsA(
            isA<TimelineJudgeRefused>()
                .having((e) => e.failedRecommendation, 'drop only it', isTrue)
                .having((e) => e.message, 'message', contains('test_money.py')),
          ),
        );
        expect(
          timelineJudgeMessage(run, const {}),
          contains('Test files changed: test_money.py'),
        );
        expect(
          timelineComparison(run).join('\n'),
          contains('    EDITED TESTS: test_money.py'),
        );
        final lines = timelineJudgmentLines(
          run,
          TimelineJudgment.fromJson(jsonDecode(answer(null)) as Map),
        ).join('\n');
        expect(lines, contains('[1] Fix helper  9/10  — EDITED TESTS'));
        // When the task asks for test changes, it can be recommended.
        expect(
          parseTimelineJudgment(
            answer(1),
            editingRun('fix it and update the tests'),
          ).recommended,
          1,
        );
      },
    );
  });
}
