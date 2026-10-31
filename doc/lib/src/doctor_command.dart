import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cli.dart';
import 'config.dart';
import 'dmc_client.dart';
import 'model_client.dart';
import 'model_router.dart';
import 'talk_command.dart';
import 'timelines.dart';
import 'timelines_command.dart';

/// How long a `--check` call to Modal may take before Doc calls it a cold
/// start.
const Duration glimmerColdAfter = Duration(seconds: 30);

/// The `doc timelines` defaults the estimate is shown for.
const int _defaultAgents = 3;
const int _defaultSteps = 20;

enum DoctorLevel { ok, warn, fail }

class DoctorLine {
  final DoctorLevel level;
  final String text;
  final String? fix;

  const DoctorLine(this.level, this.text, [this.fix]);
}

/// `doc doctor [--check]`: is everything set up? dmc and its version, each
/// agent's dmc hooks (through dmc's JSON), each provider's key (never its
/// value) and roles, the Modal endpoint, the microphone tool, and the
/// Muse Code agents' model with the estimated cost of a timelines run. No
/// model call is made unless `--check`, which sends one tiny prompt to
/// each provider in use (waking Muse Glimmer on Modal). Each line that is
/// not ok says how to fix it. Exit 1 when anything failed.
Future<int> runDoctorCommand(DocContext context) async {
  final check = context.args['check'] as bool;
  final env = context.env;
  final out = context.out;
  final lines = <DoctorLine>[];
  void add(DoctorLevel level, String text, [String? fix]) {
    final line = DoctorLine(level, text, fix);
    lines.add(line);
    _print(out, line);
  }

  out.writeln(
    check
        ? 'Doc doctor (--check: one tiny prompt to each provider in use)'
        : 'Doc doctor (no model calls; add --check to call each provider)',
  );

  // dmc.
  DmcClient? dmc;
  String? root;
  try {
    dmc = await context.dmc();
    final capabilities = await dmc.runJson([
      'capabilities',
    ], workspace: context.workspace);
    final features = (capabilities['data'] as Map?)?['features'] as Map?;
    if (features?['hooksStatusJson'] == true && features?['disable'] == true) {
      add(
        DoctorLevel.ok,
        'dmc: ${dmc.executable} (dmc ${capabilities['dmcVersion']})',
      );
    } else {
      add(
        DoctorLevel.warn,
        'dmc: ${dmc.executable} (dmc ${capabilities['dmcVersion']}) predates dmc disable and hooks status --json',
        'dart run tool/setup_dmc.dart, then point DMC_BIN at .deps/dmc/build/dmc/bundle/bin/dmc',
      );
    }
    final listed = await dmc.runJson([
      'checkpoint',
      'list',
      '--limit',
      '1',
    ], workspace: context.workspace);
    if (listed['ok'] == true) {
      root = (listed['workspace'] as Map?)?['path'] as String?;
      add(DoctorLevel.ok, 'dmc workspace: $root');
    } else {
      add(
        DoctorLevel.warn,
        'No dmc workspace at ${context.workspace}',
        'dmc init (in your project\'s Git repository)',
      );
    }
  } on DmcException catch (error) {
    add(
      DoctorLevel.fail,
      'dmc not found: ${error.message}',
      'dart run tool/setup_dmc.dart, then export DMC_BIN=<repo>/.deps/dmc/build/dmc/bundle/bin/dmc',
    );
  }

  // Agent hooks, through dmc's JSON.
  if (dmc != null) {
    for (final agent in const ['claude-code', 'muse-code']) {
      final name = agent == 'claude-code' ? 'Claude Code' : 'Muse Code';
      if (agent == 'claude-code' && root == null) {
        add(
          DoctorLevel.warn,
          'Hooks ($name): not checked (no dmc workspace here; Claude Code hooks are per repository)',
          'dmc init, then dmc hooks install --agent claude-code --apply',
        );
        continue;
      }
      final status = await dmc.runJson([
        'hooks',
        'status',
        '--agent',
        agent,
      ], workspace: root ?? context.workspace);
      final data = status['data'];
      if (data is! Map) {
        add(
          DoctorLevel.warn,
          'Hooks ($name): dmc could not report them (${_errors(status)})',
          'dart run tool/setup_dmc.dart (a dmc with hooks status --json)',
        );
        continue;
      }
      final events = (data['events'] as Map?) ?? const {};
      final missing = [
        for (final e in events.entries)
          if (e.value != true) e.key,
      ];
      final others = (data['otherDmcCommands'] as List? ?? const []);
      final scope = data['scope'];
      if (missing.isEmpty && others.isEmpty) {
        add(
          DoctorLevel.ok,
          'Hooks ($name, $scope): installed (${events.length} events)',
        );
      } else if (missing.length == events.length && others.isEmpty) {
        add(
          DoctorLevel.warn,
          'Hooks ($name, $scope): not installed, so its turns are not checkpointed',
          'dmc hooks install --agent $agent --apply',
        );
      } else {
        add(
          DoctorLevel.warn,
          'Hooks ($name, $scope): ${missing.isEmpty ? '' : 'missing ${missing.join(', ')}'}'
              '${others.isEmpty ? '' : '${missing.isEmpty ? '' : '; '}${others.length} hook(s) from another dmc build'}',
          'dmc disable --apply, then dmc hooks install --agent $agent --apply',
        );
      }
    }
  }

  // Providers: keys (never values) and roles.
  final roles = <String, List<String>>{};
  final primaries = <String>{};
  for (final entry in context.config.roles.entries) {
    final route = context.router.resolve(entry.key);
    (roles[route.provider.id] ??= []).add(entry.key);
    primaries.add(route.provider.id);
    if (route.fallbackProvider case final fallback?) {
      (roles[fallback.id] ??= []).add('${entry.key} (fallback)');
    }
  }
  final probes = <String, String>{};
  for (final provider in context.config.providers.values) {
    final assigned = roles[provider.id];
    if (assigned == null) continue;
    final roleText = 'roles: ${assigned.join(', ')}';
    final keyEnv = provider.keyEnv;
    final keySet = keyEnv == null || (env[keyEnv] ?? '').isNotEmpty;
    final url = provider.resolvedBaseUrl(env);
    final primary = primaries.contains(provider.id);
    if (!provider.hosted) {
      add(DoctorLevel.ok, '${provider.id}: this machine; $roleText');
      continue;
    }
    if (provider.billing == ProviderBilling.gpuTime && url.isEmpty) {
      add(
        DoctorLevel.warn,
        '${provider.id}: no endpoint configured, so ${assigned.join(', ')} fall back (logged); $roleText',
        'set ${provider.baseUrlEnv ?? 'providers.${provider.id}.baseUrl'} to the deployment URL ending in /v1 (deploy/modal/README.md)',
      );
      continue;
    }
    if (!keySet) {
      add(
        primary ? DoctorLevel.fail : DoctorLevel.warn,
        '${provider.id}: $keyEnv is NOT set; $roleText${primary ? '' : ' (only a fallback: skipped when needed)'}',
        'export $keyEnv=… in your shell profile',
      );
      continue;
    }
    add(
      DoctorLevel.ok,
      '${provider.id}: ${keyEnv == null ? 'no key needed' : '$keyEnv set'}${provider.billing == ProviderBilling.gpuTime ? '; endpoint configured' : ''}; $roleText',
    );
    if (context.config.roles.entries.any(
      (r) =>
          r.value.chat &&
          (context.router.resolve(r.key).provider.id == provider.id ||
              context.router.resolve(r.key).fallbackProvider?.id ==
                  provider.id),
    )) {
      probes[provider.id] = provider.id == 'modal'
          ? modalGlimmerModel
          : provider.defaultModel;
    }
  }

  // --check: one tiny prompt each (wakes Glimmer).
  if (check) {
    for (final entry in probes.entries) {
      final provider = context.config.providers[entry.key]!;
      if (provider.billing == ProviderBilling.gpuTime) {
        out.writeln(
          '        … asking Muse Glimmer on Modal: if Glimmer is cold, the first call takes about 2 minutes',
        );
      }
      try {
        final call = await context.router.callProvider(
          provider,
          entry.value,
          const [ChatMessage('user', 'Reply with the single word: ok')],
          maxTokens: 600,
        );
        final ms = call.result.latency.inMilliseconds;
        final cold =
            provider.billing == ProviderBilling.gpuTime &&
            call.result.latency >= glimmerColdAfter;
        add(
          DoctorLevel.ok,
          '${provider.id} answers (${entry.value}, $ms ms)${cold
              ? ': Glimmer was cold and is warm now (it scales to zero after 5 idle minutes)'
              : provider.billing == ProviderBilling.gpuTime
              ? ': Glimmer is warm'
              : ''}',
        );
      } on ModelCallException catch (error) {
        final onlyFallback = !primaries.contains(provider.id);
        add(
          onlyFallback && ModelRouter.isUnavailableError(error)
              ? DoctorLevel.warn
              : DoctorLevel.fail,
          '${provider.id} did not answer: ${explainFailure(error, provider, localOnly: context.router.localOnly)}',
          provider.billing == ProviderBilling.gpuTime
              ? 'check the deployment (deploy/modal/README.md); summary falls back to Baseten meanwhile'
              : 'check the key and the network, then doc models --check',
        );
      }
    }
  }

  // Microphone for doc talk.
  final tools = AudioTools.find(env);
  if (tools.rec != null) {
    add(DoctorLevel.ok, 'Microphone: rec (SoX) for doc talk');
  } else if (tools.ffmpeg != null && Platform.isMacOS) {
    add(
      DoctorLevel.ok,
      'Microphone: ffmpeg (AVFoundation) for doc talk; macOS asks for microphone permission the first time',
    );
  } else {
    add(
      DoctorLevel.warn,
      'Microphone: no rec (SoX) or ffmpeg, so doc talk can only use --file with a 16-bit mono WAV',
      AudioTools.install,
    );
  }

  // Agents.
  final muse = env['DOC_MUSE_BIN'] ?? _which('muse', env);
  final model = museConfiguredModel(readMuseSettings(env));
  if (muse == null) {
    add(
      DoctorLevel.warn,
      'Muse Code: not found (doc timelines and doc start muse-code need it)',
      'install Muse Code, or set DOC_MUSE_BIN',
    );
  } else {
    final version = await _version(muse);
    final estimate = model == null
        ? null
        : estimateTimelineCostFor(_defaultAgents, _defaultSteps, model);
    add(
      DoctorLevel.ok,
      'Muse Code: ${(version ?? muse).replaceFirst(RegExp(r'^Muse Code '), '')}; timeline agents use ${model ?? 'Muse Code\'s default model (not set in its settings)'}'
      '${estimate == null ? '' : '; doc timelines estimates ≤ \$${estimate.toStringAsFixed(2)} per run at the defaults ($_defaultAgents agents × $_defaultSteps steps, no cache discount; real runs are far lower)'}',
    );
  }
  final claude = env['DOC_CLAUDE_BIN'] ?? _which('claude', env);
  if (claude == null) {
    add(
      DoctorLevel.warn,
      'Claude Code: not found (the demo and doc start claude-code use it)',
      'install Claude Code, or set DOC_CLAUDE_BIN',
    );
  } else {
    add(DoctorLevel.ok, 'Claude Code: ${await _version(claude) ?? claude}');
  }

  final failures = lines.where((l) => l.level == DoctorLevel.fail).length;
  final warnings = lines.where((l) => l.level == DoctorLevel.warn).length;
  out.writeln(
    '${lines.length - failures - warnings} ok, $warnings warning(s), $failures failure(s).',
  );
  return failures > 0 ? 1 : 0;
}

