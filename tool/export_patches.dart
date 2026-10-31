// Regenerates dmc-patches/ from the commits in .deps/dmc after the pinned
// base commit, for changes to the dmc engine.
//
//   dart run tool/export_patches.dart
//
// Workflow: run tool/setup_dmc.dart, change and commit dmc inside .deps/dmc
// (its own gates: dart run tool/check_analyzer.dart, dart test
// --concurrency=1, dart test tool/haven_contract_test.dart
// --concurrency=1), then run this, update PATCHES.md and commit
// dmc-patches/ here. Nothing is ever pushed to the dmc repository.

import 'dart:io';

import 'setup_dmc.dart' show dmcBaseCommit, join, repoRoot;

Future<void> main(List<String> arguments) async {
  final root = repoRoot;
  final dmc = join(join(root, '.deps'), 'dmc');
  if (!Directory(join(dmc, '.git')).existsSync()) {
    stderr.writeln(
      'export_patches: no .deps/dmc; run dart run tool/setup_dmc.dart first.',
    );
    exit(1);
  }
  Future<ProcessResult> git(List<String> args) =>
      Process.run('git', args, workingDirectory: dmc);
  final dirty = await git(['status', '--porcelain', '--untracked-files=no']);
  if ('${dirty.stdout}'.trim().isNotEmpty) {
    stderr.writeln(
      'export_patches: .deps/dmc has uncommitted changes; commit them first.',
    );
    exit(1);
  }
  if ((await git([
        'merge-base',
        '--is-ancestor',
        dmcBaseCommit,
        'HEAD',
      ])).exitCode !=
      0) {
    stderr.writeln(
      'export_patches: .deps/dmc HEAD does not descend from $dmcBaseCommit.',
    );
    exit(1);
  }
  final out = Directory(join(root, 'dmc-patches'))..createSync(recursive: true);
  for (final old in out.listSync().whereType<File>().where(
    (f) => f.path.endsWith('.patch'),
  )) {
    old.deleteSync();
  }
  final result = await git([
    'format-patch',
    '--quiet',
    '--no-signature',
    '--zero-commit',
    '--full-index',
    '-o',
    out.path,
    '$dmcBaseCommit..HEAD',
  ]);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    exit(1);
  }
  final count = out
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.patch'))
      .length;
  stdout
    ..writeln('Wrote $count patch(es) to ${out.path}.')
    ..writeln(
      'Update PATCHES.md, re-run dart run tool/setup_dmc.dart to check they apply, then commit dmc-patches/.',
    );
}
