# looprinter

A loop template for building iterative agent harnesses. Copy `loop.sh`, edit the prompts, run it.

## Core Concepts

### 1. [Ralph Loop](https://ghuntley.com/ralph/)

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

### 5. Two-Gate Cycle Contract — Cycle Verify + Key Objective

`loop.sh` enforces a strict cycle order with **two completion gates**:

1. `setup()` runs once, then the cycle starts.
2. `Plan` runs when `output/plan.json` is missing or when all tasks are already complete.
3. `Build` runs and repeatedly executes exactly one task per iteration.
4. `Verify` (cycle-level) checks required artifacts and schema invariants — *did this cycle's plan execute correctly?*
5. On cycle verify fail, the loop archives `output/plan.json` as `working-records/plan_cycle_<N>.json`, removes it, then re-plans next cycle with errors.
6. On cycle verify pass, **`Verify Objective` (global)** runs — *is the key objective truly met?*
7. On objective fail, the loop archives `output/plan.json` as `working-records/plan_cycle_<N>_objective_gap.json`, removes it, and re-plans the next increment with the gap injected into the replan prompt.
8. On objective pass, configured post-phases run and then the loop exits.

The build contract is one-task-per-iteration:

- read `output/plan.json` and `output/progress.txt` first
- execute the first remaining task where `passes` is `false`
- mark that single task as `passes: true`
- append cumulative findings to `output/progress.txt`
- finish the build iteration

### 6. Key Objective — the global gate

`KEY_OBJECTIVE` (a one-line string near the top of `loop.sh`) is the north star injected into every prompt and paired with `verify_objective()`. The loop will not exit until that function returns 0.

Strict enforcement is opt-in: while the `LOOPRINTER_OBJECTIVE_TODO` marker remains inside `verify_objective()`, the gate passes through with a stderr warning so the raw template can still terminate on cycle verify alone. Removing the marker (which `/looprinter-interview` does automatically) activates the gate and turns the loop into "iterate until truly done."

## Structure

```
loop.sh                              — self-contained loop template (prompts + engine in one file)
working-records/                     — JSONL logs from loop iterations (gitignored)
output/                              — runtime artifacts produced by the loop (gitignored)
.claude/skills/looprinter-interview/ — interactive harness configuration skill
.claude/skills/looprinter-executor/  — loop execution and monitoring skill
```

## Artifact Contract

- `output/plan.json` — object containing `tasks` array; each task has `id`, `title`, `description`, `targetFile`, `passes`, and `notes`.
- `output/progress.txt` — cumulative findings and notes; must be non-empty for `verify()`.
- `working-records/*.jsonl` — line-delimited records for each phase/output cycle.
- `working-records/plan_cycle_<N>.json` — archived plan when **cycle verify** failed (plan execution problem).
- `working-records/plan_cycle_<N>_objective_gap.json` — archived plan when cycle verify passed but **`verify_objective()`** returned 1 (global gate not yet met). Filename suffix tells you which gate stopped the cycle.

## Usage

Two skills drive the workflow from a main Claude Code session:

1. `/looprinter-interview` — interview the user, then write prompt functions and the `verify()` gate into `loop.sh`.
2. `/looprinter-executor` — launch `loop.sh` as a cronjob, monitor `output/progress.txt` and `working-records/`, intervene by editing prompt functions when failures repeat, and stop the cron when done.

Always run the loop through `/looprinter-executor` from a Claude Code session. Foreground execution blocks the session and breaks the double-loop pattern (the main agent can no longer observe `working-records/` or improve the harness).

Direct shell invocation exists only for debugging the harness itself outside a Claude Code session:

```bash
./loop.sh codex 50
./loop.sh codex-spark
./loop.sh claude 30
```

## Porting to Another Project

To use looprinter in a different project, copy these two paths into the target project root:

```
loop.sh
.claude/skills/looprinter-executor/
```

Optionally also copy `.claude/skills/looprinter-interview/` if you want the interactive harness configurator in that project.

Once copied, no edits to the target project's `CLAUDE.md` are required — both skills self-register via Claude Code's skill discovery and trigger on phrases like "run the loop", "execute", or "configure the loop". The first time you run `/looprinter-interview` in the new project, it writes the project-specific prompt functions and `verify()` gate into the copied `loop.sh`.

Make sure `loop.sh` is executable (`chmod +x loop.sh`) and that the project's `.gitignore` excludes `output/` and `working-records/`.

## Building a New Harness

Use the `/looprinter-interview` skill to interactively configure a harness — it interviews you about your key objective and cycle-level deliverables, then generates `KEY_OBJECTIVE`, `verify_objective()`, the prompt functions, and the per-cycle `verify()` gate directly into `loop.sh`.

Or manually copy `loop.sh` and edit:

- `KEY_OBJECTIVE` — one-line north star, injected into all prompts
- `verify_objective()` — global completion gate (remove the `LOOPRINTER_OBJECTIVE_TODO` marker to activate)
- `gen_plan_prompt()` — what the planning agent should do per cycle
- `gen_build_prompt()` — what the build agent should do per task
- `gen_replan_prompt()` — how to recover from cycle errors and/or close the objective gap
- `verify()` — cycle-level quality gate (exit 0 = pass)
- `setup()` — one-time preprocessing before the loop
- `POST_PHASES` + `gen_<name>_prompt()` — optional phases that run after both gates pass
