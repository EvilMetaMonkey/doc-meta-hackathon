# Demo runbook (3-minute video)

The whole find → fix → remember loop on a small Python shop, with real agents and real models.
Every command and prompt below was run end to end on Mike's Mac on 2026-10-31. Timings are from
that run (see "Measured" at the end).

**Opening line (say it, and show the README):**

> "dmc is my pre-existing open-source rollback tool for AI coding agents. It's on GitHub as
> EvilMetaMonkey/dmc, and this repo sets it up with one command. Everything you'll see on top
> of it, Doc and its Muse-powered bisect, parallel timelines, judging, restore, lessons and voice,
> was built during the hackathon."

## Before recording (about 5 minutes, off camera)

```sh
cd ~/Projects/doc-meta-hackathon
dart run tool/setup_dmc.dart                          # dmc in .deps/dmc (patched, built)
dart compile exe doc/bin/doc.dart -o build/doc         # a fast doc binary (build/ is gitignored)
export DMC_BIN="$PWD/.deps/dmc/build/dmc/bundle/bin/dmc"
alias doc="$PWD/build/doc"

dart run demo/make_demo_repo.dart /tmp/doc-demo        # asks before installing both agents' hooks
cd /tmp/doc-demo
python3 -m unittest -q                                 # 6 tests, OK
doc doctor                                             # every line should be "ok" (each problem shows its fix)
```

`doc doctor` checks:

- dmc and the demo workspace;
- both agents' hooks;
- each key (never its value) and its roles;
- the Modal endpoint;
- the microphone tool;
- Muse Code's model, with the estimated cost of a timelines run.

It makes no model calls.

- Keys: `MODEL_API_KEY` (Meta: Muse Spark, Wonder, Voice), `BASETEN_API_KEY`, and
  `MODAL_GLIMMER_KEY` with `DOC_MODAL_BASE_URL`, all in `~/.zshrc`. Never show them on screen.
