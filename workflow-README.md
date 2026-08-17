# Cursor Requirements-to-Code Workflow

A human-gated workflow for turning a feature request into validated code without allowing the agent to silently reinterpret requirements or autonomously run through a large implementation.

The workflow combines:

- preserved original task intent;
- requirements discovery and a PRD;
- behavior examples / Gherkin as a requirements-validation tool;
- repository reconnaissance before technical design;
- an explicit architecture and implementation plan;
- vertical-slice task decomposition;
- test-first / contract-first implementation where appropriate;
- human approval after each meaningful slice;
- system acceptance and traceability auditing.

## Core principle

No single generated artifact is the complete specification.

```text
Original Task
    ↓
PRD ↔ Behavioral Scenarios
    ↓
Repository Evidence
    ↓
Architecture / Plan
    ↓
Vertical-Slice Tasks
    ↓
Tests + Code
    ↓
System Acceptance
```

Later artifacts may clarify earlier ones, but they must never silently weaken or contradict them.

---

## Installation

Copy `.cursor/rules/*.mdc` into your project's `.cursor/rules/` directory.

Generated feature artifacts are written under `/tasks/`. Each feature also gets `tasks/state-[feature].md`, which is the durable workflow state and records approval gates so progress does not depend on chat memory.

Recommended project layout:

```text
project/
├── .cursor/
│   └── rules/
│       ├── start-feature.mdc
│       ├── refine-scenarios.mdc
│       ├── analyze-repository.mdc
│       ├── create-architecture-plan.mdc
│       ├── generate-tasks.mdc
│       ├── process-task-list.mdc
│       ├── system-acceptance.mdc
│       └── traceability-audit.mdc
├── tasks/
└── ...
```

---

# Workflow


## Persistent workflow state

Every feature maintains:

```text
tasks/state-[feature].md
```

It records only workflow control state, not product truth:

```text
Current phase
Product Gate: pending | approved
Technical Design Gate: pending | approved
Task Plan Gate: pending | approved
System Acceptance: pending | pass | fail | incomplete
Traceability Audit: pending | pass | gaps
Artifact paths
Approval/change history
```

A gate may be changed to `approved` only after an explicit user approval. Downstream rules must read this file instead of assuming an approval from the mere existence of an artifact.

---


## Phase 1 — Capture intent and create the PRD

Start with:

```text
Use @start-feature.mdc

Feature/task:
[describe what you want]
```

The agent must:

1. preserve the original request in `tasks/td-[feature].md`;
2. initialize `tasks/state-[feature].md`;
3. ask clarification questions instead of guessing important product behavior;
4. create `tasks/prd-[feature].md` with traceable requirement IDs;
5. stop without implementing anything.

Typical identifiers:

```text
FR-01   Functional requirement
NFR-01  Non-functional requirement
BR-01   Business rule
AC-01   Acceptance criterion
```

The Task Description is provenance. The PRD is the consolidated product contract. Neither is source code design.

---

## Phase 2 — Challenge the requirements with scenarios

Run:

```text
Use @refine-scenarios.mdc with
@tasks/td-[feature].md
@tasks/prd-[feature].md
```

The agent derives scenarios for behavior that is important, risky, ambiguous, stateful, boundary-sensitive, or error-prone.

Example:

```gherkin
@GS-03 @FR-07 @BR-02
Scenario: Retry an upload after a transient network failure
  Given ...
  When ...
  Then ...
```

The purpose is not to translate the whole PRD into Gherkin mechanically. The scenarios are probes:

```text
PRD rule
  ↓
Concrete example
  ↓
Ambiguity or contradiction discovered
  ↓
Clarification
  ↓
PRD + scenarios updated together
```

The output is:

```text
tasks/scenarios-[feature].feature
```

The agent must stop at a **Product Gate** and obtain explicit approval before technical design begins.

---

## Phase 3 — Analyze the existing repository

For an existing codebase, run:

```text
Use @analyze-repository.mdc for [feature]
using @tasks/prd-[feature].md and @tasks/scenarios-[feature].feature
```

This phase is mandatory for brownfield work.

