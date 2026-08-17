# Implementation Tasks: Vast.ai wakeup notifier and training runner

## Inputs
- PRD: `tasks/prd-wakeup-notifier.md`
- Scenarios: `tasks/scenarios-wakeup-notifier.feature`
- Architecture: `tasks/architecture-wakeup-notifier.md`
- Repository Analysis: `tasks/repo-analysis-wakeup-notifier.md`

## Verification Commands Discovered
- Operator / CI entry: `bash bin/selftest.sh`
- Focused runner (invoked by selftest): `bash tests/run.sh`
- Python units: `python3 -m unittest discover -s tests -p 'test_*.py' -v`
- Single behavioral file: `bash tests/test_<name>.sh`
- Syntax: `bash -n bin/*.sh tests/*.sh templates/onstart.vastai.sh`
- Compile: `python3 -m py_compile` of modules listed in `bin/selftest.sh` (add new `.py` files there)
- Lint: `shellcheck --severity=warning -x bin/*.sh tests/*.sh templates/onstart.vastai.sh`
- CI: GitHub Actions Python 3.9 and 3.10 with dummy HTTP(S) proxies, plus ShellCheck — no credentials, no live Vast.ai

There is no pytest, Jest, Playwright, or similar. Offline tests mock HTTP/SMTP (and, in later tasks, git, `train.sh`, keep flags, and Vast.ai stop). BR-05 unattended stop/start is manual, not CI.

## Task Marker Legend

- `[ ]` — not implemented / in progress
- `[~]` — implemented and verified by the agent, awaiting human approval
- `[x]` — explicitly approved by the user

## Tasks

- [ ] **TASK-01 — Config and path foundation**
  - **Status:** pending
  - **Depends on:** none
  - **Covers:** FR-02, FR-18, FR-19, FR-20, FR-24, FR-27, E-01, BR-03, NFR-07, NFR-12, AC-06, AC-09 (env/secrets allowlist)
  - **Scenarios:** SC-03, SC-04, SC-05, SC-06
  - **Architecture:** ARCH-01, ARCH-04 (required keys), ARCH-05, ARCH-06
  - **Acceptance:**
    - Default `DATA_DIR` / `INSTALL_DIR` is `/workspace/vastai`.
    - Two uncommitted env files are parsed as data (not sourced as shell): `wakeup.env` (channels, `VAST_API_KEY`, `VAST_INSTANCE_ID`, operational paths) and `train.env` (`TRAIN_REPO_URL` only).
    - Normal start validation fails with an actionable message when no channel is complete, `TRAIN_REPO_URL` is missing, `VAST_API_KEY` is missing, or `VAST_INSTANCE_ID` is missing; malformed numeric settings also fail.
    - Env-file mode broader than `0600` warns and continues; it does not, by itself, abort load.
    - `VAST_API_KEY` is a secret (file-only, in `SECRET_KEYS`); it does not appear in dumps meant for logs or argv.
    - Precedence remains CLI > documented non-secret process env > file > defaults. Secrets stay file-only.
    - `.gitignore` excludes `train.env`.
  - **Verification:**
    - Extend `tests/test_envutil.py` and `tests/test_config.sh` for two-file load, missing URL/key/id/channel, and warn-on-loose-mode (existing reject-on-loose-mode cases must be updated to the approved policy).
    - Targeted: `python3 -m unittest tests.test_envutil -v` and `bash tests/test_config.sh`.
    - Broader: `bash bin/selftest.sh`.
  - **Expected change surface:**
    - `bin/envutil.py`
    - `bin/dump_env_shell.py` (if it must load `train.env` / new keys)
    - `templates/wakeup.env.example`
    - `templates/train.env.example` (new)
    - `.gitignore`
    - `tests/test_envutil.py`, `tests/test_config.sh`
  - **Risk notes:** Permission policy changes from reject to warn-and-continue (PRD-required security relaxation). Existing tests and `docs/SECURITY.md` still describe reject; docs catch-up is TASK-08. Do not start `start.sh` or change onstart in this slice.
  - **Evidence:** _filled during implementation_

