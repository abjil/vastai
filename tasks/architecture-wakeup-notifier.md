# Architecture and Implementation Plan: Vast.ai wakeup notifier and training runner

Technical Design Gate: **approved** 2026-08-17. This plan does not change the approved PRD.

User decisions 2026-08-17:

1. Orchestrator env requires `VAST_INSTANCE_ID` next to `VAST_API_KEY`.
2. New `bin/start.sh` is the host-start orchestrator; nag `wakeup.sh` / `ack.sh` are not the start path.
3. `onstart.sh` locks, `nohup`s `start.sh`, and returns (same process shape as today’s nag daemon).

## 1. Inputs and Approved Product Contract

- Task Description: `td-wakeup-notifier.md`
- PRD: `prd-wakeup-notifier.md` (Product Gate approved)
- Scenarios: `scenarios-wakeup-notifier.feature` (`SC-01`–`SC-24`)
- Repository analysis: `repo-analysis-wakeup-notifier.md`
- Prior design (current code): `ARCHITECTURE.md` — in-container, file state,
  independent channel adapters, session identity ≠ process identity, Bash +
  Python 3.9 stdlib, pin this repo, background the long-running job

v1 product: one-shot lifecycle notices, clone/update one public training repo,
run `train.sh`, stop the instance unless `KEEP_ALIVE` / `KEEP_ALIVE_PERMANENT`.
No nag-until-ACK, no `ack.sh` as the operator ACK.

## 2. Repository Constraints

From `ARCHITECTURE.md` and repo analysis (must keep):

- No pip, no nested Docker, no database, no web UI.
- Env files are data (`envutil.py`), not sourced shell.
- Channel adapters: env file + rendered plaintext; independent timeouts.
- `session_id.py` lock / verified PID / do not kill unrelated processes.
- `pin_revision.sh` + required `WAKEUP_REVISION` on production onstart.
- CI: `bash bin/selftest.sh`, Python 3.9/3.10, ShellCheck, no credentials,
  dummy HTTP(S) proxies.
- Long work is **not** the onstart foreground process (`nohup wakeup.sh` today).

Product overrides of current code:

- Default path `/workspace/vastai` (was `/workspace/vastai-wakeup`).
- Env mode broader than `0600`: **warn and continue** (code today **rejects**).
- Host start is `start.sh`, not the nag loop.

## 3. Proposed System Behavior and Boundaries

```text
Vast.ai control plane
  │ starts instance, invokes onstart
  ▼
container (NGC PyTorch + Jupyter overlay)
  ├── templates/onstart.vastai.sh
  │     └── pin_revision.sh (this repo only)
  │           └── bin/onstart.sh
  │                 └── nohup bin/start.sh
  ├── /workspace/vastai/          this project + wakeup.env + train.env
  ├── /workspace/<repo>/          public training checkout + train.sh
  ├── /workspace/KEEP_ALIVE
  ├── /workspace/KEEP_ALIVE_PERMANENT
  └── outbound
        ├── Telegram / SMTP / Twilio
        ├── git (HTTPS, public)
        ├── optional IP lookup
        └── Vast.ai API stop (not destroy)
```

**In scope of this project:** install wiring, start orchestration, notices,
git fetch of the **training** URL, launching `train.sh`, keep flags, stop.

**Out of scope:** training-repo internals, Vast.ai billing, Jupyter UI,
destroy, private git, nag ACK.

`install.sh` does not call the Vast.ai control-plane API to rewrite the
onstart field. It prepares local files, enables the SSH keep hook, and
prints the onstart snippet for the operator to paste (same operational
model as `ARCHITECTURE.md`).

## 4. Architectural Decisions

- **ARCH-01:** Remain a single-operator in-container file-based utility
  (no new runtime stack).
  - Rationale: Satisfies NG-01/NG-06 and current `ARCHITECTURE.md`.
  - Alternatives considered: nested Docker / extra Python packages — rejected.
  - Requirements: G-05, NG-01, NG-06, NFR-10.

