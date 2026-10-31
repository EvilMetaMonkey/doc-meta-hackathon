# dmc patches

This repository holds only work done during the Meta AI Developer Hackathon 2026. **dmc**, the
engine Doc drives, is Mike Hood's pre-existing open-source project at
<https://github.com/EvilMetaMonkey/dmc>. Its code and history are not copied here. The event's
changes to dmc are in [`dmc-patches/`](dmc-patches/) as a `git format-patch` series against dmc
commit **`d177c4bf73901cfac0a4ba7ef068cf24b95a2cb0`** (2026-10-25 19:00 UTC, the pre-event
baseline), pinned by SHA.

- `dart run tool/setup_dmc.dart` clones dmc into `.deps/dmc`, checks out that commit and applies
  the series with `git am`, then builds the bundle.
- `dart run tool/export_patches.dart` regenerates the series from `.deps/dmc` after an engine
  change.

**Verified on 2026-10-31:**

- The series applies cleanly with `git am` to a fresh clone of EvilMetaMonkey/dmc at that commit
  (re-checked on 2026-10-31 with 35 patches: a clean `tool/setup_dmc.dart` applied 35 of 35).
- The resulting dmc tree is identical, blob for blob, to the dmc files of the event repository
  it came from (`EvilMetaMonkey/dmc-meta-hackathon` `main` at `0f58a36`).
- `tool/export_patches.dart` reproduces the series byte for byte.

Patches 0001–0031 came from the event's first repository; 0032 onwards were made in `.deps/dmc`
and exported with `tool/export_patches.dart`. Subjects are unnumbered (`[PATCH]`), so adding a
patch never rewrites the others.

The series is one patch per original commit that touched dmc files, in order, merges flattened,
and limited to dmc's paths. Doc's own files were removed from these patches; they live in this
repository with their real history.

## The patches

