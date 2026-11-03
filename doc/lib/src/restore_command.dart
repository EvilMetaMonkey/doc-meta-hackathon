import 'package:path/path.dart' as p;

import 'cli.dart';
import 'dmc_client.dart';
import 'lesson_commands.dart';
import 'nl_restore_command.dart';
import 'plural.dart';

/// A dmc checkpoint ID (`cp_<base36 time>_<hex>`): `doc restore` with one
/// keeps the checkpoint flow; anything else is a natural-language request.
final RegExp checkpointIdPattern = RegExp(r'^cp_[a-z0-9]+_[0-9a-f]+$');

/// `doc restore <checkpoint-id> [--yes] [--no-lesson]`, or
/// `doc restore "<request>"` for natural-language restore
/// ([runNaturalRestore]).
///
/// Rollback without amnesia: preview dmc's checkpoint restore in plain
/// terms, apply it only after the user says yes, then offer to draft a
/// lesson from the work that was undone. Every file change goes through
/// dmc's preview-first, journaled restore; Doc never writes workspace files
/// and never forces a conflicting or interrupted restore. `--yes` answers
/// yes to both questions and is meant only for scripted demos.
Future<int> runRestoreCommand(DocContext context) async {
  final rest = context.args.rest;
  if (rest.length < 2 || rest.skip(1).join(' ').trim().isEmpty) {
    context.log(
      'Usage: doc restore <checkpoint-id> [--yes] [--no-lesson], or doc restore "<request>" [--limit <n>] [--diff] [--yes] [--no-lesson] [--json]',
    );
    return 2;
  }
  if (rest.length == 2 && checkpointIdPattern.hasMatch(rest[1])) {
    return restoreCheckpoint(context, rest[1]);
  }
  return runNaturalRestore(context, rest.skip(1).join(' ').trim());
}

/// The `doc restore` flow for checkpoint [id]: dmc's preview in plain
/// terms, a question, dmc's journaled apply, then the lesson offer. Used by
/// `doc restore` and offered after `doc bisect`.
Future<int> restoreCheckpoint(DocContext context, String id) async {
  final yes = context.args['yes'] as bool;
  final DmcClient dmc;
  try {
    dmc = await context.dmc();
  } on DmcException catch (error) {
    context.log(error.message);
    return 1;
  }
  final out = context.out;

  final show = await dmc.runJson([
    'checkpoint',
    'show',
    id,
  ], workspace: context.workspace);
  final checkpoint = (show['data'] as Map?)?['checkpoint'];
  final agent = checkpoint is Map ? checkpoint['agent'] : null;
  final agentName = agent is Map ? agent['name'] as String? : null;

  final preview = await dmc.runJson([
    'checkpoint',
    'restore',
    id,
  ], workspace: context.workspace);
  final data = (preview['data'] as Map?) ?? const {};
  final actions = (data['actions'] as List? ?? const [])
      .whereType<Map>()
      .toList();
  final skipped = (data['skipped'] as List? ?? const [])
      .whereType<Map>()
      .toList();
  final conflicts = [
    ...(data['conflicts'] as List? ?? const []).whereType<Map>(),
    ...(data['dataErrors'] as List? ?? const []).whereType<Map>(),
  ];

  // One file: the question says it all. Several: the list comes first (a
  // full-screen UI keeps it under details).
  if (actions.length > 1) {
    out.writeln('Restore would change ${plural(actions.length, 'file')}:');
    for (final action in actions) {
      out.writeln('  - ${action['path']}: ${describeRestoreAction(action)}');
    }
  }
  if (skipped.isNotEmpty) {
    out.writeln(
      'Left alone (protection changed during the turn; never written):',
    );
    for (final item in skipped) {
      out.writeln('  - ${item['path']}: ${item['code']}');
    }
  }
  if (data['canApply'] != true || preview['ok'] != true) {
    if (conflicts.isNotEmpty) {
      out.writeln('dmc will not restore this checkpoint as it stands:');
      for (final conflict in conflicts) {
        out.writeln(
          '  - ${conflict['path'] ?? '(checkpoint)'}: ${conflict['code']}: ${conflict['message']}',
        );
      }
    }
    for (final error
        in (preview['errors'] as List? ?? const []).whereType<Map>()) {
      if (conflicts.any(
        (c) => c['code'] == error['code'] && c['path'] == error['path'],
      )) {
        continue;
      }
      out.writeln('  - ${error['code']}: ${error['message']}');
    }
    out.writeln(
      'Nothing was changed. Resolve the conflicts (for example, save or undo your later edits) and run doc restore again; Doc never forces a restore.',
    );
    return (preview['exitCode'] as num?)?.toInt() ?? 4;
  }
  if (actions.isEmpty) {
    out.writeln(
      'Nothing to restore: the workspace already matches the state before the turn.',
    );
    return 0;
  }

  if (!await _ask(
    context,
    restoreQuestion('Undo ${turnPhrase(agentName)}?', [
      for (final action in actions)
        (
          path: '${action['path']}',
          action: describeRestoreAction(action, short: true),
        ),
    ]),
    yes: yes,
    byDefault: false,
  )) {
    out.writeln('Nothing was changed.');
    return 0;
  }
  final applied = await dmc.runJson([
    'checkpoint',
    'restore',
    id,
    '--apply',
  ], workspace: context.workspace);
  final appliedData = (applied['data'] as Map?) ?? const {};
  if (applied['ok'] != true) {
    out.writeln('dmc did not complete the restore:');
    for (final error
        in (applied['errors'] as List? ?? const []).whereType<Map>()) {
      out.writeln(
        '  - ${error['path'] == null ? '' : '${error['path']}: '}${error['code']}: ${error['message']}',
      );
    }
    final operation = appliedData['operationId'];
    if ((applied['exitCode'] as num?)?.toInt() == 6 && operation != null) {
      out.writeln(
        'The restore was interrupted. Recover with: dmc checkpoint recover $operation --resume (or --rollback). Doc does not recover it for you.',
      );
    }
    return (applied['exitCode'] as num?)?.toInt() ?? 1;
  }
  out.writeln(
    appliedData['noOp'] == true
        ? 'Nothing needed restoring.'
        : 'Restored ${plural(actions.length, 'file')} through dmc (operation ${appliedData['operationId']}).',
  );

  if (context.args['no-lesson'] as bool) return 0;
  if (!await _ask(
    context,
    'Draft a lesson from the work you just undid? [Y/n] ',
    yes: yes,
    byDefault: true,
  )) {
    out.writeln('No lesson drafted. You can still run: doc lesson draft $id');
    return 0;
  }
  // Only the person who undid the work knows why; ask once (optional).
  var note = context.args['note'] as String?;
  if (note == null && !yes) {
    out.write('What went wrong? (optional, press Enter to skip) ');
    final answer = (await context.readLine())?.trim();
    if (answer != null && answer.isNotEmpty) note = answer;
  }
  // The restore itself succeeded: a failed draft is reported on stderr and
  // does not change the exit code.
  await draftLesson(context, id, note: note);
  return 0;
}