- **ARCH-02:** `bin/start.sh` is the v1 orchestrator (one-shot sequence).
  Channel senders stay. Nag `wakeup.sh` is not launched from onstart.
  `ack.sh` is not a v1 operator tool.
  - Rationale: User choice (2A). Matches FR-36 “separate script” from
    `install.sh`. Avoids stretching the nag loop.
  - Alternatives considered: rewrite `wakeup.sh` in place (2B) — rejected.
  - Requirements: G-02, FR-26, FR-36, FR-30, NG-11, SC-01, SC-02.

- **ARCH-03:** `onstart.sh` validates, acquires the existing startup lock,
  ensures one `start.sh` for this session, `nohup`s it, confirms PID
  publication, returns.
  - Rationale: User choice (3A). Same shape as `ARCHITECTURE.md` startup
    sequence, with the daemon script path changed to `start.sh`.
  - Alternatives considered: block in onstart until train+stop (3B) — rejected.
  - Requirements: FR-01, FR-03, NFR-04, E-06, SC-22.

- **ARCH-04:** Stop uses `VAST_API_KEY` and **required** `VAST_INSTANCE_ID`
  in the orchestrator env file. Missing either fails before host-up.
  Stop is HTTP PUT `state=stopped` (same shape as
  `deploy_vastai_wikitext_small.sh`). Never destroy. Implementation must
  **not** put the API key on a process command line (`ps`); use Python
  stdlib HTTPS like Telegram, not `curl -H Authorization: Bearer …`.
  - Rationale: User choice (1A). Testable. Avoids secret-in-argv (NFR /
    SECURITY.md).
  - Alternatives considered: discover instance id (1B); list-and-pick (1C).
  - Requirements: FR-02, FR-35, AC-06, AC-17, SC-01, SC-05.

- **ARCH-05:** Two env files, both parsed by `envutil.py` (data, not shell).
  1. `wakeup.env` — channels, timeouts, `VAST_API_KEY`, `VAST_INSTANCE_ID`,
     operational paths.
  2. `train.env` — public git URL only (`TRAIN_REPO_URL`).
  Precedence unchanged: CLI > documented non-secret process env > file >
  defaults. Secrets stay file-only. Loose mode: **warn and continue**.
  - Rationale: FR-18, FR-19, FR-20, OQ-02/NFR-07. Reuse parser.
  - Alternatives considered: one file; `source` env — rejected.
  - Requirements: FR-18–20, NFR-07, NFR-12, SC-03–SC-06.

- **ARCH-06:** Default `DATA_DIR` / install path `/workspace/vastai`.
  `INSTALL_DIR` in the onstart template defaults there. FR-20 overrides
  still allow another path.
  - Rationale: PRD FR-24 vs current `/workspace/vastai-wakeup`.
  - Alternatives considered: keep old directory name — rejected by Product Gate.
  - Requirements: FR-24, AC-14, SC-01.

- **ARCH-07:** Lifecycle notice helper renders templates and calls existing
  `send_email_from_template.sh` / `send_telegram.sh` / `send_sms.sh`
  independently. One attempt per event per start (not a nag). Channel
  failure is logged; sequence continues.
  - Rationale: Reuse adapters from `ARCHITECTURE.md`.
  - Alternatives considered: new HTTP client — rejected.
  - Requirements: FR-07, FR-09, FR-31, FR-32, BR-04, BR-11, NFR-03, SC-01, SC-07.

- **ARCH-08:** Training git: clone to `/workspace/<repo-name>` if missing;
  else `git fetch` + `git reset --hard` to the remote default branch.
  **Do not** `git clean`. No tokens in the URL.
  - Rationale: Discard tracked edits, keep untracked files (SC-12).
  - Alternatives considered: `git pull --ff-only` (deploy script) — rejected.
  - Requirements: FR-27, FR-28, AC-15, AC-24, SC-11, SC-12, SC-15.

