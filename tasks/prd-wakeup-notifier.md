# PRD: Vast.ai wakeup notifier and training runner

## 1. Source

- Task Description: `td-wakeup-notifier.md`
- Analyzed sources: `README.md`, `old-PRD.md`
- User amendment 2026-08-16: deploy via `install.sh`, clone/update a training
  repo, run `train.sh`, lifecycle notifications, shutdown unless a keep flag
  exists
- Status: **Product Gate approved** 2026-08-16 for this PRD and
  `scenarios-wakeup-notifier.feature`.

## 2. Problem / Context

A Vast.ai GPU instance that returns from stop or offline begins billing
immediately. Vast.ai does not reliably produce a notification the operator will
see in time.

The operator also wants the host, once it is up, to fetch a specified **public**
training repository and run `train.sh` without a manual login, then **stop**
the instance (not destroy it) unless a keep flag is present.

This product is a **secondary safety mechanism**, not an authoritative billing
monitor. It runs **inside** the instance (the Vast.ai PyTorch/Jupyter template
is a Docker container) and therefore depends on the container, persistent
workspace, networking, the Vast.ai API for stop, and the start hook that
`install.sh` wires to a **separate** training-start script.

This PRD is the contract for **completed v1**.

**Supersession note.** Earlier drafts specified wakeup **nags until ACK**.
v1 instead sends **one message per lifecycle event**. There is no
nag-until-ACK and no `ack.sh`. An SSH login creates `KEEP_ALIVE` (this
start only), which can prevent automatic stop.

## 3. Goals

- **G-01:** On host start, send **one** "host up" notification as soon as the
  container and network are usable and channel validation passed.
- **G-02:** On each restart, send **one** message for each of: host up, repo
  update, training started, training stopped, and (when actually stopping)
  host is shutting down. These are not nag loops.
- **G-03:** Deliver over independent channels. v1 may run with **any one**
  fully configured documented channel: Telegram, public SMTP, or Twilio SMS.
- **G-04:** Keep secrets and settings in uncommitted environment files on
  persistent workspace storage (channel/API file and training-repo file are
  **different** files).
- **G-05:** First-time deploy: clone this project's git repository
  (`https://github.com/abjil/vastai`) to `/workspace/vastai` and run
  `install.sh`. `install.sh` does **not** clone the training repo or start
  training. A **separate** script does clone/update and training. Later host
  starts must run that separate script without repeating install. Pin this
  project to a reviewed release, tag, or commit rather than an unpinned
  moving branch on every boot.
- **G-06:** Make configuration, lifecycle, delivery, training, and shutdown
  failures visible through setup checks, persistent logs, and automated tests.
- **G-07:** A dedicated environment file contains the training repository
  **git URL only**. v1 supports **public** repositories only.
- **G-08:** The separate start script clones the training repo under
  `/workspace` if missing, or updates it if present, then runs `train.sh` at
  that repo's root with no extra arguments.
- **G-09:** After the training path has ended (success, failure, missing
  `train.sh`, or skipped after clone failure), **stop** the Vast.ai instance
  unless `KEEP_ALIVE` or `KEEP_ALIVE_PERMANENT` is present. Do not destroy
  the instance. The orchestrator env file holds a Vast.ai API key for stop.
- **G-10:** Optional public-IP lookup in notifications remains off by default.

## 4. Non-Goals

- **NG-01:** Nested Docker, sidecar containers, a database, a web UI, an
  account system, or a remote ACK API.
- **NG-02:** Replacing Vast.ai notification or billing systems.
- **NG-03:** Guaranteed notification or training when the instance cannot boot
  or cannot reach the network.
- **NG-04:** External Vast.ai API **polling** as a wakeup channel. Using the
  Vast.ai API to **stop** the instance after the run is in scope (FR-35).
