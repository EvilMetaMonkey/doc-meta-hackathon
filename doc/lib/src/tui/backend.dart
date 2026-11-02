/// The TUI's real data sources: dmc's JSON, Doc's commands run
/// in-process, and Doc's data dir. No business logic of its own.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../abandoned_work.dart';
import '../bisect_command.dart';
import '../bisect_store.dart';
import '../cli.dart';
import '../cli.dart' as cli show runDoc;
import '../config.dart';
import '../dmc_client.dart';
import '../doctor_command.dart';
import '../lesson_commands.dart';
import '../lessons.dart';
import 'app.dart';
import 'model.dart';

class DocBackend implements TuiBackend {
  final DocContext context;
  final DmcClient? dmc;

  /// dmc's workspace root and identity, when there is a workspace.
  final String? root;
  final String? fingerprint;

  DocBackend._(this.context, this.dmc, this.root, this.fingerprint);

  /// Finds dmc and the workspace; either may be missing (the TUI then
  /// shows how to set it up).
  static Future<DocBackend> create(DocContext context) async {
    DmcClient? dmc;
    String? root;
    String? fingerprint;
    try {
      dmc = await context.dmc();
      final listed = await dmc.runJson([
        'checkpoint',
        'list',
        '--limit',
        '1',
      ], workspace: context.workspace);
      final workspace = listed['workspace'];
      if (listed['ok'] == true && workspace is Map) {
        root = workspace['path'] as String?;
        fingerprint = workspace['fingerprint'] as String?;
      }
    } on DmcException {
      // Shown as the empty state.
    }
    return DocBackend._(context, dmc, root, fingerprint);
  }

  DmcClient get _dmc =>
      dmc ?? (throw DmcException('dmc was not found (set DMC_BIN or --dmc)'));

  @override
  String get workspaceName => p.basename(root ?? context.workspace);

  @override
  String get dmcCommand => dmcFixCommand(dmc?.executable ?? 'dmc');

  @override
  String get logDirectory => p.join(docDataDirectory(context.env), 'ui-logs');

  @override
  Future<List<DoctorLine>> doctor() => doctorChecks(context);

  @override
  Future<Map<String, Object?>> checkpointList() => _dmc.runJson([
    'checkpoint',
    'list',
    '--limit',
    '1000',
  ], workspace: context.workspace);

  @override
  Map<String, Object?>? lastBisect() =>
      fingerprint == null ? null : loadLastBisect(context.env, fingerprint!);

  @override
  Future<String?> diff(
    String checkpointId,
    List<({String path, String change})> files,
  ) => abandonedDiff(
    _dmc,
    workspace: context.workspace,
    checkpointId: checkpointId,
    files: files,
  );

  @override
  Future<Map<String, Object?>> show(String checkpointId) => _dmc.runJson([
    'checkpoint',
    'show',
    checkpointId,
  ], workspace: context.workspace);

  @override
  Future<Map<String, Object?>> dmcJson(List<String> args) =>
      _dmc.runJson(args, workspace: context.workspace);

  /// The options a command run from the TUI inherits.
  List<String> get _inherited => [
    if (dmc != null) ...['--dmc', dmc!.executable],
    '--workspace',
    context.workspace,
    if (context.args['local'] as bool) '--local',
    for (final value in context.args['role-provider'] as List<String>) ...[
      '--role-provider',
      value,
    ],
  ];

  @override
  Future<int> runDoc(List<String> args, DocRunIo io) => cli.runDoc(
    [...args, ..._inherited],
    environment: context.env,
    out: io.out,
    err: io.out,
    client: context.router.client,
    readLine: io.ask,
    progress: io.progress,
    handOverTerminal: io.handOver,
    voice: io.voice,
  );

  @override
  Future<List<LessonItem>> lessons() async {
    final LessonStore store;
    try {
      store = await lessonStoreFor(context);
    } on DmcException {
      return const [];
    }
    LessonItem item(Lesson lesson, {required bool draft}) => LessonItem(
      id: lesson.id,
      title: lesson.title,
      files: lesson.files,
      draft: draft,
      text: lesson.toMarkdown(),
    );
    return [
      for (final draft in store.pendingDrafts()) item(draft, draft: true),
      for (final lesson in store.approved()) item(lesson, draft: false),
    ];
  }

  File _summaryFile(String id) =>
      File(p.join(docDataDirectory(context.env), 'summaries', '$id.txt'));

  @override
  String? cachedSummary(String checkpointId) {
    final file = _summaryFile(checkpointId);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  @override
  void saveSummary(String checkpointId, String text, String? footer) {
    final file = _summaryFile(checkpointId);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('$text\n${footer == null ? '' : '\n$footer\n'}');
  }

  @override
  String? defaultTest() =>
      (root == null ? null : context.config.bisectTestFor(root!)) ??
      lastBisect()?['test'] as String?;

  @override
  String? defaultSetup() =>
      lastBisect()?['setup'] as String? ??
      (root == null ? null : suggestSetup(root!));

  @override
  bool get summaryOnModal =>
      context.router.resolve('summary').provider.billing ==
      ProviderBilling.gpuTime;
}
