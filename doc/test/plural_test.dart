import 'dart:io';

import 'package:dmc_doc/src/plural.dart';
import 'package:dmc_doc/src/timelines.dart' show plainPlurals;
import 'package:test/test.dart';

void main() {
  test('counts read "1 file", "2 files"', () {
    expect(plural(0, 'file'), '0 files');
    expect(plural(1, 'file'), '1 file');
    expect(plural(2, 'file'), '2 files');
    expect(plural(2, 'entry', 'entries'), '2 entries');
    expect(
      plainPlurals('did not finish within 8 step(s)'),
      'did not finish within 8 steps',
    );
    expect(plainPlurals('within 1 step(s)'), 'within 1 step');
  });

  test('no "file(s)"-style plural anywhere in Doc\'s output strings', () {
    final offenders = <String>[];
    final pattern = RegExp(r'[A-Za-z]\(s\)');
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//')) continue;
        if (pattern.hasMatch(line)) {
          offenders.add('${entity.path}:${i + 1}: $line');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
