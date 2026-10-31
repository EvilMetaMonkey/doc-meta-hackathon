# Doc: a recovery loop for AI coding agents

**Meta AI Developer Hackathon 2026 entry, by Mike Hood ([@EvilMetaMonkey](https://github.com/EvilMetaMonkey)).**
Everything in this repository was written during the event (from 2026-10-26).

**Pre-existing work:** Doc drives [dmc](https://github.com/EvilMetaMonkey/dmc), Mike's
pre-existing open-source rollback tool for AI coding agents. dmc is not part of this repository.
It is used as a service Doc calls, set up from its own repository at a pinned pre-event commit,
plus this event's patches in [`dmc-patches/`](dmc-patches/) (see [PATCHES.md](PATCHES.md)).

## What Doc does

AI coding agents (Muse Code, Claude Code) change many files per turn, and sometimes they break
things. dmc records every agent turn as a checkpoint: what each file was before and after,
restorable through a preview-first, journaled restore. **Doc** is the companion that puts Meta's
Muse models on top of that record, as one loop:

1. **Find it.** `doc bisect --test "<command>"` runs your tests on exported checkpoint states
   (never your working copy) to find the turn where they started failing, and Muse Spark explains
   why.
2. **Fix it.** `doc timelines "<task>" --test "<command>"`: Muse Wonder plans three different
   approaches, three Muse Code agents try them in separate Git worktrees, and Doc runs the tests
   in each and compares them side by side. You pick one; the others stay as branches. Nothing is
   merged for you.
3. **Remember it.** `doc restore` undoes a turn through dmc, then drafts a lesson from the undone
   work. Approved lessons are offered to the next agent that touches the same files
   (`doc start`).

Also built in:

- natural-language restore: `doc restore "take me back to before it touched auth"`, always with
  dmc's preview and a confirmation;
- "Hey Doc" push-to-talk: `doc talk`, with Muse Voice Transcribe;
- plain-English checkpoint summaries: `doc summarize`.

The AI never touches your files directly. Every change goes through dmc, and Doc asks before
anything is restored, run or sent to a model. Secrets are redacted before any hosted call.

## Models

| Model | Where | Job |
|---|---|---|
| Muse Code | local CLI (`muse exec`) | The agent in each parallel timeline, and a demo agent |
| Muse Spark 1.3 (`muse-spark-1.3`) | Meta Model API | Natural-language restore |
| Muse Spark Open (`meta-models/muse-spark-open-1026`) | Baseten, with Fireworks as the backup | Lesson drafts, bisect explanations, voice routing; fallback for summaries and restore |
| Muse Wonder (`muse-wonder-1.0`) | Meta Model API | Plans the parallel timelines (judging comes next) |
| Muse Glimmer 30B (`meta-models/Muse-Glimmer-30B`) | A private deployment on Modal (vLLM, one L40S; [`deploy/modal/`](deploy/modal/)) | Checkpoint summaries and lesson briefs |
| Muse Voice Transcribe (`muse-voice-transcribe-1.0`) | Meta Model API, realtime WebSocket | "Hey Doc" push-to-talk |

Roles, prices, fallbacks and every verified provider detail are in [doc/README.md](doc/README.md).

## Setup

You need [Dart](https://dart.dev/get-dart) 3.11 and Git. Doc runs on macOS, Linux and Windows.

```sh
git clone https://github.com/EvilMetaMonkey/doc-meta-hackathon
cd doc-meta-hackathon

# 1. dmc: clone EvilMetaMonkey/dmc into .deps/dmc at the pinned commit, apply dmc-patches/ with
#    git am, and build the bundle. Prints the dmc path. Safe to re-run.
dart run tool/setup_dmc.dart

# 2. Point Doc at it (the setup prints the exact line for your shell).
export DMC_BIN="$PWD/.deps/dmc/build/dmc/bundle/bin/dmc"      # Windows: .deps\dmc\build\dmc\bundle\bin\dmc.exe

# 3. Doc.
cd doc
dart pub get --enforce-lockfile
dart run bin/doc.dart models          # roles, providers, and which keys are set
```

Keys come only from environment variables: `MODEL_API_KEY` (Meta), `BASETEN_API_KEY`, and
optionally `FIREWORKS_API_KEY`, `MODAL_GLIMMER_KEY` with `DOC_MODAL_BASE_URL` (see
[deploy/modal/README.md](deploy/modal/README.md)). Muse Code and Claude Code are installed
separately.

**To try it on a project:**

1. In the project's Git repository, run `dmc init`.
2. Install the agent hooks so each turn becomes a checkpoint:
   `dmc hooks install --agent muse-code --apply` (and/or `--agent claude-code`).
3. Use Doc from that folder, for example `dart run <this repo>/doc/bin/doc.dart bisect --test
   "python3 -m unittest"`.

**Tests**, the same gates CI runs:

```sh
dart run tool/setup_dmc.dart
cd .deps/dmc && dart run tool/check_analyzer.dart && dart test --concurrency=1 \
  && dart test tool/haven_contract_test.dart --concurrency=1 && cd ../..
cd doc && dart pub get --enforce-lockfile && dart analyze --fatal-infos \
  && DMC_TEST_BIN=../.deps/dmc/build/dmc/bundle/bin/dmc dart test --concurrency=1
```

## Layout

| Path | What it is |
|---|---|
| [`doc/`](doc/) | Doc, a Dart package (`dmc_doc`, executable `doc`): every model call, and all the commands above |
| [`dmc-patches/`](dmc-patches/), [`PATCHES.md`](PATCHES.md) | The event's changes to dmc, as a `git format-patch` series against dmc `d177c4b` |
| [`tool/setup_dmc.dart`](tool/setup_dmc.dart), [`tool/export_patches.dart`](tool/export_patches.dart) | Set up `.deps/dmc` from the patches; regenerate the patches after an engine change |
| [`deploy/modal/`](deploy/modal/) | The Muse Glimmer deployment on Modal |
| [`docs/AGENT-HOOKS.md`](docs/AGENT-HOOKS.md) | Verified Muse Code and Claude Code hook facts |
| [`HACKATHON.md`](HACKATHON.md), [`STATUS.md`](STATUS.md) | What is pre-existing and what was built during the event; the running build status |

## License

MIT. See [LICENSE](LICENSE). dmc is MIT-licensed in its own repository.
