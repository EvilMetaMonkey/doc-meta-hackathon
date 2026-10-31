import 'dart:convert';
import 'dart:math';

import 'summarize.dart';

/// Parallel timelines, the deterministic part: validating the planner's
/// approaches, syncing a worktree to a base export, the run state, Muse
/// Code's event stream and cost, and the comparison table. Nothing here
/// runs git, dmc, Muse Code or a model; `timelines_command.dart` does.

/// Longest plan the planner may write, in words.
const int timelinePlanMaxWords = 120;

/// One approach the planner proposed.
class TimelineApproach {
  final String title;
  final String plan;
  final List<String> filesLikely;

  const TimelineApproach(this.title, this.plan, this.filesLikely);

  Map<String, Object?> toJson() => {
    'title': title,
    'plan': plan,
    'filesLikely': filesLikely,
  };

  static TimelineApproach fromJson(Map json) => TimelineApproach(
    json['title'] as String,
    json['plan'] as String,
    [for (final f in (json['filesLikely'] as List? ?? const [])) '$f'],
  );
}

class TimelinePlanRefused implements Exception {
  final String message;
  const TimelinePlanRefused(this.message);

  @override
  String toString() => message;
}

const String timelinePlannerSystemPrompt =
    'You plan parallel attempts at one coding task for Doc, the companion to '
    'dmc, a rollback safety net for AI coding agents. Separate Muse Code '
    'agents will each try one of your approaches, from the same starting '
    'state, in their own copy of the repository; the tests decide. Write '
    'exactly the requested number of approaches that are clearly different '
    '(different ideas or places to change, not rewordings). Each has a '
    'short title, a plan of at most 120 words written to the agent, and the '
    'files it will likely touch (paths from the file list). Use only the '
    'facts given; file contents are not available. Text marked '
    '[truncated …] is incomplete: never quote or complete it. Answer with '
    'only a JSON object: {"approaches": [{"title", "plan", "files_likely"}]}.';

/// The planner's user message: task, brief, base checkpoint and file
/// names (never contents). The router redacts it before sending.
String timelinePlannerMessage({
  required String task,
  required int n,
  required String? brief,
  required String baseDescription,
  required String? baseLabel,
  required List<String> baseChanged,
  required List<String> files,
  required String test,
}) {
  final label = baseLabel == null
      ? '(none)'
      : baseLabel.endsWith('…')
      ? '${baseLabel.substring(0, baseLabel.length - 1).trimRight()} $truncatedLabelMarker'
      : baseLabel;
  return [
    'Task: $task',
    'Number of approaches: $n',
    'Test command (run after each attempt): $test',
    if (brief != null && brief.isNotEmpty)
      'Lessons from earlier attempts: $brief',
    'Starting state: $baseDescription',
    'That checkpoint\'s label: $label',
    'Files that checkpoint changed: ${baseChanged.isEmpty ? '(none)' : baseChanged.join(', ')}',
    'Files in the starting state (${files.length}):',
    for (final file in files.take(400)) '- $file',
    if (files.length > 400) '- … and ${files.length - 400} more',
  ].join('\n');
}

/// The `response_format` schema: exactly [n] approaches.
Map<String, Object?> timelineApproachesFormat(int n) => {
  'type': 'json_schema',
  'json_schema': {
    'name': 'timeline_approaches',
    'strict': true,
    'schema': {
      'type': 'object',
      'additionalProperties': false,
      'required': ['approaches'],
      'properties': {
        'approaches': {
          'type': 'array',
          'minItems': n,
          'maxItems': n,
          'items': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['title', 'plan', 'files_likely'],
            'properties': {
              'title': {'type': 'string'},
              'plan': {'type': 'string'},
              'files_likely': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
          },
        },
      },
    },
  },
};

Set<String> _words(String text) => {
  for (final word in text.toLowerCase().split(RegExp(r'[^a-z0-9_]+')))
    if (word.length > 2) word,
};

/// Word-set overlap (Jaccard) of two plans, 0..1.
double planSimilarity(String a, String b) {
  final x = _words(a);
  final y = _words(b);
  if (x.isEmpty && y.isEmpty) return 1;
  return x.intersection(y).length / x.union(y).length;
}

/// Plans more alike than this are not "clearly different".
const double timelineMaxSimilarity = 0.7;