- **ARCH-09:** Keep flags are empty files at `/workspace/KEEP_ALIVE` and
  `/workspace/KEEP_ALIVE_PERMANENT`. On a **new container session**
  (new `session.id`), delete leftover `KEEP_ALIVE` only; never delete
  `KEEP_ALIVE_PERMANENT`. Same-session re-onstart must not delete a
  `KEEP_ALIVE` created during this start (e.g. SSH). Stop decision reads
  both files after training ends.
  - Rationale: Empty file (PRD); leftover vs this-start; reuse session
    identity from `ARCHITECTURE.md` instead of stamping the flag.
  - Alternatives considered: session token inside KEEP_ALIVE — conflicts
    with “empty file is enough”.
  - Requirements: FR-34, E-04, AC-18, AC-23, SC-16–SC-20.

- **ARCH-10:** SSH keep hook reuses the `install-login-ack.sh` bashrc
  pattern (markers, `SSH_CONNECTION`, `~/.no_login_ack`, uninstall).
  `install.sh` **enables** it. Action: create empty `/workspace/KEEP_ALIVE`,
  not `ack.sh`. Never create `KEEP_ALIVE_PERMANENT`.
  - Rationale: FR-36, FR-39, BR-14, SC-17, SC-21.
  - Alternatives considered: keep calling `ack.sh` — rejected (NG-11).

- **ARCH-11:** `train.sh` is executed at the training-repo root with no extra
  arguments, after a successful clone/update. Missing/non-runnable → no
  training-started notice; training-stopped (did not run); then stop rule.
  Non-zero exit → training-stopped marked failed; then stop rule.
  - Rationale: FR-29, FR-32, FR-37, E-10, E-11, SC-13, SC-14.
  - Alternatives considered: wrap with extra args / timeout watchdog — not
    in PRD; do not add a product timeout unless later specified.

- **ARCH-12:** Pin **this** project with `WAKEUP_REVISION` on production
  onstart (`pin_revision.sh`). Training repo is **not** pinned to a
  commit in v1 (URL + default branch only).
  - Rationale: FR-23, NFR-09, current onstart template.
  - Alternatives considered: pin training SHA in env — not in PRD.

- **ARCH-13:** `--test-channels` / `--dry-run` live on `start.sh` (or a
  thin wrapper that does not import the nag loop). `--test-channels`: one
  live send per configured channel, then exit; no git, no `train.sh`, no
  stop. `--dry-run`: validate + render, no live send, no git mutate, no
  train, no stop. `--once` is the default `start.sh` behavior (full
  sequence once); keep the flag as an alias so FR-21 stays true.
  - Rationale: FR-21, AC-07, SC-08.
  - Alternatives considered: leave flags only on `wakeup.sh` — would keep
    a nag entry point as the documented test tool.

- **ARCH-14:** Public-IP lookup stays in fact collection, off by default,
  cached per session, failure → `unknown`, no abort (`ARCHITECTURE.md`).
  - Requirements: FR-25, NFR-20, AC-12, SC-09.

- **ARCH-15:** `deploy_vastai_wikitext_small.sh` is **not** the v1 start
  path. Stop URL/method is the only reuse. Script may remain in the tree
  as an unrelated operator helper until a later cleanup; it must not be
  invoked by onstart or `install.sh`.
  - Rationale: pip, `git pull --ff-only`, sourced `.env`, hardcoded repo.
  - Requirements: NG-06, ARCH-08.

- **ARCH-16:** Logging: `start.sh` owns application log writes; onstart
  only logs bootstrap. Same rotation (`LOG_MAX_BYTES` / backups). UTC
  one-record-per-event. Distinct event names in the log (host_up,
  repo_update, training_started, training_stopped, shutting_down).
  - Rationale: `ARCHITECTURE.md` anti-duplication via tee.
  - Requirements: NFR-05, NFR-15, NFR-16.

## 5. Components and Responsibilities