- [ ] **TASK-02 — One-shot lifecycle notices without train or stop**
  - **Status:** pending
  - **Depends on:** TASK-01
  - **Covers:** FR-07, FR-09, FR-12, FR-21, FR-22, FR-25, FR-30, FR-31 (templates/send helper), BR-04, BR-11, NFR-02 (channel timeouts), NFR-03, NFR-16, NFR-20, AC-07, AC-12
  - **Scenarios:** SC-08, SC-09, SC-10
  - **Architecture:** ARCH-07, ARCH-13, ARCH-14, ARCH-16 (event names)
  - **Acceptance:**
    - Five events exist as templates and a notify helper: `host_up`, `repo_update`, `training_started`, `training_stopped`, `shutting_down`.
    - `training_stopped` can distinguish success / failed / did-not-run without requiring exact prose in tests.
    - Each event is one attempt per start, not a nag loop. Channel adapters are invoked independently; one channel failing does not skip the others.
    - Facts in a message (for example uptime) are current for that message.
    - Public-IP lookup stays off by default; when off, no IP-lookup site is contacted. When on, lookup is bounded, failure yields unknown, sequence continues.
    - `bin/start.sh --test-channels` probes configured channels then exits: no git, no `train.sh`, no stop.
    - `bin/start.sh --dry-run` validates and renders, with no live send, no git mutate, no train, no stop.
    - `--once` is an alias of the full one-shot run (in this slice the run may still be notify-only / incomplete until later tasks; the flag must exist and must not start a nag loop).
    - Secrets (API key, channel credentials) do not appear in rendered notices, logs, or argv.
  - **Verification:**
    - New or extended template tests (`tests/test_templates.py`) and channel tests (`tests/test_channels.sh`, `tests/test_public_ip.sh`) aimed at `start.sh`, not the nag loop as the documented entry.
    - Secrets scan of rendered output / logs in the channel or config tests (SC-10).
    - Targeted: `bash tests/test_channels.sh`, `python3 -m unittest tests.test_templates -v`, `bash tests/test_public_ip.sh`.
    - Broader: `bash bin/selftest.sh`.
    - Lint new shell: `shellcheck --severity=warning -x bin/start.sh` (and notify helper if separate).
  - **Expected change surface:**
    - `bin/start.sh` (new; CLI + notify; no git/train/stop yet)
    - `bin/notify.sh` or equivalent functions in `start.sh`
    - `templates/` lifecycle templates per event and channel (reuse `bin/render_template.py` and existing `bin/send_*.sh`)
    - `bin/selftest.sh` (`py_compile` if a new Python helper appears)
    - `tests/test_templates.py`, `tests/test_channels.sh`, `tests/test_public_ip.sh`, possibly `tests/test_config.sh` CLI flags
  - **Risk notes:** Leave `wakeup.sh` unused by this slice; do not make nag `--keep-ack` the v1 test path. `--test-channels` and `--dry-run` remain mutually exclusive as today. Public-IP helper may move from `wakeup.sh` into `start.sh` / shared lib rather than remaining only on the nag script.
  - **Evidence:** _filled during implementation_