/// Strictly parse and validate the planner's answer: exactly [n]
/// approaches, each with a title and a plan of at most 120 words, titles
/// distinct, plans clearly different. `files_likely` keeps only
/// workspace-relative paths (any not in [files] are dropped).
List<TimelineApproach> parseTimelineApproaches(
  String content,
  int n, {
  Set<String> files = const {},
}) {
  var text = content.trim();
  final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    throw const TimelinePlanRefused('The answer was not a JSON object.');
  }
  if (json is! Map || json['approaches'] is! List) {
    throw const TimelinePlanRefused('The answer has no "approaches" list.');
  }
  final items = json['approaches'] as List;
  if (items.length != n) {
    throw TimelinePlanRefused(
      'Expected exactly $n approaches, got ${items.length}.',
    );
  }
  final approaches = <TimelineApproach>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is! Map ||
        item['title'] is! String ||
        item['plan'] is! String ||
        (item['files_likely'] != null && item['files_likely'] is! List)) {
      throw TimelinePlanRefused(
        'Approach ${i + 1} needs a string "title", a string "plan" and a "files_likely" list.',
      );
    }
    final title = (item['title'] as String).trim();
    final plan = (item['plan'] as String).trim();
    if (title.isEmpty || plan.isEmpty) {
      throw TimelinePlanRefused(
        'Approach ${i + 1} has an empty title or plan.',
      );
    }
    final words = plan.split(RegExp(r'\s+')).length;
    if (words > timelinePlanMaxWords) {
      throw TimelinePlanRefused(
        'Approach ${i + 1}\'s plan has $words words; at most $timelinePlanMaxWords.',
      );
    }
    final likely = <String>[];
    for (final raw in (item['files_likely'] as List? ?? const [])) {
      final path = '$raw'.trim().replaceAll('\\', '/');
      if (path.isEmpty || path.startsWith('/') || path.contains('..')) continue;
      if (files.isNotEmpty && !files.contains(path)) continue;
      if (!likely.contains(path)) likely.add(path);
    }
    approaches.add(TimelineApproach(title, plan, likely));
  }
  for (var i = 0; i < approaches.length; i++) {
    for (var j = i + 1; j < approaches.length; j++) {
      if (approaches[i].title.toLowerCase() ==
          approaches[j].title.toLowerCase()) {
        throw TimelinePlanRefused(
          'Approaches ${i + 1} and ${j + 1} have the same title.',
        );
      }
      final similarity = planSimilarity(approaches[i].plan, approaches[j].plan);
      if (similarity > timelineMaxSimilarity) {
        throw TimelinePlanRefused(
          'Approaches ${i + 1} and ${j + 1} are not clearly different (${(similarity * 100).round()}% of their words are shared).',
        );
      }
    }
  }
  return approaches;
}

/// One step of making a worktree's tree exactly the base export.
class SyncAction {
  /// `copy` (from the export) or `delete`.
  final String kind;
  final String path;

  const SyncAction(this.kind, this.path);

  @override
  bool operator ==(Object other) =>
      other is SyncAction && other.kind == kind && other.path == path;

  @override
  int get hashCode => Object.hash(kind, path);

  @override
  String toString() => '$kind $path';
}

/// The actions that make a worktree whose tracked and unignored files are
/// [worktreeFiles] hold exactly [exportFiles] (both workspace-relative
/// POSIX paths): copy every export file in (contents may differ), delete
/// every other file. Paths under `.git` and `.dmc` are never touched.
List<SyncAction> treeSyncActions(
  Set<String> exportFiles,
  Set<String> worktreeFiles,
) {
  bool reserved(String path) {
    final first = path.split('/').first;
    return first == '.git' || first == '.dmc';
  }

  return [
    for (final path in exportFiles.toList()..sort())
      if (!reserved(path)) SyncAction('copy', path),
    for (final path in worktreeFiles.toList()..sort())
      if (!reserved(path) && !exportFiles.contains(path))
        SyncAction('delete', path),
  ];
}

/// What one `muse exec --json` run reported.
class MuseOutcome {
  /// `completed`, `failed` or null (no terminal event: killed or crashed).
  final String? terminal;
  final String? reason;
  final String? model;
  final int steps;
  final int inputTokens;
  final int cachedTokens;
  final int outputTokens;
  final String finalText;

  const MuseOutcome({
    this.terminal,
    this.reason,
    this.model,
    this.steps = 0,
    this.inputTokens = 0,
    this.cachedTokens = 0,
    this.outputTokens = 0,
    this.finalText = '',
  });

  bool get stepLimit => reason?.contains('step(s)') ?? false;
}