- **NG-05:** Multi-tenant notification service for untrusted operators.
- **NG-06:** Requiring pip packages in **this** project beyond Bash, curl, and
  Python 3.9+ already present in the supported image. The training repository
  may have its own dependencies; this product only launches `train.sh`.
- **NG-07:** Jupyter as an operator interface.
- **NG-08:** A general CI/CD or multi-job scheduler. v1 runs **one** public
  training repository's `train.sh` per host start.
- **NG-09:** Private training repositories (token/SSH). Public git URL only.
- **NG-10:** Destroying the Vast.ai instance.
- **NG-11:** Wakeup nag loops, `ack.sh`, and ACK-to-silence. SSH does not
  ACK notifications; it creates `KEEP_ALIVE`.

## 5. Actors and Domain Concepts

### Actors

- **GPU renter / operator (primary).** Starts Vast.ai instances (sometimes
  after hours). Needs one-shot lifecycle messages and may create
  `KEEP_ALIVE` or `KEEP_ALIVE_PERMANENT` to prevent stop.
- **Operator over SSH.** A login with `SSH_CONNECTION` creates empty
  `/workspace/KEEP_ALIVE` (this start only). That prevents automatic stop if
  it exists at the stop decision. Any such SSH session, including
  automation, can keep the instance up for this start. The operator may also
  create `KEEP_ALIVE` or `KEEP_ALIVE_PERMANENT` by hand at any time before
  stop.
- **Local tester.** Runs this project off a Vast.ai host; uses channel test
  tools and keep flags so a local run does not attempt a real instance stop.
- **Trusted small team.** Not mutually untrusted tenants.

### Domain concepts

- **This project:** git repo cloned to `/workspace/vastai`.
- **Training repository:** a separate **public** git repo identified by URL
  in its own env file; checked out under `/workspace`.
- **Instance session:** one running lifetime after start. Stop/start is a new
  session.
- **`install.sh`:** first-time-only install. Wires later starts. Does not
  clone or train.
- **Start script:** separate from `install.sh`. Clones/updates the training
  repo, runs `train.sh`, sends lifecycle messages, decides stop. Filename
  not mandated here.
- **`train.sh`:** entry point at the **root** of the training repository; no
  extra arguments.
- **Channel:** Telegram, email/SMTP, or SMS.
- **`KEEP_ALIVE`:** empty file under `/workspace`. Prevents automatic stop
  for **this start only**. A leftover file from a previous session is not
  honored: each new start ignores or removes it before the run. An SSH
  login during this start creates it again.
- **`KEEP_ALIVE_PERMANENT`:** empty file under `/workspace`. Prevents
  automatic stop on **this start and later starts** until the file is
  deleted.
- **Stop:** Vast.ai instance stop via API (billing stops; instance can be
  started later). Not destroy. Not OS-only halt without stopping the
  instance.

## 6. Functional Requirements

### Deploy and install

- **FR-23:** Executing an unpinned moving branch of **this** project on every
  boot is not an accepted deployment mode. Install and start must use a
  reviewed release, tag, or commit of this repository.
- **FR-24:** The documented default install path is `/workspace/vastai`.
  Other paths remain allowed through the documented precedence rule (FR-20).
- **FR-26:** First-time deploy is: clone this repository to `/workspace/vastai`
  and run `install.sh`. `install.sh` shall **not** clone the training
  repository and shall **not** start training.
- **FR-36:** Clone/update of the training repository and running `train.sh`
  shall be done by a **separate** start script, not by `install.sh`. After
  install, host restart shall invoke that start script automatically.
  Install shall also enable the SSH→`KEEP_ALIVE` hook (with a way to
  disable it).

### Startup and one-shot lifecycle notifications

- **FR-01:** Host start shall run exactly one start-script session for the
  current container. Concurrent or repeated start shall not launch overlapping
  training runs of this product.
- **FR-02:** Before sending "host up", startup shall validate required files,
  writable paths, numeric settings, at least one fully configured channel,
  the training-repo env file (public git URL), and presence of a Vast.ai API
  key in the orchestrator env file. Missing channels or malformed settings
  shall fail with an actionable message. Env-file permissions broader than
  `0600` shall **warn and continue**.
