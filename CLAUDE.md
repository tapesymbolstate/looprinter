# CLAUDE.md

## What This Project Is

looprinter is a loop template repository. `loop.sh` is a self-contained template for building any kind of iterative agent harness. Copy it, edit the prompt functions, run it.

## Architecture

```
loop.sh                              — the template (prompts + engine in one file)
working-records/                     — JSONL logs per run [gitignored]
output/                              — runtime artifacts (plan.json, progress.txt) [gitignored]
.claude/skills/looprinter-interview/ — interactive harness configuration skill
```

## Core Concepts

### 1. Headless Mode

The loop spawns agents in headless mode (`codex exec`, `claude -p`). Each iteration is a fresh agent with a clean context window. State lives in the filesystem, not in agent memory.

### 2. Working Records

Every iteration appends to a JSONL record file in `working-records/`. Records are the loop's persistent memory — they survive context resets and compound across iterations.

- Every agent iteration MUST append to the record file
- Never truncate or overwrite records mid-run

### 3. Cronjob / Background Execution

The intended workflow: a main Claude Code session launches `loop.sh` as a background task or cronjob, then observes `working-records/` and stdout to improve the harness.

```
Main Claude Code session
  ├── launches loop.sh as cronjob/task (inner loop)
  ├── reads working-records/ to detect failure patterns
  └── edits loop.sh prompt functions (outer loop)
```

The inner loop does the work. The outer loop (main agent) improves how the work gets done.

## Building a New Harness

Use `/looprinter-interview` to interactively configure a harness — it interviews you about your objective, then writes the prompt functions and verify() gate directly into `loop.sh`.

Or manually copy `loop.sh` and edit these functions:

- `gen_plan_prompt()` — planning phase prompt
- `gen_build_prompt()` — build phase prompt
- `gen_replan_prompt()` — recovery prompt after verify failure
- `verify()` — quality gate (exit 0 = pass); default checks plan.json tasks and progress.txt
- `setup()` — one-time preprocessing
- `POST_PHASES` + `gen_<name>_prompt()` — optional phases after verify passes

## Loop Execution Protocol

When asked to "run the loop":

1. **Launch via cronjob**: Use `CronCreate` to schedule `./loop.sh claude [max_iterations]`
   - Default interval: every 10 minutes (`*/10 * * * *`)
   - loop.sh exits on completion, rate limit, or max iterations — the cronjob restarts it at the next interval
   - Model override: `CLAUDE_MODEL=sonnet ./loop.sh claude` if requested

2. **Outer loop** (this session): After creating the cronjob:
   - Read `output/progress.txt` and latest `working-records/*.jsonl` to track progress
   - If repeated failures detected, edit prompt functions in loop.sh
   - Changes take effect on the next cronjob invocation (each iteration spawns a fresh agent)

3. **Stop**: Use `CronDelete` to remove the cronjob when done or when manual intervention is needed.

4. **Never run loop.sh in foreground** — it blocks the main session.

Reference: [Claude Code Scheduled Tasks](https://docs.anthropic.com/en/docs/claude-code/scheduled-tasks)

## Rules

- Keep prompt functions focused — one responsibility per phase
- Verification gates must be fast and deterministic (no LLM calls in verify)
- Prompts reference file paths the agent can read, not inline data