/// Read Muse Code 1.4.14's `--json` event lines (verified on Mike's Mac,
/// 2026-10-28): `run.usage` carries `models[{model, input_tokens,
/// cached_tokens, output_tokens}]` and `calls` (model steps), and
/// `run.terminal.completed` / `run.terminal.failed` carry `terminal`,
/// `text` and `reason` (for example "model did not reach a terminal state
/// within 8 step(s)"). Unknown lines are ignored.
MuseOutcome parseMuseEvents(Iterable<String> lines) {
  String? terminal;
  String? reason;
  String? model;
  var steps = 0;
  var input = 0;
  var cached = 0;
  var output = 0;
  var text = '';
  for (final line in lines) {
    if (!line.trimLeft().startsWith('{')) continue;
    final Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (event is! Map) continue;
    final type = event['payload_type'];
    final payload = event['payload'];
    if (payload is! Map) continue;
    if (type == 'run.usage') {
      steps = (payload['calls'] as num?)?.toInt() ?? steps;
      input = cached = output = 0;
      for (final m
          in (payload['models'] as List? ?? const []).whereType<Map>()) {
        model ??= m['model'] as String?;
        input += (m['input_tokens'] as num?)?.toInt() ?? 0;
        cached += (m['cached_tokens'] as num?)?.toInt() ?? 0;
        output += (m['output_tokens'] as num?)?.toInt() ?? 0;
      }
    } else if (type is String && type.startsWith('run.terminal.')) {
      terminal = payload['terminal'] as String? ?? type.split('.').last;
      reason = payload['reason'] as String?;
      text = payload['text'] as String? ?? '';
    }
  }
  return MuseOutcome(
    terminal: terminal,
    reason: reason,
    model: model,
    steps: steps,
    inputTokens: input,
    cachedTokens: cached,
    outputTokens: output,
    finalText: text,
  );
}

/// Token prices for Muse Code's models, USD per million (Meta's pricing
/// page, 2026-10-28): input, cached input, output.
const Map<String, (double, double, double)> museModelPrices = {
  'muse-spark-1.3-contributor': (0.10, 0.002, 0.20),
  'muse-spark-1.2-contributor': (0.10, 0.002, 0.20),
  'muse-spark-1.3': (1.25, 0.15, 4.25),
  'muse-spark-1.2': (1.25, 0.15, 4.25),
  'muse-wonder-1.0': (4.00, 0.20, 20.00),
};

/// The cost of one Muse Code run, or null for an unknown model.
double? museCostUsd(MuseOutcome outcome) {
  final price = museModelPrices[outcome.model];
  if (price == null) return null;
  final (input, cachedInput, output) = price;
  final fresh = max(0, outcome.inputTokens - outcome.cachedTokens);
  return (fresh * input +
          outcome.cachedTokens * cachedInput +
          outcome.outputTokens * output) /
      1e6;
}

/// Tokens one Muse Code step used on this Mac (27–28k input, a few
/// hundred output); the estimate assumes no cache hits.
const int museInputTokensPerStep = 30000;
const int museOutputTokensPerStep = 600;

/// The upper estimate for [n] agents of at most [maxSteps] steps each on
/// [model], with no cache discount, or null when its price is unknown.
double? estimateTimelineCostFor(int n, int maxSteps, String model) {
  final price = museModelPrices[model];
  if (price == null) return null;
  return n *
      maxSteps *
      (museInputTokensPerStep * price.$1 + museOutputTokensPerStep * price.$3) /
      1e6;
}

/// The model Muse Code uses by default: `model` in its user settings
/// ([settingsJson], from `~/.config/muse/settings.json`), or null.
String? museConfiguredModel(String? settingsJson) {
  if (settingsJson == null) return null;
  try {
    final json = jsonDecode(settingsJson);
    final model = json is Map ? json['model'] : null;
    return model is String && model.trim().isNotEmpty ? model.trim() : null;
  } on FormatException {
    return null;
  }
}

/// Upper estimates for [n] agents of at most [maxSteps] steps each, in
/// Contributor and Standard mode (Muse Spark 1.3 prices).
({double contributor, double standard}) estimateTimelineCost(
  int n,
  int maxSteps,
) {
  double at((double, double, double) price) =>
      n *
      maxSteps *
      (museInputTokensPerStep * price.$1 + museOutputTokensPerStep * price.$3) /
      1e6;
  return (
    contributor: at(museModelPrices['muse-spark-1.3-contributor']!),
    standard: at(museModelPrices['muse-spark-1.3']!),
  );
}

/// One file a timeline changed against the base.
class TimelineFileChange {
  final String path;

  /// Null for a binary file.
  final int? added;
  final int? removed;

  const TimelineFileChange(this.path, this.added, this.removed);

  Map<String, Object?> toJson() => {
    'path': path,
    'added': added,
    'removed': removed,
  };

  static TimelineFileChange fromJson(Map json) => TimelineFileChange(
    json['path'] as String,
    (json['added'] as num?)?.toInt(),
    (json['removed'] as num?)?.toInt(),
  );
}

/// Parse `git diff --numstat` output.
List<TimelineFileChange> parseNumstat(String text) => [
  for (final line in const LineSplitter().convert(text))
    if (line.split('\t') case [
      final a,
      final r,
      final path,
    ] when path.isNotEmpty)
      TimelineFileChange(path, int.tryParse(a), int.tryParse(r)),
];

/// The tests in one timeline.
class TimelineTest {
  final bool passed;
  final bool timedOut;
  final bool setupFailed;
  final double seconds;
  final String tail;

  const TimelineTest({
    required this.passed,
    required this.timedOut,
    required this.setupFailed,
    required this.seconds,
    required this.tail,
  });

