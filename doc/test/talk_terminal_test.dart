@Timeout(Duration(minutes: 2))
library;

import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The real StdinTalkTerminal, in a subprocess whose stdin is a pipe (the
/// talk CLI tests use a fake terminal and never reach it).
void main() {
  late String docRoot;

  setUpAll(() {
    docRoot = p.dirname(
      p.dirname(
        Isolate.resolvePackageUriSync(
          Uri.parse('package:dmc_doc/doc.dart'),
        )!.toFilePath(),
      ),
    );
  });

  Future<List<String>> readKeys(List<int> input, List<String> args) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      p.join('test', 'support', 'read_talk_keys.dart'),
      ...args,
    ], workingDirectory: docRoot);
    final stdoutText = process.stdout
        .transform(const SystemEncoding().decoder)
        .join();
    final stderrText = process.stderr
        .transform(const SystemEncoding().decoder)
        .join();
    process.stdin.add(input);
    await process.stdin.flush();
    await process.stdin.close();
    final code = await process.exitCode;
    final out = await stdoutText;
    expect(code, 0, reason: '$out${await stderrText}');
    return out.split(RegExp(r'\r?\n')).where((l) => l.isNotEmpty).toList();
  }

  test('Enter, Space and Esc are read from the real stdin', () async {
    expect(await readKeys('\n'.codeUnits, ['1']), ['key toggle']);
    expect(await readKeys(' '.codeUnits, ['1']), ['key toggle']);
    expect(await readKeys([0x1b], ['1']), ['key cancel']);
  });

  test('keys are read one at a time; end of input is a cancel', () async {
    expect(await readKeys([0x20, 0x78, 0x1b], ['4']), [
      'key toggle',
      'key other',
      'key cancel',
      'key cancel',
    ]);
  });

  test('a later readLineSync gets the rest of the input', () async {
    expect(await readKeys('\nyes\n'.codeUnits, ['1', '--then-line']), [
      'key toggle',
      'line yes',
    ]);
  });
}