| Component | Responsibility |
| --- | --- |
| `install.sh` | First-time only: chmod, env examples, enable SSH keep hook, print onstart snippet. No clone/train/stop. |
| `templates/onstart.vastai.sh` | Require `WAKEUP_REVISION`, pin this checkout, `exec` `onstart.sh`. Default `INSTALL_DIR=/workspace/vastai`. |
| `bin/pin_revision.sh` | Unchanged: fetch/detach this repo or fail closed. |
| `bin/onstart.sh` | Validate both env files + channels + API key + instance id; lock; one `start.sh`; `nohup`; PID verify. |
| `bin/start.sh` | Session leftover `KEEP_ALIVE` cleanup; one-shot sequence; git; `train.sh`; stop decision. |
| `bin/notify.sh` (or equivalent function in `start.sh`) | Render event templates; invoke three senders independently. |
| `bin/stop_instance.py` (stdlib HTTPS) | PUT stop using key+id from parsed config; no key on argv. |
| `bin/send_*.sh` | Unchanged adapters. |
| `bin/envutil.py` | Parser for both files; warn on loose mode; new keys allowlisted; `VAST_API_KEY` in `SECRET_KEYS`. |
| `bin/session_id.py` | Unchanged primitives; daemon script path = `start.sh`. |
| `bin/install-login-ack.sh` | Repurposed or replaced: touch `KEEP_ALIVE`; same disable/uninstall. |
| `bin/wakeup.sh` / `bin/ack.sh` | Not on the v1 host-start path. May remain in tree during migration but must not be called by onstart/`install.sh`. |
| `bin/selftest.sh` | Entry for offline tests including new mocks. |
| `train.sh` | **Not this repo.** Owned by the training checkout. |

## 6. Interfaces and Data Contracts

### Orchestrator env (`wakeup.env`)

Existing channel keys plus:

- `VAST_API_KEY` (secret, file-only)
- `VAST_INSTANCE_ID` (required for normal start; not a secret of the same class but not logged as a credential dump)

### Training env (`train.env`)

- `TRAIN_REPO_URL` — https git URL, public only

### Keep flags

- `/workspace/KEEP_ALIVE` — empty; this session after new-session cleanup
- `/workspace/KEEP_ALIVE_PERMANENT` — empty; survives sessions

### Notices

Events: `host_up`, `repo_update`, `training_started`, `training_stopped`,
`shutting_down`. Templates under `templates/` per event and channel,
`{{PLACEHOLDER}}` via `render_template.py`. Training-stopped must be able
to show success / failed / did-not-run without requiring exact prose in
tests.

### Stop API

- Method/URL as in `deploy_vastai_wikitext_small.sh`: PUT
  `https://console.vast.ai/api/v0/instances/{id}/` with JSON
  `{"state": "stopped"}` and bearer token, TLS verify on.
- Timeout: `CHANNEL_TIMEOUT_SEC` or a dedicated positive integer default
  (finite, NFR-02).
- Do not send `destroy`.

### Git

- Destination: `/workspace/` + basename of URL (strip `.git`).
- Default branch of `origin`.
- Update: fetch + `reset --hard origin/<default>`; no `clean`.

### CLI (`start.sh`)

- `--test-channels`, `--dry-run`, `--once` (alias of full one-shot run)

## 7. Data Flow / State Flow

```text
install.sh (once)
  → env examples, SSH hook, printed onstart snippet

host start
  → onstart.vastai.sh (pin this repo)
  → onstart.sh
       validate wakeup.env + train.env
       warn if mode > 0600
       acquire lock
       if start.sh already running this session → exit 0
       if stale/other-session verified process → stop only that process
       nohup start.sh
       wait until PID file matches
       release lock; return

start.sh
  → ensure session.id
  → if this is a new session: rm KEEP_ALIVE (not PERMANENT)
  → notify host_up
  → clone or update training repo → notify repo_update
       on git fail: notify failure; skip training-started;
                    notify training_stopped (did not run); goto stop_decision
  → if no runnable train.sh: notify training_stopped (did not run); goto stop_decision
  → notify training_started
  → run ./train.sh (no args)
  → notify training_stopped (ok or failed)
  → stop_decision:
       if KEEP_ALIVE or KEEP_ALIVE_PERMANENT exists → exit 0 (no shutting_down)
       else notify shutting_down; stop API; exit
```