  Map<String, Object?> toJson() => {
    'passed': passed,
    'timedOut': timedOut,
    'setupFailed': setupFailed,
    'seconds': seconds,
    'outputTail': tail,
  };

  static TimelineTest fromJson(Map json) => TimelineTest(
    passed: json['passed'] as bool,
    timedOut: json['timedOut'] as bool? ?? false,
    setupFailed: json['setupFailed'] as bool? ?? false,
    seconds: (json['seconds'] as num?)?.toDouble() ?? 0,
    tail: json['outputTail'] as String? ?? '',
  );
}

/// Agent status of one timeline.
enum TimelineStatus { pending, running, done, failed, timedOut, stopped }

/// One timeline: its approach, worktree, branch, agent result and tests.
class Timeline {
  final int k;
  final TimelineApproach approach;
  final String branch;
  final String worktree;
  TimelineStatus status;
  String? reason;
  int steps;
  int inputTokens;
  int cachedTokens;
  int outputTokens;
  String? model;
  double? costUsd;
  double seconds;
  String? commit;
  List<TimelineFileChange> files;
  TimelineTest? test;
  int checkpoints;

  Timeline({
    required this.k,
    required this.approach,
    required this.branch,
    required this.worktree,
    this.status = TimelineStatus.pending,
    this.reason,
    this.steps = 0,
    this.inputTokens = 0,
    this.cachedTokens = 0,
    this.outputTokens = 0,
    this.model,
    this.costUsd,
    this.seconds = 0,
    this.commit,
    this.files = const [],
    this.test,
    this.checkpoints = 0,
  });

  Map<String, Object?> toJson() => {
    'k': k,
    'approach': approach.toJson(),
    'branch': branch,
    'worktree': worktree,
    'status': status.name,
    'reason': reason,
    'steps': steps,
    'inputTokens': inputTokens,
    'cachedTokens': cachedTokens,
    'outputTokens': outputTokens,
    'model': model,
    'costUsd': costUsd,
    'seconds': seconds,
    'commit': commit,
    'files': [for (final f in files) f.toJson()],
    'test': test?.toJson(),
    'checkpoints': checkpoints,
  };

  static Timeline fromJson(Map json) => Timeline(
    k: (json['k'] as num).toInt(),
    approach: TimelineApproach.fromJson(json['approach'] as Map),
    branch: json['branch'] as String,
    worktree: json['worktree'] as String,
    status: TimelineStatus.values.byName(json['status'] as String),
    reason: json['reason'] as String?,
    steps: (json['steps'] as num?)?.toInt() ?? 0,
    inputTokens: (json['inputTokens'] as num?)?.toInt() ?? 0,
    cachedTokens: (json['cachedTokens'] as num?)?.toInt() ?? 0,
    outputTokens: (json['outputTokens'] as num?)?.toInt() ?? 0,
    model: json['model'] as String?,
    costUsd: (json['costUsd'] as num?)?.toDouble(),
    seconds: (json['seconds'] as num?)?.toDouble() ?? 0,
    commit: json['commit'] as String?,
    files: [
      for (final f in (json['files'] as List? ?? const []).whereType<Map>())
        TimelineFileChange.fromJson(f),
    ],
    test: json['test'] is Map
        ? TimelineTest.fromJson(json['test'] as Map)
        : null,
    checkpoints: (json['checkpoints'] as num?)?.toInt() ?? 0,
  );
}

/// A whole `doc timelines` run, saved as `run.json` in Doc's data dir.
class TimelineRun {
  final String id;
  final String createdAt;
  final String task;
  final String test;
  final String? setup;
  final List<String> links;
  final int maxSteps;
  final int timeoutMinutes;
  final String repo;
  final String workspaceFingerprint;
  final String baseCheckpoint;
  final String baseState;
  final String? baseLabel;

  /// The "timeline base" commit every timeline branch starts from.
  String? baseCommit;
  final String? brief;
  final Map<String, Object?> planner;
  final List<Timeline> timelines;

  /// `planned`, `running`, `done`, `interrupted`, `declined` or `cleaned`.
  String status;
  int? picked;
  double seconds;

  /// Wonder's judgment and how it was obtained (provider, model, tokens,
  /// cost), or null when the run was not judged.
  Map<String, Object?>? judgment;

  TimelineRun({
    required this.id,
    required this.createdAt,
    required this.task,
    required this.test,
    required this.setup,
    required this.links,
    required this.maxSteps,
    required this.timeoutMinutes,
    required this.repo,
    required this.workspaceFingerprint,
    required this.baseCheckpoint,
    required this.baseState,
    required this.baseLabel,
    required this.baseCommit,
    required this.brief,
    required this.planner,
    required this.timelines,
    this.status = 'planned',
    this.picked,
    this.seconds = 0,
    this.judgment,
  });