- [ ] **TASK-03 — First-time install and SSH keep hook**
  - **Status:** pending
  - **Depends on:** TASK-01
  - **Covers:** FR-26, FR-36 (install half), FR-39, BR-12, BR-14, AC-14, AC-22 (hook creates `KEEP_ALIVE` only)
  - **Scenarios:** SC-02, SC-17 (hook creates empty `KEEP_ALIVE`, not `KEEP_ALIVE_PERMANENT`), SC-21
  - **Architecture:** ARCH-10, ARCH-02 (install does not clone/train), ARCH-06 (documented default path)
  - **Acceptance:**
    - `install.sh` is the documented first-time deploy step: chmod, env examples for both files, enable the SSH keep hook, print the onstart snippet for the operator to paste.
    - `install.sh` does **not** clone or update the training repository, does **not** run `train.sh`, and does **not** stop the instance.
    - `install.sh` does **not** call the Vast.ai control-plane API to rewrite onstart.
    - SSH login with `SSH_CONNECTION` creates empty `/workspace/KEEP_ALIVE` and never creates `KEEP_ALIVE_PERMANENT`.
    - A disable path exists (`~/.no_login_ack` and/or uninstall), matching the current bashrc-marker pattern.
    - Install documents that any matching SSH login, including automation, can prevent automatic stop for this start.
  - **Verification:**
    - Adapt `tests/test_login_ack.sh` to assert `KEEP_ALIVE` touch, not `ack.sh`, and to assert uninstall/disable.
    - A test that `install.sh` does not invoke git clone of `TRAIN_REPO_URL`, `train.sh`, or the stop client (SC-02).
    - Targeted: `bash tests/test_login_ack.sh` and a new `tests/test_install.sh` if cleaner than overloading login-ack.
    - Broader: `bash bin/selftest.sh`.
    - `shellcheck --severity=warning -x install.sh bin/install-login-ack.sh`.
  - **Expected change surface:**
    - `install.sh` (new, repo root)
    - `bin/install-login-ack.sh` (repurpose: touch `/workspace/KEEP_ALIVE`; keep markers, `SSH_CONNECTION`, disable, uninstall)
    - `tests/test_login_ack.sh`, optionally `tests/test_install.sh`
  - **Risk notes:** Keep flags live at `/workspace/`, outside `DATA_DIR`. Do not implement leftover-`KEEP_ALIVE` cleanup here (TASK-07). The printed onstart snippet may still mention `wakeup.sh` until TASK-04 updates the template; this slice must not *invoke* clone/train/stop.
  - **Evidence:** _filled during implementation_

- [ ] **TASK-04 — Host start launches one `start.sh`**
  - **Status:** pending
  - **Depends on:** TASK-01, TASK-02
  - **Covers:** FR-01, FR-03, FR-23, FR-36 (restart invokes start script), NFR-04, NFR-05, NFR-06, NFR-09, NFR-15, E-06, AC-01, AC-08 (onstart still CI-clean)
  - **Scenarios:** SC-22, SC-23 (new session can run the start path again; full lifecycle completed in later tasks)
  - **Architecture:** ARCH-02, ARCH-03, ARCH-12, ARCH-16
  - **Acceptance:**
    - Production onstart still requires `WAKEUP_REVISION` and pins **this** repo via `pin_revision.sh` (fail closed). Training repo is not pinned.
    - `templates/onstart.vastai.sh` default `INSTALL_DIR` is `/workspace/vastai`.
    - `bin/onstart.sh` validates both env files + channels + API key + instance id (TASK-01 rules), acquires the existing startup lock, ensures one `start.sh` for this session, `nohup`s it, confirms PID publication, and returns.
    - Concurrent / repeated onstart does not launch an overlapping `start.sh` / training run. A stale PID does not cause an unrelated process to be stopped; verify the recorded process is this product's `start.sh`.
    - Onstart does not run training or block until train+stop. Application log writes belong to `start.sh`; onstart only logs bootstrap. Logs use UTC, rotation (`LOG_MAX_BYTES` / backups), and one record per event.
    - After a successful detach, a host-up attempt is produced (via TASK-02 notify) without waiting for git/train.
  - **Verification:**
    - Extend `tests/test_lifecycle.sh` / `tests/test_session_id.py` so the daemon script path is `start.sh`.
    - Concurrent onstart case (SC-22) with a fake long-running `start.sh`.
    - `tests/test_pin.sh` still requires a reviewed revision on the production template.
    - Targeted: `bash tests/test_lifecycle.sh`, `python3 -m unittest tests.test_session_id -v`, `bash tests/test_pin.sh`, `bash tests/test_logging.sh`.
    - Broader: `bash bin/selftest.sh`.
    - `shellcheck --severity=warning -x bin/onstart.sh templates/onstart.vastai.sh bin/start.sh`.
  - **Expected change surface:**
    - `bin/onstart.sh`
    - `templates/onstart.vastai.sh`
    - `bin/start.sh` (session lock / PID / log ownership; still no git/train/stop)
    - `bin/session_id.py` if daemon script path / runtime dir names must change
    - `tests/test_lifecycle.sh`, `tests/test_session_id.py`, `tests/test_pin.sh`, `tests/test_logging.sh`
  - **Risk notes:** `wakeup.sh` may still exist; this slice must stop launching it from onstart. A leftover nag daemon is not the v1 start path. Runtime filenames (`wakeup.pid` vs `start.pid`) may be reused only if verify-daemon uses the `start.sh` script path.
  - **Evidence:** _filled during implementation_

