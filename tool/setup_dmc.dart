// Sets up dmc, the engine Doc drives, from its own public repository.
//
//   dart run tool/setup_dmc.dart [--force] [--no-build]
//
// 1. Clones https://github.com/EvilMetaMonkey/dmc into .deps/dmc (gitignored)
//    and checks out the pinned pre-event commit (never a branch).
// 2. Applies the event's dmc changes from dmc-patches/ with `git am`.
// 3. Runs `dart pub get --enforce-lockfile` and builds the dmc bundle.
// 4. Prints the dmc executable and how to point Doc at it (DMC_BIN).
//
// Re-running it rebuilds from scratch: the checkout is reset to the pinned
// commit, cleaned and patched again. It refuses to throw away work in
// .deps/dmc (uncommitted changes, or commits not yet exported with
// tool/export_patches.dart) unless --force is given. Uses only dart:io, so
// it runs the same on macOS, Linux and Windows.

import 'dart:io';

const String dmcRepository = 'https://github.com/EvilMetaMonkey/dmc';

/// dmc at the `pre-hackathon` baseline (2026-10-25 19:00 UTC).
const String dmcBaseCommit = 'd177c4bf73901cfac0a4ba7ef068cf24b95a2cb0';

/// Who `git am` records as committer in the local checkout.
const List<String> _identity = [
  '-c',
  'user.name=doc setup',
  '-c',
  'user.email=doc-setup@localhost',
  '-c',
  'commit.gpgsign=false',
  '-c',
  'core.autocrlf=false',
];

String get repoRoot => File.fromUri(Platform.script).parent.parent.path;
String join(String a, String b) => '$a${Platform.pathSeparator}$b';

Future<ProcessResult> run(
  String executable,
  List<String> args, {
  String? cwd,
  bool check = true,
  bool echo = true,
}) async {
  if (echo) stdout.writeln('\$ $executable ${args.join(' ')}');
  final result = await Process.run(executable, args, workingDirectory: cwd);
  if (check && result.exitCode != 0) {
    stderr
      ..write(result.stdout)
      ..write(result.stderr);
    stderr.writeln(
      'setup_dmc: "$executable ${args.join(' ')}" failed (exit ${result.exitCode}).',
    );
    exit(1);
  }
  return result;
}