  /// "archived" for every timeline but the picked one, once one is picked.
  String pickState(Timeline timeline) => picked == null
      ? 'not picked yet'
      : picked == timeline.k
      ? 'picked'
      : 'archived';

  Map<String, Object?> toJson() => {
    'command': 'doc.timelines',
    'version': 1,
    'id': id,
    'createdAt': createdAt,
    'status': status,
    'task': task,
    'test': test,
    'setup': setup,
    'links': links,
    'maxSteps': maxSteps,
    'timeoutMinutes': timeoutMinutes,
    'repo': repo,
    'workspaceFingerprint': workspaceFingerprint,
    'base': {
      'checkpointId': baseCheckpoint,
      'state': baseState,
      'label': baseLabel,
      'commit': baseCommit,
    },
    'brief': brief,
    'planner': planner,
    'timelines': [
      for (final t in timelines) {...t.toJson(), 'pick': pickState(t)},
    ],
    'picked': picked,
    'seconds': seconds,
    'judgment': judgment,
  };

  static TimelineRun fromJson(Map json) {
    final base = json['base'] as Map;
    return TimelineRun(
      id: json['id'] as String,
      createdAt: json['createdAt'] as String,
      task: json['task'] as String,
      test: json['test'] as String,
      setup: json['setup'] as String?,
      links: [for (final l in (json['links'] as List? ?? const [])) '$l'],
      maxSteps: (json['maxSteps'] as num).toInt(),
      timeoutMinutes: (json['timeoutMinutes'] as num).toInt(),
      repo: json['repo'] as String,
      workspaceFingerprint: json['workspaceFingerprint'] as String,
      baseCheckpoint: base['checkpointId'] as String,
      baseState: base['state'] as String,
      baseLabel: base['label'] as String?,
      baseCommit: base['commit'] as String?,
      brief: json['brief'] as String?,
      planner: ((json['planner'] as Map?) ?? const {}).cast<String, Object?>(),
      timelines: [
        for (final t in (json['timelines'] as List).whereType<Map>())
          Timeline.fromJson(t),
      ],
      status: json['status'] as String? ?? 'planned',
      picked: (json['picked'] as num?)?.toInt(),
      seconds: (json['seconds'] as num?)?.toDouble() ?? 0,
      judgment: (json['judgment'] as Map?)?.cast<String, Object?>(),
    );
  }
}

