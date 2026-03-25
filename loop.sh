#!/bin/bash
# Ralph Loop — iterative agent harness
#
# Usage: ./loop.sh [codex|codex-spark|claude] [max_iterations]
#
# Tools:
#   codex       — Codex CLI with gpt-5.4 (default)
#   codex-spark — Codex CLI with gpt-5.3-codex-spark (fast)
#   claude      — Claude Code with opus (CLAUDE_MODEL=sonnet for Sonnet)
#
# Examples:
#   ./loop.sh codex 50              — gpt-5.4, max 50 iterations
#   ./loop.sh codex-spark           — spark, unlimited
#   ./loop.sh claude 30             — Claude opus, max 30
#   CLAUDE_MODEL=sonnet ./loop.sh claude — Claude sonnet
#
# Workflow:
#   Setup  → run once before the loop (optional preprocessing)
#   Plan   → generate a task plan (plan.json)
#   Build  → iterate through plan tasks, one per agent call
#   Verify → check if output meets quality gates
#   If verify fails → archive plan, re-plan with error context, goto Build
#   If verify passes → run post-phases → done

set -euo pipefail
cd "$(dirname "$0")"

# ═══════════════════════════════════════════════════════════════════════════════
# ARG PARSING
# ═══════════════════════════════════════════════════════════════════════════════

TOOL="codex"
if [[ "${1:-}" =~ ^(codex|codex-spark|claude)$ ]]; then
    TOOL="$1"; shift
fi

MAX_ITERATIONS=${1:-0}
ITERATION=0
CYCLE=0
BUILD_ERRORS=""

WORK_DIR="output"
PLAN_FILE="$WORK_DIR/plan.json"
PROGRESS_FILE="$WORK_DIR/progress.txt"

PLAN="$PLAN_FILE"
PROGRESS="$PROGRESS_FILE"

# ═══════════════════════════════════════════════════════════════════════════════
# WORKING RECORDS
# ═══════════════════════════════════════════════════════════════════════════════

RECORDS_DIR="working-records"
mkdir -p "$RECORDS_DIR" output

RECORD_FILE="$RECORDS_DIR/$(date '+%Y-%m-%d-%H%M%S')-$TOOL.jsonl"
echo "Record: $RECORD_FILE"

# ═══════════════════════════════════════════════════════════════════════════════
# PROMPTS — edit these functions to customize the harness
# ═══════════════════════════════════════════════════════════════════════════════

gen_plan_prompt() {
    cat <<'PROMPT_EOF'
You are a planning agent. Read the project context and create a task plan.

## Job
1. Analyze what needs to be done
2. Generate `output/plan.json` with schema:
   ```json
   {
     "tasks": [
       { "id": "T-001", "title": "...", "description": "...",
         "targetFile": "output/...", "passes": false, "notes": "" }
     ]
   }
   ```
3. Write `output/progress.txt` with initial findings

## Completion
When done, output: <promise>PLAN_COMPLETE</promise>
PROMPT_EOF
}

