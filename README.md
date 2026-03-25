# looprinter

A loop template for building iterative agent harnesses. Copy `loop.sh`, edit the prompts, run it.

## Core Concepts

### 1. Ralph Loop

```
while true:
    Plan → Build → Verify → (fail? re-plan) → ... → Done
```

Each iteration starts a fresh agent with a clean context window. State lives in the filesystem, not in the agent's memory. All phases — prompts, verification gates, post-processing — live in a single `.sh` file.

### 2. Headless Agent Execution

The loop runs agents in **headless mode** (`codex exec`, `claude -p`) from inside a main Claude Code session. The main agent spawns background loops as tasks or cronjobs. This means:

- The loop runs autonomously — no human in the loop
- The main agent stays free to observe, analyze, and intervene
- Multiple loops can run in parallel on different tasks

### 3. Working Records

Every agent iteration appends to a working record (JSONL in `working-records/`). Records capture what the agent attempted, what failed, and what changed. The agent's context window is disposable — the working record is not.

### 4. Cronjob-Driven Double Loop

The main agent reads `working-records/` from background loops, then **improves the harness itself**:

```
┌─────────────────────────────────────────────┐
│  Main Agent (Claude Code session)           │
│                                             │
│  reads working-records/ ──► edits loop.sh   │
│       ▲                         │           │
│       │                         ▼           │
│  ┌────┴────────────────────────────────┐    │
│  │  Background Loop (cronjob/task)     │    │
│  │  Plan → Build → Verify → re-plan    │    │
│  │       │                             │    │
│  │       └──► writes working-records/  │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
```

## Structure

```
loop.sh              — self-contained loop template (prompts + engine in one file)
working-records/     — JSONL logs from loop iterations (gitignored)
output/              — runtime artifacts produced by the loop (gitignored)
```

## Usage

```bash
# Run directly
./loop.sh codex 50
./loop.sh codex-spark
./loop.sh claude 30

# Run as background task from a main Claude Code session
# The main agent monitors working-records/ and edits loop.sh to improve the harness
```

## Building a New Harness

Copy `loop.sh` and edit the functions:

- `gen_plan_prompt()` — what the planning agent should do
- `gen_build_prompt()` — what the build agent should do per task
- `gen_replan_prompt()` — how to recover from verification failure
- `verify()` — quality gates (exit 0 = pass)
- `setup()` — one-time preprocessing before the loop
- `POST_PHASES` + `gen_<name>_prompt()` — optional phases after verify passes
