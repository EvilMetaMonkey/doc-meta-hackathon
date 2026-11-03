import 'dart:convert';

import 'model_client.dart';
import 'redaction.dart';

/// Bumped whenever the summary prompt or answer shape changes, so a cached
/// summary from an older prompt is not reused.
const int summaryPromptVersion = 2;

const String summarySystemPrompt =
    'You are Doc, the companion to dmc, a rollback safety net for AI coding '
    'agents. Describe one change to a software project for the developer who '
    'owns it. Answer with only a JSON object {"title": ..., "summary": ...}. '
    'title: 4 to 6 plain words naming the change in the project\'s own terms, '
    'for example "Discount takes a fraction". '
    'summary: at most 2 sentences and about 45 words: what changed, in the '
    'project\'s terms (files, functions, behaviour), and any real risk '
    '(a deleted file, a secrets-like file such as .env, CI, config or '
    'dependency files, a file whose protection changed). '
    'Never mention checkpoint IDs, the word "checkpoint", whether anything is '
    'open or closed, which agent made the change, counts of protected, '
    'excluded or fatal anything, or a list of things that were not touched or '
    'not changed. Use only the facts given; file contents are not available. '
    'No preamble, no lists, no markdown.';

/// The `response_format` schema for the summary answer.
const Map<String, Object?> summaryResponseFormat = {
  'type': 'json_schema',
  'json_schema': {
    'name': 'turn_summary',
    'strict': true,
    'schema': {
      'type': 'object',
      'additionalProperties': false,
      'required': ['title', 'summary'],
      'properties': {
        'title': {'type': 'string'},
        'summary': {'type': 'string'},
      },
    },
  },
};

/// Phrases a summary must not contain: dmc's internals and lists of what
/// was not touched.
final List<(RegExp, String)> _forbidden = [
  (RegExp(r'\bcp_[a-z0-9]', caseSensitive: false), 'a checkpoint ID'),
  (RegExp(r'\bcheckpoints?\b', caseSensitive: false), 'the word "checkpoint"'),
  (
    RegExp(r'\b(is|was|now|been) (closed|open)\b', caseSensitive: false),
    'open/closed state',
  ),
  (RegExp(r'\bexclu(sion|ded)', caseSensitive: false), 'exclusions'),
  (RegExp(r'\bprotected files?\b', caseSensitive: false), 'protected files'),
  (RegExp(r'\b(no|zero|0) fatal\b', caseSensitive: false), 'fatal counts'),
  (
    RegExp(
      r'\b(no|none of the|nothing)\b[^.]{0,80}\b(were|was)\b[^.]{0,20}\b(touched|deleted|changed|modified|affected)\b',
      caseSensitive: false,
    ),
    'a list of things not touched',
  ),
  (
    RegExp(
      r'\b(were|was) not (touched|changed|modified)\b',
      caseSensitive: false,
    ),
    'a list of things not touched',
  ),
];

/// A summary answer that cannot be used.
class SummaryAnswerError implements Exception {
  final String message;
  const SummaryAnswerError(this.message);
  @override
  String toString() => message;
}

/// Parse and check the model's `{title, summary}` answer. [agentName] (if
/// the turn was an agent's) must not appear either.
({String title, String summary}) parseSummaryAnswer(
  String content, {
  String? agentName,
}) {
  var text = content.trim();
  final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    throw const SummaryAnswerError('The answer was not a JSON object.');
  }
  if (json is! Map) {
    throw const SummaryAnswerError('The answer was not a JSON object.');
  }
  final title = json['title'];
  final summary = json['summary'];
  if (title is! String || title.trim().isEmpty) {
    throw const SummaryAnswerError('"title" must be a non-empty string.');
  }
  if (summary is! String || summary.trim().isEmpty) {
    throw const SummaryAnswerError('"summary" must be a non-empty string.');
  }
  final cleanTitle = title.trim().replaceAll(RegExp(r'[.\s]+$'), '');
  final titleWords = cleanTitle.split(RegExp(r'\s+')).length;
  if (titleWords > 8 || cleanTitle.length > 60) {
    throw SummaryAnswerError('"title" must be 4 to 6 words, not $titleWords.');
  }
  final cleanSummary = summary.trim().replaceAll(RegExp(r'\s+'), ' ');
  final words = cleanSummary.split(' ').length;
  if (words > 70) {
    throw SummaryAnswerError(
      '"summary" must be at most 2 sentences and about 45 words, not $words words.',
    );
  }
  for (final value in [cleanTitle, cleanSummary]) {
    for (final (pattern, what) in _forbidden) {
      if (pattern.hasMatch(value)) {
        throw SummaryAnswerError('The answer mentions $what.');
      }
    }
    if (agentName != null &&
        agentName.isNotEmpty &&
        value.toLowerCase().contains(agentName.toLowerCase())) {
      throw const SummaryAnswerError('The answer names the agent.');
    }
  }
  return (title: cleanTitle, summary: cleanSummary);
}