/// A restore action in plain words. [short]: for the one-line question,
/// where "the turn" is already named ("…: put back the version from
/// before it").
String describeRestoreAction(Map action, {bool short = false}) {
  final expected = (action['expected'] as Map?)?['kind'];
  final intended = (action['intended'] as Map?)?['kind'];
  if (intended == 'absent') return 'delete it (the turn created it)';
  if (expected == 'absent') return 'recreate it (the turn deleted it)';
  return 'put back the version from before ${short ? 'it' : 'the turn'}';
}

/// "this muse turn" for an agent's turn, else "this change".
String turnPhrase(String? agentName) => agentName == null
    ? 'this change'
    : 'this ${switch (agentName) {
        'claude-code' => 'claude',
        'muse-code' => 'muse',
        final other => other,
      }} turn';

/// The one shape of a restore question, on one line:
/// "Undo this muse turn? README.md: put back the version from before it  [y/N] "
/// or "Undo this muse turn? 3 files change (money.py, checkout.py, +1)  [y/N] ".
String restoreQuestion(
  String lead,
  List<({String path, String action})> files,
) {
  final String what;
  if (files.length == 1) {
    what = '${files.single.path}: ${files.single.action}';
  } else {
    final names = [
      for (final file in files.take(2)) p.basename(file.path),
      if (files.length > 2) '+${files.length - 2}',
    ];
    what = '${plural(files.length, 'file')} change (${names.join(', ')})';
  }
  return '$lead $what  [y/N] ';
}

Future<bool> _ask(
  DocContext context,
  String question, {
  required bool yes,
  required bool byDefault,
}) async {
  if (yes) {
    context.out.writeln('$question${'yes (--yes)'}');
    return true;
  }
  context.out.write(question);
  final answer = ((await context.readLine()) ?? '').trim().toLowerCase();
  if (answer.isEmpty) return byDefault;
  return answer == 'y' || answer == 'yes';
}