String _clock(double seconds) {
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String _statusText(Timeline t) => switch (t.status) {
  TimelineStatus.done => 'done',
  TimelineStatus.failed =>
    t.reason != null && t.reason!.contains('step(s)') ? 'step limit' : 'failed',
  TimelineStatus.timedOut => 'timed out',
  TimelineStatus.stopped => 'stopped',
  TimelineStatus.running => 'running',
  TimelineStatus.pending => 'not run',
};

/// The side-by-side comparison of a run, one block per timeline.
List<String> timelineComparison(TimelineRun run, {int tailLines = 8}) {
  final lines = <String>[];
  // What each diff really did, once Wonder has judged the run.
  final judged = run.judgment == null
      ? const <int, JudgeEntry>{}
      : {
          for (final e in TimelineJudgment.fromJson(run.judgment!).ranking)
            e.k: e,
        };
  for (final t in run.timelines) {
    final added = t.files.fold<int>(0, (sum, f) => sum + (f.added ?? 0));
    final removed = t.files.fold<int>(0, (sum, f) => sum + (f.removed ?? 0));
    final test = t.test;
    final testText = test == null
        ? 'not run'
        : test.passed
        ? 'PASS (${test.seconds.toStringAsFixed(1)}s)'
        : test.setupFailed
        ? 'FAIL (setup failed)'
        : test.timedOut
        ? 'FAIL (timed out)'
        : 'FAIL (${test.seconds.toStringAsFixed(1)}s)';
    lines
      ..add('[${t.k}] ${t.approach.title}')
      ..add(
        '    agent: ${_statusText(t)}, ${t.steps} step(s), ${_clock(t.seconds)}'
        '${t.costUsd == null ? '' : ', \$${t.costUsd!.toStringAsFixed(4)}'}'
        '${t.reason != null && t.status != TimelineStatus.done ? ' (${t.reason})' : ''}',
      )
      ..add(
        '    files: ${t.files.isEmpty ? 'no changes' : t.files.map((f) => f.added == null ? '${f.path} (binary)' : '${f.path} +${f.added} −${f.removed}').join(', ')}'
        '${t.files.length > 1 ? '  (total +$added −$removed)' : ''}',
      )
      ..addAll([
        if (judged[t.k]?.actualChange case final did?)
          '    did (per Wonder): $did${judged[t.k]!.strayed ? '  ← ${planAdherenceText(judged[t.k]!.followedPlan)}' : ''}',
      ])
      ..add('    tests: $testText')
      ..add('    branch: ${t.branch}  (${run.pickState(t)})');
    if (test != null && !test.passed && test.tail.trim().isNotEmpty) {
      final tail = const LineSplitter().convert(test.tail.trimRight());
      for (final line in tail.skip(max(0, tail.length - tailLines))) {
        lines.add('      | $line');
      }
    }
  }
  return lines;
}

// ---------------------------------------------------------------------------
// Judging (part 2): Wonder ranks the finished timelines; the user picks.

/// Longest rationale per timeline, in words.
const int judgeRationaleMaxWords = 60;

/// Most diff text sent per timeline, in characters.
const int judgeDiffLimitChars = 6000;

const String timelineJudgeSystemPrompt =
    'You judge parallel attempts at one coding task for Doc, the companion '
    'to dmc, a rollback safety net for AI coding agents. Each timeline is '
    'one agent\'s attempt from the same starting state, with its approach, '
    'its diff against that state, and whether the tests passed. Rank every '
    'timeline from best to worst for the task: correct, minimal, safe and '
    'consistent with the tests and the rest of the code. Give each a score '
    'from 0 to 10, a rationale of at most 60 words, and its risks. '
    'Check each diff against its own plan: say whether it followed the plan '
    '("yes", "partly" or "no"; an agent may solve the task another way '
    'than planned), and describe in at most 25 words what the diff actually '
    'does. Recommend one timeline only if its tests passed; otherwise '
    'recommend none (null). A timeline with no changes did nothing. Use '
    'only the facts and diffs given. Text marked [truncated …] is '
    'incomplete: never quote or complete it. Answer with only a JSON '
    'object: {"ranking": [{"k", "score", "rationale", "risks", '
    '"followed_plan", "actual_change"}], "recommended": k or null, '
    '"summary": one sentence}.';

/// Longest description of what a timeline's diff actually does, in words.
const int judgeActualChangeMaxWords = 25;

/// The judge's user message. The router redacts it before sending.
String timelineJudgeMessage(TimelineRun run, Map<int, String> diffs) {
  final label = run.baseLabel == null
      ? '(none)'
      : run.baseLabel!.endsWith('…')
      ? '${run.baseLabel!.substring(0, run.baseLabel!.length - 1).trimRight()} $truncatedLabelMarker'
      : run.baseLabel!;
  final buffer = StringBuffer()
    ..writeln('Task: ${run.task}')
    ..writeln('Test command: ${run.test}')
    ..writeln(
      'Starting state: ${run.baseState} state of checkpoint ${run.baseCheckpoint}; its label: $label',
    );
  for (final t in run.timelines) {
    final test = t.test;
    buffer
      ..writeln()
      ..writeln('=== Timeline ${t.k}: ${t.approach.title}')
      ..writeln('Plan: ${t.approach.plan}')
      ..writeln(
        'Agent: ${t.status.name}${t.reason == null ? '' : ' (${t.reason})'}, ${t.steps} step(s), ${t.seconds.round()} s',
      )
      ..writeln(
        'Tests: ${test == null
            ? 'not run'
            : test.passed
            ? 'passed'
            : 'FAILED'}',
      );
    if (test != null && !test.passed && test.tail.trim().isNotEmpty) {
      final tail = const LineSplitter().convert(test.tail.trimRight());
      buffer
        ..writeln('Failing output (tail):')
        ..writeln(tail.skip(max(0, tail.length - 20)).join('\n'));
    }
    final diff = diffs[t.k] ?? '';
    if (t.files.isEmpty || diff.trim().isEmpty) {
      buffer.writeln('Diff: (no changes)');
    } else {
      buffer
        ..writeln('Diff against the starting state:')
        ..writeln(
          diff.length > judgeDiffLimitChars
              ? '${diff.substring(0, judgeDiffLimitChars)}\n… (diff cut at $judgeDiffLimitChars characters)'
              : diff.trimRight(),
        );
    }
  }
  return buffer.toString().trimRight();
}

/// The `response_format` schema: one entry per timeline.
Map<String, Object?> timelineJudgeFormat(List<int> ks) => {
  'type': 'json_schema',
  'json_schema': {
    'name': 'timeline_judgment',
    'strict': true,
    'schema': {
      'type': 'object',
      'additionalProperties': false,
      'required': ['ranking', 'recommended', 'summary'],
      'properties': {
        'ranking': {
          'type': 'array',
          'minItems': ks.length,
          'maxItems': ks.length,
          'items': {
            'type': 'object',
            'additionalProperties': false,
            'required': [
              'k',
              'score',
              'rationale',
              'risks',
              'followed_plan',
              'actual_change',
            ],
            'properties': {
              'k': {'type': 'integer', 'enum': ks},
              'score': {'type': 'number'},
              'rationale': {'type': 'string'},
              'risks': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              'followed_plan': {
                'type': 'string',
                'enum': ['yes', 'partly', 'no'],
              },
              'actual_change': {'type': 'string'},
            },
          },
        },
        'recommended': {
          'type': ['integer', 'null'],
          'enum': [...ks, null],
        },
        'summary': {'type': 'string'},
      },
    },
  },
};

