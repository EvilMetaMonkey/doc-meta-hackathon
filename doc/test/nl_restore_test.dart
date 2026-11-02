import 'package:dmc_doc/doc.dart';
import 'package:test/test.dart';

NlFileState file(String hash) => NlFileState('file', hash, 420);
const absent = NlFileState('absent', null, null);

/// A candidate that changed [files] (path -> (before, after)).
RestoreCandidate candidate(
  String id,
  int at, {
  Map<String, (NlFileState, NlFileState)> files = const {},
  String? label,
  bool undone = false,
}) => RestoreCandidate(
  id: id,
  source: 'claude-code',
  agent: 'claude-code',
  session: 's1',
  label: label ?? 'turn $id',
  createdAt: at,
  closedAt: at + 1,
  alreadyUndone: undone,
  files: [
    for (final entry in files.entries)
      NlCandidateFile(
        path: entry.key,
        change: entry.value.$1.absent
            ? 'created'
            : entry.value.$2.absent
            ? 'deleted'
            : 'modified',
        before: entry.value.$1,
        after: entry.value.$2,
      ),
  ],
);

/// The model's answer: list numbers, 1 = newest.
NlRestoreAnswer answer(
  int pick, {
  NlRestoreMode mode = NlRestoreMode.goBackBefore,
  double confidence = 0.9,
  List<int> alternatives = const [],
  String reason = 'because',
}) => NlRestoreAnswer(
  mode: mode,
  pick: pick,
  confidence: confidence,
  reason: reason,
  alternatives: alternatives,
);

/// dmc's preview envelope: [actions] paths, [conflicts] paths.
NlStepPreview preview(
  RestoreCandidate step, {
  List<String> actions = const [],
  List<String> conflicts = const [],
}) => NlStepPreview(step, {
  'ok': conflicts.isEmpty,
  'errors': [
    for (final path in conflicts)
      {'code': 'workspace_drift', 'message': 'drift', 'path': path},
  ],
  'data': {
    'actions': [
      for (final path in actions) {'path': path},
    ],
    'conflicts': [
      for (final path in conflicts)
        {'code': 'workspace_drift', 'message': 'drift', 'path': path},
    ],
    'dataErrors': [],
    'skipped': [],
  },
});

