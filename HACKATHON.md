# Meta AI Developer Hackathon 2026: Doc

This repository is Mike Hood's ([@EvilMetaMonkey](https://github.com/EvilMetaMonkey)) entry in the
**Meta AI Developer Hackathon (October–November 2026), indie developer track**. Theme: **Push the
Frontier**.

## What is pre-existing, and where it lives

**dmc** is Mike's pre-existing open-source project: <https://github.com/EvilMetaMonkey/dmc>. It
records AI coding-agent changes in a project-local vault and restores them through a
preview-first, journaled restore. The hackathon proposal said the entry would build on dmc, and
the proposal was accepted.

**None of dmc's code or history is in this repository.** Doc uses dmc as a service. It runs the
dmc executable and reads its versioned JSON (machine schema 1). `tool/setup_dmc.dart` clones dmc
from its own repository at the pinned pre-event commit below, applies this event's patches, and
builds it.

| | |
|---|---|
| dmc repository | <https://github.com/EvilMetaMonkey/dmc> |
| Pre-event commit (pinned by SHA) | `d177c4bf73901cfac0a4ba7ef068cf24b95a2cb0` |
| Its date | 2026-10-25 19:00 UTC |
| dmc version there | `1.1.0-dev.5.1` |
| Hackathon kickoff | 2026-10-26 |

At that commit dmc already had:

- recording of eligible file versions into a project's `.dmc/` folder;
- `checkpoint begin`/`close` interval checkpoints;
- preview-first, journaled restore and redo with conflict checks, and recovery from interrupted
  operations;
- the Haven machine contract, status, doctor, gc;
- the CLI, terminal UI, install scripts and project website.

## What was built during the event

Everything in this repository, written from 2026-10-26 on. Its history is the event's history:
every commit is dated 2026-10-26 or later.

- **Doc** ([`doc/`](doc/)), the companion that runs every model call:
  - `doc bisect`, time-travel bisect over agent-turn checkpoints;
  - `doc timelines`, parallel Muse Code timelines in Git worktrees, planned and judged by Muse
    Wonder, starting from the turn bisect found (`--from-bisect`);
  - `doc restore`, rollback without amnesia, with lesson drafts;
  - natural-language restore;
  - the lesson library and `doc start`;
  - `doc talk`, "Hey Doc" push-to-talk with Muse Voice Transcribe;
  - `doc summarize`;
  - `doc doctor`, which checks the whole setup and gives each problem's fix;
  - one model client with role routing, logged fallbacks, budgets and secret redaction.
- **The Muse Glimmer deployment** on Modal ([`deploy/modal/`](deploy/modal/)).
- **Verified agent-hook research** ([`docs/AGENT-HOOKS.md`](docs/AGENT-HOOKS.md)).
- **The demo** ([`demo/`](demo/)): a script that builds the demo repository and the video runbook.
- **The event's changes to dmc**, as 35 patches in [`dmc-patches/`](dmc-patches/), described one
  by one in [PATCHES.md](PATCHES.md):
  - agent-turn checkpoints from Muse Code and Claude Code hooks (`dmc agent-hook`, `dmc hooks`,
    schema 4);
  - Git-compatible ignore handling;
  - per-file ignore-policy drift (schema 5);
  - `dmc checkpoint export`;
  - the worktree rule;
  - `dmc disable` and `dmc doctor`'s agent-hook checks;
  - test fixes and docs.

  dmc stays deterministic: it runs no model.

## History of this repository

The event was first developed in `EvilMetaMonkey/dmc-meta-hackathon`, which also held dmc's
pre-event code and history. To keep the entry to event work only, on 2026-10-31 that repository's
history was filtered down to the event-only paths:

- `doc/`, `deploy/`, `docs/AGENT-HOOKS.md`, `HACKATHON.md` and `STATUS.md`;
- with the original author and commit dates;
- with no commit from before the event;
- with the Modal workspace name scrubbed.

Its dmc changes became the patch series. The new top-level files (this one, README, AGENTS,
CLAUDE, LICENSE, CHANGELOG, PATCHES, CI and the two tools) were written fresh for this repository.

## Meta models

| Model | Where | Job |
|---|---|---|
| Muse Code | local CLI | The agent in each parallel timeline (`muse exec` headless, one per Git worktree), and a demo agent |
| Muse Spark 1.3 (`muse-spark-1.3`) | Meta Model API (Baseten Muse Spark Open as the logged fallback) | Natural-language restore: picks a checkpoint and a mode as JSON; Doc validates it, dmc previews and applies |
| Muse Spark Open (`meta-models/muse-spark-open-1026`) | Baseten, with Fireworks as the logged backup | Lesson drafts, bisect explanations, voice routing; fallback for summaries, briefs and restore |
| Muse Wonder (`muse-wonder-1.0`) | Meta Model API | Plans the timelines and judges their diffs and test results, both as validated JSON; the judgment is advice, the user picks (live since 2026-10-31) |
| Muse Glimmer 30B (`meta-models/Muse-Glimmer-30B`) | A private deployment on Modal (vLLM 0.28.0, one L40S, FP8) | Per-checkpoint summaries and lesson briefs |
| Muse Voice Transcribe (`muse-voice-transcribe-1.0`) | Meta Model API, realtime WebSocket | "Hey Doc" push-to-talk |

Model IDs, prices and verified provider behaviour are in [doc/README.md](doc/README.md). The
running build record is [STATUS.md](STATUS.md).

## Design rules

- **Awareness over agency.** Doc suggests; the user decides. Nothing is restored, run, forked into
  timelines or sent to a model without the user asking, and nothing is merged automatically.
- **The AI never touches your files directly.** Every file change goes through dmc's journaled
  restore; timelines work in separate worktrees.
- **Secrets are redacted** before anything is sent to a hosted model.
- **Local-first.** History stays on the user's machine; `--local` keeps model work there too.

## License

MIT. See [LICENSE](LICENSE).