List<File> patches(String root) {
  final directory = Directory(join(root, 'dmc-patches'));
  if (!directory.existsSync()) return [];
  return directory
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.patch'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// `git patch-id --stable` of each commit after the base, or of each file.
Future<List<String>> patchIds(String dmc, {List<File>? files}) async {
  final ids = <String>[];
  if (files != null) {
    for (final file in files) {
      final process = await Process.start('git', [
        'patch-id',
        '--stable',
      ], workingDirectory: dmc);
      await process.stdin.addStream(file.openRead());
      await process.stdin.close();
      final text = await process.stdout
          .transform(const SystemEncoding().decoder)
          .join();
      await process.exitCode;
      if (text.trim().isNotEmpty) ids.add(text.trim().split(' ').first);
    }
    return ids;
  }
  final log = await run(
    'git',
    ['rev-list', '--reverse', '$dmcBaseCommit..HEAD'],
    cwd: dmc,
    echo: false,
  );
  for (final commit
      in '${log.stdout}'.split('\n').where((c) => c.trim().isNotEmpty)) {
    final show = await Process.start('git', [
      'show',
      commit.trim(),
    ], workingDirectory: dmc);
    final patchId = await Process.start('git', [
      'patch-id',
      '--stable',
    ], workingDirectory: dmc);
    await patchId.stdin.addStream(show.stdout);
    await patchId.stdin.close();
    final text = await patchId.stdout
        .transform(const SystemEncoding().decoder)
        .join();
    await patchId.exitCode;
    await show.exitCode;
    if (text.trim().isNotEmpty) ids.add(text.trim().split(' ').first);
  }
  return ids;
}

Future<void> main(List<String> arguments) async {
  final force = arguments.contains('--force');
  final build = !arguments.contains('--no-build');
  final unknown = arguments.where((a) => a != '--force' && a != '--no-build');
  if (unknown.isNotEmpty) {
    stderr.writeln(
      'Usage: dart run tool/setup_dmc.dart [--force] [--no-build]',
    );
    exit(2);
  }
  final root = repoRoot;
  final dmc = join(join(root, '.deps'), 'dmc');
  final series = patches(root);
  if (series.isEmpty) {
    stderr.writeln('setup_dmc: no patches in ${join(root, 'dmc-patches')}.');
    exit(1);
  }

  if (!Directory(join(dmc, '.git')).existsSync()) {
    Directory(join(root, '.deps')).createSync(recursive: true);
    await run('git', [
      '-c',
      'core.autocrlf=false',
      'clone',
      '--quiet',
      dmcRepository,
      dmc,
    ]);
    await run('git', ['config', 'core.autocrlf', 'false'], cwd: dmc);
  } else {
    // Never discard work that is not in dmc-patches/.
    await run(
      'git',
      [..._identity, 'am', '--abort'],
      cwd: dmc,
      check: false,
      echo: false,
    );
    final dirty = await run(
      'git',
      ['status', '--porcelain', '--untracked-files=no'],
      cwd: dmc,
      echo: false,
    );
    final hasBase =
        (await run(
          'git',
          ['merge-base', '--is-ancestor', dmcBaseCommit, 'HEAD'],
          cwd: dmc,
          check: false,
          echo: false,
        )).exitCode ==
        0;
    if (!force && '${dirty.stdout}'.trim().isNotEmpty) {
      stderr.writeln(
        'setup_dmc: .deps/dmc has uncommitted changes. Commit them and run tool/export_patches.dart, or pass --force to discard them.',
      );
      exit(1);
    }
    if (!force && hasBase) {
      final local = await patchIds(dmc);
      final shipped = await patchIds(dmc, files: series);
      if (local.isNotEmpty && local.join() != shipped.join()) {
        stderr.writeln(
          'setup_dmc: .deps/dmc has commits that are not in dmc-patches/. Run dart run tool/export_patches.dart first, or pass --force to discard them.',
        );
        exit(1);
      }
    }
  }

  // The pinned base, clean, then the event's patches.
  final hasCommit =
      (await run(
        'git',
        ['cat-file', '-e', '$dmcBaseCommit^{commit}'],
        cwd: dmc,
        check: false,
        echo: false,
      )).exitCode ==
      0;
  if (!hasCommit) await run('git', ['fetch', '--quiet', 'origin'], cwd: dmc);
  await run('git', [
    'checkout',
    '--quiet',
    '--force',
    '--detach',
    dmcBaseCommit,
  ], cwd: dmc);
  await run('git', ['reset', '--quiet', '--hard', dmcBaseCommit], cwd: dmc);
  await run('git', ['clean', '-ffdxq'], cwd: dmc);
  stdout.writeln('\$ git am dmc-patches/*.patch (${series.length} patch(es))');
  await run('git', echo: false, [
    ..._identity,
    'am',
    '--quiet',
    '--committer-date-is-author-date',
    for (final file in series) file.path,
  ], cwd: dmc);
  final applied = await run(
    'git',
    ['rev-list', '--count', '$dmcBaseCommit..HEAD'],
    cwd: dmc,
    echo: false,
  );
  stdout.writeln(
    'Applied ${'${applied.stdout}'.trim()} of ${series.length} patch(es) on dmc $dmcBaseCommit.',
  );

  await run(Platform.resolvedExecutable, [
    'pub',
    'get',
    '--enforce-lockfile',
  ], cwd: dmc);
  final executable = join(
    join(join(join(join(dmc, 'build'), 'dmc'), 'bundle'), 'bin'),
    Platform.isWindows ? 'dmc.exe' : 'dmc',
  );
  if (!build) {
    stdout.writeln('Skipped the build (--no-build).');
    return;
  }
  await run(Platform.resolvedExecutable, [
    'build',
    'cli',
    '-o',
    join('build', 'dmc'),
  ], cwd: dmc);
  if (!File(executable).existsSync()) {
    stderr.writeln('setup_dmc: the build did not produce $executable.');
    exit(1);
  }
  final version = await run(executable, ['--version'], echo: false);
  stdout
    ..writeln('')
    ..writeln('dmc is ready: $executable (${'${version.stdout}'.trim()})')
    ..writeln(
      'Point Doc at it with DMC_BIN (or pass --dmc to each doc command):',
    )
    ..writeln(
      Platform.isWindows
          ? '  PowerShell: \$env:DMC_BIN = "$executable"   (persist: setx DMC_BIN "$executable")'
          : '  export DMC_BIN="$executable"   (add it to your shell profile to keep it)',
    )
    ..writeln(
      'Doc\'s tests use DMC_TEST_BIN; with neither set they look for this build.',
    );
}
