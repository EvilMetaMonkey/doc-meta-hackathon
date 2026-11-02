/// `doc ui`: the full-screen TUI.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../cli.dart';
import 'app.dart';
import 'backend.dart';
import 'terminal.dart';
import 'text.dart';

Future<int> runUiCommand(DocContext context) async {
  if (!stdin.hasTerminal || !stdout.hasTerminal) {
    context.log(
      'doc ui needs an interactive terminal. Run the commands directly instead (doc --help).',
    );
    return 2;
  }
  final colorOption = context.args['color'] as String?;
  if (colorOption != null &&
      !const {'auto', 'always', 'never'}.contains(colorOption)) {
    context.log('--color takes auto, always or never.');
    return 2;
  }
  final backend = await DocBackend.create(context);
  String? dmcVersion;
  try {
    final capabilities = await backend.dmc?.runJson([
      'capabilities',
    ], workspace: context.workspace);
    dmcVersion = capabilities?['dmcVersion'] as String?;
  } on Object {
    dmcVersion = null;
  }
  final host = TerminalHost(
    color: useColor(colorOption, context.env, tty: stdout.supportsAnsiEscapes),
  );
  final logs = backend.logDirectory;
  var counter = 0;
  final app = TuiApp(
    host: host,
    backend: backend,
    splash: !(context.args['no-splash'] as bool),
    dmcVersion: dmcVersion,
    openLog: (name) {
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final path = p.join(
        logs,
        '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}-${counter++}-${name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}.log',
      );
      Directory(logs).createSync(recursive: true);
      final sink = File(path).openWrite();
      return (sink: sink, path: path, close: () => sink.close());
    },
  )..readLogFile = (path) => File(path).readAsStringSync();
  host
    ..onResize = app.redraw
    ..onSignal = (code) => app.quit(code);
  host.start();
  try {
    return await app.run();
  } finally {
    host.stop();
  }
}