/// The old free-text answer, for when the JSON answer could not be used
/// twice: the text itself, or the "summary" field of a JSON-ish answer.
String freeTextSummary(String content) {
  final text = content.trim();
  final field = RegExp(r'"summary"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(text);
  if (field != null) {
    try {
      return (jsonDecode('"${field[1]}"') as String).trim();
    } on FormatException {
      return field[1]!.trim();
    }
  }
  return text;
}

/// The agent's name from `checkpoint show`, if the turn was an agent's.
String? checkpointAgentName(Map<String, Object?> show) {
  final checkpoint =
      ((show['data'] as Map?)?['checkpoint'] as Map?) ?? const {};
  final agent = checkpoint['agent'];
  return agent is Map ? agent['name'] as String? : null;
}

/// The facts Doc sends about a checkpoint: labels, paths, change kinds and
/// issue codes from dmc's `checkpoint show` and `checkpoint diff` JSON. No
/// file contents, hashes or snapshot IDs. With [internals] false (the
/// summary), also no checkpoint ID, lifecycle state, agent name or counts:
/// those are dmc's, not the project's, and a model repeats what it is given.
String checkpointFacts(
  Map<String, Object?> show,
  Map<String, Object?> diff, {
  bool internals = true,
}) {
  final data = (show['data'] as Map?) ?? const {};
  final checkpoint = (data['checkpoint'] as Map?) ?? const {};
  final files = [
    for (final file in ((diff['data'] as Map?)?['files'] as List? ?? const []))
      if (file is Map) file,
  ];
  final changed = [
    for (final file in files)
      if ((file['change'] != null && file['change'] != 'unchanged') ||
          file['scope'] != null)
        file,
  ];
  final issues = [
    for (final issue in (data['issues'] as List? ?? const []))
      if (issue is Map &&
          (issue['fatal'] == true || issue['code'] == 'policy_changed'))
        issue,
  ];
  String describe(Map file) {
    final path = file['path'];
    final change = file['scope'] ?? file['change'];
    final note = Redactor.isNeverSentFile('$path')
        ? ' (secret-bearing file name; contents never sent)'
        : '';
    return '- $path: $change$note';
  }

  final agent = checkpoint['agent'];
  return [
    if (internals) 'Checkpoint ${checkpoint['id']} (${checkpoint['status']})',
    _labelFact(checkpoint),
    if (internals) ...[
      'Source: ${checkpoint['source']}${agent is Map ? '; agent ${agent['name']}' : ''}',
      'Protected files: ${checkpoint['protectedFileCount']}; changed: ${checkpoint['changedFileCount']}; '
          'exclusions: ${checkpoint['exclusionCount']}; fatal issues: ${checkpoint['fatalErrorCount']}',
    ] else
      agent is Map
          ? 'Made by: an AI coding agent, from the prompt above'
          : 'Made by: a person',
    if (changed.isEmpty) 'Changed files: none',
    if (changed.isNotEmpty) 'Changed files (${changed.length}):',
    for (final file in changed.take(80)) describe(file),
    if (changed.length > 80) '- … and ${changed.length - 80} more',
    for (final issue in issues)
      'Issue: ${issue['code']}${issue['path'] == null ? '' : ' (${issue['path']})'}: ${issue['message']}',
  ].join('\n');
}

List<ChatMessage> summaryMessages(
  Map<String, Object?> show,
  Map<String, Object?> diff,
) => [
  const ChatMessage('system', summarySystemPrompt),
  ChatMessage('user', checkpointFacts(show, diff, internals: false)),
];

/// dmc keeps only the first line of an agent's prompt, cut to 100
/// characters with "…". A cut label is marked, so a model never quotes or
/// completes it as if it were the whole prompt.
const String truncatedLabelMarker =
    '[truncated by dmc: the full prompt is not available; do not quote or complete it]';

String _labelFact(Map checkpoint) {
  final label = checkpoint['label'] as String?;
  if (label == null || label.isEmpty) return 'Label: (none)';
  final kind = checkpoint['agent'] is Map
      ? 'Agent prompt (first line, as recorded by dmc)'
      : 'Label';
  final cut = label.endsWith('…');
  final text = cut ? label.substring(0, label.length - 1).trimRight() : label;
  return cut ? '$kind: $text $truncatedLabelMarker' : '$kind: $text';
}
