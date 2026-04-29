---
name: looprinter-interview
description: Interview the user about what a loop harness should accomplish, then generate KEY_OBJECTIVE, verify_objective(), prompt functions, and the verify() gate directly into loop.sh. Use when the user wants to configure a new loop task, or says "looprinter-interview", "new loop", or "loop interview".
allowed-tools: Read, Edit, Grep, Glob, AskUserQuestion
---

# looprinter-interview

Interviews the user, then writes the result directly into `loop.sh` — the **key objective**, its programmatic verifier, and the per-cycle prompt functions and verify gate.

**Output is code, not documents.** There is no `specs/` directory. The spec lives as executable shell functions inside `loop.sh`.

The interview is structured around a two-gate model:

- **`verify_objective()` — global gate.** Decides whether the loop is *truly done*. Pinned to `KEY_OBJECTIVE`. Activating it (removing the `LOOPRINTER_OBJECTIVE_TODO` guard) means the loop will not exit on cycle verify alone.
- **`verify()` — cycle gate.** Decides whether the current cycle's plan executed correctly. Failure triggers a re-plan with errors.

Stage 1 of the interview defines the global gate. Stages 2–4 define the cycle gate, deliverables, and build constraints.

## What Gets Generated

From a single interview session, produce these in `loop.sh`:

| Symbol | Role |
|---|---|
| `KEY_OBJECTIVE` (variable) | One-line north star. Injected into every prompt and paired with the global gate. |
| `verify_objective()` | **Global** completion gate — the loop will not exit until this returns 0. |
| `gen_plan_prompt()` | Plan schema + cycle deliverables. |
| `gen_build_prompt()` | One-task-per-iteration contract. |
| `gen_replan_prompt()` | Recovery prompt fed by cycle errors and/or objective gap. |
| `verify()` | **Cycle-level** quality gate — did this cycle's plan execute correctly? |
| `POST_PHASES` + `gen_<name>_prompt()` | Optional phases that run only after both gates pass. |

The two gates are intentionally distinct:

- `verify()` — *did this cycle's plan execute correctly?* (schema, files exist, tasks all `passes:true`)
- `verify_objective()` — *is the key objective truly met?* (domain-level completion check)

The loop only exits when **both** return 0. If `verify()` passes but `verify_objective()` fails, the engine archives the plan as `working-records/plan_cycle_<N>_objective_gap.json`, removes `output/plan.json`, and re-plans the next increment with the objective gap injected into the replan prompt.

## Interview Process

Use AskUserQuestion for each stage. Keep questions sharp — uncover what's needed to write **working shell functions**, not abstract requirements.

### Stage 1: Key Objective (the north star)

This is the most important stage. The answers here become `KEY_OBJECTIVE` and `verify_objective()` — the global gate that decides when the loop is **truly** done.

Push for two things:

**(a) One-line statement.** Concrete, observable, no fluff. Bad: "Build a great CLI." Good: "`./mycli --help` exits 0 and lists at least 5 subcommands, each documented in README.md."

**(b) How a script can detect it.** This is what `verify_objective()` will run. Reject answers that need human judgment.

```yaml
questions:
  - question: "What single sentence describes 'truly done' for this loop?"
    header: "Key Objective"
    options:
      - label: "Generate code/files"
        description: "A specific set of files exists with specific content"
      - label: "Transform existing code"
        description: "Existing files reach a measurable end state (tests pass, lint clean, etc.)"
      - label: "Analyze and produce a report"
        description: "A report file exists with required sections"
      - label: "Something else"
        description: "I'll describe it"

  - question: "How can a shell script detect that the objective is met?"
    header: "Objective Verifier"
    multiSelect: true
    options:
      - label: "File(s) exist with required content"
        description: "Check existence + grep for required patterns"
      - label: "Test suite or script exits 0"
        description: "Run a command and check the exit code"
      - label: "Specific count threshold"
        description: "e.g., at least N items in a JSON array"
      - label: "External signal file"
        description: "A specific file is written by a downstream check"
      - label: "Custom"
        description: "I'll describe the check"
```

The verifier answers must be deterministic and fast. No LLM calls. If the user can't articulate a programmatic check, push back — without one, the loop has no way to stop on real success and the brand promise of "key objective" collapses.

### Stage 2: Cycle Deliverables