- [ ] **TASK-05 — Public training-repo clone or update**
  - **Status:** pending
  - **Depends on:** TASK-04
  - **Covers:** FR-27, FR-28, FR-38 (notify + skip train), BR-10, NFR-02 (git timeout), NFR-08 (git-over-HTTPS / TLS), AC-15 (clone/update half), AC-20, AC-24
  - **Scenarios:** SC-11, SC-12, SC-15
  - **Architecture:** ARCH-08, ARCH-15 (do not use `deploy_vastai_wikitext_small.sh` as the start path)
  - **Acceptance:**
    - After host-up, `start.sh` clones `TRAIN_REPO_URL` to `/workspace/<repo-name>` (basename of the URL, strip `.git`) if missing, using the remote default branch, public HTTPS only, no token in the URL.
    - If the checkout exists: `git fetch` + `git reset --hard` to `origin/<default branch>`. Do **not** `git clean`. Tracked local edits are discarded; untracked/new files remain.
    - Success sends one `repo_update` notice. Failure sends a failure notice, does **not** send `training_started`, sends `training_stopped` (did not run), and proceeds to the stop decision point (stop itself is TASK-07; this slice must skip `train.sh`).
    - Git has a finite timeout. `deploy_vastai_wikitext_small.sh` is not invoked.
  - **Verification:**
    - Offline git fixture (local remote or mocked `git`) covering missing checkout, reset-tracked/keep-untracked, and clone/update failure.
    - Assert no `git clean` and no `git pull --ff-only` as the unattended update.
    - Targeted: new `tests/test_train_git.sh` (name may vary) plus existing selftest discovery of `tests/test_*.sh`.
    - Broader: `bash bin/selftest.sh`.
  - **Expected change surface:**
    - `bin/start.sh` (git steps + notices)
    - possibly a small `bin/` git helper
    - `tests/test_train_git.sh` (new), test fixtures under `tests/`
    - `bin/selftest.sh` only if a new Python mock needs `py_compile`
  - **Risk notes:** Do not copy `git pull --ff-only` from the wikitext deploy script. Keep flags / stop API are still out of this slice except that git failure must not start training.
  - **Evidence:** _filled during implementation_

- [ ] **TASK-06 — Run `train.sh` and report outcome**
  - **Status:** pending
  - **Depends on:** TASK-05
  - **Covers:** FR-29, FR-32, FR-37, E-10, E-11, AC-15 (`train.sh` invoke), AC-19, AC-21
  - **Scenarios:** SC-13, SC-14
  - **Architecture:** ARCH-11
  - **Acceptance:**
    - After a successful clone/update, run `./train.sh` at the training-repo root with **no extra arguments**.
    - Before a successful start: send one `training_started` notice. After exit 0: one `training_stopped` (success). After non-zero: one `training_stopped` marked failed.
    - Missing or non-runnable `train.sh`: no `training_started`; `training_stopped` indicates did not run; then the stop-decision point (stop is TASK-07).
    - No product-level training timeout watchdog. No `ack.sh`. Training does not wait for an ACK.
  - **Verification:**
    - Fake checkout with runnable `train.sh` (exit 0 and non-zero) and missing/non-executable `train.sh`.
    - Assert argv of `train.sh` is empty beyond the script itself; cwd is repo root.
    - Targeted: new `tests/test_train_run.sh` (name may vary).
    - Broader: `bash bin/selftest.sh`.
  - **Expected change surface:**
    - `bin/start.sh`
    - `tests/test_train_run.sh` (new)
    - lifecycle templates already added in TASK-02 if placeholders need an outcome field
  - **Risk notes:** A hung `train.sh` holds the instance until the operator SSHs or kills the process (accepted architecture risk). Do not add a timeout unless the PRD is reopened.
  - **Evidence:** _filled during implementation_

