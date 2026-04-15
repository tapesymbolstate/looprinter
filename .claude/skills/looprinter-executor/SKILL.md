---
name: looprinter-executor
description: Launch loop.sh as a cronjob, monitor progress, intervene on failures, and stop when done. Use when the user says "run the loop", "start the loop", "execute the loop", "kick off loop.sh", or "looprinter-executor".
allowed-tools: Read, Glob, Grep, Bash, Edit, CronCreate, CronDelete, CronList
---

# looprinter-executor

Runs the double-loop pattern: inner loop (loop.sh via cronjob) does the work, outer loop (this session) monitors and improves.

## Prerequisites

Before launching, verify in this order — stop and surface the issue to the user if any check fails:

1. **`loop.sh` exists** at the project root (`ls loop.sh`). If missing, the project hasn't been set up with looprinter — direct the user to copy `loop.sh` and `.claude/skills/looprinter-executor/` from the looprinter repo (see its README's "Porting to Another Project" section). Do not attempt to recreate `loop.sh` from memory.
2. **`loop.sh` is executable** (`test -x loop.sh`). If not, run `chmod +x loop.sh`.
3. **Prompt functions are configured** — `gen_plan_prompt()`, `gen_build_prompt()`, `gen_replan_prompt()` should reflect the project's actual objective, not the default template placeholders. If they look generic, suggest running `/looprinter-interview` first.
4. **Tool selected** — confirm which tool the user wants (`claude`, `codex`, `codex-spark`). Default to `claude` if unspecified.

## Launch

Use `CronCreate` to schedule `loop.sh`. Never run it in the foreground — it blocks this session.

Resolve the project root first (`pwd`) and build the command with the **absolute path** — cron runs from the user's home directory, not from the project, so a relative `./loop.sh` will fail to find the script.

```
Schedule: */10 * * * *
Command: cd /absolute/path/to/project && ./loop.sh <tool> <max_iterations>
```

Defaults:
- Tool: `claude`
- Interval: every 10 minutes (`*/10 * * * *`)
- Max iterations: `30` (prevents runaway loops)
- Model override: `CLAUDE_MODEL=sonnet ./loop.sh claude` if user requests cheaper/faster runs

After `CronCreate`, optionally fire one immediate run in the background so the user gets feedback before the first cron interval (up to 10 minutes away):

```bash
cd /absolute/path/to/project && nohup ./loop.sh <tool> <max_iterations> > /tmp/loop-bootstrap.log 2>&1 &
```

Use `Bash` with `run_in_background: true` for this — do not block the session waiting on it.

Inform the user of the cron ID after creation — they need it to stop the loop.

## Monitor (Outer Loop)

After launching, enter the monitor cycle. Read these files to assess progress:

### 1. Progress file

```
Read output/progress.txt
```

Shows cumulative task completions and notes from each build iteration. Check for:
- Forward progress (new tasks completed since last check)
- Repeated failures on the same task
- Error messages or stuck states

### 2. Working records

```
Glob working-records/*.jsonl → pick the latest file → Read tail
```

Raw agent output from each iteration. Useful for diagnosing why a task failed.

### 3. Plan state

```
Read output/plan.json
```

Check how many tasks remain (`passes: false`). If all tasks are done but verify keeps failing, the issue is in the verify gate.

## Intervene

When the monitor cycle detects problems, act on them:

### Repeated build failures on the same task

The prompt is unclear or the task is too large. Fix:

```
Edit loop.sh → gen_build_prompt() or gen_plan_prompt()
```

Changes take effect on the next cronjob firing (each iteration spawns a fresh agent).

### Verify keeps failing after all tasks pass

The verify gate expects something the build prompts don't produce. Fix:

- Adjust `verify()` checks if they're too strict
- Or adjust `gen_build_prompt()` to produce what verify expects

### Agent produces wrong output format

The plan prompt isn't clear enough about the schema. Fix:

```
Edit loop.sh → gen_plan_prompt() → ## Schema section
```

### Rate limit hit

The loop self-stops when rate limit threshold is reached. It will resume on the next cron interval. No intervention needed unless the user wants to adjust:

```
RATE_LIMIT_THRESHOLD=50 ./loop.sh claude
```

## Stop

When the loop completes (or when manual intervention is needed):

```
CronDelete {cron_id}
```

Also stop if:
- The user asks to stop
- The same failure repeats 3+ cron cycles with no progress
- Rate limit is persistently hit (adjust threshold or wait)

## Outer Loop Cadence

This Claude Code session does not wake up on its own between user messages. The "outer loop" runs whenever the user pings back or whenever an external scheduler resumes the session.

Check progress when:

1. **The user asks for a status update** — read fresh state and report.
2. **The user says they want autonomous monitoring** — schedule periodic check-ins by invoking the `/loop` skill (e.g. `/loop 15m check loop progress and intervene if stuck`). That skill is what actually wakes the session at intervals; this skill cannot self-wake.
3. **Right after launch** — do one check immediately (the optional bootstrap run from the Launch section makes early progress visible without waiting for the first cron interval).

Each check:
1. Read `output/progress.txt` — summarize what's new since last check.
2. If stalled, read the latest `working-records/*.jsonl` tail for diagnostics.
3. If intervention is needed, edit `loop.sh` and report what changed.
4. If done, stop the cron and report final state.

## Reporting to User

Keep status updates concise:

```
[Cycle N] T-001~T-003 complete, T-004 in progress. No errors.
```

```
[Cycle N] T-004 failed 2x — build prompt unclear about output format. Fixed gen_build_prompt(). Next cron will retry.
```

```
Done. All tasks passed verify. Cron stopped.
```

## What NOT to Do

- Do not run `loop.sh` in the foreground (blocks this session).
- Do not edit the ENGINE or SETUP sections of `loop.sh` — only edit prompt functions and verify.
- Do not manually create `output/plan.json` or `output/progress.txt` — the loop manages these.
- Do not delete `working-records/` without asking the user — it's persistent run history.
- Do not keep the cron running after completion — always clean up.
