// Creates the demo repository for demo/RUNBOOK.md: a small Python shop
// (money helpers and a checkout) with unittest tests, as a Git repository
// with a dmc vault, and (after asking) both agents' dmc hooks.
//
//   dart run demo/make_demo_repo.dart <folder> [--dmc <path>] [--yes] [--force]
//
// <folder> must not exist or be empty, and must not be inside another Git
// work tree (unless --force). dmc is found with --dmc, then DMC_BIN, then
// this repository's .deps/dmc build (dart run tool/setup_dmc.dart). The hook
// question defaults to No when stdin is not a terminal; --yes installs the
// hooks without asking (for scripted runs). Uses only dart:io, so it runs
// on macOS, Linux and Windows.

import 'dart:io';

const Map<String, String> files = {
  '.gitignore': '__pycache__/\n*.pyc\n.venv/\n',
  'README.md': '''# Tiny shop

Money helpers and a checkout for a small online shop.

Run the tests with:

    python3 -m unittest -q
''',
  'money.py':
      '''"""Money helpers. Amounts are dollars, rounded to whole cents."""


def round_money(amount):
    """Round an amount to whole cents."""
    return round(amount, 2)


def apply_discount(amount, percent):
    """Take percent (0 to 100) off amount, rounded to cents."""
    if not 0 <= percent <= 100:
        raise ValueError("percent must be between 0 and 100")
    return round_money(amount * (100 - percent) / 100)


def add_tax(amount, rate):
    """Add tax at rate (0.08 for 8%), rounded to cents."""
    return round_money(amount * (1 + rate))
''',
  'checkout.py': '''"""The checkout: a cart of (price, quantity) lines."""

from money import add_tax, apply_discount, round_money

TAX_RATE = 0.08


def cart_subtotal(lines):
    return round_money(sum(price * quantity for price, quantity in lines))


def checkout_total(lines, discount_percent=0):
    subtotal = cart_subtotal(lines)
    discounted = apply_discount(subtotal, discount_percent)
    return add_tax(discounted, TAX_RATE)
''',
  'test_money.py': '''import unittest

from money import add_tax, apply_discount, round_money


class MoneyTest(unittest.TestCase):
    def test_round_money_keeps_cents(self):
        self.assertEqual(round_money(19.987), 19.99)

    def test_apply_discount_takes_percent(self):
        self.assertEqual(apply_discount(80.00, 25), 60.00)

    def test_apply_discount_rejects_out_of_range(self):
        with self.assertRaises(ValueError):
            apply_discount(10.00, 150)

    def test_add_tax(self):
        self.assertEqual(add_tax(20.04, 0.08), 21.64)


if __name__ == "__main__":
    unittest.main()
''',
  'test_checkout.py': '''import unittest

from checkout import cart_subtotal, checkout_total


class CheckoutTest(unittest.TestCase):
    def test_subtotal(self):
        self.assertEqual(cart_subtotal([(12.50, 2), (5.00, 3)]), 40.00)

    def test_total_with_ten_percent_off(self):
        # 40.00, minus 10% = 36.00, plus 8% tax = 38.88
        self.assertEqual(checkout_total([(12.50, 2), (5.00, 3)], 10), 38.88)


if __name__ == "__main__":
    unittest.main()
''',
};

String repoRoot() => File.fromUri(Platform.script).parent.parent.path;

String sep(List<String> parts) => parts.join(Platform.pathSeparator);

Future<ProcessResult> run(
  String executable,
  List<String> args,
  String cwd, {
  bool check = true,
}) async {
  stdout.writeln('\$ ${[executable, ...args].join(' ')}');
  final result = await Process.run(executable, args, workingDirectory: cwd);
  final text = '${result.stdout}${result.stderr}'.trim();
  if (text.isNotEmpty) stdout.writeln(text.split('\n').take(6).join('\n'));
  if (check && result.exitCode != 0) {
    stderr.writeln('make_demo_repo: that failed (exit ${result.exitCode}).');
    exit(1);
  }
  return result;
}

const String usage = '''
Usage: dart run demo/make_demo_repo.dart <folder> [--dmc <path>] [--yes] [--force]

Creates the demo repository for demo/RUNBOOK.md: a small Python shop with
unittest tests, git init, dmc init, and (after asking) both agents' dmc hooks.

  <folder>      A new or empty folder, not inside another Git work tree.
  --dmc <path>  The dmc executable (default: DMC_BIN, then .deps/dmc's build).
  --yes         Install the hooks without asking (scripted runs).
  --force       Allow a folder inside another Git work tree.
  -h, --help    Show this help.''';

/// The Git work tree that contains [directory] (its nearest existing
/// ancestor), or null.
String? enclosingWorkTree(Directory directory) {
  var current = directory.absolute;
  while (!current.existsSync()) {
    final parent = current.parent;
    if (parent.path == current.path) return null;
    current = parent;
  }
  final result = Process.runSync('git', [
    '-C',
    current.path,
    'rev-parse',
    '--show-toplevel',
  ]);
  final top = '${result.stdout}'.trim();
  return result.exitCode == 0 && top.isNotEmpty ? top : null;
}