- [ ] **TASK-07 — Keep flags and instance stop**
  - **Status:** pending
  - **Depends on:** TASK-06
  - **Covers:** FR-33, FR-34, FR-35, FR-38 (stop after clone failure), FR-39 (SSH keep prevents stop), BR-01, BR-09, NFR-02 (stop timeout), NFR-08 (Vast.ai API TLS), AC-16, AC-17, AC-18, AC-20 (stop half), AC-22 (prevents stop), AC-23
  - **Scenarios:** SC-01, SC-07, SC-15 (stop after clone fail), SC-16, SC-17 (stop skipped), SC-18, SC-19, SC-20, SC-23 (sequence repeats on a later start)
  - **Architecture:** ARCH-04, ARCH-09
  - **Acceptance:**
    - On a **new** container session (new `session.id`), delete leftover `/workspace/KEEP_ALIVE` only; never delete `KEEP_ALIVE_PERMANENT`. Same-session re-onstart must not delete a `KEEP_ALIVE` created during this start (for example by SSH).
    - After the training path has ended (success, failed, missing `train.sh`, or skipped after git failure), if neither keep flag exists: send one `shutting_down` notice and PUT Vast.ai **stop** (`state=stopped`) using `VAST_API_KEY` + `VAST_INSTANCE_ID`. Never destroy. Never put the API key on a process command line; use Python stdlib HTTPS with TLS verify.
    - If `KEEP_ALIVE` or `KEEP_ALIVE_PERMANENT` exists at the decision: do not stop; do not send `shutting_down`.
    - Stop API failure is logged, bounded, not retried without bound, and does not claim billing ended (BR-01). No destroy fallback.
    - Successful unattended path produces one notice each for host up, repo update, training started, training stopped, and host is shutting down, then stop — not a nag loop.
    - Channel independence still holds: a failed channel does not skip train or stop (SC-07).
  - **Verification:**
    - Mock HTTP stop PUT: body is stopped not destroyed; skipped when a flag is present; leftover `KEEP_ALIVE` is ignored on a new session; `KEEP_ALIVE_PERMANENT` persists; flag created mid-run (including SSH hook) skips stop; git-fail and `train.sh` non-zero still reach stop unless a flag is present.
    - Secret not in argv/logs for the stop client (AC-09).
    - Targeted: new `tests/test_stop.sh` / `tests/test_keep_flags.sh` using `tests/mock_http.py`.
    - Broader: `bash bin/selftest.sh`.
    - Add new Python stop client to `bin/selftest.sh` `py_compile`.
  - **Expected change surface:**
    - `bin/start.sh` (leftover cleanup + stop_decision)
    - `bin/stop_instance.py` (new)
    - `tests/test_stop.sh` and/or `tests/test_keep_flags.sh` (new)
    - `bin/selftest.sh`
    - `.gitignore` if new runtime names appear
  - **Risk notes:** Operator-supplied `VAST_INSTANCE_ID` can stop the wrong instance; do not guess or discover an id. Stop URL/method is copied from `deploy_vastai_wikitext_small.sh`; if the control plane changes, fail closed (log, no destroy).
  - **Evidence:** _filled during implementation_

