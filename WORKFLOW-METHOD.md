# Requirements-to-Code Design Method for Cursor

## Purpose

Use requirements, concrete behavioral examples, repository evidence, technical design, executable verification and human approval to turn an initial task into validated software without treating any single artifact as the complete specification.

## Flow

```text
Task Description
        ↓
Requirements discovery
        ↓
Draft PRD
        ↕
Behavioral examples / Gherkin
        ↓
PRODUCT GATE
        ↓
Repository reconnaissance
        ↓
Architecture + Implementation Plan
        ↓
TECHNICAL DESIGN GATE
        ↓
Vertical-slice task plan
        ↓
PLAN GATE
        ↓
Tests + code one slice at a time
        ↓
HUMAN REVIEW PER SLICE
        ↓
System acceptance
        ↓
Traceability audit
```

## Task acceptance states

Implementation tasks use three visible markers so agent completion is never confused with human acceptance:

```text
[ ]  not implemented / in progress
[~]  implemented and verified, awaiting human approval
[x]  explicitly approved by the user
```

Typical lifecycle:

```text
[ ] pending
    ↓
[ ] in_progress
    ↓ implementation + verification
[~] awaiting_review
    ↓ explicit human approval
[x] accepted
```

If review requests changes, `[~]` returns to `[ ]` while the slice is reworked.

## Persistent control state

`state-[feature].md` records phase/gate state and artifact locations so a new Cursor chat can recover the workflow without guessing which approvals occurred. It is control metadata, not a source of product requirements.

## Artifact responsibilities

- **Task Description:** provenance, original goals, constraints and deliverables.
- **PRD:** consolidated product contract.
- **Gherkin Scenarios:** concrete examples validating externally observable behavior.
- **Repository Analysis:** verified technical environment and reusable existing patterns.
- **Architecture Plan:** technical structure and implementation strategy.
- **Task List:** reviewable vertical slices linked to requirements/scenarios/architecture.
- **Tests / Verification:** executable evidence.
- **Code:** implementation of the approved contracts.
- **Acceptance Report:** end-to-end evidence against the product contract.
- **Traceability Audit:** proof that requirements and implementation remain connected.

## Precedence and conflict handling

1. Original constraints must not be silently removed.
2. The PRD is the consolidated product contract.
3. Scenarios validate/illustrate the PRD; they do not override it by accident.
4. Repository evidence constrains design but does not redefine product intent.
5. Architecture must satisfy product requirements and repository constraints.
6. Tasks must operationalize approved architecture and product behavior.
7. Tests demonstrate covered contracts; passing tests do not prove unrepresented requirements.
8. Code must satisfy the approved upstream artifacts.
9. Conflicts are resolved explicitly and propagated downstream before work continues.