SSH during `train.sh`: bashrc creates `KEEP_ALIVE` → stop_decision skips stop.

## 8. Persistence / Migration Plan

New/changed files under `/workspace/vastai/` (checkout + env + logs +
`start.pid` / `start.lock` or reused `wakeup.pid` **only if** verify-daemon
uses the `start.sh` script path).

Keep flags live at `/workspace/` so they are independent of `DATA_DIR`
overrides.

Migration from `/workspace/vastai-wakeup`:

- Document clone path change; do not auto-migrate secrets.
- Onstart template default `INSTALL_DIR` changes; operators must update
  the Vast.ai onstart field.
- Leftover `ACK` / nag PID: onstart must not start `wakeup.sh`. A leftover
  nag daemon is not the v1 start path; verified stop may target `start.sh`
  only. Operators should not run both.

`.gitignore`: add `train.env`, `KEEP_ALIVE` is under `/workspace` (not in
this git tree). Ignore `train.env` in the project if copied beside checkout.

No database migrations.

## 9. Failure, Retry and Error Handling

- Config missing channel / URL / API key / instance id / bad numbers: fail
  before host-up (no `start.sh` sequence).
- Loose env permissions: log warning; continue.
- Channel send failure: log sanitized detail; continue sequence.
- Git failure: notices as in flow; skip train; stop_decision.
- `train.sh` missing / non-zero: notices as specified; stop_decision.
- Stop API failure: log; do not retry unbounded; instance may keep billing
  (BR-01). Finite timeout. No destroy fallback.
- Overlapping start: second onstart exits 0 if `start.sh` is healthy for
  this session.
- Stale PID: ignore; do not kill unrelated PIDs.
- No boot/network: no promises (E-07).

No nag retries for lifecycle events. Public-IP and stop have one bounded
attempt (stop: single PUT; optional one retry is an implementation detail
if still bounded and not a nag).

## 10. Security / Permissions

- `VAST_API_KEY`, SMTP password, Telegram token, Twilio token: never in
  argv, logs, templates, onstart snippet.
- Stop client: Python stdlib, TLS verify (NFR-08).
- Git: public HTTPS only; no token query-string.
- Env parse: allowlist; unknown keys warned; reserved names rejected.
- SSH hook: document automation risk; `~/.no_login_ack` and uninstall.
- Public-IP lookup remains opt-in disclosure.
- `chmod 600` documented; warn if broader.

## 11. Compatibility and Rollout

- **Breaks** nag-until-ACK, `ack.sh`, default `/workspace/vastai-wakeup`,
  reject-on-loose-permissions.
- **Keeps** channel adapters, env syntax, pin-revision, selftest entry,
  ShellCheck CI.
- `wakeup.sh` / `ack.sh`: not invoked; removal can be a later slice after
  start.sh is proven, to avoid a giant first diff.
- `FIX_IMPLEMENTATION_PLAN.md` nag-lifecycle items that only serve ACK
  looping are superseded by this plan for the host-start path.
- Root `ARCHITECTURE.md` remains historical until implementation updates it
  to match this file (after Technical Design Gate, as a docs slice).

## 12. Verification Strategy

Keep `bin/selftest.sh` → `tests/run.sh`.

Add/extend offline tests (mocks, no live Vast.ai, no credentials):

- Config: two files, missing URL/key/id/channel, warn on mode (SC-03–06)
- `--test-channels` does not git/train/stop (SC-08)
- Secrets absent from logs (SC-10)
- Git: clone path; reset tracked, keep untracked (SC-11–12)
- Missing `train.sh`; non-zero `train.sh`; git fail (SC-13–15)
- KEEP_ALIVE during run; leftover ignored; PERMANENT persists (SC-16–20)
- SSH hook creates KEEP_ALIVE only; disable (SC-17, SC-21)
- Concurrent onstart (SC-22)
- Mock stop PUT: stopped not destroyed; skipped when flag present
- Public-IP off (SC-09)