- [ ] **TASK-08 — Retire nag start path and operator docs**
  - **Status:** pending
  - **Depends on:** TASK-07
  - **Covers:** FR-23, FR-24, FR-30, NG-11, BR-05, NFR-09, NFR-11, NFR-13, NFR-14, NFR-17, NFR-18, NFR-19, AC-08, AC-13, AC-14
  - **Scenarios:** SC-02 (docs: later start does not re-run install), SC-24 documented as a non-promise
  - **Architecture:** ARCH-01, ARCH-02 (nag not the start path), ARCH-15, ARCH-06 (migration note)
  - **Acceptance:**
    - `install.sh` and onstart do not call `wakeup.sh` or `ack.sh`. `deploy_vastai_wikitext_small.sh` is not the v1 start path (may remain as an unrelated helper).
    - Operator docs describe clone to `/workspace/vastai`, `install.sh`, `start.sh` lifecycle, two env files, keep flags, SSH→`KEEP_ALIVE`, pin via `WAKEUP_REVISION`, and `--test-channels` / `--dry-run` on `start.sh`.
    - Docs state that nag-until-ACK / `ack.sh` are not v1; leftover `/workspace/vastai-wakeup` is not auto-migrated.
    - No Jupyter operator UI is documented or added.
    - Root `ARCHITECTURE.md` is updated to match the approved v1 plan (historical nag description replaced or clearly marked superseded).
    - Clean checkout still passes CI on Python 3.9 and 3.10 plus ShellCheck, covering config, lifecycle messages, mocked clone/update (keep untracked), missing `train.sh`, non-zero `train.sh`, keep flags, SSH→`KEEP_ALIVE`, and mocked stop.
    - BR-05 remains a documented **manual** unattended Vast.ai stop/start gate, not a CI job.
    - SC-24 / E-07 remains a documented non-promise (no implementation).
  - **Verification:**
    - Grep/docs review: no remaining “run `wakeup.sh` on host start” or `/workspace/vastai-wakeup` as the default install path in `README.md` / `docs/DEPLOY.md`.
    - `bash tests/test_clean_checkout.sh` (may need to invoke `start.sh` instead of `wakeup.sh`).
    - Broader: `bash bin/selftest.sh`.
    - `shellcheck --severity=warning -x bin/*.sh tests/*.sh templates/onstart.vastai.sh`.
  - **Expected change surface:**
    - `README.md`, `docs/DEPLOY.md`, `docs/SECURITY.md`, `docs/CHANNELS.md`, `docs/SPINOFF.md`
    - `ARCHITECTURE.md`
    - `tests/test_clean_checkout.sh` and any leftover nag-centric tests that would fail CI (`tests/test_ack.sh`, `tests/test_loop.sh`) — retarget, skip with reason, or drop from `tests/run.sh` only if they no longer describe v1
    - Optional: leave `bin/wakeup.sh` / `bin/ack.sh` unused in-tree (architecture allows this)
  - **Risk notes:** Dual presence of unused nag scripts can confuse operators until this slice lands. Do not expand into deleting those scripts unless CI is green without them; deletion is optional and must not be mixed with an incomplete start path.
  - **Evidence:** _filled during implementation_

## Coverage check

