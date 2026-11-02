import 'dart:async';

import 'package:dmc_doc/doc.dart';

/// A terminal for TuiApp tests: scripted keys, a fixed size, every frame
/// kept (plain text, no colour).
class FakeHost implements TuiHost {
  final StreamController<KeyEvent> controller = StreamController.broadcast();
  final List<List<String>> frames = [];
  int width;
  int height;
  int handOvers = 0;

  FakeHost({this.width = 120, this.height = 36});

  @override
  Stream<KeyEvent> get keys => controller.stream;

  @override
  (int, int) get size => (width, height);

  @override
  bool get color => false;

  @override
  void draw(List<String> lines) => frames.add(lines);

  @override
  Future<int> handOver(Future<int> Function() run) async {
    handOvers++;
    return run();
  }

  String get screen => frames.isEmpty ? '' : frames.last.join('\n');

  Future<void> press(Object key) async {
    final event = key is KeyEvent
        ? key
        : key == ' '
        ? const KeyEvent(KeyKind.space)
        : KeyEvent.char('$key');
    controller.add(event);
    await pump();
  }

  Future<void> type(String text) async {
    for (final char in text.split('')) {
      await press(char);
    }
  }

  Future<void> enter() => press(const KeyEvent(KeyKind.enter));
  Future<void> escape() => press(const KeyEvent(KeyKind.escape));
}

/// Lets timers and microtasks run.
Future<void> pump([int times = 5]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// Waits until [condition] holds (or fails after ~3 s).
Future<void> until(bool Function() condition, {String? what}) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Timed out waiting for ${what ?? 'a condition'}');
}

Map<String, Object?> turnJson(
  String id,
  int at, {
  String agent = 'claude-code',
  String status = 'closed',
  String? label,
  bool undone = false,
}) => {
  'id': id,
  'status': status,
  'source': agent,
  'label': label ?? 'turn $id',
  'createdAt': at,
  'closedAt': status == 'closed' ? at + 1 : null,
  'agent': {'name': agent, 'sessionId': 's1'},
  'operations': [
    if (undone)
      {'direction': 'restore', 'status': 'completed', 'completedAt': at + 5},
  ],
};

/// A backend with fixed data; [runDoc] calls [onRun], which may write to
/// io.out and ask questions through io.ask.
class FakeBackend implements TuiBackend {
  List<Map<String, Object?>> turns;
  Map<String, Object?>? bisect;
  List<LessonItem> lessonItems;
  final List<List<String>> runs = [];
  final List<List<String>> dmcCalls = [];
  final Map<String, String> summaries = {};
  Future<int> Function(List<String> args, DocRunIo io)? onRun;
  Map<String, Object?> Function(List<String> args)? onDmc;
  bool workspace = true;
  List<DoctorLine> doctorLines = const [
    DoctorLine(DoctorLevel.ok, 'dmc: /x/dmc (dmc 1.1.0)'),
    DoctorLine(
      DoctorLevel.ok,
      'Hooks (Claude Code, local): installed (4 events)',
    ),
    DoctorLine(DoctorLevel.ok, 'Hooks (Muse Code, user): installed (5 events)'),
  ];

  FakeBackend({
    this.turns = const [],
    this.bisect,
    this.lessonItems = const [],
  });

  @override
  String get workspaceName => 'shop';

  @override
  String get dmcCommand => '"/x/dmc"';

  @override
  String get logDirectory => '/logs';

  @override
  bool get summaryOnModal => false;

  @override
  Future<List<DoctorLine>> doctor() async => doctorLines;

  @override
  Future<Map<String, Object?>> checkpointList() async => workspace
      ? {
          'ok': true,
          'data': {'checkpoints': turns},
        }
      : {
          'ok': false,
          'errors': [
            {'code': 'not_initialized', 'message': 'no vault'},
          ],
        };

  @override
  Map<String, Object?>? lastBisect() => bisect;

  @override
  Future<String?> diff(
    String id,
    List<({String path, String change})> files,
  ) async => '--- money.py (modified)\n-    return 100\n+    return 1\n same';

  @override
  Future<Map<String, Object?>> show(String id) async => {
    'ok': true,
    'data': {
      'files': [
        {'path': 'money.py', 'change': 'modified'},
      ],
    },
  };

  @override
  Future<Map<String, Object?>> dmcJson(List<String> args) async {
    dmcCalls.add(args);
    return onDmc?.call(args) ?? {'ok': true, 'data': {}};
  }

  @override
  Future<int> runDoc(List<String> args, DocRunIo io) async {
    runs.add(args);
    return onRun == null ? 0 : onRun!(args, io);
  }

  @override
  Future<List<LessonItem>> lessons() async => lessonItems;

  @override
  String? cachedSummary(String id) => summaries[id];

  @override
  void saveSummary(String id, String text, String? footer) =>
      summaries[id] = '$text\n\n${footer ?? ''}';

  @override
  String? defaultTest() => 'python3 -m unittest -q';

  @override
  String? defaultSetup() => null;
}

/// A TuiApp over the fakes, with short timers and in-memory logs.
({TuiApp app, Future<int> running}) startApp(
  FakeHost host,
  FakeBackend backend, {
  bool splash = false,
}) {
  final logs = <String, StringBuffer>{};
  final app = TuiApp(
    host: host,
    backend: backend,
    splash: splash,
    dmcVersion: '1.1.0',
    pollEvery: const Duration(hours: 1),
    summaryDelay: const Duration(milliseconds: 5),
    splashFor: const Duration(milliseconds: 50),
    openLog: (name) {
      final buffer = StringBuffer();
      final path = '/logs/$name-${logs.length}.log';
      logs[path] = buffer;
      return (sink: buffer, path: path, close: () async {});
    },
  )..readLogFile = (path) => logs[path]?.toString() ?? '';
  return (app: app, running: app.run());
}
