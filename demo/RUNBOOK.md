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
```

- Keys: `MODEL_API_KEY` (Meta: Muse Spark, Wonder, Voice), `BASETEN_API_KEY`, and
  `MODAL_GLIMMER_KEY` with `DOC_MODAL_BASE_URL`, all in `~/.zshrc`. Never show them on screen.
- **Muse Code's model:** Mike's Muse Code defaults to `muse-wonder-1.0` with high reasoning
  (`~/.config/muse/settings.json`). With that, three timeline agents cost about $0.80. Add
  `--agent-model muse-spark-1.3-contributor` to `doc timelines` for a run of about $0.01. Doc's
  estimate names the model it will use.
- Muse Code workspace trust is not needed: the hooks are user scope, and `muse exec` edits files
  with its default approval and sandbox.
- **Warm Glimmer about 2 minutes before you start recording:** `doc models --check`. A cold start
  took 113 s. Glimmer scales to zero after 5 idle minutes, so warm it again if the lesson step is
  more than 5 minutes later.

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
| 1 | **Find it** | `doc bisect --test "python3 -m unittest -q"`, then **n** at "Restore to before this turn?" | about 2 s |
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
  - the side-by-side comparison;
  - "**Wonder recommends timeline k: …**" with the ranking, risks and "Advice only: nothing was
    applied."
- **Step 4** shows the diff and writes the patch to Doc's data dir. **Doc runs nothing in the
  repository**; the other timelines stay as branches.
- **Step 5:** `doc restore` is **not** needed here, because no later turn touched `money.py`, so
  the patch applies on top of turns 3 and 4 and keeps them. If `git apply --check` fails (a later
  turn changed the same lines), first run `doc restore <first bad cp>`: it previews, asks, and
  restores through dmc. Then apply.
- **Step 8:** `doc start` shows the brief built from the approved lesson ("Before you start: … keep
  the percent-based interface …") and asks before adding it to Muse Code's first prompt. Muse
  Code's TUI then opens with the brief, a blank line and the task. It needs a real terminal.

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

## Afterwards

```sh
cd /tmp/doc-demo
"$DMC_BIN" hooks uninstall --agent claude-code --apply
"$DMC_BIN" hooks uninstall --agent muse-code --apply      # puts ~/.config/muse/settings.json back
doc timelines clean <run-id>                              # worktree folders; branches stay in /tmp/doc-demo
rm -rf /tmp/doc-demo
```

## Measured (2026-10-31, Mike's Mac)

| Step | Wall time | Cost |
|---|---|---|
| `make_demo_repo.dart` | about 1 s | none |
| `doc models --check` (Glimmer cold) | 121 s (Glimmer 113 s) | Meta/Baseten/Fireworks about $0.002 plus Modal GPU time |
| 4 agent turns | 19 + 36 + 15 + 17 s | Claude Code subscription; Muse Code on its own account |
| `doc bisect` (4 probes and the explanation) | 2 s | Baseten $0.0028 |
| `doc timelines --from-bisect` (3 agents on `muse-wonder-1.0`, 7/7/10 steps, then judging) | 66 s (agents 48 s) | Muse Code $0.81, Wonder planner $0.026, Wonder judge $0.026 |
| `doc timelines pick` | under 1 s | none |
| `git apply`, `python3 -m unittest -v` | under 1 s | none |
| `doc lesson draft` | 2 s | Baseten $0.0029 |
| `doc lesson approve` | under 1 s | none |
| brief / `doc start` (Glimmer warm) | 13–15 s | Modal GPU time |
| `doc talk --file` (either variant) | about 9 s | Voice $0.0001; routing on Baseten about $0.002; NL restore on Meta $0.0037 |