| # | Subject | dmc files | Event feature |
|---|---|---|---|
| 0001 | Mark repository as the Meta AI Developer Hackathon 2026 entry | `CLAUDE.md`, `README.md` | Repository setup: hackathon banner in the README and agent notes |
| 0002 | Add STATUS.md and require agents to keep it current | `AGENTS.md`, `CLAUDE.md` | Repository setup: the STATUS.md rules for coding agents |
| 0003 | Record verified agent hook surfaces and payload fixtures | `test/fixtures/agent_hooks/…` | Agent-turn checkpoints: captured Claude Code and Muse Code hook payloads (test fixtures) |
| 0004 | Add agent-turn context to checkpoints (schema 4) | `AGENTS.md`, `docs/HAVEN-INTEGRATION.md`, `lib/src/checkpoint_models.dart`, `lib/src/checkpoint_repository.dart`, `lib/src/checkpoint_service.dart`, `lib/src/database.dart`, `lib/src/status.dart`, `test/migration_test.dart` | Agent-turn checkpoints: schema 4, agent context per checkpoint (agent, session, turn, transcript hash) |
| 0005 | Add dmc agent-hook for Muse Code and Claude Code turns | `lib/dmc.dart`, `lib/src/agent_hooks.dart`, `lib/src/checkpoint_service.dart`, `lib/src/cli.dart`, `test/agent_hooks_test.dart` | Agent-turn checkpoints: `dmc agent-hook` (begin on prompt, close on Stop/StopFailure/SessionEnd/Interrupt) |
| 0006 | Add dmc hooks install/uninstall/status for agent hooks | `AGENTS.md`, `CHANGELOG.md`, `lib/dmc.dart`, `lib/src/cli.dart`, `lib/src/hook_installer.dart`, `test/hook_installer_test.dart` | Agent-turn checkpoints: `dmc hooks install|uninstall|status` |
| 0007 | Resolve agent hook fixtures from the package root | `test/agent_hooks_test.dart` | Agent-turn checkpoints: test fixtures resolved from the package root (CI flake fix) |
| 0008 | Make hooks uninstall restore the original config bytes | `lib/src/hook_installer.dart`, `test/hook_installer_test.dart` | Agent-turn checkpoints: uninstall restores the original config bytes |
| 0009 | Use captured Muse Code payloads; close only the named turn | `lib/src/agent_hooks.dart`, `test/agent_hooks_test.dart`, `test/fixtures/agent_hooks/…` | Agent-turn checkpoints: real Muse payloads; a close must match the turn |
| 0010 | Record the Muse Code 1.4.13 verification | `CHANGELOG.md` | Agent-turn checkpoints: changelog for the Muse Code 1.4.13 verification |
| 0011 | Run CI tests with --concurrency=1 | `.github/workflows/ci.yml` | CI: run tests with --concurrency=1 (race fix) |
| 0012 | Let Git decide what is ignored inside a Git work tree | `lib/dmc.dart`, `lib/src/checkpoint_service.dart`, `lib/src/doctor.dart`, `lib/src/git_ignore.dart`, `lib/src/ignore.dart`, `lib/src/snap.dart`, `lib/src/status.dart`, `lib/src/watcher.dart`, `lib/src/workspace_scan.dart` | Git-compatible ignores (needed to checkpoint real repos): Git decides what is ignored |
| 0013 | Refuse checkpoint restore and redo of Git-ignored paths | `lib/src/checkpoint_plan.dart`, `lib/src/checkpoint_restore_service.dart` | Git-compatible ignores: restore and redo refuse Git-ignored paths |
| 0014 | Test Git-mode ignore handling | `test/git_ignore_test.dart` | Git-compatible ignores: tests |
| 0015 | Document Git-mode ignore handling | `AGENTS.md`, `CHANGELOG.md`, `README.md`, `website/src/content/docs/docs/dmc/getting-started.md` | Git-compatible ignores: docs and website page |
| 0016 | Handle ignore-policy drift per file instead of invalidating close | `lib/src/checkpoint_models.dart`, `lib/src/checkpoint_plan.dart`, `lib/src/checkpoint_repository.dart`, `lib/src/checkpoint_restore_service.dart`, `lib/src/checkpoint_service.dart`, `lib/src/database.dart`, `lib/src/ignore.dart`, `test/checkpoint_test.dart`, `test/git_ignore_test.dart`, `test/migration_test.dart`, `test/policy_drift_test.dart` | Ignore-policy drift handled per file (schema 5); a turn that edits .gitignore can close |
| 0017 | Add dmc checkpoint export <id> --to <dir> [--state before\\|after] | `lib/dmc.dart`, `lib/src/checkpoint_export.dart`, `lib/src/cli.dart`, `test/checkpoint_export_test.dart` | `dmc checkpoint export` (bisect probes, abandoned-work diffs, NL-restore line counts, timeline bases) |
| 0018 | Document per-file policy drift and checkpoint export | `AGENTS.md`, `CHANGELOG.md`, `README.md`, `docs/HAVEN-INTEGRATION.md`, `website/src/content/docs/docs/dmc/checkpoints.md` | Docs for policy drift and checkpoint export |
| 0019 | Keep agent hooks inside their own Git work tree | `lib/dmc.dart`, `lib/src/agent_hooks.dart`, `lib/src/doctor.dart`, `lib/src/git_worktree.dart`, `lib/src/status.dart`, `test/worktree_test.dart` | Worktree check: agent hooks stay in their own Git work tree; status/doctor show worktrees (also used by timelines) |
| 0020 | Add the Doc package with its model and dmc clients | `analysis_options.yaml` | Doc package: dmc analyzer excludes doc/ (Doc has its own analyzer run) |
| 0021 | Add Doc's role router and the models, summarize and usage commands | `.github/workflows/ci.yml` | Doc package: dmc CI also analyzed and tested doc/ (superseded by this repo's CI) |
| 0022 | Document the worktree rule, Doc and the verified Muse model IDs | `AGENTS.md`, `CHANGELOG.md`, `README.md` | Docs: worktree rule, Doc boundary, Muse verification |
| 0023 | Retry the delete in the watcher rename test | `test/watcher_hardening_test.dart` | Test-only fix: retry a delete in the Windows watcher test |
| 0024 | Document Glimmer on Modal, the Fireworks backup and the lesson library | `AGENTS.md`, `CHANGELOG.md` | Docs: Glimmer on Modal and the Fireworks backup (AGENTS/CHANGELOG) |
| 0025 | Stop tracking Python bytecode | `.gitignore` | .gitignore: Python bytecode under deploy/ |
| 0026 | Default the summary role to Baseten while Modal is on hold | `AGENTS.md` | Docs: summary role default (AGENTS) |
| 0027 | Document doc restore, --last-restore and abandoned-work diffs | `AGENTS.md`, `CHANGELOG.md` | Docs: doc restore and lesson drafts (AGENTS/CHANGELOG) |
| 0028 | Document doc bisect | `AGENTS.md`, `CHANGELOG.md` | Docs: doc bisect (AGENTS/CHANGELOG) |
| 0029 | Document Glimmer on Modal and natural-language restore | `AGENTS.md`, `CHANGELOG.md` | Docs: Glimmer and natural-language restore (AGENTS/CHANGELOG) |
| 0030 | Document Hey Doc push-to-talk and the lesson-draft change | `AGENTS.md`, `CHANGELOG.md` | Docs: Hey Doc and lesson drafts (AGENTS/CHANGELOG) |
| 0031 | Document parallel timelines, part 1 | `AGENTS.md`, `CHANGELOG.md` | Docs: parallel timelines part 1 (AGENTS/CHANGELOG) |
| 0032 | Add dmc disable and JSON hooks status | `lib/dmc.dart`, `lib/src/cli.dart`, `lib/src/disable.dart`, `lib/src/hook_installer.dart`, `lib/src/hook_report.dart`, `test/disable_test.dart` | Parity: `dmc disable [--apply]` removes only dmc's own hooks (every supported config file, this build's and other dmc builds', exact-match uninstall, byte-exact restore) and stops the watcher, keeping `.dmc/` and every checkpoint; `hooks status --json` (for `doc doctor`); `capabilities` lists both |
| 0033 | dmc doctor checks agent hooks | `lib/dmc.dart`, `lib/src/cli.dart`, `lib/src/doctor.dart`, `lib/src/hook_doctor.dart`, `test/hook_doctor_test.dart` | Parity: doctor reports a missing or non-executable dmc in a hook, a hook pointing at a different dmc build, a non-async Muse Interrupt hook, and an agent checkpoint left open past `--stale-hours` (default 2) by an ended session, each with its fix; it changes nothing |
| 0034 | Document dmc disable, the doctor hook checks and hooks status --json | `AGENTS.md`, `CHANGELOG.md` | Docs for 0032–0033 |
| 0035 | doctor: skip the execute-bit check on Windows by default | `lib/src/hook_doctor.dart` | Fix for 0033 on Windows (no execute bit), found by CI |