- **FR-03:** Before replacing an existing start-script process, the product
  shall verify that the recorded process is actually this product's process.
  A stale process identifier shall not cause an unrelated process to be
  stopped.
- **FR-07:** After successful validation, send **one** "host up" message.
- **FR-09:** Telegram, email, and SMS shall each have a bounded timeout and
  report success or failure independently. Failure of one channel shall not
  prevent attempts on the others, and shall not skip the rest of the
  start-script sequence.
- **FR-12:** Facts in a message (for example host uptime) shall be current
  for that message.
- **FR-25:** Messages may include public IP. Lookup is **off by default**.
  When off, do not contact an IP-lookup site. When enabled, lookup is
  bounded, third-party disclosure is documented, and failure does not abort
  the sequence (IP shown as unknown).
- **FR-31:** On a normal successful path, send **one** message for each event
  that actually happens, in order:
  1. host up
  2. repo update (clone or update)
  3. training started
  4. training stopped
  5. host is shutting down (only if a stop will be requested)
- **FR-32:** Send **training stopped** when:
  - `train.sh` exits 0 (success);
  - `train.sh` exits non-zero (**marked as failed**);
  - `train.sh` is missing or not runnable (did not run);
  - training was skipped after clone/update failure (did not run).
- **FR-39:** An SSH session with `SSH_CONNECTION` shall create empty
  `/workspace/KEEP_ALIVE` (not `KEEP_ALIVE_PERMANENT`). Install shall
  document that any matching SSH login, including automation, can prevent
  automatic stop for this start. A way to disable that hook shall exist.

### Configuration

- **FR-18:** Two uncommitted env files on persistent storage, not in Git:
  1. **Orchestrator / channels file** — notification settings and the
     Vast.ai API key used to **stop** the instance.
  2. **Training-repo file** — public git URL only.
- **FR-19:** Env files shall be parsed without executing arbitrary shell
  content. Only documented keys shall be accepted.
- **FR-20:** Process overrides follow one documented precedence rule across
  commands.
- **FR-21:** `--test-channels`, `--once`, and `--dry-run` remain available
  for channel setup and diagnosis.
- **FR-22:** Message templates remain editable without changing channel
  behavior.

### Training repository and run

- **FR-27:** The training-repo env file shall contain a **public git URL
  only**. No token or SSH key. Private repos are out of v1.
- **FR-28:** The start script shall clone the public URL under
  `/workspace/<repo-name>` (name from the git URL) if missing, or update it
  if present, using the remote **default branch**. Update shall **discard
  local edits** to tracked files and **keep all new (untracked) files**.
- **FR-29:** After a successful clone/update, run `./train.sh` at the
  training-repo **root** with **no extra arguments**.
- **FR-30:** Training does not wait for an ACK. There is no nag loop and no
  `ack.sh` in v1.
- **FR-37:** If `train.sh` is missing or not runnable: do not start training;
  send a "training stopped" (or equivalent did-not-run) notice; then follow
  the shutdown rule (stop unless a keep flag is present).

### Shutdown

- **FR-33:** After the training path has ended (including skipped training
  after clone failure or missing `train.sh`), **stop** the Vast.ai instance
  unless a keep flag is present at the decision point. Send **one** "host is
  shutting down" message when a stop will be requested. Do not send that
  message when keeping the host up.
- **FR-34:** Empty files `KEEP_ALIVE` and `KEEP_ALIVE_PERMANENT` under
  `/workspace` are sufficient. Either may be created **at any time** before
  the stop decision (including by SSH creating `KEEP_ALIVE`). If either is
  present then, do **not** stop the instance.
  - `KEEP_ALIVE` applies to **this start only**. At the beginning of a new
    start, a leftover `KEEP_ALIVE` is ignored or removed so an unattended
    restart will still stop unless the operator SSHs (or recreates the
    file) during that new start, or `KEEP_ALIVE_PERMANENT` exists.
  - `KEEP_ALIVE_PERMANENT` remains effective across later starts until
    deleted.