| ID | Task | Notes |
| --- | --- | --- |
| FR-01, FR-03 | TASK-04 | |
| FR-02, FR-18–20, FR-24, FR-27 | TASK-01 | |
| FR-07, FR-09, FR-12, FR-21, FR-22, FR-25, FR-30 | TASK-02 | |
| FR-23 | TASK-04, TASK-08 | pin on start; docs |
| FR-26, FR-39 | TASK-03 | |
| FR-28, FR-38 (skip train) | TASK-05 | stop half in TASK-07 |
| FR-29, FR-32, FR-37 | TASK-06 | |
| FR-31 | TASK-02 templates; TASK-05–07 sequence | |
| FR-33–35 | TASK-07 | |
| FR-36 | TASK-03 install, TASK-04 onstart | |
| BR-01, BR-09 | TASK-07 | |
| BR-03 | TASK-01 | |
| BR-04, BR-11 | TASK-02 | |
| BR-05 | TASK-08 | manual; not CI |
| BR-06 | — | product constraint; no extra component |
| BR-10 | TASK-05 | |
| BR-12, BR-14 | TASK-03 | |
| NFR-02 | TASK-02, TASK-05, TASK-07 | channels, git, stop |
| NFR-03 | TASK-02 | |
| NFR-04, NFR-06, NFR-09 | TASK-04 | |
| NFR-05, NFR-15 | TASK-04 | event names also TASK-02 |
| NFR-07, NFR-12 | TASK-01 | |
| NFR-08 | TASK-05, TASK-07 | |
| NFR-10 | all (ARCH-01) | no pip |
| NFR-11, NFR-17–19 | TASK-08 + each slice’s tests | |
| NFR-13, NFR-14 | existing; TASK-08 confirms | |
| NFR-16, NFR-20 | TASK-02 | |
| AC-01 | TASK-04 | |
| AC-06, AC-09 (config) | TASK-01 | stop-client secrets also TASK-07 |
| AC-07, AC-12 | TASK-02 | |
| AC-08, AC-13, AC-14 | TASK-08 / TASK-03 | |
| AC-15 | TASK-05, TASK-06 | |
| AC-16, AC-17, AC-18, AC-23 | TASK-07 | |
| AC-19, AC-21 | TASK-06 | |
| AC-20 | TASK-05, TASK-07 | |
| AC-22 | TASK-03, TASK-07 | |
| AC-24 | TASK-05 | |
| SC-01, SC-07, SC-16–20, SC-23 | TASK-07 | SC-07 channel half also TASK-02 |
| SC-02, SC-21 | TASK-03 | |
| SC-03–SC-06 | TASK-01 | |
| SC-08–SC-10 | TASK-02 | |
| SC-11, SC-12, SC-15 | TASK-05 | SC-15 stop in TASK-07 |
| SC-13, SC-14 | TASK-06 | |
| SC-17 | TASK-03, TASK-07 | |
| SC-22 | TASK-04 | |
| SC-24 / E-07 / NG-03 | — | intentional non-promise; documented in TASK-08 |
| ARCH-01 | all | |
| ARCH-02, ARCH-03, ARCH-12, ARCH-16 | TASK-04 | nag retirement docs TASK-08 |
| ARCH-04 | TASK-01 keys, TASK-07 client | |
| ARCH-05, ARCH-06 | TASK-01 | |
| ARCH-07, ARCH-13, ARCH-14 | TASK-02 | |
| ARCH-08, ARCH-15 (not used as start) | TASK-05, TASK-08 | |
| ARCH-09 | TASK-07 | |
| ARCH-10 | TASK-03 | |
| ARCH-11 | TASK-06 | |

**Intentional exceptions**

- **SC-24 / E-07 / NG-03:** If the instance never becomes usable, no notices, training, or stop are required. Not an implementation slice.
- **BR-05:** Real unattended Vast.ai stop/start remains a manual operator gate (TASK-08 docs). Not CI.
- **BR-06, AC-13, NFR-13, NFR-14:** Constraints already satisfied by the repo (trusted operator, no Jupyter UI, gitignore pyc, MIT). TASK-08 only confirms docs do not regress.
- **`bin/wakeup.sh` / `bin/ack.sh`:** May remain unused in-tree after TASK-08 (architecture §11). Removal is optional and is not a separate required slice.
- **`deploy_vastai_wikitext_small.sh`:** Unrelated helper; must not be wired into onstart or `install.sh` (ARCH-15).

No PRD requirement, scenario, or architecture item that requires implementation is left without a task, except the exceptions above.

## Relevant Files
_To be maintained during implementation._

## Change Log
- 2026-08-17 Task list created from approved slice structure (TASK-01–TASK-08). Task Plan Gate pending.
