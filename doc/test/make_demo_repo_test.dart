@Timeout(Duration(minutes: 6))
library;

import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/dmc_fixture.dart';

void main() {
  late Directory scratch;
  late String dmc;
  late String script;

  setUpAll(() async {
    scratch = Directory.systemTemp.createTempSync('doc_make_demo_');
    dmc = await compiledDmc(scratch);
    final docRoot = p.dirname(
      p.dirname(
        Isolate.resolvePackageUriSync(
          Uri.parse('package:dmc_doc/doc.dart'),
        )!.toFilePath(),
      ),
    );
    script = p.join(
      scratch.path,
      Platform.isWindows ? 'make_demo.exe' : 'make_demo',
    );
    final built = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      p.join(p.dirname(docRoot), 'demo', 'make_demo_repo.dart'),
      '-o',
      script,
    ]);
    expect(built.exitCode, 0, reason: '${built.stdout}${built.stderr}');
  });

  tearDownAll(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  late Directory home;
  setUp(() {
    home = Directory.systemTemp.createTempSync('doc_make_demo_home_');
  });
  tearDown(() => home.deleteSync(recursive: true));

  /// Runs the script with stdin not a terminal and a throwaway HOME, so the
  /// user's real Muse settings are never touched.
  Future<ProcessResult> make(List<String> args) => Process.run(
    script,
    args,
    environment: {
      'HOME': home.path,
      'USERPROFILE': home.path,
      'PATH': Platform.environment['PATH'] ?? '',
      if (Platform.isWindows)
        'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
    },
    includeParentEnvironment: false,
  );

  File museSettings() =>
      File(p.join(home.path, '.config', 'muse', 'settings.json'));

  test('--help and -h print the usage; unknown options are errors', () async {
    for (final flag in ['--help', '-h']) {
      final result = await make([flag]);
      expect(result.exitCode, 0);
      expect(
        '${result.stdout}',
        contains('Usage: dart run demo/make_demo_repo.dart <folder>'),
      );
      expect('${result.stdout}', contains('--force'));
    }
    final bogus = await make(['--bogus', p.join(home.path, 'x')]);
    expect(bogus.exitCode, 2);
    expect('${bogus.stderr}', contains('unknown option --bogus'));
    expect(Directory(p.join(home.path, 'x')).existsSync(), isFalse);
    final noPath = await make(['--dmc']);
    expect(noPath.exitCode, 2);
  });

  test('a target that exists and is not empty is refused', () async {
    final target = Directory(p.join(home.path, 'busy'))..createSync();
    File(p.join(target.path, 'keep.txt')).writeAsStringSync('mine');
    final result = await make([target.path, '--dmc', dmc]);
    expect(result.exitCode, 1);
    expect('${result.stderr}', contains('exists and is not empty'));
    expect(target.listSync(), hasLength(1));
  });

  test(
    'a target inside another Git work tree is refused unless --force',
    () async {
      final outer = Directory(p.join(home.path, 'outer'))..createSync();
      expect(
        (await Process.run('git', [
          'init',
          '-q',
        ], workingDirectory: outer.path)).exitCode,
        0,
      );
      final target = p.join(outer.path, 'demo');
      final refused = await make([target, '--dmc', dmc]);
      expect(refused.exitCode, 1);
      expect('${refused.stderr}', contains('is inside the Git work tree'));
      expect(Directory(target).existsSync(), isFalse);
      final forced = await make([target, '--dmc', dmc, '--force']);
      expect(forced.exitCode, 0, reason: '${forced.stdout}${forced.stderr}');
      expect(Directory(p.join(target, '.dmc')).existsSync(), isTrue);
    },
  );

  test('without a terminal the hook question defaults to No', () async {
    final target = p.join(home.path, 'demo');
    final result = await make([target, '--dmc', dmc]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(
      '${result.stdout}',
      contains('no (stdin is not a terminal; pass --yes to install)'),
    );
    expect('${result.stdout}', contains('Hooks not installed'));
    for (final name in [
      'money.py',
      'checkout.py',
      'test_money.py',
      'test_checkout.py',
      '.gitignore',
    ]) {
      expect(File(p.join(target, name)).existsSync(), isTrue, reason: name);
    }
    expect(Directory(p.join(target, '.git')).existsSync(), isTrue);
    expect(Directory(p.join(target, '.dmc')).existsSync(), isTrue);
    expect(
      File(p.join(target, '.claude', 'settings.local.json')).existsSync(),
      isFalse,
    );
    expect(museSettings().existsSync(), isFalse);
  });

  test('--yes installs both agents\' hooks', () async {
    final target = p.join(home.path, 'demo');
    final result = await make([target, '--dmc', dmc, '--yes']);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(
      File(p.join(target, '.claude', 'settings.local.json')).readAsStringSync(),
      contains('agent-hook claude-code Stop'),
    );
    expect(
      museSettings().readAsStringSync(),
      contains('agent-hook muse-code Stop'),
    );
  });
}
