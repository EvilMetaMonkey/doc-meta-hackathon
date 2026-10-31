import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'lessons.dart';

/// The last `doc bisect` result per workspace, kept in Doc's data dir as
/// `bisect/<first 24 hex of dmc's workspace fingerprint>.json`, so
/// `doc timelines --from-bisect` can start from it. Never in the workspace.
///
/// The name is the first 24 hex digits of the fingerprint (`sha256:<hex>`),
/// as the lesson library uses, so it is valid on every platform (Windows
/// forbids the colon).
File lastBisectFile(Map<String, String> environment, String fingerprint) {
  final key = fingerprint.replaceFirst('sha256:', '');
  if (!RegExp(r'^[0-9a-f]{16,}$').hasMatch(key)) {
    throw FormatException('Unexpected workspace fingerprint: $fingerprint');
  }
  return File(
    p.join(
      docDataDirectory(environment),
      'bisect',
      '${key.length > 24 ? key.substring(0, 24) : key}.json',
    ),
  );
}

void saveLastBisect(
  Map<String, String> environment,
  String fingerprint,
  Map<String, Object?> result,
) {
  final file = lastBisectFile(environment, fingerprint);
  file.parent.createSync(recursive: true);
  final temporary = File('${file.path}.tmp');
  temporary.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(result)}\n',
  );
  temporary.renameSync(file.path);
}

/// The saved result, or null when this workspace has none (or it is
/// unreadable).
Map<String, Object?>? loadLastBisect(
  Map<String, String> environment,
  String fingerprint,
) {
  final file = lastBisectFile(environment, fingerprint);
  if (!file.existsSync()) return null;
  try {
    return (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
  } on FormatException {
    return null;
  }
}
