# CLAUDE.md

## What This Project Is

harness-factory builds loop-based agent harnesses. A harness = prompts + phases + verification gates + working records. The loop engine (`loop.sh`) is generic; domain logic lives in config directories under `configs/`.

## Architecture

```
loop.sh                  — generic loop engine (Plan → Build → Verify → cycle)
configs/<name>/          — harness configs (prompt generators, verify scripts)
output/                  — runtime artifacts (plan, progress, source, records)
output/records/          — working records (JSONL logs, archived plans)
tmp/                     — reference documents on harness/context engineering
```

## Working Records Are Sacred

Every design decision in this project optimizes for working record quality. Records are the loop's persistent memory — they survive context resets and compound across iterations. When building or modifying a harness:

- Every agent iteration MUST append to the record file
- Records use JSONL format, one entry per iteration
- Include: what the agent attempted, what it found, what failed, what changed
- Never truncate or overwrite records mid-run

## The Double Loop

The primary workflow is a double loop:

1. **Inner loop** — `loop.sh` runs a harness in the background (via Claude Code task/cronjob)
2. **Outer loop** — a separate Claude Code session observes working records + stdout and improves the harness configs

When building harness improvement features, always design for this pattern. The observer needs:
- Real-time access to working records and stdout
- Ability to edit config files that the inner loop reads on next iteration
- Failure pattern detection from accumulated records

## How to Build a New Harness

A harness config directory needs these files:

| File | Required | Purpose |
|------|----------|---------|
| `plan.prompt.sh` | yes | Outputs the PLAN phase prompt to stdout |
| `build.prompt.sh` | yes | Outputs the BUILD phase prompt to stdout |
| `verify.sh` | yes | Verification gate. Exit 0 = pass. Write errors to `$WORK_DIR/build_errors.txt` on failure |
| `setup.sh` | no | One-time pre-loop initialization |
| `replan.prompt.sh` | no | Re-plan prompt after verify failure. Falls back to `plan.prompt.sh` |
| `post_N_<name>.prompt.sh` | no | Post-loop phases, run in order after verify passes |

Each `.prompt.sh` script receives env vars: `CYCLE`, `ITERATION`, `WORK_DIR`, `PLAN_FILE`, `PROGRESS_FILE`, `BUILD_ERRORS`, `TOOL`, `CONFIG_DIR`.

Agent completion signals use `<promise>` tags: `PLAN_COMPLETE`, `CYCLE_DONE`, `<NAME>_DONE`, `<NAME>_PROGRESS`.

## Rules

- Keep prompt scripts focused — one responsibility per phase
- Verification gates must be fast and deterministic (no LLM calls in verify.sh)
- Prompts reference file paths the agent can read, not inline data
- Config directories are self-contained — no cross-config dependencies
- Reference docs in `tmp/` are read-only context, not runtime dependencies