The agent inspects only enough of the repository to understand the implementation context, including where relevant:

- project instructions and Cursor rules;
- architecture and directory structure;
- package/dependency manifests;
- existing implementations of similar behavior;
- API conventions;
- state-management conventions;
- persistence and migrations;
- test framework and test layout;
- lint/typecheck/build commands;
- shared UI/design-system components;
- error-handling and observability patterns.

Output:

```text
tasks/repo-analysis-[feature].md
```

The report distinguishes **verified repository facts** from **inferences** and **unknowns**.

For a greenfield project, the same phase records the current project baseline and explicitly says which conventions do not yet exist.

---

## Phase 4 — Create and approve the technical design

Run:

```text
Use @create-architecture-plan.mdc with
@tasks/td-[feature].md
@tasks/prd-[feature].md
@tasks/scenarios-[feature].feature
@tasks/repo-analysis-[feature].md
```

The agent must not simply produce a design and proceed.

For consequential choices with multiple reasonable options, it must:

1. explain the alternatives;
2. state the trade-offs;
3. give its recommendation;
4. ask the user to choose or approve.

After decisions are resolved, it creates:

```text
tasks/architecture-[feature].md
```

Architecture identifiers use:

```text
ARCH-01
ARCH-02
...
```

The plan covers relevant system boundaries, components, interfaces, data flow, persistence, external dependencies, failure handling, security, compatibility/migration concerns, and verification strategy.

Every important PRD requirement/scenario must map to the plan, or explicitly state why no architectural work is needed.

This phase ends at a **Technical Design Gate**. No implementation begins until the user approves the design.

---

## Phase 5 — Generate vertical-slice tasks

Run:

```text
Use @generate-tasks.mdc with
@tasks/prd-[feature].md
@tasks/scenarios-[feature].feature
@tasks/architecture-[feature].md
@tasks/repo-analysis-[feature].md
```

The agent first proposes only the high-level vertical slices.

A good slice is a coherent, independently reviewable behavior such as:

```text
TASK-03 — Allow a user to retry a failed upload
```

A poor slice is a mechanical file operation such as:

```text
Create component
Create hook
Add import
Add handler
```

After the user approves the slice structure, the agent writes:

```text
tasks/tasks-[feature].md
```

Each task contains:

```text
TASK-ID
Behavior / outcome
Requirements covered
Scenarios covered
Architecture items used
Acceptance conditions
Verification commands / checks
Expected files or areas
Status
```

Test commands must be discovered from the repository. The workflow never assumes Jest, Vitest, pytest, Playwright, etc.

---

## Phase 6 — Implement one vertical slice at a time

Start implementation with:

```text
Use @process-task-list.mdc with @tasks/tasks-[feature].md
Start TASK-01.
```

For each slice, the agent follows:

```text
Read relevant upstream contracts
        ↓
Acceptance-test skeleton / executable contract where useful
        ↓
Unit + integration tests where useful
        ↓
Implementation
        ↓
Relevant automated verification
        ↓
Inspect failures and refine
        ↓
Update task evidence
        ↓
AWAIT USER REVIEW
```

### Important task-state rule

The task list uses a three-state visual marker:

```text
[ ]  not implemented / currently being implemented
[~]  implemented and agent-verified, awaiting human approval
[x]  explicitly approved/accepted by the user
```

`[~]` is an intentional workflow marker rather than a standard Markdown task-checkbox state. Even if a Markdown renderer displays it as plain text, the agent must preserve its meaning.

`[x]` therefore never means merely "the agent wrote the code."

The detailed task status remains:

```text
pending
in_progress
awaiting_review
accepted
blocked
```

Typical mapping:

```text
[ ] + pending
[ ] + in_progress
[~] + awaiting_review
[x] + accepted
[ ] + blocked
```

When implementation and verification finish:

```text
[ ] → [~]
Status: in_progress → awaiting_review
```

The agent reports:

- what changed;
- files changed;
- tests/checks run and results;
- any deviations or assumptions;
- any risks still present.

It then asks:

```text
Approve this slice and continue to the next one?
```

Only after explicit approval does it change:

