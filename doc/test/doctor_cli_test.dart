@Timeout(Duration(minutes: 6))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dmc_doc/doc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/dmc_fixture.dart';
import 'support/fake_provider.dart';

void main() {
  late Directory scratch;
  late String dmc;

  setUpAll(() async {
    scratch = Directory.systemTemp.createTempSync('doc_doctor_');
    dmc = await compiledDmc(scratch);
  });

  tearDownAll(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  late Directory home;
  late Directory workspace;
  late Directory bin;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() async {
    home = Directory.systemTemp.createTempSync('doc_doctor_home_');
    workspace = Directory(p.join(home.path, 'project'))..createSync();
    bin = Directory(p.join(home.path, 'bin'))..createSync();
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() => home.deleteSync(recursive: true));

  Map<String, String> baseEnv(Map<String, String> extra) => {
    'DOC_CONFIG_DIR': p.join(home.path, 'config'),
    'DOC_DATA_DIR': p.join(home.path, 'data'),
    'HOME': home.path,
    'USERPROFILE': home.path,
    // Only the test's own bin: no real muse, claude, sox or ffmpeg.
    'PATH': bin.path,
    if (Platform.isWindows)
      'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
    ...extra,
  };

  Future<int> doc(List<String> args, {Map<String, String> env = const {}}) =>
      runDoc(
        [...args, '--dmc', dmc, '--workspace', workspace.path],
        environment: baseEnv(env),
        out: out,
        err: err,
        client: ChatClient(maxRetries: 0, sleep: (_) async {}),
      );

  Future<void> dmcIn(List<String> args) async {
    final result = await Process.run(
      dmc,
      args,
      workingDirectory: workspace.path,
      environment: {'HOME': home.path, 'USERPROFILE': home.path},
    );
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }

  void config(Map<String, String> urls) {
    File(p.join(home.path, 'config', 'config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'providers': {
            for (final e in urls.entries) e.key: {'baseUrl': e.value},
          },
        }),
      );
  }

  test('nothing set up: each problem with its fix, failures exit 1', () async {
    expect(await doc(['doctor']), 1);
    final text = '$out';
    expect(text, contains('Doc doctor (no model calls; add --check'));
    expect(text, contains('  ok    dmc: $dmc (dmc '));
    expect(text, contains('  warn  No dmc workspace at ${workspace.path}'));
    expect(text, contains('        Fix: dmc init'));
    expect(
      text,
      contains(
        '  FAIL  meta: MODEL_API_KEY is NOT set; roles: restore, planner, judge, voice',
      ),
    );
    expect(text, contains('  FAIL  baseten: BASETEN_API_KEY is NOT set'));
    expect(
      text,
      contains(
        '  warn  fireworks: FIREWORKS_API_KEY is NOT set; roles: workhorse (fallback) (only a fallback',
      ),
    );
    expect(
      text,
      contains(
        '  warn  modal: no endpoint configured, so summary fall back (logged)',
      ),
    );
    expect(text, contains('Fix: set DOC_MODAL_BASE_URL'));
    expect(text, contains('  warn  Microphone: no rec (SoX) or ffmpeg'));
    expect(text, contains('  warn  Muse Code: not found'));
    expect(text, contains('  warn  Claude Code: not found'));
    expect(text, contains('failure(s).'));
  });

  test('set up: hooks via dmc JSON, keys never printed, the agent model and '
      'its estimate, and no model call', () async {
    final meta = await FakeProvider.start([FakeReply.chat('ok')]);
    addTearDown(meta.close);
    config({'meta': meta.baseUrl, 'modal': meta.baseUrl});
    await dmcIn(['init']);
    await dmcIn(['hooks', 'install', '--agent', 'claude-code', '--apply']);
    await dmcIn(['hooks', 'install', '--agent', 'muse-code', '--apply']);
    final settings = File(
      p.join(home.path, '.config', 'muse', 'settings.json'),
    );
    final museConfig = jsonDecode(settings.readAsStringSync()) as Map;
    museConfig['model'] = 'muse-wonder-1.0';
    settings.writeAsStringSync(jsonEncode(museConfig));
    if (!Platform.isWindows) {
      for (final (name, version) in [
        ('muse', 'Muse Code 1.4.14'),
        ('claude', '2.1.312 (Claude Code)'),
        ('ffmpeg', 'ffmpeg 8'),
      ]) {
        final tool = File(p.join(bin.path, name))
          ..writeAsStringSync('#!/bin/sh\necho "$version"\n');
        Process.runSync('chmod', ['+x', tool.path]);
      }
    }
    const secrets = {
      'MODEL_API_KEY': 'LLM|meta-secret-value-0001',
      'BASETEN_API_KEY': 'baseten-secret-value-02',
      'FIREWORKS_API_KEY': 'fireworks-secret-value-3',
      'MODAL_GLIMMER_KEY': 'modal-secret-value-0004',
    };
    expect(await doc(['doctor'], env: secrets), 0, reason: '$out');
    final text = '$out';
    for (final value in secrets.values) {
      expect(text, isNot(contains(value)));
    }
    expect(text, contains('  ok    dmc workspace: '));
    expect(
      text,
      contains('  ok    Hooks (Claude Code, local): installed (4 events)'),
    );
    expect(
      text,
      contains('  ok    Hooks (Muse Code, user): installed (5 events)'),
    );
    expect(
      text,
      contains(
        '  ok    meta: MODEL_API_KEY set; roles: restore, planner, judge, voice',
      ),
    );
    expect(
      text,
      contains(
        '  ok    modal: MODAL_GLIMMER_KEY set; endpoint configured; roles: summary',
      ),
    );
    if (!Platform.isWindows) {
      expect(
        text,
        contains(
          '  ok    Muse Code: 1.4.14; timeline agents use muse-wonder-1.0; doc timelines estimates ≤ \$7.92 per run at the defaults',
        ),
      );
      expect(text, contains('  ok    Claude Code: 2.1.312 (Claude Code)'));
    }
    expect(meta.requests, isEmpty);
  });

  test('--check calls each provider in use and warms Glimmer', () async {
    final meta = await FakeProvider.start([FakeReply.chat('ok')]);
    final baseten = await FakeProvider.start([FakeReply.chat('ok')]);
    final fireworks = await FakeProvider.start([
      const FakeReply(401, {'error': 'bad key'}),
    ]);
    final modal = await FakeProvider.start([FakeReply.chat('ok')]);
    for (final fake in [meta, baseten, fireworks, modal]) {
      addTearDown(fake.close);
    }
    config({
      'meta': meta.baseUrl,
      'baseten': baseten.baseUrl,
      'fireworks': fireworks.baseUrl,
      'modal': modal.baseUrl,
    });
    final code = await doc(
      ['doctor', '--check'],
      env: {
        'MODEL_API_KEY': 'LLM|meta-key-for-tests-01',
        'BASETEN_API_KEY': 'baseten-key-for-tests-01',
        'FIREWORKS_API_KEY': 'fireworks-key-for-tests-1',
        'MODAL_GLIMMER_KEY': 'modal-key-for-tests-0001',
      },
    );
    final text = '$out';
    expect(code, 0, reason: text);
    expect(
      text,
      contains('Doc doctor (--check: one tiny prompt to each provider in use)'),
    );
    expect(
      text,
      contains('if Glimmer is cold, the first call takes about 2 minutes'),
    );
    expect(
      text,
      contains(
        RegExp(
          r'ok    modal answers \(muse-glimmer, \d+ ms\): Glimmer is warm',
        ),
      ),
    );
    expect(
      text,
      contains(RegExp(r'ok    meta answers \(muse-spark-1\.3, \d+ ms\)')),
    );
    // Fireworks is only a fallback: a rejected key is a warning.
    expect(text, contains('  warn  fireworks did not answer'));
    expect(meta.requests, hasLength(1));
    expect(modal.requests, hasLength(1));
  });

  test('hooks from another dmc build are a warning with the fix', () async {
    await dmcIn(['init']);
    File(p.join(workspace.path, '.claude', 'settings.local.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'hooks': {
            'Stop': [
              {
                'matcher': '*',
                'hooks': [
                  {
                    'type': 'command',
                    'command': '/old/dmc agent-hook claude-code Stop',
                  },
                ],
              },
            ],
          },
        }),
      );
    await doc(['doctor']);
    expect(
      '$out',
      contains(
        'warn  Hooks (Claude Code, local): missing UserPromptSubmit, Stop, StopFailure, SessionEnd; 1 hook(s) from another dmc build',
      ),
    );
    expect(
      '$out',
      contains(
        'Fix: dmc disable --apply, then dmc hooks install --agent claude-code --apply',
      ),
    );
  });
}