/// One timeline's place in the judgment.
class JudgeEntry {
  final int k;
  final double score;
  final String rationale;
  final List<String> risks;

  /// Whether the diff followed the timeline's own plan: `yes`, `partly` or
  /// `no` (null in judgments saved before this was asked).
  final String? followedPlan;

  /// What the diff actually does, in at most 25 words.
  final String? actualChange;

  const JudgeEntry(
    this.k,
    this.score,
    this.rationale,
    this.risks, {
    this.followedPlan,
    this.actualChange,
  });

  bool get strayed => followedPlan == 'no' || followedPlan == 'partly';

  Map<String, Object?> toJson() => {
    'k': k,
    'score': score,
    'rationale': rationale,
    'risks': risks,
    'followedPlan': followedPlan,
    'actualChange': actualChange,
  };

  static JudgeEntry fromJson(Map json) => JudgeEntry(
    (json['k'] as num).toInt(),
    (json['score'] as num).toDouble(),
    json['rationale'] as String,
    [for (final r in (json['risks'] as List? ?? const [])) '$r'],
    followedPlan: json['followedPlan'] as String?,
    actualChange: json['actualChange'] as String?,
  );
}

/// How a plan-adherence answer reads in Doc's output.
String planAdherenceText(String? followedPlan) => switch (followedPlan) {
  'no' => "didn't follow its plan",
  'partly' => 'only partly followed its plan',
  _ => '',
};

/// The judge's validated answer.
class TimelineJudgment {
  final List<JudgeEntry> ranking;
  final int? recommended;
  final String summary;

  /// Set when Doc changed the answer, for example dropping a
  /// recommendation of a timeline whose tests failed.
  final String? note;

  const TimelineJudgment(
    this.ranking,
    this.recommended,
    this.summary, {
    this.note,
  });

  Map<String, Object?> toJson() => {
    'ranking': [for (final e in ranking) e.toJson()],
    'recommended': recommended,
    'summary': summary,
    'note': note,
  };

  static TimelineJudgment fromJson(Map json) => TimelineJudgment(
    [
      for (final e in (json['ranking'] as List? ?? const []).whereType<Map>())
        JudgeEntry.fromJson(e),
    ],
    (json['recommended'] as num?)?.toInt(),
    json['summary'] as String? ?? '',
    note: json['note'] as String?,
  );
}

class TimelineJudgeRefused implements Exception {
  final String message;

  /// The only problem is a recommended timeline whose tests failed.
  final bool failedRecommendation;

  /// The ranking, valid apart from the recommendation.
  final TimelineJudgment? ranking;

  const TimelineJudgeRefused(
    this.message, {
    this.failedRecommendation = false,
    this.ranking,
  });

  @override
  String toString() => message;
}