Future<void> main(List<String> arguments) async {
  final args = [...arguments];
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(usage);
    exit(0);
  }
  final yes = args.remove('--yes');
  final force = args.remove('--force');
  String? dmc;
  final at = args.indexOf('--dmc');
  if (at >= 0) {
    if (at + 1 >= args.length) {
      stderr.writeln('make_demo_repo: --dmc needs a path.\n\n$usage');
      exit(2);
    }
    dmc = args[at + 1];
    args.removeRange(at, at + 2);
  }
  final unknown = args.where((a) => a.startsWith('-')).toList();
  if (unknown.isNotEmpty) {
    stderr.writeln(
      'make_demo_repo: unknown option ${unknown.first}.\n\n$usage',
    );
    exit(2);
  }
  if (args.length != 1) {
    stderr.writeln(usage);
    exit(2);
  }
  final folder = Directory(args.single).absolute;
  if (folder.existsSync() && folder.listSync().isNotEmpty) {
    stderr.writeln('make_demo_repo: ${folder.path} exists and is not empty.');
    exit(1);
  }
  final enclosing = enclosingWorkTree(folder);
  if (enclosing != null && !force) {
    stderr.writeln(
      'make_demo_repo: ${folder.path} is inside the Git work tree $enclosing. '
      'Pick a folder outside it (for example /tmp/doc-demo), or pass --force.',
    );
    exit(1);
  }
  dmc ??= Platform.environment['DMC_BIN'];
  dmc ??= sep([
    repoRoot(),
    '.deps',
    'dmc',
    'build',
    'dmc',
    'bundle',
    'bin',
    Platform.isWindows ? 'dmc.exe' : 'dmc',
  ]);
  if (!File(dmc).existsSync()) {
    stderr.writeln(
      'make_demo_repo: no dmc at $dmc. Run dart run tool/setup_dmc.dart, or pass --dmc <path>.',
    );
    exit(1);
  }

  folder.createSync(recursive: true);
  for (final entry in files.entries) {
    File(sep([folder.path, entry.key])).writeAsStringSync(entry.value);
  }
  stdout.writeln('Wrote ${files.length} files to ${folder.path}.');
  final cwd = folder.path;
  await run('git', ['init', '--quiet'], cwd);
  await run('git', ['add', '-A'], cwd);
  // The user's own identity when set, else a demo one for this repo only.
  final named =
      (await Process.run('git', [
        'config',
        'user.name',
      ], workingDirectory: cwd)).exitCode ==
      0;
  await run('git', [
    if (!named) ...[
      '-c',
      'user.name=Demo',
      '-c',
      'user.email=demo@example.com',
    ],
    'commit',
    '--quiet',
    '-m',
    'Tiny shop: money helpers, checkout and tests',
  ], cwd);
  final tests = await run(
    'python3',
    ['-m', 'unittest', '-q'],
    cwd,
    check: false,
  );
  stdout.writeln(
    tests.exitCode == 0
        ? 'Tests pass (python3 -m unittest -q).'
        : 'Warning: the tests did not pass here (is python3 installed?).',
  );
  await run(dmc, ['init'], cwd);

  stdout.write(
    '\nInstall dmc hooks so every agent turn becomes a checkpoint?\n'
    '  Claude Code: $cwd/.claude/settings.local.json (this repository only)\n'
    '  Muse Code: ~/.config/muse/settings.json (user scope; the hooks do nothing outside a dmc workspace)\n'
    'Install both? [y/N] ',
  );
  var install = yes;
  if (yes) {
    stdout.writeln('yes (--yes)');
  } else if (!stdin.hasTerminal) {
    // Scripts and pipes get the safe default.
    stdout.writeln('no (stdin is not a terminal; pass --yes to install)');
  } else {
    final answer = (stdin.readLineSync() ?? '').trim().toLowerCase();
    install = answer == 'y' || answer == 'yes';
  }
  if (install) {
    await run(dmc, [
      'hooks',
      'install',
      '--agent',
      'claude-code',
      '--apply',
    ], cwd);
    await run(dmc, [
      'hooks',
      'install',
      '--agent',
      'muse-code',
      '--apply',
    ], cwd);
  } else {
    stdout.writeln(
      'Hooks not installed. Without them, agent turns are not checkpointed.',
    );
  }

  stdout.writeln('''

The demo repository is ready: $cwd
Next (see demo/RUNBOOK.md):
  cd "$cwd"
  export DMC_BIN="$dmc"
  doc models --check                     # warms Muse Glimmer on Modal
  # then the scripted agent turns, doc bisect, doc timelines --from-bisect, …
When you are done:
  $dmc hooks uninstall --agent claude-code --apply   (in $cwd)
  $dmc hooks uninstall --agent muse-code --apply
''');
}