void _print(StringSink out, DoctorLine line) {
  final color = identical(out, stdout) && stdout.supportsAnsiEscapes;
  final (tag, code) = switch (line.level) {
    DoctorLevel.ok => ('ok  ', '32'),
    DoctorLevel.warn => ('warn', '33'),
    DoctorLevel.fail => ('FAIL', '31'),
  };
  out.writeln('  ${color ? '\x1b[${code}m$tag\x1b[0m' : tag}  ${line.text}');
  if (line.fix != null) out.writeln('        Fix: ${line.fix}');
}

String _errors(Map<String, Object?> envelope) =>
    (envelope['errors'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => '${e['code']}: ${e['message']}')
        .join('; ');

String? _which(String name, Map<String, String> env) {
  final path = env['PATH'] ?? env['Path'] ?? '';
  for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
    if (directory.isEmpty) continue;
    for (final candidate in [
      '$directory${Platform.pathSeparator}$name',
      if (Platform.isWindows) ...[
        '$directory${Platform.pathSeparator}$name.exe',
        '$directory${Platform.pathSeparator}$name.cmd',
      ],
    ]) {
      if (FileSystemEntity.typeSync(candidate) == FileSystemEntityType.file) {
        return candidate;
      }
    }
  }
  return null;
}

/// The first line of `<executable> --version`, or null.
Future<String?> _version(String executable) async {
  try {
    final result = await Process.run(executable, [
      '--version',
    ], stdoutEncoding: utf8).timeout(const Duration(seconds: 10));
    final first = '${result.stdout}'.trim().split('\n').first.trim();
    return result.exitCode == 0 && first.isNotEmpty ? first : null;
  } on Object {
    return null;
  }
}