/// Strictly parse and validate the judge's answer for [run]: every
/// timeline exactly once, scores 0–10, rationales of at most 60 words, and
/// a recommendation (if any) of a timeline whose tests passed. The ranking
/// is then ordered so that timelines without changes come last, unless
/// every timeline is empty.
TimelineJudgment parseTimelineJudgment(String content, TimelineRun run) {
  var text = content.trim();
  final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    throw const TimelineJudgeRefused('The answer was not a JSON object.');
  }
  if (json is! Map || json['ranking'] is! List) {
    throw const TimelineJudgeRefused('The answer has no "ranking" list.');
  }
  final byK = {for (final t in run.timelines) t.k: t};
  final entries = <JudgeEntry>[];
  for (final item in json['ranking'] as List) {
    if (item is! Map ||
        item['k'] is! num ||
        item['score'] is! num ||
        item['rationale'] is! String ||
        (item['risks'] != null && item['risks'] is! List)) {
      throw const TimelineJudgeRefused(
        'Each ranking entry needs a number "k", a number "score", a string "rationale" and a "risks" list.',
      );
    }
    final k = (item['k'] as num).toInt();
    if (!byK.containsKey(k)) {
      throw TimelineJudgeRefused(
        'Timeline $k does not exist (the run has ${byK.keys.join(', ')}).',
      );
    }
    if (entries.any((e) => e.k == k)) {
      throw TimelineJudgeRefused('Timeline $k is ranked twice.');
    }
    final score = (item['score'] as num).toDouble();
    if (score < 0 || score > 10) {
      throw TimelineJudgeRefused('Timeline $k\'s score must be from 0 to 10.');
    }
    final rationale = (item['rationale'] as String).trim();
    final words = rationale.isEmpty
        ? 0
        : rationale.split(RegExp(r'\s+')).length;
    if (words > judgeRationaleMaxWords) {
      throw TimelineJudgeRefused(
        'Timeline $k\'s rationale has $words words; at most $judgeRationaleMaxWords.',
      );
    }
    final followed = item['followed_plan'];
    if (followed is! String ||
        !const {'yes', 'partly', 'no'}.contains(followed)) {
      throw TimelineJudgeRefused(
        'Timeline $k needs "followed_plan": "yes", "partly" or "no".',
      );
    }
    final actual = item['actual_change'];
    if (actual is! String || actual.trim().isEmpty) {
      throw TimelineJudgeRefused(
        'Timeline $k needs "actual_change": what its diff actually does.',
      );
    }
    final actualWords = actual.trim().split(RegExp(r'\s+')).length;
    if (actualWords > judgeActualChangeMaxWords) {
      throw TimelineJudgeRefused(
        'Timeline $k\'s actual_change has $actualWords words; at most $judgeActualChangeMaxWords.',
      );
    }
    entries.add(
      JudgeEntry(
        k,
        score,
        rationale,
        [
          for (final r in (item['risks'] as List? ?? const []))
            if ('$r'.trim().isNotEmpty) '$r'.trim(),
        ],
        followedPlan: followed,
        actualChange: actual.trim(),
      ),
    );
  }
  final missing = byK.keys.where((k) => !entries.any((e) => e.k == k));
  if (missing.isNotEmpty) {
    throw TimelineJudgeRefused(
      'The ranking leaves out timeline(s) ${missing.join(', ')}.',
    );
  }
  final recommended = json['recommended'];
  if (recommended != null && recommended is! num) {
    throw const TimelineJudgeRefused(
      '"recommended" must be a timeline number or null.',
    );
  }
  final summary = json['summary'] is String
      ? (json['summary'] as String).trim()
      : '';
  final ordered = orderJudgeRanking(entries, run);
  final pick = (recommended as num?)?.toInt();
  if (pick != null && !byK.containsKey(pick)) {
    throw TimelineJudgeRefused('Recommended timeline $pick does not exist.');
  }
  if (pick != null && !(byK[pick]!.test?.passed ?? false)) {
    throw TimelineJudgeRefused(
      'Timeline $pick is recommended, but its tests did not pass.',
      failedRecommendation: true,
      ranking: TimelineJudgment(ordered, null, summary),
    );
  }
  return TimelineJudgment(ordered, pick, summary);
}

/// [entries] best first, with timelines that changed nothing moved to the
/// end (keeping their relative order), unless every timeline is empty.
List<JudgeEntry> orderJudgeRanking(List<JudgeEntry> entries, TimelineRun run) {
  bool empty(int k) => run.timelines.firstWhere((t) => t.k == k).files.isEmpty;
  if (entries.every((e) => empty(e.k))) return entries;
  return [
    for (final e in entries)
      if (!empty(e.k)) e,
    for (final e in entries)
      if (empty(e.k)) e,
  ];
}

/// The judgment as advice under the comparison table.
List<String> timelineJudgmentLines(TimelineRun run, TimelineJudgment judgment) {
  String title(int k) =>
      run.timelines.firstWhere((t) => t.k == k).approach.title;
  bool empty(int k) => run.timelines.firstWhere((t) => t.k == k).files.isEmpty;
  JudgeEntry? entry(int? k) =>
      judgment.ranking.where((e) => e.k == k).firstOrNull;
  final recommended = entry(judgment.recommended);
  String score(double value) =>
      value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1);
  return [
    judgment.recommended == null
        ? 'Wonder recommends none of the timelines${judgment.summary.isEmpty ? '' : ' — ${judgment.summary}'}'
        : 'Wonder recommends timeline ${judgment.recommended}: ${title(judgment.recommended!)} — ${judgment.summary}',
    if (recommended != null && recommended.strayed)
      'Note: timeline ${recommended.k} ${planAdherenceText(recommended.followedPlan)}. Planned: ${title(recommended.k)}. Did: ${recommended.actualChange}',
    ?judgment.note,
    'Ranking (advice only; you pick):',
    for (var i = 0; i < judgment.ranking.length; i++) ...[
      '  ${i + 1}. [${judgment.ranking[i].k}] ${title(judgment.ranking[i].k)}'
          '${empty(judgment.ranking[i].k) ? ' (no changes)' : ''}'
          '  ${score(judgment.ranking[i].score)}/10'
          '${judgment.ranking[i].strayed ? '  — ${planAdherenceText(judgment.ranking[i].followedPlan).toUpperCase()}' : ''}',
      if (judgment.ranking[i].actualChange != null) ...[
        '     Planned: ${title(judgment.ranking[i].k)}',
        '     Did: ${judgment.ranking[i].actualChange}',
      ],
      '     ${judgment.ranking[i].rationale}',
      if (judgment.ranking[i].risks.isNotEmpty)
        '     Risks: ${judgment.ranking[i].risks.map((r) => r.replaceFirst(RegExp(r'[.;]+$'), '')).join('; ')}',
    ],
  ];
}
