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

## Rules

- Keep prompt functions focused — one responsibility per phase
- Verification gates must be fast and deterministic (no LLM calls in verify)
- Prompts reference file paths the agent can read, not inline data
