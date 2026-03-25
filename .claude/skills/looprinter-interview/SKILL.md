---
name: looprinter-interview
description: Interview the user about what a loop harness should accomplish, then generate the prompt functions and verify() gate directly into loop.sh. Use when the user wants to configure a new loop task, or says "looprinter-interview", "new loop", or "loop interview".
allowed-tools: Read, Edit, Grep, Glob, AskUserQuestion
---

# looprinter-interview

Interviews the user, then writes the result directly into `loop.sh` as prompt functions and a verify gate.

**Output is code, not documents.** There is no `specs/` directory. The spec lives as executable shell functions inside `loop.sh`.

## What Gets Generated

From a single interview session, produce these functions in `loop.sh`:

| Function | Role |
|---|---|
| `gen_plan_prompt()` | Objective + plan schema. The planning agent reads this. |
| `gen_build_prompt()` | Objective context + one-task-per-iteration contract. |
| `gen_replan_prompt()` | Objective + previous errors + recovery instructions. |
| `verify()` | Programmatic quality gate. Exit 0 = pass, exit 1 = fail. |
| `POST_PHASES` + `gen_<name>_prompt()` | Optional post-verify phases (see POST_PHASES section below). |

## Interview Process

Use AskUserQuestion for each stage. Keep questions sharp — uncover what's needed to write **working shell functions**, not abstract requirements.

### Stage 1: Objective

What should the loop accomplish? Get a concrete, one-sentence goal.

```yaml
questions:
  - question: "What should this loop produce when it's done?"
    header: "End State"
    options:
      - label: "Generate code/files"
        description: "Create new files or a project in output/"
      - label: "Transform existing code"
        description: "Refactor, migrate, or modify files in the repo"
      - label: "Analyze and report"
        description: "Read code/data and produce a report in output/"
      - label: "Something else"
        description: "I'll describe it"
```

Follow up to get specifics:
- What files are created or modified?
- What does "done" look like concretely?

### Stage 2: Deliverables

What artifacts must exist for verify() to pass?

```yaml
questions:
  - question: "Where should the loop write its output?"
    header: "Output Location"
    options:
      - label: "output/ only"
        description: "All artifacts stay in the gitignored output directory"
      - label: "Project files"
        description: "Loop modifies actual project files (loop.sh, README, etc.)"
      - label: "Both"
        description: "Some in output/, some in the project"
```

Get a concrete list of expected files and their formats.

### Stage 3: Verification

What can we check programmatically? This becomes verify().

```yaml
questions:
  - question: "How should we verify the output?"
    header: "Quality Gate"
    multiSelect: true
    options:
      - label: "File existence"
        description: "Check that specific files were created"
      - label: "Run tests"
        description: "Execute a test script and check exit code"
      - label: "Content checks"
        description: "Grep for expected patterns or validate structure"
      - label: "Lint / syntax check"
        description: "Run a linter or syntax validator"
      - label: "Custom script"
        description: "I have a specific validation in mind"
```

For each selected method, drill into specifics:
- Which files? Which patterns?
- What test command?
- What constitutes failure?

### Stage 4: Constraints

```yaml
questions:
  - question: "Any constraints for the build agent?"
    header: "Build Rules"
    multiSelect: true
    options:
      - label: "Don't modify specific files"
        description: "Certain files are off-limits"
      - label: "Follow existing patterns"
        description: "Agent should study existing code first"
      - label: "Use specific tools/libraries"
        description: "Mandate certain dependencies"
      - label: "No constraints"
        description: "Agent has full freedom within output/"
```

## Writing the Functions

After the interview, generate functions following these rules:

### gen_plan_prompt()