```text
[~] → [x]
Status: awaiting_review → accepted
```

If the user requests changes instead, the task returns to active work:

```text
[~] → [ ]
Status: awaiting_review → in_progress
```

---

# Change control during implementation

New information is inevitable. It must not silently mutate the project.

### Level 1 — implementation detail

If the change stays inside the approved architecture and does not affect public behavior, interfaces, schemas, dependencies, security posture, or scope, the agent may handle it inside the current task and record it.

### Level 2 — technical design change

If implementation reveals that an approved architectural decision should change, the agent must stop, explain the issue, propose the architecture update, and obtain approval before continuing.

### Level 3 — product/requirements change

If behavior, scope, a business rule, an acceptance criterion, or a non-functional requirement must change, the agent must return to the PRD/scenario layer, propose the change, obtain approval, update the affected artifacts, and then propagate the change downstream.

A newly discovered task may be added automatically only when it is clearly necessary to fulfill already-approved scope and does not introduce a Level 2 or Level 3 change. Otherwise it must be proposed first.

---

## Phase 7 — System acceptance

When all implementation tasks are accepted, run:

```text
Use @system-acceptance.mdc with the artifacts for [feature].
```

The agent verifies the delivered system against:

- original Task Description;
- PRD functional requirements;
- business rules;
- acceptance criteria;
- Gherkin scenarios;
- non-functional requirements;
- cross-feature interactions;
- architecture constraints;
- required build/deployment/publication deliverables.

Output:

```text
tasks/acceptance-[feature].md
```

Each item is marked:

```text
PASS
FAIL
NOT VERIFIED
NOT APPLICABLE
```

with evidence.

A task list being fully checked is not evidence of system acceptance.

If acceptance finds a defect or missing requirement, the agent creates/proposes corrective tasks and returns to implementation.

---

## Phase 8 — Traceability audit

Finally run:

```text
Use @traceability-audit.mdc with the artifacts for [feature].
```

Output:

```text
tasks/traceability-[feature].md
```

The audit looks for:

- original constraints omitted from the PRD;
- PRD requirements with no implementation task;
- behavior requirements with no scenario where one is warranted;
- scenarios with no acceptance-test evidence;
- architecture items with no implementing task;
- accepted tasks with no requirement/architecture justification;
- relevant code changes that are unaccounted for;
- non-functional requirements that were never verified.

The desired chain is:

```text
Task Description
    ↓
PRD requirement
    ↓
Scenario (when behavioral)
    ↓
Architecture decision / implementation path
    ↓
Vertical-slice task
    ↓
Test / verification evidence
    ↓
Delivered code
```

---

# Artifact precedence

When artifacts conflict, do not guess which one "wins" and continue.

Use this policy:

1. The original Task Description preserves provenance and external constraints.
2. The PRD is the consolidated product contract.
3. Gherkin scenarios exemplify and validate observable PRD behavior; they do not silently override the PRD.
4. Repository analysis describes the technical environment; it does not override product requirements.
5. Architecture must satisfy the approved product contract and repository constraints.
6. Tasks operationalize the approved architecture and requirements.
7. Tests provide executable evidence; passing tests do not erase uncovered requirements.
8. Code must satisfy the validated upstream contracts.

Any real conflict is resolved explicitly and then propagated to downstream artifacts.

---

# Suggested operating style

Use the full workflow for:

- new features;
- significant behavioral changes;
- multi-module changes;
- migrations;
- security-sensitive work;
- work where correctness matters more than speed.

For a trivial local bug or mechanical refactor, you may intentionally use a lighter path, but explicitly state which phases are being skipped and why. Do not silently skip product clarification when behavior is ambiguous.

---

# Recommended invocation sequence

```text
1. @start-feature.mdc
2. @refine-scenarios.mdc
   → approve Product Gate
3. @analyze-repository.mdc
4. @create-architecture-plan.mdc
   → approve Technical Design Gate
5. @generate-tasks.mdc
   → approve task slices
6. @process-task-list.mdc
   → review/approve each vertical slice
7. @system-acceptance.mdc
8. @traceability-audit.mdc
```