gen_replan_prompt() {
    local cycle_num="$1"
    local build_errors="$2"

    cat <<PROMPT_EOF
You are a planning agent running cycle $cycle_num. The previous cycle had issues.

## Previous errors
\`\`\`
$build_errors
\`\`\`

## Job
1. Read \`output/progress.txt\` for context on what was already done
2. Generate a NEW \`output/plan.json\` for cycle $cycle_num
3. Fix the issues from the previous cycle
4. Append cycle notes to \`output/progress.txt\`

## Completion
When done, output: <promise>PLAN_COMPLETE</promise>
PROMPT_EOF
}

gen_build_prompt() {
    cat <<'PROMPT_EOF'
You are a build agent. Execute one task from the plan.

## Context — read FIRST
1. `output/plan.json` — task list
2. `output/progress.txt` — cumulative findings

## Workflow
1. Read `output/plan.json`, find the first task where `passes` is `false`
2. Execute that task
3. Update `output/plan.json`: set `passes: true` for completed task
4. Append progress to `output/progress.txt`

## Rules
- ONE task per iteration
- Update the plan JSON after completing each task

## Completion
If ALL tasks have `passes: true`, output: <promise>CYCLE_DONE</promise>
Otherwise, complete your one task and exit.
PROMPT_EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# POST PHASES — define gen_<name>_prompt() functions and add names to POST_PHASES
# ═══════════════════════════════════════════════════════════════════════════════

POST_PHASES=()

# ═══════════════════════════════════════════════════════════════════════════════
# VERIFY — exit 0 = pass, exit 1 = fail
# ═══════════════════════════════════════════════════════════════════════════════

verify() {
    echo "── VERIFY ──"

    if [ ! -d "output" ] || [ -z "$(ls output/ 2>/dev/null)" ]; then
        BUILD_ERRORS="No output files found."
        echo "FAIL: $BUILD_ERRORS"
        return 1
    fi

    echo "PASS"
    BUILD_ERRORS=""
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# SETUP — runs once before the loop
# ═══════════════════════════════════════════════════════════════════════════════

setup() {
    echo "── SETUP ──"
    mkdir -p output
    echo "Ready."
}

# ═══════════════════════════════════════════════════════════════════════════════
# ENGINE — generic loop machinery
# ═══════════════════════════════════════════════════════════════════════════════

spawn_agent() {
    local prompt="$1"
    if [[ "$TOOL" == "codex" || "$TOOL" == "codex-spark" ]]; then
        local model="${CODEX_MODEL:-gpt-5.4}"
        [[ "$TOOL" == "codex-spark" ]] && model="gpt-5.3-codex-spark"
        echo "$prompt" | codex exec \
            --full-auto \
            --json \
            --model "$model" \
            2>&1 || true
    else
        claude -p \
            --model "${CLAUDE_MODEL:-opus}" \
            --effort "${CLAUDE_EFFORT:-max}" \
            --permission-mode bypassPermissions \
            --dangerously-skip-permissions \
            --output-format stream-json \
            "$prompt" 2>&1 || true
    fi
}

log() { echo "$*" | tee -a "$RECORD_FILE"; }

has_incomplete_tasks() {
    [[ -f "$PLAN" ]] && python3 -c "
import json, sys
d = json.load(open('$PLAN'))
tasks = d.get('userStories', d.get('tasks', []))
sys.exit(0 if any(not t.get('passes') and not t.get('done') for t in tasks) else 1)
" 2>/dev/null
}

all_tasks_done() {
    [[ -f "$PLAN" ]] && python3 -c "
import json, sys
d = json.load(open('$PLAN'))
tasks = d.get('userStories', d.get('tasks', []))
sys.exit(0 if tasks and all(t.get('passes') or t.get('done') for t in tasks) else 1)
" 2>/dev/null
}

run_post_phases() {
    [[ ${#POST_PHASES[@]} -eq 0 ]] && return 0
    for phase_name in "${POST_PHASES[@]}"; do
        log ""
        log "── ${phase_name^^} ──"

        local prompt step=0
        local fn="gen_${phase_name}_prompt"
        if ! type "$fn" &>/dev/null; then
            log "Warning: no prompt function for phase $phase_name, skipping"
            continue
        fi
        prompt=$($fn)

        local signal_done="${phase_name^^}_DONE"
        local signal_progress="${phase_name^^}_PROGRESS"

        while true; do
            step=$((step + 1))
            log "step $step ($(date '+%H:%M:%S'))"

            local result
            result=$(spawn_agent "$prompt")
            log "$result"

            if grep -q "$signal_done" <<< "$result"; then
                log "${phase_name} complete."
                break
            elif grep -q "$signal_progress" <<< "$result"; then
                continue
            else
                log "No signal from ${phase_name} step $step. Retrying..."
                continue
            fi
        done
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN
# ═══════════════════════════════════════════════════════════════════════════════

setup

while true; do
    CYCLE=$((CYCLE + 1))

    log ""
    log "════════════════════════════════════════"
    log "  CYCLE $CYCLE"
    log "════════════════════════════════════════"

    # ── PLAN ──────────────────────────────────────────────────────────────

    if [[ ! -f "$PLAN" ]] || ! has_incomplete_tasks; then
        log ""
        log "── PLAN (cycle $CYCLE) ──"

        if [[ -n "$BUILD_ERRORS" ]]; then
            PLAN_PROMPT=$(gen_replan_prompt "$CYCLE" "$BUILD_ERRORS")
        else
            PLAN_PROMPT=$(gen_plan_prompt)
        fi

        OUTPUT=$(spawn_agent "$PLAN_PROMPT")
        log "$OUTPUT"

        if [[ ! -f "$PLAN" ]]; then
            log "Error: plan phase did not produce $PLAN"
            exit 1
        fi
    fi

    # ── BUILD ─────────────────────────────────────────────────────────────

    log ""
    log "── BUILD (cycle $CYCLE) ──"

    BUILD_PROMPT=$(gen_build_prompt)

    while has_incomplete_tasks; do
        if [[ "$MAX_ITERATIONS" -gt 0 && "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
            log "Max iterations reached ($MAX_ITERATIONS)."
            log "Record: $RECORD_FILE"
            exit 0
        fi

        ITERATION=$((ITERATION + 1))
        log ""
        log "── build C${CYCLE}.${ITERATION} ($(date '+%H:%M:%S')) ──"

        OUTPUT=$(spawn_agent "$BUILD_PROMPT")
        log "$OUTPUT"

        if grep -qi 'rate.limit\|429\|too many requests\|overloaded' <<< "$OUTPUT"; then
            log "Rate limited. Waiting 60s..."
            sleep 60
            ITERATION=$((ITERATION - 1))
            continue
        fi

        if all_tasks_done || grep -q 'CYCLE_DONE' <<< "$OUTPUT"; then
            log "All tasks complete (cycle $CYCLE)."
            break
        fi
    done

    # ── VERIFY ────────────────────────────────────────────────────────────

    log ""
    if verify; then
        run_post_phases

        log ""
        log "════════════════════════════════════════"
        log "  DONE"
        log "════════════════════════════════════════"
        log "Record: $RECORD_FILE"
        exit 0
    fi

    # ── FAIL → archive plan, re-plan next cycle ───────────────────────────

    log "Verification failed. Re-planning..."
    cp "$PLAN" "$RECORDS_DIR/plan_cycle_${CYCLE}.json" 2>/dev/null || true
    rm -f "$PLAN"
done
