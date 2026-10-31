# Changelog

Event work only (Meta AI Developer Hackathon 2026, from 2026-10-26). Changes to dmc are listed
by patch in [PATCHES.md](PATCHES.md).

## 2026-10-31: Wonder judges the timelines; demo wiring

- Muse Wonder (`judge` role) ranks the finished timelines as validated JSON:
  - it gets each timeline's approach, redacted diff, test result and steps;
  - it cannot recommend a timeline whose tests failed (Doc refuses and retries, then shows the
    ranking with no recommendation);
  - empty timelines are ranked last;
  - the advice shows under the comparison and is saved in the run.

  `doc timelines judge <run-id>`; `--no-judge`.
- `doc bisect` saves its last result per workspace. `doc timelines --from-bisect` starts from the
  first bad turn's after-state, with bisect's test command.
- `doc talk` routes "try three different fixes for the failing test" to `doc timelines …
  --from-bisect`, and always asks before running it.
- `doc timelines` estimates with the agents' real model (`--agent-model`, else Muse Code's
  configured default) instead of assuming Contributor-mode Spark.
- `doc timelines pick` writes the patch to Doc's run folder and prints `git apply`, which applies
  onto a working copy with uncommitted changes (`git apply --3way` refused those).
- `demo/make_demo_repo.dart` and `demo/RUNBOOK.md`, run end to end with real agents and models.

## 2026-10-31: event-only repository

- The entry moved to this repository. Its history is the event's history, filtered to Doc,
  `deploy/`, the agent-hook research, HACKATHON.md and STATUS.md, with original dates and no
  pre-event commit.
- dmc is no longer part of the repository. `tool/setup_dmc.dart` clones
  github.com/EvilMetaMonkey/dmc at the pinned pre-event commit `d177c4b`, applies the 31 patches
  in `dmc-patches/` with `git am` and builds the bundle. `tool/export_patches.dart` regenerates
  the series.
- New README, HACKATHON.md, AGENTS.md, CLAUDE.md, LICENSE, PATCHES.md and CI (setup, dmc gates
  in `.deps/dmc`, Doc gates) on ubuntu, windows, macos-latest and macos-15-intel.
- Doc's tests fall back to building `.deps/dmc` when `DMC_TEST_BIN` is not set.

## Parallel timelines, part 1 (2026-10-28)

- `doc timelines "<task>" --test "<command>"`:
  - the base is a dmc export (`--from <cp> --state before|after`);
  - Muse Wonder plans exactly N different approaches as validated JSON;
  - after one confirmation with a cost estimate, N `muse exec` agents work in parallel, each in a
    Git worktree outside the repository with its own dmc vault;
  - each result is committed on `doc/timeline/<run>/<k>` and tested, and the results are compared
    side by side.
- `doc timelines pick | list | show | clean`: pick prints the diff and the git commands and runs
  nothing; clean keeps branches.

## "Hey Doc" push-to-talk (2026-10-28)

- `doc talk` (alias `doc hey`), using Muse Voice Transcribe over Meta's realtime WebSocket:
  - push to talk with Space or Enter;
  - `--file` for recordings;
  - recent file names sent as recognition keywords.
- The redacted transcript is routed by the workhorse role to one validated Doc command, which runs
  only after "Run it?". `doc status` lists the latest checkpoints.
- Lesson drafts no longer invent why work was undone: without a note, "Why it failed" says "Not
  stated" and approval waits for an edit.

## Muse Glimmer on Modal and natural-language restore (2026-10-28)

- Muse Glimmer 30B deployed on Modal (one L40S, FP8; cold start about 94 s, warm about 2 s) and
  used for summaries and briefs, with a logged Baseten fallback. Request bodies carry a
  Content-Length (Modal's proxy rejected chunked bodies).
- `doc restore "<request>"`:
  - the restore role picks a checkpoint and a mode as JSON, which Doc validates;
  - low confidence always goes to the user;
  - every step is previewed with dmc and combined into one plan with line counts;
  - one confirmation, then the steps apply newest first, and a failure offers dmc redo.
- An unavailable fallback (missing or rejected key) is reported and skipped.

## Time-travel bisect (2026-10-28)

- `doc bisect --test "<command>"` finds the first agent turn after which the tests fail:
  - it tests `dmc checkpoint export` states in temporary folders, never the working copy;
  - `--setup`, `--link`, timeouts and `--json` are supported;
  - an explanation follows, and a restore is offered.

## Rollback without amnesia and the lesson library (2026-10-27 to 2026-10-28)

- `doc restore <checkpoint>` previews dmc's restore, applies it after a yes, and offers to draft a
  lesson from the undone work. `doc lesson draft --last-restore` drafts from the latest restore.
- The lesson library:
  - markdown lessons in Doc's data dir;
  - `doc lesson draft|edit|approve|reject|show|brief`;
  - `doc lessons`;
  - `doc start <agent> "<task>"`, which offers a brief from matching lessons as the agent's
    first prompt.

## Doc's foundation (2026-10-27)

- Doc, a separate Dart package that talks to dmc only through its versioned JSON:
  - one OpenAI-compatible client for Meta, Baseten, Fireworks, Modal and a local server, with
    retries, timeouts, budgets, usage and logged fallbacks;
  - secret redaction;
  - `doc models [--check] [--available]`, `doc summarize`, `doc usage`.

## Engine work in dmc (2026-10-26 to 2026-10-27, as patches)

- Agent-turn checkpoints from Muse Code and Claude Code hooks (`dmc agent-hook`, `dmc hooks`,
  schema 4).
- Git-compatible ignore handling.
- Per-file ignore-policy drift (schema 5).
- `dmc checkpoint export`.
- The worktree rule for agent hooks.

Details in PATCHES.md and [docs/AGENT-HOOKS.md](docs/AGENT-HOOKS.md).