- **FR-35:** Stop means Vast.ai **stop** (not destroy), using the API key
  from the orchestrator env file, so billing can end and the instance can be
  started later.
- **FR-38:** On clone/update failure: notify, skip training (no "training
  started"), then stop unless a keep flag is present (the "setting" in the
  operator's answer is these keep flags).

## 7. Business Rules

- **BR-01:** This product does not certify billing state. Absence of a
  message must not be interpreted as "the instance is not billing."
- **BR-03:** Any one fully configured channel among Telegram, SMTP, and SMS
  is enough.
- **BR-04:** Channel independence: a delivery failure on one path does not
  cancel the others.
- **BR-05:** The operator must perform a real unattended stop/start test
  before relying on auto-train and auto-stop.
- **BR-06:** Single operator or trusted small team.
- **BR-09:** Keep flags prevent automatic **stop** only. They are not
  notification ACKs.
- **BR-10:** One public training repository per host start.
- **BR-11:** Lifecycle messages are one-shot per event per start, not nags.
- **BR-12:** `install.sh` is first-time only. Training work belongs to the
  separate start script.
- **BR-14:** SSH auto-keep creates `KEEP_ALIVE` only, never
  `KEEP_ALIVE_PERMANENT`.

## 8. Data / Input / Output Contracts

### Inputs

- Orchestrator env file: channels + Vast.ai API key; mode `0600`.
- Training-repo env file: public git URL only; mode `0600`.
- Clone of this project plus `install.sh` (first deploy only).
- Host start after install (runs the separate start script).
- Optional empty `KEEP_ALIVE` and/or `KEEP_ALIVE_PERMANENT` under
  `/workspace`. SSH login may create `KEEP_ALIVE`.
- `train.sh` at the training-repo root.

### Outputs / inspectable state

- One-shot messages: host up, repo update, training started, training
  stopped, host is shutting down (when stopping).
- Persistent logs with UTC timestamps and one record per event.
- Training checkout under `/workspace`.
- Keep-flag files the operator can inspect over SSH.
- Channel attempt records without secrets.
- Vast.ai instance **stop** when no keep flag is present.

### Secrets handling

- Secrets (including the Vast.ai API key) shall not appear in command
  arguments, logs, rendered messages, or start-hook text.
- Public-IP lookup remains off by default; third-party disclosure documented
  when enabled.

### Paths (documented defaults)

- This project: `/workspace/vastai`.
- Training checkout: `/workspace/<repo-name>` from the git URL.
- Keep flags: `/workspace/KEEP_ALIVE` and
  `/workspace/KEEP_ALIVE_PERMANENT`.

## 9. Error and Edge-Case Behavior

- **E-01:** Missing channels, missing training git URL, missing Vast.ai API
  key, or malformed numeric settings fail startup with an actionable
  message. Env permissions broader than `0600` warn and continue.
- **E-02:** Channel timeouts/errors are logged; the start-script sequence
  continues.
- **E-04:** A later stop/start runs the full one-shot sequence again.
  Leftover `KEEP_ALIVE` does not apply; `KEEP_ALIVE_PERMANENT` does until
  deleted.
- **E-06:** Stale lock/PID must not block a new start indefinitely or kill
  unrelated processes.
- **E-07:** If the instance never becomes usable, no messages or training
  are promised.
- **E-09:** Clone/update failure: notify; skip training; stop unless a keep
  flag is present.
- **E-10:** Missing/non-runnable `train.sh`: no "training started"; send
  "training stopped" (did not run); stop unless a keep flag is present.
- **E-11:** `train.sh` non-zero exit: send **training stopped** marked as
  failed; then send **host is shutting down** and stop the instance, unless
  a keep flag is present.
- **E-12:** Keep flag present at stop decision: do not stop; do not send
  "host is shutting down."
- **E-13:** SSH with `SSH_CONNECTION` creates `KEEP_ALIVE` during the
  current start. If that file is present at the stop decision, do not stop.

## 10. Non-Functional Requirements

### Reliability

- **NFR-02:** Every external request (channels, git, IP lookup, Vast.ai stop)
  has a finite timeout.
- **NFR-03:** Channel failures shall not abort the start-script sequence.
- **NFR-04:** Start shall be concurrency-safe: no overlapping training runs
  from this product.
- **NFR-05:** Persistent logs shall not grow without a documented bound or
  rotation policy.
- **NFR-06:** Unattended start shall produce a "host up" attempt on a
  configured channel within two minutes when the instance is usable.

### Security and privacy

- **NFR-07:** Env files are Git-excluded; warn and continue if mode is
  broader than `0600`.
- **NFR-08:** TLS verification remains enabled for SMTP, HTTPS, git-over-HTTPS,
  and the Vast.ai API.
- **NFR-09:** This project is deployed from a reviewed release, tag, or
  commit.
- **NFR-20:** Public-IP lookup off means no IP-lookup site is contacted.

### Portability and maintainability

- **NFR-10:** This project: Bash, curl, Python 3.9+ stdlib on
  `nvcr.io/nvidia/pytorch` + Vast.ai Jupyter overlay. No pip packages in
  this project.
- **NFR-11:** A clean Git checkout works without relying on executable bits
  from a Windows client.
- **NFR-12:** One shared env-parse behavior; no executing shell from env
  files.
- **NFR-13:** `__pycache__` / `*.pyc` not tracked.
- **NFR-14:** MIT license.

### Observability

- **NFR-15:** Logs use UTC timestamps and one record per event. No duplicate
  logging of the same event to the same file.
- **NFR-16:** Channel attempts identify channel, outcome, and bounded error
  detail without credentials. Lifecycle events are distinguishable in logs.

### Verification

- **NFR-17:** `bin/selftest.sh` is the operator test entry point. Offline
  tests mock HTTP/SMTP, git, `train.sh`, keep flags, and Vast.ai stop. No
  live Vast.ai host and no real credentials required for CI.
- **NFR-18:** CI on Python 3.9 and 3.10, no credentials, no external
  network, plus ShellCheck.
- **NFR-19:** Clean checkout passes CI covering config, lifecycle messages,
  mocked clone/update (including keeping untracked files), missing
  `train.sh`, non-zero `train.sh`, keep flags, SSH→`KEEP_ALIVE`, and mocked
  stop.

## 11. Acceptance Criteria

- **AC-01:** After unattended start, logs or a channel show a **host up**
  attempt within two minutes if the instance booted and had network.
- **AC-06:** Missing channels, missing training URL, missing API key, or
  malformed numeric settings fail setup with an actionable message.
  Permissions broader than `0600` warn and do not, by themselves, prevent
  startup.
- **AC-07:** `--test-channels` works without running training or stop.
- **AC-08:** Clean checkout passes CI without credentials on Python 3.9 and
  3.10, plus ShellCheck.
- **AC-09:** Secrets (including the Vast.ai API key) do not appear in logs,
  messages, argv, or start-hook text.
- **AC-12:** Public-IP lookup off: no IP-lookup request. On: success may
  appear in a message; failure yields unknown; sequence continues.
- **AC-13:** No Jupyter-specific UI.
- **AC-14:** Documented first deploy is clone to `/workspace/vastai` and
  `install.sh`. Install does not clone the training repo or run `train.sh`.
- **AC-15:** After install, host restart runs the separate start script:
  clone or update the public training repo at `/workspace/<repo-name>`
  (default branch). Update discards local edits to tracked files and keeps
  untracked/new files. Then `train.sh` at repo root with no extra args (if
  present).
- **AC-16:** A successful run produces one message each for host up, repo
  update, training started, training stopped, and host is shutting down
  (the last only when stopping).
- **AC-17:** When the training path has ended and neither keep flag is
  present, the instance is **stopped** (not destroyed) via the API.
- **AC-18:** If `KEEP_ALIVE` or `KEEP_ALIVE_PERMANENT` exists at the stop
  decision, the instance is not stopped and "host is shutting down" is not
  sent.
- **AC-19:** Missing `train.sh`: no training started message; training
  stopped (did not run) is sent; then stop unless a keep flag is present.
- **AC-20:** Clone/update failure: notify; skip training; stop unless a keep
  flag is present.
- **AC-21:** `train.sh` non-zero: training started was already sent; training
  stopped is sent and marked failed; then host is shutting down and stop,
  unless a keep flag is present.
- **AC-22:** An SSH login with `SSH_CONNECTION` creates `/workspace/KEEP_ALIVE`
  (not `KEEP_ALIVE_PERMANENT`). If that happens before the stop decision,
  the instance is not stopped.
- **AC-23:** A leftover `KEEP_ALIVE` from a previous start does not prevent
  stop on a new unattended start. `KEEP_ALIVE_PERMANENT` does prevent stop
  on later starts until deleted.
- **AC-24:** Repo update keeps untracked/new files while discarding tracked
  local edits.

## 12. External Constraints and Deliverables

- Public repository: `https://github.com/abjil/vastai`.
- Documented clone path: `/workspace/vastai`.
- First-time deploy: `install.sh`.
- Separate start script: clone/update + `train.sh` + notifications + stop
  decision.
- Training entry point: `train.sh` at training-repo root.
- Orchestrator env: channels + Vast.ai API key.
- Training env: public git URL only.
- Keep flags: `KEEP_ALIVE`, `KEEP_ALIVE_PERMANENT`.
- SSH login creates `KEEP_ALIVE`.
- Supported image: `nvcr.io/nvidia/pytorch` with Vast.ai Jupyter overlay.
- MIT license.

## 13. Open Questions

### Resolved

- **OQ-01:** Any one of Telegram / SMTP / SMS.
- **OQ-02:** Env mode > `0600`: warn and continue.
- **OQ-03:** This PRD is completed **v1**.
- **OQ-05:** Optional public-IP lookup, off by default.
- **OQ-06:** No Jupyter operator UI.
- **OQ-07:** Default path `/workspace/vastai`.
- **OQ-08 / OQ-16:** On restart, **one** message each for host up, repo
  update, training started, training stopped, host shutting down (when
  stopping). Not a nag loop.
- **OQ-10:** `train.sh` at repo root, no extra args. If missing: do not
  train; stop unless a keep flag is present.
- **OQ-11:** Public git URL only; checkout `/workspace/<repo-name>`;
  default branch. Update discards local edits to tracked files and **keeps
  new/untracked files**.
- **OQ-13:** Clone/update failure: notify, skip training, then stop unless a
  keep flag is present.
- **OQ-14 / OQ-20:** Empty `KEEP_ALIVE` (this start only; leftover ignored
  on next start) and `KEEP_ALIVE_PERMANENT` (survives until deleted). Create
  any time before stop. Location `/workspace/`.
- **OQ-15:** Do not destroy. Stop via Vast.ai API. API key in the
  orchestrator env file.
- **OQ-17:** Training repo URL is a **different** env file from
  channels/API key.
- **OQ-18:** `install.sh` first time only. Clone/training is a separate
  script.
- **OQ-12:** `train.sh` non-zero: send training stopped marked failed, then
  host is shutting down and stop, unless a keep flag is present.
- **OQ-19:** No nag-until-ACK and no `ack.sh`. SSH login creates
  `KEEP_ALIVE` (this start only), not `KEEP_ALIVE_PERMANENT`.

### Still open

None. Product Gate approved 2026-08-16.
