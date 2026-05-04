---
name: looprinter-executor
description: Launch loop.sh as a cronjob, monitor cycle and key-objective progress, intervene on failures, and stop when the key objective is met. Use when the user says "run the loop", "start the loop", "execute the loop", "kick off loop.sh", or "looprinter-executor".
allowed-tools: Read, Glob, Grep, Bash, Edit, CronCreate, CronDelete, CronList
---

# looprinter-executor

Runs the double-loop pattern: inner loop (loop.sh via cronjob) does the work, outer loop (this session) monitors and improves.

The inner loop has **two completion gates**, and the outer loop watches both:

- **Cycle verify** — did the latest cycle's plan execute correctly? Failure archives `plan_cycle_<N>.json` and re-plans with errors.
- **Key objective** — is the global key objective truly met? Failure (after cycle verify passes) archives `plan_cycle_<N>_objective_gap.json` and re-plans the next increment.

The loop only exits when both gates pass on the same cycle. Until then, the outer loop's job is to spot which gate is blocking and tighten the relevant prompts or checks.

## Prerequisites

Before launching, verify in this order — stop and surface the issue to the user if any check fails:

1. **`loop.sh` exists** at the project root (`ls loop.sh`). If missing, the project hasn't been set up with looprinter — direct the user to copy `loop.sh` and `.claude/skills/looprinter-executor/` from the looprinter repo (see its README's "Porting to Another Project" section). Do not attempt to recreate `loop.sh` from memory.
2. **`loop.sh` is executable** (`test -x loop.sh`). If not, run `chmod +x loop.sh`.
3. **`KEY_OBJECTIVE` is configured.** Grep for `KEY_OBJECTIVE="TODO:` — if present, the north star has not been set. Strongly recommend running `/looprinter-interview` first; the loop will still run but the objective gate will only warn, not enforce, so the loop falls back to "exit when cycle verify passes" behavior (i.e. the brand promise of "key objective" is inactive). Confirm with the user before launching in that mode.
4. **`verify_objective()` is configured (optional but recommended).** Grep for `LOOPRINTER_OBJECTIVE_TODO` inside `loop.sh`. If present, the global gate is in pass-through mode; surface this to the user the same way as item 3. Activated mode (marker absent + real checks present) means the loop will not exit until the objective check returns 0.
5. **Prompt functions are configured** — `gen_plan_prompt()`, `gen_build_prompt()`, `gen_replan_prompt()` should reflect the project's actual cycle deliverables, not the default template placeholders. If they look generic, suggest `/looprinter-interview` before launch (when available). Otherwise the user can edit the three prompt functions in `loop.sh` manually.
6. **Tool selected** — confirm which tool the user wants (`claude`, `codex`, `codex-spark`). Default to `claude` if unspecified — matches `loop.sh`'s own default so behavior is the same whether launched via this skill or directly.

Quick prerequisite probe:

```bash
grep -n 'KEY_OBJECTIVE="TODO:\|LOOPRINTER_OBJECTIVE_TODO' loop.sh || echo "objective gate active"
```

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

Check how many tasks remain (`passes: false`). If all tasks are done but cycle verify keeps failing, the issue is in `verify()`.

### 4. Plan archives — distinguishes the two failure modes

```
Glob working-records/plan_cycle_*.json
```

Filename suffix tells you *why* the cycle ended:

- `plan_cycle_<N>.json` — cycle-level `verify()` failed; plan executed but the per-cycle gate caught a problem. Look at recent build records to find the broken task.
- `plan_cycle_<N>_objective_gap.json` — cycle verify passed but `verify_objective()` returned 1; the agent finished its plan correctly but the global key objective is still not met. This is normal early in a long objective; suspicious if it repeats with no incremental progress.

### 5. Objective gate state

If recent cycles all archive as `*_objective_gap.json` with no new progress in `output/progress.txt`, the loop is iterating without closing the gap. That signals one of:

- Plan/build prompts aren't pushed hard enough toward the objective
- `verify_objective()` is checking something the agent has no way to produce
- The objective itself is too vague — the agent doesn't know what would close the gap

## Intervene

When the monitor cycle detects problems, act on them:

### Repeated build failures on the same task

The prompt is unclear or the task is too large. Fix:

```
Edit loop.sh → gen_build_prompt() or gen_plan_prompt()
```

Changes take effect on the next cronjob firing (each iteration spawns a fresh agent).

### Cycle verify keeps failing after all tasks pass

The cycle gate expects something the build prompts don't produce. Fix:

- Adjust `verify()` checks if they're too strict
- Or adjust `gen_build_prompt()` to produce what verify expects

### Objective gap repeats with no progress

If three or more cycles archive as `plan_cycle_<N>_objective_gap.json` and `output/progress.txt` shows no real movement toward the gap items, intervene:

1. Read `verify_objective()` and check if the gap items are achievable from the agent's vantage point (correct paths, deterministic patterns, no hidden dependencies on humans).
2. Read the latest `working-records/*.jsonl` tail — does the agent attempt to close the gap, or does it busy-work on cycle deliverables and ignore the objective?
3. If the agent ignores the gap, sharpen `gen_replan_prompt()` — make the "Key objective gap" section more directive about what specific files or commands would close it.
4. If `verify_objective()` is checking something unachievable (or trivially flapping), tighten or relax it as appropriate.
5. As a last resort, refine `KEY_OBJECTIVE` itself if the original phrasing is too vague to plan against.

Each fix takes effect on the next cron firing — fresh agent, fresh prompt.

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

Keep status updates concise. Always name the gate state:

```
[Cycle N] T-001~T-003 complete, T-004 in progress. Cycle gate: pending. Objective gate: pending.
```

```
[Cycle N] Cycle gate passed. Objective gate fail (gap: final_report.md missing ## Conclusion). Re-planning toward objective.
```

```
[Cycle N] T-004 failed 2x — build prompt unclear about output format. Fixed gen_build_prompt(). Next cron will retry.
```

```
Done. Cycle verify and key objective both met. Cron stopped.
```

## What NOT to Do

- Do not run `loop.sh` in the foreground (blocks this session).
- Do not edit the ENGINE or SETUP sections of `loop.sh` — only edit `KEY_OBJECTIVE`, prompts, `verify()`, and `verify_objective()`.
- Do not manually create `output/plan.json` or `output/progress.txt` — the loop manages these.
- Do not delete `working-records/` without asking the user — it's persistent run history (including the `*_objective_gap.json` archives that diagnose objective stalls).
- Do not stop the cron just because cycle verify passed — the loop is supposed to continue on objective gap. Only stop when both gates pass, or when the user asks, or on persistent stall.
- Do not re-add the `LOOPRINTER_OBJECTIVE_TODO` marker to silence the objective gate. If the user wants to stop, they ask; otherwise the gate is the whole point of running this skill.