- **The agents' model for the video is Muse Code's configured default:** `muse-wonder-1.0` with
  high reasoning (Mike's choice). It costs about $0.80 per timelines run. Doc's estimate and
  question name it ("Run 3 Muse Code agents (muse-wonder-1.0) …").
  - For rehearsals, add `--agent-model muse-spark-1.3-contributor`, about $0.01 per run. Those
    agents are weaker: in one rehearsal one of them hit a Meta `server_error`.
- Muse Code workspace trust is not needed: the hooks are user scope, and `muse exec` edits files
  with its default approval and sandbox.
- **Warm Glimmer about 2 minutes before you start recording:** `doc doctor --check`.
  - It sends one tiny prompt to each provider and says "if Glimmer is cold, the first call takes
    about 2 minutes". A cold start took 91–113 s.
  - Glimmer scales to zero after 5 idle minutes, so warm it again if the lesson step is more than
    5 minutes later.
- **Check the live microphone** (verified working on Mike's Mac on 2026-11-02):
  1. Run `doc talk`. The first time, macOS asks to allow the microphone for the terminal app:
     allow it.
  2. Press Space, say "What's the status?", and press Space again.
  3. Check that the partial transcript updates live, then that Doc shows "I heard … → I'll run:
     doc status. Run it? [y/N]". Answer `y`.
  4. Run `doc talk` again, press Space, and press Esc mid-recording. It should say "Cancelled.
     Nothing more was sent.", and the terminal should still echo what you type afterwards.

## The scripted agent turns (record or pre-run, about 90 s)

Run them in `/tmp/doc-demo`, in this order. Turn 2 introduces the bug (it changes the discount
contract, and the callers and tests still pass percents). For a 3-minute video, pre-run them and
show `doc status`, or speed this part up.

```sh
# 1. Claude Code (about 19 s)
claude -p "Add a function format_price(amount) to money.py that returns the amount as a string with a dollar sign, thousands separators and two decimals, for example \$1,234.50. Only edit money.py." --allowedTools "Read" "Edit(money.py)"

# 2. Muse Code: the bug (about 36 s)
muse exec "In money.py, change apply_discount to take the discount as a fraction between 0 and 1 (0.25 for 25%) instead of a percent from 0 to 100. Only edit money.py." --disable-shell --disable-web-tools

# 3. Claude Code (about 15 s)
claude -p "Add a short docstring to cart_subtotal and checkout_total in checkout.py. Only edit checkout.py." --allowedTools "Read" "Edit(checkout.py)"

# 4. Muse Code (about 17 s)
muse exec "In README.md, add a short Usage section with one example call of checkout_total. Only edit README.md." --disable-shell --disable-web-tools

python3 -m unittest -q        # FAILED (errors=2): ValueError: discount must be between 0 and 1
doc status                    # four checkpoints, both agents
```

## On camera

| # | Step | Command | Time |
|---|---|---|---|
| 1 | **Find it** | `doc bisect --test "python3 -m unittest -q"`, then **n** at "Undo this muse turn? money.py: put back the version from before it  [y/N]" | about 2 s |
| 2 | **Fix it** | `doc timelines "fix the failing tests without changing the tests" --from-bisect --max-steps 10`, then **y** | about 70 s (3 agents in parallel, then judging) |
| 3 | Wonder's advice | (printed by step 2, under the comparison) | none |
| 4 | Pick | `doc timelines pick <run-id> <k>` (Wonder's pick, or yours) | under 1 s |
| 5 | Apply | the two `git apply` lines `pick` printed (`--check`, then apply) | under 1 s |
| 6 | Tests pass | `python3 -m unittest -v` | under 1 s |
| 7 | **Remember it** | `doc lesson draft <first bad cp> --note "checkout.py and the tests still pass percents like 10 and 25, so every discount raised ValueError"`, then `doc lesson approve <id>` | about 2 s |
| 8 | The brief | `doc start muse-code "Add a bulk_discount(amount, quantity) function to money.py that takes 5 percent off orders of 10 or more items"` (answer **y**) | about 15 s (Glimmer warm) |

What to point at:

- **Step 1** names the Muse turn as the first bad turn, with the failing output and Muse Spark's
  explanation. It probes exported states only; the working copy is never touched.
- **Step 2** first says: "Base from the last doc bisect … Using its after-state, where the tests
  fail". The before-state already passes, so there is nothing to fix there. It then shows:
  - Muse Wonder's three approaches;
  - the cost estimate and one question;
  - three worktrees outside the repo, three agents in parallel, each with tests;
  - "Asking Muse Wonder to judge the timelines…", then the side-by-side comparison, where each
    timeline has a "**did (per Wonder):** …" line;
  - "**Wonder recommends timeline k: …**" and the ranking. Each entry shows "**Planned:** <the
    approach> / **Did:** <what the diff really does>", with the rationale and risks. A timeline
    whose diff did something else is flagged "**DIDN'T FOLLOW ITS PLAN**"; Wonder judges this
    and Doc never changes the scores. Then "Advice only: nothing was applied."
  - Point at this: an agent can solve the task another way than its approach. In a real run,
    "Migrate checkout callers" actually changed `apply_discount` instead, and Planned / Did
    makes that visible.
- **Step 4** shows the diff and writes the patch to Doc's data dir. **Doc runs nothing in the
  repository**; the other timelines stay as branches.
- **Step 5:** `doc restore` is **not** needed here, because no later turn touched `money.py`, so
  the patch applies on top of turns 3 and 4 and keeps them. If `git apply --check` fails (a later
  turn changed the same lines), first run `doc restore <first bad cp>`: it previews, asks, and
  restores through dmc. Then apply.
- **Step 8:** `doc start` shows the brief built from the approved lesson ("Before you start: … keep
  the percent-based interface …") and asks before adding it to Muse Code's first prompt. Muse
  Code's TUI then opens with the brief, a blank line and the task. It needs a real terminal.

## On camera, in the TUI (`doc ui`)

The same loop in one full-screen window, end to end. Make the terminal **120×36** (the frames
in the PR were captured at that size; below 80×24 Doc asks for a bigger window). Pre-run the four
agent turns above, and warm Glimmer (`doc doctor --check`) about 2 minutes before recording.

**Opening shot: raw dmc beside Doc.** Split the terminal in two panes in `/tmp/doc-demo`, and
use the Muse turn that changed `apply_discount` (the third line of `"$DMC_BIN" checkpoint list`):

```sh
"$DMC_BIN" checkpoint show <muse cp>     # left: ids, status, counts, hashes: what dmc records
doc summarize <muse cp>                  # right: "Title: …" and two plain sentences
```

Say: "dmc records everything; Doc tells you what it means." Then close the left pane and run
`doc ui` (or plain `doc`). The splash shows the car for about a second; any key skips it.

| # | Step | Keys | What shows |
|---|---|---|---|
| 1 | The turns | ↑↓ | Four turns, newest first, each by a short title once Glimmer has summarized it ("summarizing…" first; titles are cached). The detail pane: who and when, the title, two sentences, the files with +/− and the diff from the first change. |
| 2 | **Find it** | **b**, type `python3 -m unittest -q` (prefilled once a bisect has run), Enter, Enter (setup) | The strip fills in PASS / FAIL per probe, then "Turn 2 broke the tests: …", the file, the failing test's name and error line, and Muse Spark's explanation. The turn gets a red ✗. |
| 3 | The offer | **n** | One line: "Undo this muse turn? money.py: put back the version from before it  [y/N]". For the video, fix it instead. |
| 4 | **Fix it** | **t**, Enter ×3, then the model, Enter | The task is prefilled ("Fix the tests broken by: <title>"), then the test, the setup and the agent model with its estimate (Enter keeps Muse Code's configured `muse-wonder-1.0`; for rehearsals type `muse-spark-1.3-contributor`). |
| 5 | The cost | **y** | One line: "Run 3 Muse Code agents (<model>) in separate worktrees (… est. cost ≤ $…)? [y/N]". The plan and the estimate's working are under `d`. |
| 6 | Three lanes | (watch) | One lane per approach: steps and a live clock, running / done / stalled (with why) / timed out, then tests PASS or FAIL. A lesson, if one matched, shows once above the lanes ("Using lesson: …"). A failing test is named once. |
| 7 | Wonder's advice | (watch) | "Asking Muse Wonder to judge…", then in the same lanes: the score, "Planned: … / Did: …", "didn't follow its plan" in yellow, and ★ recommended. Point at Planned / Did. |
| 8 | Pick | ↑↓ to the ★ lane, **p** | The diff, coloured and scrollable, and the `git apply` commands. Nothing is applied; Esc closes it. |
| 9 | **Remember it** | Esc, ↑↓ to the ✗ turn, **r**, **y**, **y**, the note, Enter | The one-line restore question, the restore through dmc, the lesson offer and "What went wrong?" (say: "checkout.py and the tests still pass percents like 10 and 25, so every discount raised ValueError"). The turn shows ↺ undone, and the tests pass again. |
| 10 | Approve | **l**, **y** on the draft | The lessons pane; a draft that still says "Not stated" is refused with the exact fix. |
| 11 | The brief | **a**, Enter (muse-code), the task, Enter (files) | The brief, "From: <lesson title>", then "Add this to the agent's first prompt? [y/N]"; **y** opens Muse Code with it. When it exits, the TUI comes back. |
| 12 | **Hey Doc** | **Space**, say "What's the status?", **Space** | The bar shows the live transcript, then "I heard … → I'll run: doc status. Run it? [y/N]"; **y**. |

Step 8 or step 9 fixes the code, not both: the restore puts `money.py` back, so the picked patch
would no longer apply. To ship the timeline's fix instead, run the two `git apply` lines from
`p` in a second pane, skip `r`, and draft the lesson from the command bar (`:` then `lesson
draft <muse cp> --note "…"`).

After timelines, `c` in the lanes pane removes the run's worktree folders (it asks first; the
branches stay).

`d` shows details (the full diff, ids, times, the model, tokens and cost; in the lanes, worktrees
and branches too), `o` the raw log of that action (in the lanes, the agent's own log), `?` every
key, and `:` runs any `doc …` command (or a read-only `dmc …` one) into a result pane. `q` quits;
Ctrl-C also quits and always gives the terminal back.

### "Hey Doc" variants (push to talk)

Use `doc talk`. Press Space or Enter, speak, then press Space or Enter again. Doc always says what
it heard and asks "Run it?". `--yes` never answers that for restore, bisect or timelines.

| Instead of | Say | Doc runs (after "Run it? y") |
|---|---|---|
| Step 2 | "Try three different fixes for the failing tests." | `doc timelines "try three different fixes for the failing tests" --from-bisect` (plus `--test` from the workspace's `bisectTest` config if set, otherwise bisect's own test) |
| A restore (before step 5) | "Take me back to before the discount change." | `doc restore "take me back to before the discount change."`: natural-language restore picks the Muse turn (0.95 in the real run), shows the 3-step plan, and asks before applying |

Voice notes:

- Say the restore variant **before** applying the patch. In the real run it was said afterwards,
  and dmc correctly refused (`money.py: workspace_drift`) and changed nothing.
- Speak clearly; "auth"-like short words can be misheard. Doc shows the transcript before
  anything runs.
- The first microphone use makes macOS ask for microphone permission for the terminal app.
- With no microphone or SoX/ffmpeg, `doc talk --file <recording.wav>` streams a recording
  instead.

## If something goes wrong on camera (30 seconds)

- **Glimmer is cold** (the brief or a summary hangs, and "Waking Muse Glimmer on Modal…" shows).
  Wait: it answers in about 90 seconds. If it fails, Doc prints `FALLBACK: role "summary" failed
  on modal … Using the configured fallback baseten`, and Muse Spark Open writes the brief.
  - Say: "Glimmer runs on my own GPU that scales to zero; when it's cold, Doc falls back to Muse
    Spark and says so."
- **An agent hits its step limit or fails.** Its block says "step limit" (or the agent error) and
  its tests run anyway. Wonder ranks it, flags it if it changed nothing, and can't recommend it if
  its tests failed. Pick another timeline.
  - If none passed: `doc timelines judge <run-id>` re-judges a saved run, or re-run with
    `--max-steps 15`.
- **dmc reports a conflict** (`workspace_drift` in a restore preview). A file changed after that
  turn. Doc changed nothing and says so; that is the safety net working.
  - Say: "dmc won't overwrite work it didn't record."
  - Then `git apply` the picked patch instead, or undo the later edit and run the restore again.
- **A hook isn't firing** (no new checkpoint after a turn): run `doc doctor`. It names the problem
  (for example a hook pointing at another dmc build) and the fix.

## Afterwards

```sh
cd /tmp/doc-demo
"$DMC_BIN" disable --apply        # removes only dmc's hooks (both agents) and stops the watcher; history stays
doc timelines clean <run-id>      # worktree folders; branches stay in /tmp/doc-demo
rm -rf /tmp/doc-demo
```

`dmc disable` (without `--apply`) previews exactly which hook entries it would remove. Muse
Code's `~/.config/muse/settings.json` goes back to its exact bytes.

## Measured (2026-10-31, Mike's Mac)

| Step | Wall time | Cost |
|---|---|---|
| `make_demo_repo.dart` | about 1 s | none |
| `doc doctor` | under 1 s | none |
| `doc doctor --check` (Glimmer cold) | 96 s (Glimmer 91 s) | Meta/Baseten/Fireworks about $0.002 plus Modal GPU time |
| `doc models --check` (Glimmer cold; the older warm-up) | 121 s (Glimmer 113 s) | the same |
| 4 agent turns | 19 + 36 + 15 + 17 s | Claude Code subscription; Muse Code on its own account |
| `doc bisect` (4 probes and the explanation) | 2 s | Baseten $0.0028 |
| `doc timelines --from-bisect` (3 agents on `muse-wonder-1.0`, 7/7/10 steps, then judging) | 66 s (agents 48 s) | Muse Code $0.81, Wonder planner $0.026, Wonder judge $0.026 |
| the same with `--agent-model muse-spark-1.3-contributor` (rehearsal, 6/8/3 steps; one agent hit a `server_error`) | 66 s (agents 51 s) | Muse Code $0.012, Wonder planner $0.023, Wonder judge $0.024 |
| `doc ui` timelines (`t`, 2026-11-02, `muse-spark-1.3-contributor`, 7/8/5 steps, all three PASS) | agents 43 / 81 / 61 s, then judging | Muse Code $0.0037 + $0.0066 + lane 3, Wonder planner $0.030, judge $0.025 |
| `doc timelines pick` | under 1 s | none |
| `git apply`, `python3 -m unittest -v` | under 1 s | none |
| `doc lesson draft` | 2 s | Baseten $0.0029 |
| `doc lesson approve` | under 1 s | none |
| brief / `doc start` (Glimmer warm) | 13–15 s | Modal GPU time |
| `doc talk --file` (either variant) | about 9 s | Voice $0.0001; routing on Baseten about $0.002; NL restore on Meta $0.0037 |
