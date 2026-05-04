#!/bin/bash
# Ralph Loop — iterative agent harness
#
# Usage: ./loop.sh [codex|codex-spark|claude] [max_iterations]
#
# Tools:
#   claude      — Claude Code with opus (default; CLAUDE_MODEL=sonnet for Sonnet)
#   codex       — Codex CLI with gpt-5.4
#   codex-spark — Codex CLI with gpt-5.3-codex-spark (fast)
#
# Examples:
#   ./loop.sh codex 50              — gpt-5.4, max 50 iterations
#   ./loop.sh codex-spark           — spark, unlimited
#   ./loop.sh claude 30             — Claude opus, max 30
#   CLAUDE_MODEL=sonnet ./loop.sh claude — Claude sonnet
#
# Rate limit gate (all tools):
#   RATE_LIMIT_THRESHOLD=80 ./loop.sh claude       — stop when 5h usage ≥ 80% (default)
#   RATE_LIMIT_THRESHOLD=50 ./loop.sh codex-spark  — more conservative
#   RATE_LIMIT_THRESHOLD=0  ./loop.sh codex        — disable gate
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

if command -v python3 &>/dev/null; then
    PYTHON=python3
elif command -v python &>/dev/null; then
    PYTHON=python
else
    echo "Error: python3 or python is required but not found in PATH."
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# ARG PARSING
# ═══════════════════════════════════════════════════════════════════════════════

TOOL="claude"
if [[ "${1:-}" =~ ^(codex|codex-spark|claude)$ ]]; then
    TOOL="$1"; shift
fi

MAX_ITERATIONS=${1:-0}
ITERATION=0
CYCLE=0
BUILD_ERRORS=""
OBJECTIVE_GAP=""

# Rate limit gate — stop when Claude 5h utilization exceeds threshold (0=disabled)
RATE_LIMIT_THRESHOLD=${RATE_LIMIT_THRESHOLD:-80}
RATE_LIMIT_CACHE=""  # set per-tool in setup
RATE_LIMIT_CACHE_TTL=60

WORK_DIR="output"
PLAN_FILE="$WORK_DIR/plan.json"
PROGRESS_FILE="$WORK_DIR/progress.txt"

# ═══════════════════════════════════════════════════════════════════════════════
# WORKING RECORDS
# ═══════════════════════════════════════════════════════════════════════════════

RECORDS_DIR="working-records"
RECORD_FILE=""

# ═══════════════════════════════════════════════════════════════════════════════
# KEY OBJECTIVE — global completion criterion (north star)
# ═══════════════════════════════════════════════════════════════════════════════
#
# A one-line description of what "truly done" means for this loop. Two roles:
#   1. Injected into every prompt (plan, build, replan) so each agent shares the
#      same north star.
#   2. Paired with verify_objective() as the global gate — the loop only exits
#      when verify_objective() returns 0.
#
# Strict enforcement is opt-in. While the LOOPRINTER_OBJECTIVE_TODO marker is
# present in verify_objective() below, that gate passes through with a stderr
# warning so the raw template can still terminate on cycle verify alone.

KEY_OBJECTIVE="TODO: describe what 'truly done' looks like for this loop"

# ═══════════════════════════════════════════════════════════════════════════════
# PROMPTS — edit these functions to customize the harness
# ═══════════════════════════════════════════════════════════════════════════════

_objective_block() {
    cat <<EOF
## Key Objective (north star — the loop will not exit until this is met)
$KEY_OBJECTIVE

EOF
}