Manual: BR-05 unattended Vast.ai stop/start (not CI).

## 13. Implementation Sequence

Vertical slices (each should leave CI green):

1. Path/env foundation: `/workspace/vastai` defaults, `train.env` keys,
   warn-on-permissions, `VAST_*` allowlist/secrets, tests.
2. `notify` + templates for five events; `--test-channels` / `--dry-run`
   without train/stop.
3. `install.sh` + SSH keep hook (no git/train).
4. `onstart.sh` launches `start.sh` (nohup, one process); pin template
   path change.
5. Git clone/update in `start.sh` + notices.
6. `train.sh` invoke + started/stopped notices + failure paths.
7. Keep-flag leftover cleanup + stop_decision + stop client.
8. Retire onstart→`wakeup.sh`; docs; optional leave nag scripts unused.

## 14. Traceability

| ID | Architecture |
| --- | --- |
| G-01 G-02 G-03 | ARCH-07, ARCH-03 |
| G-04 G-07 | ARCH-05 |
| G-05 G-08 | ARCH-02, ARCH-06, ARCH-08, install.sh |
| G-09 | ARCH-04, ARCH-09, ARCH-11 |
| G-10 | ARCH-14 |
| FR-01 FR-03 | ARCH-03 |
| FR-02 | ARCH-04, ARCH-05 |
| FR-07 FR-09 FR-12 FR-31 FR-32 | ARCH-07, ARCH-14 |
| FR-18 FR-19 FR-20 | ARCH-05 |
| FR-21 | ARCH-13 |
| FR-22 | templates + render_template.py (no new stack) |
| FR-23 FR-24 FR-26 FR-36 | ARCH-06, ARCH-12, install.sh, ARCH-02 |
| FR-25 | ARCH-14 |
| FR-27 FR-28 FR-29 FR-30 FR-37 | ARCH-08, ARCH-11, ARCH-02 |
| FR-33 FR-34 FR-35 FR-38 FR-39 | ARCH-04, ARCH-09, ARCH-10 |
| BR-01 | stop failure does not claim billing ended |
| BR-03 BR-04 BR-11 BR-12 BR-14 | ARCH-05, ARCH-07, ARCH-02, ARCH-10 |
| BR-05 | manual gate, §12 |
| BR-06 BR-09 BR-10 | product; ARCH-08 one URL |
| NFR-02 NFR-03 NFR-04 | timeouts; ARCH-07; ARCH-03 |
| NFR-05 NFR-15 NFR-16 | ARCH-16 |
| NFR-07 NFR-08 NFR-09 NFR-20 | ARCH-05, ARCH-04, ARCH-12, ARCH-14 |
| NFR-10–14 | ARCH-01; existing license/gitignore |
| NFR-17–19 | §12 |
| AC-01 AC-06–10 AC-12–24 | matching ARCH + §12 |
| E-01–E-13 | §9 |
| SC-01–SC-24 | §7 and §12 |
| NG-01–NG-11 | ARCH-01, ARCH-02, ARCH-15 |

FR-22, BR-06, NFR-13, NFR-14, AC-13 (no Jupyter UI): no extra component;
handled in implementation/docs.

## 15. Risks / Open Technical Questions

- Vast.ai stop API path/body is copied from an in-repo script; if the
  control plane changes, stop fails closed (log, no destroy).
- `VAST_INSTANCE_ID` is operator-supplied; a wrong id stops the wrong
  instance or none. Mitigation: required field, never guess.
- `nohup start.sh` vs onstart timeout is inferred from current
  `wakeup.sh`; still the chosen model (3A).
- Training has no product-level timeout; a hung `train.sh` holds the
  instance until the operator SSHs (`KEEP_ALIVE`) or kills the process.
- Dual presence of unused `wakeup.sh` during rollout could confuse
  operators until docs are updated (slice 8).
- Permission policy change (reject → warn) is a security relaxation
  required by the PRD.

No further product questions. Technical Design Gate **approved** 2026-08-17.
