import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'lessons.dart';

/// The last `doc bisect` result per workspace, kept in Doc's data dir as
/// `bisect/<first 24 hex of dmc's workspace fingerprint>.json`, so
/// `doc timelines --from-bisect` can start from it. Never in the workspace.
File lastBisectFile(
  Map<String, String> environment,
  String fingerprint,
) => File(
  p.join(
    docDataDirectory(environment),
    'bisect',
    '${fingerprint.length > 24 ? fingerprint.substring(0, 24) : fingerprint}.json',
  ),
);

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