```bash
gen_plan_prompt() {
    cat <<'PROMPT_EOF'
You are a planning agent. Create a task plan for the objective below.

## Objective
{one-paragraph objective from interview}

## Deliverables
{list of files/artifacts that must be produced}

## Context
1. Read `output/progress.txt` first; do not duplicate work already marked as done.
2. Keep tasks minimal and directly tied to the objective.

## Job
1. Read what has been completed and what remains from `output/progress.txt`.
2. Generate `output/plan.json` with exact JSON only.
3. Tasks must be ordered by execution priority.

Schema:
   ```json
   {
     "tasks": [
       { "id": "T-001", "title": "...", "description": "...",
         "targetFile": "...", "passes": false, "notes": "..." }
     ]
   }
   ```

## Rules
- targetFile must be a real file path the task creates or modifies.
- Use stable, unique IDs (T-001, T-002, ...).

## Completion
When done, output: <promise>PLAN_COMPLETE</promise>
PROMPT_EOF
}
```

Key: The `## Objective` and `## Deliverables` sections come directly from the interview. Everything else is loop machinery that stays constant.

### gen_build_prompt()

```bash
gen_build_prompt() {
    cat <<'PROMPT_EOF'
You are a build agent. Execute one task from the plan.

## Objective context
{same objective, condensed to 1-2 sentences}

## Context — read FIRST
1. `output/plan.json` — task list
2. `output/progress.txt` — cumulative findings

## Workflow
1. Read `output/plan.json` and find the first task where `passes` is `false`.
2. Execute exactly that one task — create or modify the targetFile.
3. Update only that task in `output/plan.json` to `passes: true`.
4. Append concise progress to `output/progress.txt`.
5. If ALL tasks now have `passes: true`, output `<promise>CYCLE_DONE</promise>`.
6. Otherwise stop after this one task.

## Rules
- ONE task per iteration.
- Actually create/modify the target files — do not just toggle passes.
{constraints from interview, or remove this line if none}

## Completion
If ALL tasks have `passes: true`, output: <promise>CYCLE_DONE</promise>
PROMPT_EOF
}
```

### gen_replan_prompt()

Uses shell variable interpolation (no `'PROMPT_EOF'` — note the missing quotes) so `$cycle_num` and `$build_errors` expand at runtime.

```bash
gen_replan_prompt() {
    local cycle_num="$1"
    local build_errors="$2"

    cat <<PROMPT_EOF
You are a planning agent running cycle $cycle_num. The previous cycle had issues.

## Objective (unchanged)
{same objective as gen_plan_prompt}

## Deliverables (unchanged)
{same deliverables list}

## Previous errors
\`\`\`
$build_errors
\`\`\`

## Job
1. Read \`output/progress.txt\` for context on what was already done
2. Generate a NEW \`output/plan.json\` for cycle $cycle_num with the standard schema
3. Fix the issues from the previous cycle
4. Append cycle notes to \`output/progress.txt\`

## Rules
- targetFile must be a real file path the task creates or modifies.
- Use stable, unique IDs (T-001, T-002, ...).
- Tasks already completed (visible in progress.txt) should have passes: true.

## Completion
When done, output: <promise>PLAN_COMPLETE</promise>
PROMPT_EOF
}
```

Note: `## Objective` and `## Deliverables` must be identical to gen_plan_prompt(). Copy them verbatim.

### verify()

**Do NOT rewrite verify() from scratch.** The existing verify() in loop.sh has a Python plan validator (~100 lines) that checks schema, field types, task IDs, and completion status. This must stay.

**Edit strategy**: append deliverable checks AFTER the existing plan validation block, BEFORE the final error report. The insertion point is:

```bash
    # ← existing plan validation ends here

    if [[ ! -f "$PROGRESS_FILE" ]] || [[ ! -s "$PROGRESS_FILE" ]]; then
        errors+=("progress.txt missing or empty.")
    fi

    # === DELIVERABLE CHECKS (insert here) ===

    if [[ ${#errors[@]} -gt 0 ]]; then
```

What to insert depends on the interview:

**File existence** (Stage 2):
```bash
    [[ ! -f "output/myfile.sh" ]] && errors+=("myfile.sh not created.")
```

