# AGENTS.md

Guide for coding agents (Claude Code, Muse Code, others) working in this repository. Read it,
[STATUS.md](STATUS.md) and [HACKATHON.md](HACKATHON.md) before changing anything.

## Session status (STATUS.md)

[STATUS.md](STATUS.md) is the running record of the build. Every agent keeps it current:

- **At the start of a session**, read it before doing anything else.
- **During a session**, update it whenever a task finishes, something breaks or gets fixed, or the
  plan changes.
- **At the end of every session**, update it before you stop, even if nothing worked.

Keep its four sections accurate, and say how each item was verified:

- **Done:** verified work (tests, analyzer, real runs).
- **In progress:** with enough detail to pick it up.
- **Broken:** with the exact command or symptom.
- **Next:** in order.

Update `Last updated` and add one line to the session log, newest first. Never mark something
done that was not verified, and never drop a Broken item without saying how it was fixed. Commit
STATUS.md with the work it describes.

## Layout

| Path | What | Notes |
|---|---|---|
| `doc/` | Doc, the Dart package `dmc_doc` (executable `doc`) | Every model call lives here. Its own pubspec, analyzer and tests |
| `dmc-patches/` | The event's changes to dmc, a `git format-patch` series against dmc `d177c4bf73901cfac0a4ba7ef068cf24b95a2cb0` | Exact bytes matter (`.gitattributes` marks them `-text`) |
| `PATCHES.md` | What each patch does and which feature it serves | Update it with the patches |
| `tool/setup_dmc.dart` | Clones github.com/EvilMetaMonkey/dmc into `.deps/dmc` at that SHA, applies the patches with `git am`, builds the bundle | Idempotent; refuses to discard unexported work unless `--force` |
| `tool/export_patches.dart` | Regenerates `dmc-patches/` from `.deps/dmc` commits after the SHA | |
| `.deps/dmc` | dmc, set up by the tool | Gitignored. Never commit it, and never push to the dmc repository |
| `deploy/modal/` | Muse Glimmer on Modal | The endpoint URL is never committed |
| `docs/AGENT-HOOKS.md` | Verified agent-hook facts | |

**This repository must contain event work only.** Never copy dmc's code, files or history into it.
dmc changes travel as patches.

## Changing dmc (the engine)

1. Run `dart run tool/setup_dmc.dart`.
2. Make the change in `.deps/dmc` and commit it there, one logical commit per change. dmc's rules
   apply: it is deterministic and never runs a model, all logic lives in `lib/src/`, and paths use
   the `path` package (Windows matters). Restores stay preview-first and journaled, and the Haven
   machine contract (schema 1) stays compatible. Add tests for every behaviour change.
3. Run dmc's gates in `.deps/dmc`:
   - `dart run tool/check_analyzer.dart`
   - `dart test --concurrency=1`
   - `dart test tool/haven_contract_test.dart --concurrency=1`
4. Run `dart run tool/export_patches.dart`, update PATCHES.md, and re-run
   `dart run tool/setup_dmc.dart` to check the series applies from scratch.
5. Commit `dmc-patches/` and PATCHES.md here.

## Doc's rules

- **Doc talks to dmc only by running the dmc executable** with `--json --schema-version 1`.
  - It finds dmc via `--dmc`, then `DMC_BIN`, then `PATH`, checks it with `capabilities`, and
    skips Apple's `/usr/bin/dmc`.
  - It never reads `.dmc/`, imports dmc's Dart code, or writes workspace files.
  - It writes only `config.json` and `usage.json` in its config directory, plus lessons and
    timeline runs in its data directory.
- **Providers and roles:**
  - Providers: `meta` (Muse Spark 1.3, Muse Wonder, Muse Voice Transcribe), `baseten` (Muse Spark
    Open), `fireworks` (backup), `modal` (Muse Glimmer; URL from the config or
    `DOC_MODAL_BASE_URL`) and `local`.
  - Roles: `summary` modal → baseten, `workhorse` baseten → fireworks, `restore` meta → baseten,
    `planner` and `judge` on Wonder.
  - Every fallback is logged and there is no second hop. A fallback whose key is missing or
    rejected is reported and skipped.
  - Keys come only from env vars (`MODEL_API_KEY`, `BASETEN_API_KEY`, `FIREWORKS_API_KEY`,
    `MODAL_GLIMMER_KEY`), and are never printed or logged.
  - `--local` means this machine only.
- **Redact before any hosted call.** Structured answers (`response_format` JSON schema) are parsed
  strictly and validated by pure functions before anything acts on them.
- **Ask before acting.** Every file change goes through dmc's preview and `--apply`, and nothing is
  forced. `--yes` is for scripted demos and never answers low-confidence choices,
  natural-language restore picks, or voice-routed restore and bisect. Timelines work only in
  worktrees outside the repository; `pick` prints git commands and runs none; `clean` never
  deletes branches.
- **Never print env var values**, the Modal URL or the Modal workspace name.

## Gates (all must pass; CI runs them on ubuntu, windows, macos-latest and macos-15-intel)

```sh
dart run tool/setup_dmc.dart
cd .deps/dmc && dart run tool/check_analyzer.dart && dart test --concurrency=1 \
  && dart test tool/haven_contract_test.dart --concurrency=1 && cd ../..
cd doc && dart pub get --enforce-lockfile && dart analyze --fatal-infos \
  && DMC_TEST_BIN=../.deps/dmc/build/dmc/bundle/bin/dmc dart test --concurrency=1
```

On Windows the bundle is `.deps\dmc\build\dmc\bundle\bin\dmc.exe`.

## Working rules

- Prefer small, additive changes, with tests for every behaviour change.
- Commit in logical commits, and never push to `main` without review.
- Use Doc's fake providers in tests: no test makes a real model call.
- Real checks on Mike's Mac use `/tmp` repos and are cleaned up afterwards, including agent hooks
  (Muse's `settings.json` back to the same SHA-256).
