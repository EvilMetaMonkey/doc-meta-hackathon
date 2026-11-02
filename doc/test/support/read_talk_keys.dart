// Reads keys with the real StdinTalkTerminal (stdin is a pipe here, so
// raw mode is never entered) and prints each as `key <name>`.
//
//   dart run test/support/read_talk_keys.dart <count> [--then-line]
//
// With --then-line it then reads one line with stdin.readLineSync and
// prints it as `line <text>`, to show the key reads left stdin usable.
import 'dart:io';

import 'package:dmc_doc/doc.dart';

Future<void> main(List<String> args) async {
  final terminal = StdinTalkTerminal();
  for (var i = 0; i < int.parse(args.first); i++) {
    stdout.writeln('key ${(await terminal.readKey()).name}');
  }
  if (args.contains('--then-line')) {
    stdout.writeln('line ${stdin.readLineSync()}');
  }
}