**Executable check** (if the deliverable is a script):
```bash
    [[ ! -x "output/myfile.sh" ]] && errors+=("myfile.sh not executable.")
```

**Content pattern** (Stage 3):
```bash
    grep -q "expected_pattern" "output/file.txt" 2>/dev/null || errors+=("Missing expected pattern in file.txt.")
```

**Test execution** (Stage 3):
```bash
    if [[ -f "output/test.sh" ]]; then
        local test_output
        test_output=$(bash output/test.sh 2>&1) || errors+=("Tests failed: $test_output")
    fi
```

**Lint/syntax** (Stage 3):
```bash
    bash -n "output/myfile.sh" 2>/dev/null || errors+=("myfile.sh has syntax errors.")
```

Combine as needed. The key principle: **keep everything above the insertion point unchanged**.

### POST_PHASES (optional)

If the interview reveals a need for post-verify phases (e.g., E2E testing, deployment, reporting), configure them:

```bash
POST_PHASES=("e2e" "report")

gen_e2e_prompt() {
    cat <<'PROMPT_EOF'
You are an E2E testing agent. {describe what to test}

## Completion
If all tests pass, output: <promise>E2E_DONE</promise>
If tests fail, describe what failed and output: <promise>E2E_PROGRESS</promise>
PROMPT_EOF
}
```

**Signal naming convention** (critical):
- Phase name in `POST_PHASES` array must be lowercase: `"e2e"`, `"report"`
- Prompt function must be named `gen_<name>_prompt()`: `gen_e2e_prompt()`, `gen_report_prompt()`
- Done signal is `<promise>PHASENAME_DONE</promise>` (UPPERCASED): `E2E_DONE`, `REPORT_DONE`
- Progress signal is `<promise>PHASENAME_PROGRESS</promise>`: `E2E_PROGRESS`, `REPORT_PROGRESS`
- The engine uppercases the phase name automatically to construct signal names

**Caveats**:
- Each post-phase runs in a `while true` loop until the done signal is received. Consider adding a max-step guard in the prompt.
- Post-phases use `spawn_agent()` so the agent has full tool access (including MCP tools in claude mode).
- codex sandbox may block network operations (port binding, etc.) — use claude mode for phases that need network access.

## Post-Interview: Confirm Before Editing

After all interview stages, present a summary using AskUserQuestion:

```
Objective: {one sentence}
Deliverables: {file list}
Verify checks: {what verify() will test}
Constraints: {build rules}

loop.sh 함수 4개를 이 내용으로 수정합니다.
```

Options: "진행", "수정할 부분 있음"

Only proceed to editing after confirmation.

## Edit Strategy

When writing to `loop.sh`:

1. **Read** `loop.sh` first to get exact current function boundaries.
2. **Edit** only the prompt function bodies and the deliverable-check section of verify().
3. **Preserve** the engine section (everything below `# ENGINE`) untouched.
4. **Preserve** the SETUP section unless the objective requires setup changes.
5. **Preserve** the Python plan validator inside verify() — only append deliverable checks.
6. **Clean** `output/` after writing so the next run starts fresh. Ask the user before cleaning `working-records/` — it contains persistent run history.

### Function boundaries in loop.sh

The editable region is between these markers:
```
# PROMPTS — edit these functions to customize the harness
  ← gen_plan_prompt(), gen_replan_prompt(), gen_build_prompt() live here

# POST PHASES — define gen_<name>_prompt() functions
  ← POST_PHASES and optional phase functions live here

# VERIFY — exit 0 = pass, exit 1 = fail
  ← verify() lives here (only append deliverable checks)
```

Everything below `# ENGINE` and `# SETUP` is loop machinery — do not touch.

## What NOT to Do

- Do not create `specs/` directory or spec markdown files.
- Do not modify the engine section of loop.sh.
- Do not add dependencies or external tools to loop.sh.
- Do not write prompts that reference files the agent can't see.
- Do not make verify() call an LLM — it must be fast and deterministic.