void main() {
  // Newest first, as Doc offers them.
  final c3 = candidate(
    'cp_c',
    300,
    files: {'notes.md': (file('n1'), file('n2'))},
  );
  final c2 = candidate(
    'cp_b',
    200,
    files: {
      'auth.py': (file('a1'), file('a2')),
      'notes.md': (absent, file('n1')),
    },
  );
  final c1 = candidate(
    'cp_a',
    100,
    files: {'app.py': (file('p1'), file('p2'))},
  );
  final candidates = [c3, c2, c1];

  group('parseNlRestoreAnswer', () {
    test('accepts the JSON object, also in a ```json fence', () {
      const json =
          '{"mode":"undo_turn","pick":2,"confidence":0.8,"reason":"r","alternatives":[3]}';
      for (final text in [json, '```json\n$json\n```']) {
        final parsed = parseNlRestoreAnswer(text);
        expect(parsed.mode, NlRestoreMode.undoTurn);
        expect(parsed.pick, 2);
        expect(parsed.confidence, 0.8);
        expect(parsed.alternatives, [3]);
        // --json keeps checkpointId (and ids in alternatives), and adds pick.
        expect(parsed.toJson(candidates), {
          'mode': 'undo_turn',
          'pick': 2,
          'checkpointId': 'cp_b',
          'confidence': 0.8,
          'reason': 'r',
          'alternatives': ['cp_a'],
          'alternativePicks': [3],
        });
      }
    });

    test('the old answer shape, with a checkpoint_id, is refused', () {
      expect(
        () => parseNlRestoreAnswer(
          '{"mode":"undo_turn","checkpoint_id":"cp_b","confidence":0.8,"reason":"r","alternatives":[]}',
        ),
        throwsA(
          isA<NlRestoreRefused>().having(
            (e) => e.message,
            'message',
            contains('not a "checkpoint_id"'),
          ),
        ),
      );
    });

    test('refuses anything else', () {
      for (final text in [
        'take cp_b',
        '[]',
        '{"mode":"delete_all","pick":2,"confidence":1,"reason":"r","alternatives":[]}',
        '{"mode":"undo_turn","pick":2,"confidence":1.5,"reason":"r","alternatives":[]}',
        '{"mode":"undo_turn","pick":"2","confidence":1,"reason":"r","alternatives":[]}',
        '{"mode":"undo_turn","pick":2.5,"confidence":1,"reason":"r","alternatives":[]}',
        '{"mode":"undo_turn","pick":2,"confidence":1,"reason":"r","alternatives":["cp_a"]}',
      ]) {
        expect(
          () => parseNlRestoreAnswer(text),
          throwsA(isA<NlRestoreRefused>()),
          reason: text,
        );
      }
    });
  });

  group('planNaturalRestore', () {
    test('a number outside the list is refused', () {
      for (final pick in [0, 4, -1]) {
        expect(
          () => planNaturalRestore(answer(pick), candidates),
          throwsA(
            isA<NlRestoreRefused>().having(
              (e) => e.message,
              'message',
              contains('the list has 3 checkpoint(s) (1-3)'),
            ),
          ),
          reason: '$pick',
        );
      }
      expect(
        () => planNaturalRestore(answer(2, alternatives: [9]), candidates),
        throwsA(isA<NlRestoreRefused>()),
      );
    });

    test('go_back_before undoes the target and every later one, newest '
        'first', () {
      final plan = planNaturalRestore(answer(2), candidates);
      expect([for (final s in plan.steps) s.id], ['cp_c', 'cp_b']);
      expect(plan.oldestStep!.id, 'cp_b');
      expect(plan.needsChoice, isFalse);
    });

    test('undo_turn undoes one checkpoint', () {
      final plan = planNaturalRestore(
        answer(2, mode: NlRestoreMode.undoTurn),
        candidates,
      );
      expect([for (final s in plan.steps) s.id], ['cp_b']);
    });

    test('low confidence or alternatives need a choice', () {
      expect(
        planNaturalRestore(answer(2, confidence: 0.59), candidates).needsChoice,
        isTrue,
      );
      final withAlternatives = planNaturalRestore(
        answer(2, alternatives: [2, 3, 3]),
        candidates,
      );
      expect(withAlternatives.needsChoice, isTrue);
      expect(
        [for (final c in withAlternatives.choices) c.id],
        ['cp_b', 'cp_a'],
      );
      expect(
        planNaturalRestore(answer(2, confidence: 0.6), candidates).needsChoice,
        isFalse,
      );
    });

    test('already undone checkpoints are not restored again', () {
      final undone = candidate('cp_c', 300, undone: true);
      final plan = planNaturalRestore(answer(2), [undone, c2, c1]);
      expect([for (final s in plan.steps) s.id], ['cp_b']);
      expect([for (final s in plan.alreadyUndone) s.id], ['cp_c']);
    });
  });

  group('combineStepPreviews', () {
    test('a file a newer step puts back is chained, not a conflict', () {
      // dmc previews cp_b against the working copy, where notes.md is
      // still cp_c's after state, so it reports drift on notes.md.
      final combined = combineStepPreviews([
        preview(c3, actions: ['notes.md']),
        preview(c2, actions: ['auth.py'], conflicts: ['notes.md']),
      ]);
      expect(combined.canApply, isTrue, reason: '${combined.conflicts}');
      final byPath = {for (final f in combined.files) f.path: f};
      expect(byPath.keys, ['auth.py', 'notes.md']);
      expect(byPath['notes.md']!.currentStep, 0);
      expect(byPath['notes.md']!.finalStep, 1);
      expect(byPath['notes.md']!.result.absent, isTrue);
      expect(byPath['notes.md']!.description, 'delete it');
      expect(
        byPath['auth.py']!.description,
        'put back the version from before step 2',
      );
    });

    test('a file changed between turns breaks the chain', () {
      final edited = candidate(
        'cp_b',
        200,
        files: {'notes.md': (absent, file('n-other'))},
      );
      final combined = combineStepPreviews([
        preview(c3, actions: ['notes.md']),
        preview(edited, conflicts: ['notes.md']),
      ]);
      expect(combined.canApply, isFalse);
      expect(combined.conflicts.single.code, 'chain_mismatch');
    });

    test('dmc conflicts on files no newer step touches stand', () {
      final combined = combineStepPreviews([
        preview(c3, conflicts: ['notes.md']),
      ]);
      expect(combined.canApply, isFalse);
      expect(combined.conflicts.single.code, 'workspace_drift');
      expect(combined.conflicts.single.path, 'notes.md');
    });

    test('steps that cancel out are no net change', () {
      final created = candidate(
        'cp_x',
        100,
        files: {'tmp.txt': (absent, file('t'))},
      );
      final deleted = candidate(
        'cp_y',
        200,
        files: {'tmp.txt': (file('t'), absent)},
      );
      final combined = combineStepPreviews([
        preview(deleted, actions: ['tmp.txt']),
        preview(created, conflicts: ['tmp.txt']),
      ]);
      expect(combined.canApply, isTrue);
      expect(combined.files.single.netChange, isFalse);
      expect(combined.changing, isEmpty);
    });
  });

  test('labels dmc cut are marked as truncated', () {
    final cut = candidate('cp_t', 1, label: 'Rewrite the auth module to…');
    expect(cut.labelTruncated, isTrue);
    expect(cut.displayLabel, endsWith('(truncated by dmc)'));
    expect(cut.modelLabel, contains(truncatedLabelMarker));
    expect(cut.toJson()['labelTruncated'], isTrue);
    final message = nlRestoreUserMessage('before auth', [cut, c1]);
    expect(
      message,
      contains('Rewrite the auth module to $truncatedLabelMarker'),
    );
    expect(message, contains('label: turn cp_a\n'));
  });

  test('the schema only allows list numbers; the message shows no ids', () {
    final schema =
        (nlRestoreResponseFormat(candidates)['json_schema'] as Map)['schema']
            as Map;
    final properties = schema['properties'] as Map;
    expect(schema['required'], contains('pick'));
    expect(properties.containsKey('checkpoint_id'), isFalse);
    expect((properties['pick'] as Map)['enum'], [1, 2, 3]);
    expect(((properties['alternatives'] as Map)['items'] as Map)['enum'], [
      1,
      2,
      3,
    ]);
    final message = nlRestoreUserMessage('before auth', candidates);
    expect(message, contains('2. time: '));
    expect(message, isNot(contains('id: ')));
  });

  group('the critic-agent failure (2026-11-01)', () {
    // Newest first, as offered: #1 a doc-comment turn in analysis_agent.dart,
    // #3 the toleranceCents change in critic_agent.dart. The ids differ only
    // in the middle, as dmc's do.
    RestoreCandidate turn(String middle, int at, String label, String path) =>
        candidate(
          'cp_mvx${middle}_8f3a1c2e9b7d4f6a0c5e1b3d7f9a2c4e',
          at,
          label: label,
          files: {path: (file('$middle-1'), file('$middle-2'))},
        );
    final turns = [
      turn(
        'q2a1',
        600,
        'Add a doc comment to AnalysisAgent.run',
        'lib/services/agent_engine/analysis_agent.dart',
      ),
      turn(
        'q1z9',
        500,
        'Rename the bill parser',
        'lib/services/bill_parser.dart',
      ),
      turn(
        'q0m4',
        400,
        'In critic_agent.dart, change the default toleranceCents from 1 to 200',
        'lib/services/agent_engine/critic_agent.dart',
      ),
      turn('p9k2', 300, 'Add a widget test', 'test/widget_test.dart'),
      turn('p8j1', 200, 'Update README', 'README.md'),
      turn('p7h0', 100, 'Bump the version', 'pubspec.yaml'),
    ];
    const request =
        'take me back to before Claude changed the tolerance in the critic agent';

    test('the reason says #3 and the answer picks 3: turn 3 is planned', () {
      final parsed = parseNlRestoreAnswer(
        '{"mode":"go_back_before","pick":3,"confidence":0.95,"reason":"Checkpoint 3 is the toleranceCents change.","alternatives":[]}',
      );
      final plan = crossCheckRestorePlan(
        planNaturalRestore(parsed, turns),
        request,
        turns,
      );
      expect(plan.target.id, turns[2].id);
      expect(plan.needsChoice, isFalse);
      expect(plan.crossCheck, isNull);
      expect(
        nlTurnSummary(plan.target, turns),
        'Turn 3 of 6 · claude-code · In critic_agent.dart, change the default toleranceCents from 1 to 200 · files: lib/services/agent_engine/critic_agent.dart',
      );
    });

    test('the same wrong pick (#1) is caught: the user must choose', () {
      final plan = crossCheckRestorePlan(
        planNaturalRestore(
          answer(
            1,
            confidence: 0.95,
            reason: 'Checkpoint 3 is the toleranceCents change.',
          ),
          turns,
        ),
        request,
        turns,
      );
      expect(plan.needsChoice, isTrue);
      expect(plan.confidence, lessThan(nlRestoreMinConfidence));
      expect([for (final c in plan.choices) c.id], [turns[0].id, turns[2].id]);
      expect(
        plan.crossCheck,
        'Your request names lib/services/agent_engine/critic_agent.dart, which turn 1 does not touch; turn 3 does.',
      );
      expect(plan.toJson()['crossCheck'], plan.crossCheck);
    });

    test('files are named by path, basename or every word of the name', () {
      expect(filesNamedInRequest(request, turns), {
        'lib/services/agent_engine/critic_agent.dart',
      });
      expect(
        filesNamedInRequest('undo the change to critic_agent.dart', turns),
        {'lib/services/agent_engine/critic_agent.dart'},
      );
      expect(filesNamedInRequest('before the README edit', turns), {
        'README.md',
      });
      // One word of a two-word name is not enough ("agent").
      expect(filesNamedInRequest('before the agent change', turns), isEmpty);
      // A file the picked turn touches: no change to the plan.
      final plan = planNaturalRestore(answer(3), turns);
      expect(crossCheckRestorePlan(plan, request, turns), same(plan));
    });
  });

  test('lineCounts', () {
    expect(lineCounts('a\nb\nc\n', 'a\nB\nc\nd\n'), (added: 2, removed: 1));
    expect(lineCounts(null, 'x\ny\n'), (added: 2, removed: 0));
    expect(lineCounts('x\n', null), (added: 0, removed: 1));
  });

  test('recentClosedCheckpoints keeps the newest closed ones', () {
    final items = [
      {'id': 'cp_1', 'status': 'closed', 'createdAt': 1},
      {'id': 'cp_2', 'status': 'invalid', 'createdAt': 2},
      {'id': 'cp_3', 'status': 'closed', 'createdAt': 3},
      {'id': 'cp_4', 'status': 'closed', 'createdAt': 4},
    ];
    expect(
      [for (final i in recentClosedCheckpoints(items, 2)) i['id']],
      ['cp_4', 'cp_3'],
    );
  });
}
