import 'dart:convert';
import 'dart:io';

/// A stand-in for `muse exec … --json` in timelines tests. What it does
/// depends on a marker in the prompt:
/// - FAKE-FIX: writes "good" to state.txt, finishes in 3 steps;
/// - FAKE-WRONG: adds notes.txt and leaves state.txt alone;
/// - FAKE-TESTS: writes "good" to state.txt and also edits a test file
///   (tests/state_test.txt);
/// - FAKE-FAIL: stops at the step limit (exit 1);
/// - FAKE-HANG: 4 model steps, then keeps sending events and never
///   finishes (killed by the timeout, so there is no `run.usage`);
/// - FAKE-BASH: 2 model steps, then proposes a shell command and waits for
///   an approval that never comes (no more events).
/// Step and tool events have the shape of Muse Code 1.4.14's.
/// Each call writes `{cwd, args}` to its own file in the folder
/// $FAKE_MUSE_LOG (parallel appends to one file can lose a line on
/// Windows).
Future<void> main(List<String> args) async {
  final log = Platform.environment['FAKE_MUSE_LOG'];
  if (log != null) {
    Directory(log).createSync(recursive: true);
    File('$log${Platform.pathSeparator}call-$pid.json').writeAsStringSync(
      jsonEncode({'cwd': Directory.current.path, 'args': args}),
      flush: true,
    );
  }
  final prompt = args.length > 1 ? args[1] : '';
  void event(String type, Map<String, Object?> payload) =>
      stdout.writeln(jsonEncode({'payload_type': type, 'payload': payload}));
  void usage(int calls) => event('run.usage', {
    'calls': calls,
    'models': [
      {
        'model': 'muse-spark-1.3-contributor',
        'input_tokens': calls * 20000,
        'cached_tokens': calls * 10000,
        'output_tokens': calls * 100,
      },
    ],
  });

  void task(String lifecycle, String kind) =>
      event('task.lifecycle.$lifecycle', {
        'kind': 'task_lifecycle',
        'event': {'kind': lifecycle, 'task_kind': kind},
      });
  void step() {
    task('proposed', 'model.meta.response');
    task('accepted', 'model.meta.response');
    task('completed', 'model.meta.response');
  }

  event('run.lifecycle.started', {'prompt': prompt});
  if (prompt.contains('FAKE-HANG')) {
    for (var i = 0; i < 4; i++) {
      step();
    }
    for (var i = 0; i < 3000; i++) {
      event('run.output.delta', {'text': '.'});
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  if (prompt.contains('FAKE-BASH')) {
    step();
    step();
    task('proposed', 'tool.bash');
    await Future<void>.delayed(const Duration(minutes: 10));
  }
  if (prompt.contains('FAKE-FAIL')) {
    usage(2);
    event('run.terminal.failed', {
      'terminal': 'failed',
      'text': '',
      'reason': 'model did not reach a terminal state within 2 step(s)',
    });
    exitCode = 1;
    return;
  }
  if (prompt.contains('FAKE-FIX')) {
    File('state.txt').writeAsStringSync('good\n');
  } else if (prompt.contains('FAKE-TESTS')) {
    File('state.txt').writeAsStringSync('good\n');
    File('tests${Platform.pathSeparator}state_test.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('expects anything\n');
  } else if (prompt.contains('FAKE-WRONG')) {
    File('notes.txt').writeAsStringSync('tried something else\n');
  }
  usage(3);
  event('run.terminal.completed', {
    'terminal': 'completed',
    'text': 'Done.',
    'reason': null,
  });
}
