# harness-factory

A toolkit for building loop-based agent harnesses. The harness is the product, not the code the agent writes.

## How It Works

### 1. Ralph Loop

The foundation is a simple loop that runs an AI agent repeatedly until the work is done:

```
while true:
    Plan → Build → Verify → (fail? re-plan) → ... → Done
```

Each iteration starts a fresh agent with a clean context window. State lives in the filesystem, not in the agent's memory. The loop handles phase transitions, error recovery, and rate limiting. All phases — prompts, verification gates, post-processing — live in a single `.sh` file.

### 2. Headless Agent Execution

The loop runs agents in **headless mode** (`claude -p`, `codex exec`) from inside a main Claude Code session. The main agent spawns background loops as tasks or cronjobs. This means:

- The loop runs autonomously — no human in the loop
- The main agent stays free to observe, analyze, and intervene
- Multiple loops can run in parallel on different tasks

### 3. Working Records

Every agent iteration appends to a working record (JSONL in `working-records/`). These records capture:

- What the agent attempted
- What it found, what failed, what changed
- Agent stdout from each iteration

Records are the loop's persistent memory. The agent's context window is disposable — it resets every iteration. The working record is not. It accumulates signal across hundreds of runs.

### 4. Continuous Harness Improvement

The main agent reads the working records and stdout from background loops, then **improves the harness itself**:

- Identifies failure patterns from accumulated records
- Edits prompt functions to address recurring issues
- Adjusts verification gates based on observed quality
- Tunes phase transitions based on what's actually working

This creates a **double loop**: the inner loop does the work, the outer loop (the main agent) improves how the work gets done. The harness gets better with every run without manual intervention.

```
┌─────────────────────────────────────────────┐
│  Main Agent (Claude Code session)           │
│                                             │
│  reads working-records/ ──► edits loop.sh   │
│       ▲                         │           │
│       │                         ▼           │
│  ┌────┴────────────────────────────────┐    │
│  │  Background Loop (headless)         │    │
│  │  Plan → Build → Verify → re-plan   │    │
│  │       │                             │    │
│  │       └──► writes working-records/  │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
```

## Structure

```
loop.sh              — self-contained loop harness (prompts + engine in one file)
working-records/     — JSONL logs from loop iterations (gitignored)
output/              — runtime artifacts produced by the loop (gitignored)
```

## Usage

```bash
# Run directly
./loop.sh claude 50

# Run in background from a main Claude Code session
# (using tasks/cronjobs to monitor working-records/)
```

## Building a New Harness

Copy `loop.sh` and edit the functions:

- `gen_plan_prompt()` — what the planning agent should do
- `gen_build_prompt()` — what the build agent should do per task
- `gen_replan_prompt()` — how to recover from verification failure
- `verify()` — quality gates (exit 0 = pass)
- `setup()` — one-time preprocessing before the loop
- `POST_PHASES` + `gen_<name>_prompt()` — optional phases after verify passes