gen_plan_prompt() {
    _objective_block
    cat <<'PROMPT_EOF'
You are a planning agent. Read the project context and create a task plan.

## Context
1. Read `output/progress.txt` first; do not duplicate work already marked as done.
2. Keep tasks minimal and directly tied to the current cycle objective.

## Job
1. Read what has been completed and what remains from `output/progress.txt`.
2. Generate `output/plan.json` with exact JSON only (no markdown fences, no preface, no explanation).
3. Tasks must be ordered by execution priority so build can finish them in array order.
4. Ensure every task includes all required fields and `passes` is initially `false` for unfinished work.

Schema:
   ```json
   {
     "tasks": [
       { "id": "T-001", "title": "...", "description": "...",
         "targetFile": "output/...", "passes": false, "notes": "..." }
     ]
   }
   ```

5. Overwrite `output/plan.json` each run with the complete task list.

## Rules
- Use stable, unique IDs.
- Use explicit ordering in the task array for build execution.

## Completion
The phase finishes when `output/plan.json` is written. No end-of-output signal is required.
PROMPT_EOF
}

gen_replan_prompt() {
    local cycle_num="$1"
    local build_errors="$2"
    local objective_gap="${3:-}"

    _objective_block

    cat <<PROMPT_EOF
You are a planning agent running cycle $cycle_num. The previous cycle did not finish the job.
PROMPT_EOF

    if [[ -n "$build_errors" ]]; then
        cat <<PROMPT_EOF

## Previous cycle errors (cycle-level verify failed)
\`\`\`
$build_errors
\`\`\`
PROMPT_EOF
    fi

    if [[ -n "$objective_gap" ]]; then
        cat <<PROMPT_EOF

## Key objective gap (cycle verify passed, objective not yet met)
The previous cycle's plan completed and passed cycle verification, but the global
key objective is still not met. Plan the next increment of work to close this gap:
\`\`\`
$objective_gap
\`\`\`
PROMPT_EOF
    fi

    cat <<PROMPT_EOF

## Job
1. Read \`output/progress.txt\` for context on what was already done.
2. Generate a NEW \`output/plan.json\` for cycle $cycle_num with schema:
   \`\`\`json
   {
     "tasks": [
       { "id": "T-001", "title": "...", "description": "...",
         "targetFile": "output/...", "passes": false, "notes": "" }
     ]
   }
   \`\`\`
3. Address the cycle errors and/or objective gap above; do not re-do work already
   marked done in progress.txt.
4. Append cycle notes to \`output/progress.txt\`.

## Completion
The phase finishes when \`output/plan.json\` is written. No end-of-output signal is required.
PROMPT_EOF
}

gen_build_prompt() {
    _objective_block
    cat <<'PROMPT_EOF'
You are a build agent. Execute one task from the plan.

## Context — read FIRST
1. `output/plan.json` — task list
2. `output/progress.txt` — cumulative findings

## Workflow
1. Read `output/plan.json` and find the first task where `passes` is `false` (by array order).
2. Execute exactly that one task and do not modify any other task state.
3. Update only the matching task in `output/plan.json` to `passes: true`.
4. Append concise progress to `output/progress.txt` naming:
   - completed task id
   - what changed
   - any notable decisions or risks
5. If ALL tasks in `tasks` now have `passes: true`, output `<promise>CYCLE_DONE</promise>`.
6. If tasks remain incomplete, stop after this one task.

## Rules
- ONE task per iteration
- Update the plan JSON after completing each task
- Do not reorder tasks.
- Do not add tasks that are not in the plan.
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
    local errors=()

    if [ ! -d "$WORK_DIR" ] || [ -z "$(ls "$WORK_DIR"/ 2>/dev/null)" ]; then
        errors+=("No output files found.")
    fi

    if [[ ! -f "$PLAN_FILE" ]]; then
        errors+=("plan.json not found.")
    else
        local plan_report=""
        local plan_rc=0
        local task_count=0
        local complete_count=0
        local incomplete_count=0
        local incomplete_ids=""

        plan_report=$(
$PYTHON - "$PLAN_FILE" <<'PY'
import json
import re
import sys

plan_path = sys.argv[1]
errors = []

try:
    with open(plan_path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except json.JSONDecodeError as exc:
    errors.append(f"plan.json is not valid JSON: {exc}")
else:
    if not isinstance(data, dict):
        errors.append("plan.json top-level value must be an object.")
    else:
        tasks = data.get("tasks")
        if not isinstance(tasks, list):
            errors.append("plan.json requires a 'tasks' array.")
        elif not tasks:
            errors.append("plan.json requires a non-empty tasks array.")
        else:
            task_ids = []
            required = ("id", "title", "description", "targetFile", "passes", "notes")
            for idx, task in enumerate(tasks, 1):
                if not isinstance(task, dict):
                    errors.append(f"Task #{idx} is not an object.")
                    continue
                for key in required:
                    if key not in task:
                        errors.append(f"Task #{idx} missing field '{key}'.")
                if "id" in task and not isinstance(task["id"], str):
                    errors.append(f"Task #{idx} field 'id' must be a string.")
                elif "id" in task and isinstance(task["id"], str):
                    if not task["id"].strip():
                        errors.append(f"Task #{idx} field 'id' must be a non-empty string.")
                    elif task["id"] in task_ids:
                        errors.append(f"Duplicate task id '{task['id']}' at Task #{idx}.")
                    elif not re.match(r"^T-\d{3,}$", task["id"]):
                        errors.append(f"Task #{idx} field 'id' should follow pattern 'T-###'.")
                    else:
                        task_ids.append(task["id"])
                if "title" in task and not isinstance(task["title"], str):
                    errors.append(f"Task #{idx} field 'title' must be a string.")
                elif "title" in task and not task["title"].strip():
                    errors.append(f"Task #{idx} field 'title' must be a non-empty string.")
                if "description" in task and not isinstance(task["description"], str):
                    errors.append(f"Task #{idx} field 'description' must be a string.")
                elif "description" in task and not task["description"].strip():
                    errors.append(f"Task #{idx} field 'description' must be a non-empty string.")
                if "targetFile" in task and not isinstance(task["targetFile"], str):
                    errors.append(f"Task #{idx} field 'targetFile' must be a string.")
                elif "targetFile" in task and not task["targetFile"].strip():
                    errors.append(f"Task #{idx} field 'targetFile' must be a non-empty string.")
                if "notes" in task and not isinstance(task["notes"], str):
                    errors.append(f"Task #{idx} field 'notes' must be a string.")
                if "passes" in task and not isinstance(task["passes"], bool):
                    errors.append(f"Task #{idx} field 'passes' must be true or false.")

if errors:
    print("\n".join(errors))
    raise SystemExit(1)

total_tasks = len(tasks)
complete_tasks = [t for t in tasks if isinstance(t, dict) and t.get("passes", False)]
incomplete_tasks = [t for t in tasks if isinstance(t, dict) and not t.get("passes", False)]

print(f"PLAN_TASK_COUNT={total_tasks}")
print(f"PLAN_TASK_COMPLETE={len(complete_tasks)}")
print(f"PLAN_TASK_INCOMPLETE={len(incomplete_tasks)}")
print("PLAN_INCOMPLETE_IDS=" + ",".join(
    str(task.get("id", f"#{idx + 1}"))
    for idx, task in enumerate(incomplete_tasks)
))
PY
        )
        plan_rc=$?
        if [[ $plan_rc -ne 0 ]]; then
            errors+=("$plan_report")
        else
            task_count=$(printf '%s\n' "$plan_report" | awk -F= '/^PLAN_TASK_COUNT=/{print $2}')
            complete_count=$(printf '%s\n' "$plan_report" | awk -F= '/^PLAN_TASK_COMPLETE=/{print $2}')
            incomplete_count=$(printf '%s\n' "$plan_report" | awk -F= '/^PLAN_TASK_INCOMPLETE=/{print $2}')
            incomplete_ids=$(printf '%s\n' "$plan_report" | awk -F= '/^PLAN_INCOMPLETE_IDS=/{print $2}')
        fi

        if [[ $plan_rc -eq 0 && -n "$incomplete_count" && "$incomplete_count" -gt 0 ]]; then
            errors+=("Incomplete tasks (${incomplete_count}/${task_count}): ${incomplete_ids}")
        elif [[ -n "$task_count" && "$task_count" -eq 0 ]]; then
            errors+=("plan.json has no tasks.")
        fi
    fi

    if [[ ! -f "$PROGRESS_FILE" ]] || [[ ! -s "$PROGRESS_FILE" ]]; then
        errors+=("progress.txt missing or empty.")
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        BUILD_ERRORS=$(printf '%s\n' "${errors[@]}")
        echo "FAIL: $BUILD_ERRORS"
        return 1
    fi

    echo "PASS"
    BUILD_ERRORS=""
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# VERIFY OBJECTIVE — global completion gate (key objective)
# ═══════════════════════════════════════════════════════════════════════════════
#
# Distinct from verify(): verify() asks "did this cycle's plan execute correctly?",
# verify_objective() asks "is the key objective truly met?". The loop only exits
# when BOTH return 0; if cycle verify passes but verify_objective fails, the loop
# archives the plan and re-plans the next increment toward the objective.
#
# While the LOOPRINTER_OBJECTIVE_TODO marker is present in this function body,
# the gate passes through with a stderr warning so the raw template can still
# terminate. The /looprinter-interview skill removes this guard automatically
# when generating real checks.
#
# When returning 1, populate OBJECTIVE_GAP with a description of what is missing —
# the next cycle's gen_replan_prompt() injects it into the planning context.

verify_objective() {
    echo "── VERIFY OBJECTIVE ──"

    if grep -q "LOOPRINTER_OBJECTIVE_TODO" <<< "$(declare -f verify_objective)"; then
        echo "⚠ verify_objective() not configured (LOOPRINTER_OBJECTIVE_TODO marker present)" >&2
        echo "  Loop will exit on cycle verify alone. Define checks here to enforce 'truly done'." >&2
        OBJECTIVE_GAP=""
        return 0
    fi

    # === Real objective checks go here ===
    # Pattern: collect gaps into an array, set OBJECTIVE_GAP and return 1 if any.
    #
    #   local gaps=()
    #   [[ ! -f "output/final_report.md" ]] && gaps+=("output/final_report.md missing")
    #   grep -q "PASS" output/test_summary.txt 2>/dev/null \
    #       || gaps+=("test_summary.txt does not contain PASS")
    #   if [[ ${#gaps[@]} -gt 0 ]]; then
    #       OBJECTIVE_GAP=$(printf '%s\n' "${gaps[@]}")
    #       echo "GAP: $OBJECTIVE_GAP"
    #       return 1
    #   fi

    OBJECTIVE_GAP=""
    echo "MET"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# SETUP — runs once before the loop
# ═══════════════════════════════════════════════════════════════════════════════

setup() {
    echo "── SETUP ──"
    mkdir -p "$WORK_DIR" "$RECORDS_DIR"

    RATE_LIMIT_CACHE="/tmp/.loop_rate_limit_cache_${TOOL}"
    RECORD_FILE="$RECORDS_DIR/$(date '+%Y-%m-%d-%H%M%S')-loop-$TOOL.jsonl"
    touch "$PLAN_FILE" "$PROGRESS_FILE" "$RECORD_FILE"
    if [[ ! -s "$PLAN_FILE" ]]; then
        printf '%s\n' '{"tasks":[]}' > "$PLAN_FILE"
    fi
    if [[ ! -s "$PROGRESS_FILE" ]]; then
        printf '%s\n' "Loop runner initialized at $(date '+%Y-%m-%dT%H:%M:%SZ')." > "$PROGRESS_FILE"
    fi
    echo "Record: $RECORD_FILE"

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
            --sandbox danger-full-access \
            --json \
            --model "$model" \
            2>&1 || true
    else
        claude -p \
            --model "${CLAUDE_MODEL:-opus}" \
            --effort "${CLAUDE_EFFORT:-max}" \
            --permission-mode bypassPermissions \
            --verbose --output-format stream-json \
            "$prompt" < /dev/null 2>&1 || true
    fi
}

log() { echo "$*"; }

ensure_dirs() { mkdir -p "$WORK_DIR" "$RECORDS_DIR"; }

has_incomplete_tasks() {
    [[ -f "$PLAN_FILE" ]] && $PYTHON -c "
import json, sys
d = json.load(open('$PLAN_FILE'))
tasks = d.get('tasks', [])
sys.exit(0 if any(not t.get('passes', False) for t in tasks) else 1)
" 2>/dev/null
}

all_tasks_done() {
    [[ -f "$PLAN_FILE" ]] && $PYTHON -c "
import json, sys
d = json.load(open('$PLAN_FILE'))
tasks = d.get('tasks', [])
sys.exit(0 if tasks and all(t.get('passes', False) for t in tasks) else 1)
" 2>/dev/null
}

_fetch_claude_usage() {
    local token
    token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
        | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    [[ -z "$token" ]] && return 1
    local resp
    resp=$(curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json")
    if echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
        # normalize to common schema: { pct, resets_at }
        echo "$resp" | jq '{
            pct: (.five_hour.utilization // 0 | floor),
            resets_at: (.five_hour.resets_at // null)
        }' > "$RATE_LIMIT_CACHE"
    fi
}

_fetch_codex_usage() {
    local auth_file="$HOME/.codex/auth.json"
    [[ ! -f "$auth_file" ]] && return 1
    local token
    token=$(jq -r '.tokens.access_token // empty' "$auth_file" 2>/dev/null)
    [[ -z "$token" ]] && return 1
    local resp
    resp=$(curl -s --max-time 5 "https://chatgpt.com/backend-api/wham/usage" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    echo "$resp" | jq -e '.rate_limit' >/dev/null 2>&1 || return 1

    if [[ "$TOOL" == "codex-spark" ]]; then
        # spark has its own limit in additional_rate_limits
        echo "$resp" | jq '{
            pct: ((.additional_rate_limits // [] | map(select(.metered_feature == "codex_bengalfox")) | .[0].rate_limit.primary_window.used_percent) // .rate_limit.primary_window.used_percent // 0),
            resets_at: ((.additional_rate_limits // [] | map(select(.metered_feature == "codex_bengalfox")) | .[0].rate_limit.primary_window.reset_at) // .rate_limit.primary_window.reset_at // null)
        }' > "$RATE_LIMIT_CACHE"
    else
        echo "$resp" | jq '{
            pct: (.rate_limit.primary_window.used_percent // 0),
            resets_at: (.rate_limit.primary_window.reset_at // null)
        }' > "$RATE_LIMIT_CACHE"
    fi
}

check_rate_limit() {
    [[ "$RATE_LIMIT_THRESHOLD" -eq 0 ]] && return 0

    local now
    now=$(date +%s)

    # refresh cache if stale
    if [[ ! -f "$RATE_LIMIT_CACHE" ]] || \
       [[ $(( now - $(stat -f %m "$RATE_LIMIT_CACHE" 2>/dev/null || echo 0) )) -gt $RATE_LIMIT_CACHE_TTL ]]; then
        if [[ "$TOOL" == "claude" ]]; then
            _fetch_claude_usage
        else
            _fetch_codex_usage
        fi
    fi

    if [[ -f "$RATE_LIMIT_CACHE" ]]; then
        local pct
        pct=$(jq -r '.pct // 0' "$RATE_LIMIT_CACHE" 2>/dev/null)
        local resets_at
        resets_at=$(jq -r '.resets_at // empty' "$RATE_LIMIT_CACHE" 2>/dev/null)

        # format reset time: ISO string or unix epoch
        local reset_display="$resets_at"
        if [[ "$resets_at" =~ ^[0-9]+$ ]]; then
            reset_display=$(date -r "$resets_at" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$resets_at")
        fi

        if [[ -n "$pct" && "$pct" -ge "$RATE_LIMIT_THRESHOLD" ]]; then
            log "⛔ Rate limit gate: 5h usage at ${pct}% (threshold: ${RATE_LIMIT_THRESHOLD}%)"
            [[ -n "$resets_at" ]] && log "   Resets at: $reset_display"
            log "   Stopping loop to preserve quota."
            return 1
        fi
        log "   5h usage: ${pct}% (threshold: ${RATE_LIMIT_THRESHOLD}%)"
    fi

    return 0
}

run_post_phases() {
    [[ ${#POST_PHASES[@]} -eq 0 ]] && return 0
    for phase_name in "${POST_PHASES[@]}"; do
        ensure_dirs
        log ""
        local phase_upper
        phase_upper=$(echo "$phase_name" | tr '[:lower:]' '[:upper:]')
        log "── ${phase_upper} ──"

        local prompt step=0
        local fn="gen_${phase_name}_prompt"
        if ! type "$fn" &>/dev/null; then
            log "Warning: no prompt function for phase $phase_name, skipping"
            continue
        fi
        prompt=$($fn)

        local signal_done="${phase_upper}_DONE"
        local signal_progress="${phase_upper}_PROGRESS"

        RECORD_FILE="$RECORDS_DIR/$(date '+%Y-%m-%d-%H%M%S')-${phase_name}-$TOOL.jsonl"

        while true; do
            step=$((step + 1))
            log "step $step ($(date '+%H:%M:%S'))"

            local result
            result=$(spawn_agent "$prompt")
            echo "$result" | tee -a "$RECORD_FILE"

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
    ensure_dirs

    log ""
    log "════════════════════════════════════════"
    log "  CYCLE $CYCLE"
    log "════════════════════════════════════════"

    # ── PLAN ──────────────────────────────────────────────────────────────

    if ! check_rate_limit; then
        log "Record: $RECORD_FILE"
        exit 0
    fi

    if [[ ! -f "$PLAN_FILE" ]] || ! has_incomplete_tasks; then
        log ""
        log "── PLAN (cycle $CYCLE) ──"

        if [[ -n "$BUILD_ERRORS" || -n "$OBJECTIVE_GAP" ]]; then
            PLAN_PROMPT=$(gen_replan_prompt "$CYCLE" "$BUILD_ERRORS" "$OBJECTIVE_GAP")
        else
            PLAN_PROMPT=$(gen_plan_prompt)
        fi

        OUTPUT=$(spawn_agent "$PLAN_PROMPT")
        echo "$OUTPUT" | tee -a "$RECORD_FILE"

        if [[ ! -f "$PLAN_FILE" ]]; then
            log "Error: plan phase did not produce $PLAN_FILE"
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

        if ! check_rate_limit; then
            log "Record: $RECORD_FILE"
            exit 0
        fi

        ITERATION=$((ITERATION + 1))
        log ""
        log "── build C${CYCLE}.${ITERATION} ($(date '+%H:%M:%S')) ──"

        OUTPUT=$(spawn_agent "$BUILD_PROMPT")
        echo "$OUTPUT" | tee -a "$RECORD_FILE"

        if tail -5 <<< "$OUTPUT" | grep -qi 'rate_limit\|rate limit\|"status": *429\|too many requests\|overloaded'; then
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

    # ── VERIFY (cycle-level) ──────────────────────────────────────────────

    log ""
    if verify; then
        # ── VERIFY OBJECTIVE (global) ─────────────────────────────────────
        log ""
        if verify_objective; then
            run_post_phases

            log ""
            log "════════════════════════════════════════"
            log "  DONE"
            log "════════════════════════════════════════"
            log "Record: $RECORD_FILE"
            exit 0
        fi

        log "Cycle complete but key objective not yet met. Re-planning toward objective."
        cp "$PLAN_FILE" "$RECORDS_DIR/plan_cycle_${CYCLE}_objective_gap.json" 2>/dev/null || true
        rm -f "$PLAN_FILE"
        BUILD_ERRORS=""
        # OBJECTIVE_GAP is already set by verify_objective; carry into next cycle's replan.
        continue
    fi

    # ── FAIL → archive plan, re-plan next cycle ───────────────────────────

    log "Verification failed. Re-planning..."
    cp "$PLAN_FILE" "$RECORDS_DIR/plan_cycle_${CYCLE}.json" 2>/dev/null || true
    rm -f "$PLAN_FILE"
    OBJECTIVE_GAP=""
done