## Step 1: every path changed since the `pre-hackathon` tag

Each path from `git diff --name-status pre-hackathon main` in the old repository was checked with
`git ls-tree pre-hackathon -- <path>`. A path that did not exist at the tag and is not part of dmc's
engine is **event work**, moved here with its history. Everything else (dmc's `lib/`, `bin/`,
`test/` including the new agent-hook fixtures, `tool/`, `pubspec.*`, `analysis_options.yaml`,
`.gitignore`, `.github/`, `website/`, and edits to pre-existing files) is a **dmc change**, shipped
only as patches. No path was unclear.

| Status | Path | Existed at the tag | Classification |
|---|---|---|---|
| M | `.github/workflows/ci.yml` | yes | dmc change (patch only) |
| M | `.gitignore` | yes | dmc change (patch only) |
| M | `AGENTS.md` | yes | dmc change (patch only) |
| M | `CHANGELOG.md` | yes | dmc change (patch only) |
| M | `CLAUDE.md` | yes | dmc change (patch only) |
| A | `HACKATHON.md` | no | event work (moved with history) |
| M | `README.md` | yes | dmc change (patch only) |
| A | `STATUS.md` | no | event work (moved with history) |
| M | `analysis_options.yaml` | yes | dmc change (patch only) |
| A | `deploy/modal/README.md` | no | event work (moved with history) |
| A | `deploy/modal/glimmer.py` | no | event work (moved with history) |
| A | `doc/README.md` | no | event work (moved with history) |
| A | `doc/analysis_options.yaml` | no | event work (moved with history) |
| A | `doc/bin/doc.dart` | no | event work (moved with history) |
| A | `doc/lib/doc.dart` | no | event work (moved with history) |
| A | `doc/lib/src/abandoned_work.dart` | no | event work (moved with history) |
| A | `doc/lib/src/bisect.dart` | no | event work (moved with history) |
| A | `doc/lib/src/bisect_command.dart` | no | event work (moved with history) |
| A | `doc/lib/src/cli.dart` | no | event work (moved with history) |
| A | `doc/lib/src/config.dart` | no | event work (moved with history) |
| A | `doc/lib/src/dmc_client.dart` | no | event work (moved with history) |
| A | `doc/lib/src/lesson_commands.dart` | no | event work (moved with history) |
| A | `doc/lib/src/lessons.dart` | no | event work (moved with history) |
| A | `doc/lib/src/model_client.dart` | no | event work (moved with history) |
| A | `doc/lib/src/model_router.dart` | no | event work (moved with history) |
| A | `doc/lib/src/nl_restore.dart` | no | event work (moved with history) |
| A | `doc/lib/src/nl_restore_command.dart` | no | event work (moved with history) |
| A | `doc/lib/src/probe_runner.dart` | no | event work (moved with history) |
| A | `doc/lib/src/redaction.dart` | no | event work (moved with history) |
| A | `doc/lib/src/restore_command.dart` | no | event work (moved with history) |
| A | `doc/lib/src/summarize.dart` | no | event work (moved with history) |
| A | `doc/lib/src/talk_command.dart` | no | event work (moved with history) |
| A | `doc/lib/src/timelines.dart` | no | event work (moved with history) |
| A | `doc/lib/src/timelines_command.dart` | no | event work (moved with history) |
| A | `doc/lib/src/usage.dart` | no | event work (moved with history) |
| A | `doc/lib/src/voice_client.dart` | no | event work (moved with history) |
| A | `doc/lib/src/voice_intent.dart` | no | event work (moved with history) |
| A | `doc/pubspec.lock` | no | event work (moved with history) |
| A | `doc/pubspec.yaml` | no | event work (moved with history) |
| A | `doc/test/bisect_cli_test.dart` | no | event work (moved with history) |
| A | `doc/test/bisect_test.dart` | no | event work (moved with history) |
| A | `doc/test/cli_test.dart` | no | event work (moved with history) |
| A | `doc/test/lesson_cli_test.dart` | no | event work (moved with history) |
| A | `doc/test/lessons_test.dart` | no | event work (moved with history) |
| A | `doc/test/model_client_test.dart` | no | event work (moved with history) |
| A | `doc/test/model_router_test.dart` | no | event work (moved with history) |
| A | `doc/test/nl_restore_cli_test.dart` | no | event work (moved with history) |
| A | `doc/test/nl_restore_test.dart` | no | event work (moved with history) |
| A | `doc/test/redaction_test.dart` | no | event work (moved with history) |
| A | `doc/test/restore_cli_test.dart` | no | event work (moved with history) |
| A | `doc/test/support/dmc_fixture.dart` | no | event work (moved with history) |
| A | `doc/test/support/fake_muse.dart` | no | event work (moved with history) |
| A | `doc/test/support/fake_provider.dart` | no | event work (moved with history) |
| A | `doc/test/support/fake_voice.dart` | no | event work (moved with history) |
| A | `doc/test/talk_cli_test.dart` | no | event work (moved with history) |
| A | `doc/test/timelines_cli_test.dart` | no | event work (moved with history) |
| A | `doc/test/timelines_test.dart` | no | event work (moved with history) |
| A | `doc/test/voice_client_test.dart` | no | event work (moved with history) |
| A | `doc/test/voice_intent_test.dart` | no | event work (moved with history) |
| A | `docs/AGENT-HOOKS.md` | no | event work (moved with history) |
| M | `docs/HAVEN-INTEGRATION.md` | yes | dmc change (patch only) |
| M | `lib/dmc.dart` | yes | dmc change (patch only) |
| A | `lib/src/agent_hooks.dart` | no | dmc change (patch only) |
| A | `lib/src/checkpoint_export.dart` | no | dmc change (patch only) |
| M | `lib/src/checkpoint_models.dart` | yes | dmc change (patch only) |
| M | `lib/src/checkpoint_plan.dart` | yes | dmc change (patch only) |
| M | `lib/src/checkpoint_repository.dart` | yes | dmc change (patch only) |
| M | `lib/src/checkpoint_restore_service.dart` | yes | dmc change (patch only) |
| M | `lib/src/checkpoint_service.dart` | yes | dmc change (patch only) |
| M | `lib/src/cli.dart` | yes | dmc change (patch only) |
| M | `lib/src/database.dart` | yes | dmc change (patch only) |
| M | `lib/src/doctor.dart` | yes | dmc change (patch only) |
| A | `lib/src/git_ignore.dart` | no | dmc change (patch only) |
| A | `lib/src/git_worktree.dart` | no | dmc change (patch only) |
| A | `lib/src/hook_installer.dart` | no | dmc change (patch only) |
| M | `lib/src/ignore.dart` | yes | dmc change (patch only) |
| M | `lib/src/snap.dart` | yes | dmc change (patch only) |
| M | `lib/src/status.dart` | yes | dmc change (patch only) |
| M | `lib/src/watcher.dart` | yes | dmc change (patch only) |
| M | `lib/src/workspace_scan.dart` | yes | dmc change (patch only) |
| A | `test/agent_hooks_test.dart` | no | dmc change (patch only) |
| A | `test/checkpoint_export_test.dart` | no | dmc change (patch only) |
| M | `test/checkpoint_test.dart` | yes | dmc change (patch only) |
| A | `test/fixtures/agent_hooks/README.md` | no | dmc change (patch only) |
| A | `test/fixtures/agent_hooks/claude_code/session_end.json` | no | dmc change (patch only) |
| A | `test/fixtures/agent_hooks/claude_code/session_start.json` | no | dmc change (patch only) |
| A | `test/fixtures/agent_hooks/claude_code/stop.json` | no | dmc change (patch only) |
| A | `test/fixtures/agent_hooks/claude_code/stop_failure.json` | no | dmc change (patch only) |
| A | `test/fixtures/agent_hooks/claude_code/user_prompt_submit.json` | no | dmc change (patch only) |
| A | `test/fixtures/agent_hooks/muse_code/interrupt.json` | no | dmc change (patch only) |
| A | `test/fixtures/agent_hooks/muse_code/session_end.json` | no | dmc change (patch only) |
| A | `test/fixtures/agent_hooks/muse_code/session_start.json` | no | dmc change (patch only) |
| A | `test/fixtures/agent_hooks/muse_code/stop.json` | no | dmc change (patch only) |
| A | `test/fixtures/agent_hooks/muse_code/stop_failure.json` | no | dmc change (patch only) |
| A | `test/fixtures/agent_hooks/muse_code/user_prompt_submit.json` | no | dmc change (patch only) |
| A | `test/git_ignore_test.dart` | no | dmc change (patch only) |
| A | `test/hook_installer_test.dart` | no | dmc change (patch only) |
| M | `test/migration_test.dart` | yes | dmc change (patch only) |
| A | `test/policy_drift_test.dart` | no | dmc change (patch only) |
| M | `test/watcher_hardening_test.dart` | yes | dmc change (patch only) |
| A | `test/worktree_test.dart` | no | dmc change (patch only) |
| M | `website/src/content/docs/docs/dmc/checkpoints.md` | yes | dmc change (patch only) |
| M | `website/src/content/docs/docs/dmc/getting-started.md` | yes | dmc change (patch only) |

103 paths: 53 event work, 50 dmc changes. (`A` added, `M` modified.)