What artifacts must exist for verify() to pass each cycle? (This is the *cycle-level* gate, distinct from Stage 1's *global* gate.)

```yaml
questions:
  - question: "Where should the loop write its deliverables?"
    header: "Output Location"
    options:
      - label: "output/ (gitignored sandbox)"
        description: "All artifacts go under output/ — disposable, easy to wipe between runs"
      - label: "Project root (committed)"
        description: "Artifacts land at the repo root or in real project paths (src/, docs/, etc.) — meant to be committed"
      - label: "Modify existing project files"
        description: "Loop edits files already in the repo (loop.sh, README, source files)"
      - label: "Mixed"
        description: "Some artifacts in output/, others in project root or existing files"
```

Follow up to nail down specifics:
- Exact paths (e.g., `output/report.md` vs `./report.md` vs `src/foo.ts`)
- Whether the path should be gitignored or tracked
- File formats (JSON, Markdown, shell, etc.)

This decision drives both the prompt (`targetFile` paths agents will write to) and verify() (which paths to check for existence).

### Stage 3: Cycle-Level Verification

What sanity checks should run on every cycle, distinct from the global objective? This becomes the body added to `verify()`.

This is the *per-cycle* gate. It catches plan execution problems (missing files, syntax errors, test regressions) that should fail the cycle and trigger a re-plan with errors. It is **not** where the "are we done?" question lives — that belongs in Stage 1's `verify_objective()`.

```yaml
questions:
  - question: "What should the per-cycle gate check?"
    header: "Cycle Verify"
    multiSelect: true
    options:
      - label: "Per-cycle file existence"
        description: "Files the current cycle was supposed to create/modify"
      - label: "Lint / syntax check"
        description: "Run a linter or syntax validator on changed files"
      - label: "Quick smoke tests"
        description: "Fast tests that should always pass — not the full objective verifier"
      - label: "Content sanity"
        description: "Grep for expected patterns in cycle outputs"
      - label: "Nothing extra"
        description: "Default plan-schema + progress.txt checks are enough"
```

For each selected method, drill into specifics:
- Which files? Which patterns?
- What command? What exit code = pass?

**Boundary rule**: if a check answers "are we *done*?" rather than "did this cycle execute correctly?", move it to Stage 1's `verify_objective()` instead.

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

After the interview, generate the symbols below. The engine prepends a "Key Objective" block to every prompt automatically via `_objective_block` — **do not duplicate** the objective inside the prompt bodies.

### KEY_OBJECTIVE (variable at the top of loop.sh)

```bash
KEY_OBJECTIVE="{one-line north star from Stage 1, no trailing period}"
```

If the objective is too long for one line, escalate to a function:

```bash
KEY_OBJECTIVE=""  # set blank when the function below is in use
gen_objective() {
    cat <<'EOF'
{multi-line objective}
EOF
}
```

…and update `_objective_block` to call `gen_objective` instead of expanding `$KEY_OBJECTIVE`. Default to the single-string form unless the user gave a multi-paragraph objective.

### verify_objective() — the global gate

This is the function that decides whether the loop is **truly** done. Replace the entire body (including the `LOOPRINTER_OBJECTIVE_TODO` guard) with deterministic checks derived from Stage 1's "Objective Verifier" answer.

```bash
verify_objective() {
    echo "── VERIFY OBJECTIVE ──"

    local gaps=()

    # — file existence —
    [[ ! -f "output/final_report.md" ]] && gaps+=("output/final_report.md missing")

    # — required content —
    grep -q "## Conclusion" output/final_report.md 2>/dev/null \
        || gaps+=("final_report.md missing ## Conclusion section")

    # — test suite —
    if [[ -f "output/run_tests.sh" ]]; then
        bash output/run_tests.sh >/tmp/objective_tests.log 2>&1 \
            || gaps+=("test suite failed: $(tail -1 /tmp/objective_tests.log)")
    else
        gaps+=("output/run_tests.sh missing")
    fi

    if [[ ${#gaps[@]} -gt 0 ]]; then
        OBJECTIVE_GAP=$(printf '%s\n' "${gaps[@]}")
        echo "GAP:"
        printf '  - %s\n' "${gaps[@]}"
        return 1
    fi

    OBJECTIVE_GAP=""
    echo "MET"
    return 0
}
```

Rules:
- **Removing the `LOOPRINTER_OBJECTIVE_TODO` guard activates strict enforcement.** Once removed, the loop will not exit until this function returns 0, so make sure real checks exist before deleting the guard.
- `OBJECTIVE_GAP` must be set whenever returning 1 — it feeds the next cycle's replan prompt.
- No LLM calls. No long-running operations. Same fast-and-deterministic rule as `verify()`.
- Prefer running an existing test script over hand-rolled greps when the user has tests.

### gen_plan_prompt()

```bash
gen_plan_prompt() {
    _objective_block
    cat <<'PROMPT_EOF'
You are a planning agent. Create a task plan that moves toward the Key Objective above.

## Cycle deliverables
{list of files/artifacts the current cycle should produce — distinct from objective verifier}

## Context
1. Read `output/progress.txt` first; do not duplicate work already marked as done.
2. Keep tasks minimal and directly tied to closing the gap toward the Key Objective.

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
The phase finishes when `output/plan.json` is written. No end-of-output signal is required.
PROMPT_EOF
}
```

Key: The `## Cycle deliverables` section comes from Stage 2. The Key Objective block is injected by `_objective_block` — never duplicate it inside the heredoc.

Note: Plan/replan phases finish on `output/plan.json` existence (engine-enforced). Do NOT add `<promise>PLAN_COMPLETE</promise>` to these prompts — the engine ignores it, so it only invites confusion. Only the **build** phase uses a real signal (`<promise>CYCLE_DONE</promise>`, grep'd inside the build loop), and post-phases use their own `<PHASE>_DONE` / `<PHASE>_PROGRESS` signals.

### gen_build_prompt()

```bash
gen_build_prompt() {
    _objective_block
    cat <<'PROMPT_EOF'
You are a build agent. Execute one task from the plan, advancing toward the Key Objective above.

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

Takes three args: `cycle_num`, `build_errors`, `objective_gap`. Either errors source can be empty — the engine fills only what's relevant. Use the multi-cat pattern below to render conditional sections without leaving empty headings.

```bash
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
\`\`\`
$objective_gap
\`\`\`
Plan the next increment of work to close this gap.
PROMPT_EOF
    fi

    cat <<PROMPT_EOF

## Job
1. Read \`output/progress.txt\` for context on what was already done.
2. Generate a NEW \`output/plan.json\` for cycle $cycle_num with the standard schema.
3. Address the cycle errors and/or objective gap above; do not re-do work already
   marked done in progress.txt.
4. Append cycle notes to \`output/progress.txt\`.

## Completion
The phase finishes when \`output/plan.json\` is written. No end-of-output signal is required.
PROMPT_EOF
}
```

Note: The Key Objective block is auto-injected by `_objective_block` — never paste the objective text inside the heredoc. The cycle deliverables list lives only inside `gen_plan_prompt()` (and is referenced by replan via the `objective_gap` channel when relevant).

### verify() (cycle-level gate)

**Do NOT rewrite verify() from scratch.** The existing verify() in loop.sh has a Python plan validator (~100 lines) that checks schema, field types, task IDs, and completion status. This must stay.

**Scope reminder**: verify() answers "did this cycle's plan execute correctly?" — it is *cycle-local*. Anything that answers "are we truly done?" goes in `verify_objective()` instead.

**Edit strategy**: append cycle-level deliverable checks AFTER the existing plan validation block, BEFORE the final error report. The insertion point is:

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
Key Objective:        {one sentence — north star}
Objective verifier:   {what verify_objective() will check}
Cycle deliverables:   {file list per cycle}
Cycle verify:         {what verify() will test each cycle}
Constraints:          {build rules}

loop.sh의 KEY_OBJECTIVE, verify_objective(), 그리고 프롬프트 함수 3개 + verify()를 이 내용으로 수정합니다.
LOOPRINTER_OBJECTIVE_TODO 가드는 verify_objective() 본문 교체와 함께 제거됩니다 (= 이제부터 진짜 끝날 때까지 안 멈춤).
```

Options: "진행", "수정할 부분 있음"

Only proceed to editing after confirmation. Make sure the user understands that activating `verify_objective()` means the loop will not exit on cycle verify alone — the objective gate becomes binding.

## Edit Strategy

When writing to `loop.sh`:

1. **Read** `loop.sh` first to get exact current function boundaries.
2. **Set** `KEY_OBJECTIVE` near the top (or escalate to `gen_objective` if multi-line).
3. **Replace** the entire `verify_objective()` body — including the `LOOPRINTER_OBJECTIVE_TODO` guard — with real checks. Removing the guard is what activates strict enforcement.
4. **Edit** only the prompt function bodies (preserve `_objective_block` calls) and the cycle-deliverable-check section of `verify()`.
5. **Preserve** the engine section (everything below `# ENGINE`) untouched.
6. **Preserve** the SETUP section unless the objective requires setup changes.
7. **Preserve** the Python plan validator inside `verify()` — only append deliverable checks.
8. **Clean** `output/` after writing so the next run starts fresh. Ask the user before cleaning `working-records/` — it contains persistent run history.

### Function boundaries in loop.sh

The editable region is between these markers:
```
# KEY OBJECTIVE — global completion criterion (north star)
  ← KEY_OBJECTIVE variable lives here

# PROMPTS — edit these functions to customize the harness
  ← _objective_block, gen_plan_prompt(), gen_replan_prompt(), gen_build_prompt() live here
  ← (do not edit _objective_block unless escalating to gen_objective)

# POST PHASES — define gen_<name>_prompt() functions
  ← POST_PHASES and optional phase functions live here

# VERIFY — exit 0 = pass, exit 1 = fail
  ← verify() lives here (only append cycle-level deliverable checks)

# VERIFY OBJECTIVE — global completion gate (key objective)
  ← verify_objective() lives here (replace body, remove LOOPRINTER_OBJECTIVE_TODO guard)
```

Everything below `# ENGINE` and `# SETUP` is loop machinery — do not touch.

## What NOT to Do

- Do not create `specs/` directory or spec markdown files.
- Do not modify the engine section of loop.sh.
- Do not add dependencies or external tools to loop.sh.
- Do not write prompts that reference files the agent can't see.
- Do not make `verify()` or `verify_objective()` call an LLM — both must be fast and deterministic.
- Do not put "are we done?" checks in `verify()` — those belong in `verify_objective()`.
- Do not duplicate the Key Objective text inside any prompt heredoc — `_objective_block` already injects it.
- Do not remove the `LOOPRINTER_OBJECTIVE_TODO` guard without writing real checks first — that turns the loop into an unbounded runner.
