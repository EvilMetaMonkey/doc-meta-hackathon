/// The real terminal for the TUI: alternate screen, raw mode, hidden
/// cursor, one async stdin subscription for keys, resize, and restoring
/// all of it on exit, error, Ctrl-C and SIGTERM.
library;

import 'dart:async';
import 'dart:io';

import 'app.dart';
import 'keys.dart';

class TerminalHost implements TuiHost {
  @override
  final bool color;

  final StreamController<KeyEvent> _keys = StreamController.broadcast();
  StreamSubscription<List<int>>? _stdin;
  final List<StreamSubscription<ProcessSignal>> _signals = [];
  Timer? _sizePoll;
  bool? _echo;
  bool? _line;
  bool _active = false;
  (int, int) _lastSize = (0, 0);

  /// Called on resize (redraw).
  void Function()? onResize;

  /// Called on SIGINT/SIGTERM after the terminal is restored.
  void Function(int code)? onSignal;

  TerminalHost({required this.color});

  @override
  Stream<KeyEvent> get keys => _keys.stream;

  @override
  (int, int) get size {
    try {
      return (stdout.terminalColumns, stdout.terminalLines);
    } on StdoutException {
      return (80, 24);
    }
  }

  /// Takes the terminal: alternate screen, raw mode, cursor hidden.
  void start() {
    _enter();
    // One subscription for the whole session; paused while a child
    // process has the terminal.
    _stdin = stdin.listen(
      (bytes) {
        for (final key in decodeKeys(bytes)) {
          _keys.add(key);
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
    for (final (signal, code) in [
      (ProcessSignal.sigint, 130),
      (ProcessSignal.sigterm, 143),
    ]) {
      try {
        _signals.add(
          signal.watch().listen((_) {
            stop();
            onSignal?.call(code);
          }),
        );
      } on SignalException {
        // SIGTERM cannot be watched on Windows.
      }
    }
    try {
      _signals.add(
        ProcessSignal.sigwinch.watch().listen((_) => onResize?.call()),
      );
    } on SignalException {
      // Windows: poll the size instead.
      _lastSize = size;
      _sizePoll = Timer.periodic(const Duration(milliseconds: 500), (_) {
        final now = size;
        if (now != _lastSize) {
          _lastSize = now;
          onResize?.call();
        }
      });
    }
  }

  void _enter() {
    if (_active) return;
    _active = true;
    if (stdin.hasTerminal) {
      _echo = stdin.echoMode;
      _line = stdin.lineMode;
      stdin
        ..echoMode = false
        ..lineMode = false;
    }
    stdout.write('\x1b[?1049h\x1b[?25l\x1b[2J');
  }

  void _leave() {
    if (!_active) return;
    _active = false;
    stdout.write('\x1b[0m\x1b[2J\x1b[H\x1b[?25h\x1b[?1049l');
    if (_echo != null && stdin.hasTerminal) {
      try {
        stdin
          ..lineMode = _line!
          ..echoMode = _echo!;
      } on StdinException {
        // The terminal is gone.
      }
    }
  }

  /// Gives everything back. Safe to call more than once.
  void stop() {
    _sizePoll?.cancel();
    for (final s in _signals) {
      s.cancel();
    }
    _signals.clear();
    _leave();
    _stdin?.cancel();
    _stdin = null;
  }

  @override
  void draw(List<String> lines) {
    if (!_active) return;
    // Home, then each line in place; no trailing newline, so nothing
    // scrolls.
    stdout.write('\x1b[H${lines.join('\r\n')}');
  }

  @override
  Future<int> handOver(Future<int> Function() run) async {
    _stdin?.pause();
    _leave();
    try {
      return await run();
    } finally {
      _enter();
      _stdin?.resume();
      onResize?.call();
    }
  }
}
