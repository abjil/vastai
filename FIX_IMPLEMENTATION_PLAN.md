# Fix and implementation plan

## Purpose

This plan turns the initial draft into a dependable v1 of the Vast.ai wakeup
notifier. It is based on the product, architecture, implementation, security,
and operational review performed against commit `54f1102`.

The plan intentionally fixes correctness and release hygiene before adding new
features. External Vast.ai API monitoring is valuable but belongs after the
in-instance notifier has a trustworthy baseline.

## Current baseline

### What is already sound

- The product has a narrow, useful purpose and measurable user outcome.
- Bash plus Python standard library is appropriate for the target image.
- Telegram, SMTP, and SMS adapters are separated from the alert loop.
- Channel errors are captured without terminating the loop.
- Backoff, dry-run, test-channel, and template mechanisms are present.
- Secrets and runtime artifacts are intended to live outside Git.

### Verified release blockers

1. The only GitHub Actions run for the initial commit failed with exit code
   `126`. `selftest.sh` directly executes `wakeup.sh`, while the clean checkout
   stores shell scripts without executable mode.
2. Daemon log records are duplicated because `wakeup.sh` appends through
   `tee`, while `onstart.sh` redirects the same stdout to the same file.
3. Host uptime is cached after the first fact collection and becomes stale in
   later alerts.
4. `ack.sh` and `install-login-ack.sh` do not preserve caller path overrides in
   the same way as `wakeup.sh`.
5. ACK is deleted on every notifier process start, so process restart is
   incorrectly treated as a new billed session.
6. PID-only lifecycle coordination is vulnerable to concurrent startup, PID
   reuse, and cleanup races.
7. Numeric settings, channel completeness, and secret-file permissions are not
   validated before the daemon starts.
8. The env loader can export unrelated shell variables such as `PATH`, `HOME`,
   and `PYTHONPATH`.
9. SMTP duplicates the env parser used by the other components.
10. The public repository still contains pre-publication placeholders,
    compiled Python artifacts, and no actual license.

## Priority definitions

- **P0:** prevents CI or violates the core billing-alert lifecycle.
- **P1:** security, configuration, or observability hardening required for v1.
- **P2:** release quality and optional resilience improvements.

## Phase 0 — Restore a trustworthy repository baseline

**Priority:** P0  
**Goal:** a clean checkout runs the advertised offline test successfully.

### Work

- [x] Fix clean-checkout test execution.
  - Apply executable permissions in `selftest.sh` before direct invocation.
  - Keep runtime `chmod +x` in bootstrap because Windows-authored checkouts may
    still lack executable bits.
- [x] Remove tracked `bin/__pycache__/` and `*.pyc` files.
- [x] Keep `__pycache__/` and `*.pyc` in `.gitignore`.
- [x] Choose and install a real SPDX license.
- [x] Replace executable-template placeholders and obsolete HomeLAN language.
- [x] Update GitHub Actions to a currently supported checkout action.
- [x] Add a CI badge only after the workflow is green (deferred until the
  updated workflow runs on GitHub).

### Phase 0 files

- `bin/selftest.sh`
- `.github/workflows/ci.yml`
- `.gitignore`
- `bin/__pycache__/`
- `LICENSE.txt`
- `templates/onstart.vastai.sh`
- `README.md`, `docs/*`

### Phase 0 acceptance criteria

- A fresh clone on Ubuntu passes `bash bin/selftest.sh`.
- GitHub Actions is green for push and pull request.
- `git ls-files` contains no Python bytecode, credentials, or runtime state.
- The public README, deployment commands, template, repository URL, and license
  agree.

## Phase 1 — Fix localized correctness and observability defects

**Priority:** P0  
**Depends on:** Phase 0

### Phase 1 checklist

- [x] Make `wakeup.sh` the sole owner of daemon application log writes.
- [x] Refresh uptime and other dynamic facts for every rendered message.
- [x] Centralize configuration parsing and precedence across all commands.
- [x] Validate configuration before changing lifecycle state.
- [x] Bound, rotate, truncate, and sanitize persistent logs.
- [x] Add regression tests for every Phase 1 defect.

### 1. Make one component own daemon logging

Recommended implementation:

- Keep `wakeup.sh` as the owner of structured application log writes.
- In `onstart.sh`, redirect daemon stdout/stderr to a separate bootstrap/error
  file or to `/dev/null` after startup diagnostics.
- Avoid redirecting output back into the file already written by `log()`.

Add a regression test that starts one dry-run cycle through `onstart.sh` and
asserts each known startup record occurs once.

### 2. Refresh facts for every message

- Replace the cached `UPTIME_SEC=${UPTIME_SEC:-...}` behavior with a fresh read.
- Preserve explicit test injection through a dedicated argument or test-only
  variable rather than production caching.
- Verify elapsed time and uptime both increase across two short test cycles.

### 3. Define and centralize configuration precedence

Implement this precedence consistently:

1. command-line options;
2. documented process overrides;
3. `wakeup.env`;
4. built-in defaults.

Create one Python command that returns validated configuration to Bash. Use it
from `wakeup.sh`, `ack.sh`, `install-login-ack.sh`, and all adapters. Remove the
embedded SMTP parser.

Document which process variables may override file values. Secret values
should normally come only from the owner-protected file.

### 4. Validate configuration before state changes

Validate:

- `INTERVAL_SEC > 0`;
- `INTERVAL_MAX_SEC >= INTERVAL_SEC`;
- `ACK_POLL_SEC > 0`;
- `MAX_ALERTS >= 0`;
- provider and SMTP timeouts are positive;
- configured channel credential sets are complete;
- at least one channel is usable outside dry-run;
- data, runtime, and log paths are writable.

Return usage/configuration exit codes before deleting ACK state, replacing a
daemon, or entering the loop.

### 5. Bound and sanitize logs

- Add a simple size-based rotation or documented cap.
- Truncate provider error bodies to a safe maximum.
- Redact known tokens, passwords, and authorization material defensively.
- Keep UTC timestamps and clear channel/outcome labels.

### Phase 1 files

- `bin/wakeup.sh`
- `bin/onstart.sh`
- `bin/ack.sh`
- `bin/install-login-ack.sh`
- `bin/envutil.py`
- `bin/dump_env_shell.py`
- `bin/send_email_from_template.sh`
- `bin/send_telegram.sh`
- `bin/send_sms.sh`
- `bin/selftest.sh`

### Phase 1 acceptance criteria

- Startup and every event produce one log record.
- Two alerts contain different, increasing uptime values.
- Path overrides select the same ACK file in every command.
- Invalid numeric or incomplete channel config fails before daemon launch.
- Provider failures cannot place configured secrets in logs.
- Existing channel-isolation behavior remains intact.

## Phase 2 — Implement correct session and process lifecycle

**Priority:** P0  
**Depends on:** Phase 1

### Phase 2 checklist

- [ ] Implement and test a stable container-session identity.
- [ ] Bind ACK content and final acknowledgment to the current session.
- [ ] Serialize startup with an atomic lock.
- [ ] Store and verify process identity before signaling a PID.
- [ ] Make PID/lock cleanup conditional on state ownership.
- [ ] Test sequential, concurrent, stale-PID, and restart scenarios.

### 1. Introduce a container-session identity

Do not use only `/proc/sys/kernel/random/boot_id`; multiple container restarts
can occur during one host boot.

Recommended identity:

- build a stable fingerprint from the host boot ID, PID namespace identity, and
  process 1 start time;
- hash or encode the fingerprint into a simple token;
- verify on an actual Vast.ai stop/start that it remains stable across notifier
  restarts but changes across billed container sessions;
- if the target image does not expose stable inputs, create an atomic random ID
  in an ephemeral container path such as `/run`, with a documented fallback.

Place the derivation in a small testable Python helper rather than parsing
`/proc/1/stat` in ad-hoc shell.

### 2. Bind ACK to the session

- Store the current token in `session.id`.
- Make `ack.sh` atomically write that token to `ACK`.
- Treat ACK as valid only when its content equals the current token.
- Do not delete a matching ACK merely because `wakeup.sh` restarts.
- Treat empty legacy ACK files as stale unless an explicit compatibility mode
  is chosen.
- Write the final acknowledgment at most once per session.

### 3. Serialize startup

Use an atomic `mkdir` lock because it is available without assuming `flock`.
Store lock metadata for diagnosis and recover a lock only after verifying it is
stale.

### 4. Strengthen process identity

Store PID plus process start time/session token. Before signaling:

- verify the PID exists;
- verify its start time matches;
- verify its command identifies this checkout's `wakeup.sh`;
- verify its session relationship.

If the correct daemon already runs for this session, onstart should return
success without replacing it.

### 5. Make cleanup ownership-safe

The EXIT trap removes the PID file only when it still describes the exiting
process. Startup waits for a replaced process to exit before publishing a new
PID.

### Phase 2 files

- new `bin/session_id.py` or equivalent
- `bin/onstart.sh`
- `bin/wakeup.sh`
- `bin/ack.sh`
- `bin/install-login-ack.sh`
- `bin/selftest.sh`
- message templates and docs where ACK format is shown

### Phase 2 acceptance criteria

- Re-running onstart sequentially or concurrently leaves exactly one daemon.
- A stale PID cannot signal an unrelated test process.
- ACK survives notifier restart in the same container session.
- ACK from an earlier session does not silence a later stop/start.
- PID cleanup from an old process cannot remove a newer process's state.
- All state-file writes that define lifecycle transitions are atomic.

## Phase 3 — Security and deployment hardening

**Priority:** P1  
**Depends on:** Phases 1–2

### Phase 3 checklist

- [ ] Allowlist configuration keys exported to Bash.
- [ ] Detect unsafe `wakeup.env` permissions before loading credentials.
- [ ] Make public-IP discovery optional and bounded.
- [ ] Require a pinned, reviewed deployment revision.
- [ ] Make SSH auto-ack behavior explicit, safe, and reversible.
- [ ] Add security regression tests for each control.

### 1. Allowlist configuration keys

- Define all accepted keys in one module.
- Export only keys needed by Bash.
- Warn on unknown keys and reject dangerous reserved names.
- Keep `shlex.quote` or eliminate `eval` if a simpler transport proves robust.

### 2. Enforce secret-file permissions

- On Linux, reject or prominently warn when group/other permission bits are
  present.
- Do not attempt to silently repair ownership.
- Exempt the placeholder example file and credential-free test fixtures.

### 3. Make public-IP discovery optional

- Add a setting such as `PUBLIC_IP_LOOKUP=0|1`.
- Default it according to the privacy decision recorded in the PRD.
- Query once per session or cache for a bounded interval rather than contacting
  third parties on every alert.
- Keep fallback behavior as `unknown`.

### 4. Pin deployment input

- Replace the moving-branch clone/pull example with a required
  `WAKEUP_REVISION`.
- Fetch and detach at that revision.
- Fail loudly when the requested revision cannot be obtained.
- Never continue after a failed update under the pretense that deployment
  succeeded.

### 5. Clarify auto-ack

- Make installation print the exact trigger and risk.
- Add uninstall support or document a tested removal command.
- Ensure generated shell snippets safely quote custom ACK paths.

### Phase 3 acceptance criteria

- `PATH`, `HOME`, and arbitrary names in `wakeup.env` cannot change the daemon
  environment.
- Unsafe permissions are detected before channel credentials are loaded.
- No public-IP service is contacted when lookup is disabled.
- Onstart executes the requested reviewed revision or fails.
- Auto-ack behavior is explicit, reversible, and tested.

## Phase 4 — Expand behavioral tests

**Priority:** P1  
**Runs alongside:** Phases 1–3, finalized after them

### Phase 4 checklist

- [ ] Create focused offline tests under `tests/` while retaining selftest entry.
- [ ] Cover configuration, templates, loop behavior, ACK, and lifecycle state.
- [ ] Mock every notification provider and public-IP request.
- [ ] Add clean-checkout, timeout, concurrency, and log-sanitization tests.
- [ ] Add the supported Python versions and optional ShellCheck to CI.
- [ ] Confirm CI makes no external network calls and requires no credentials.

### Test structure

Keep one top-level `bin/selftest.sh` entry for operator convenience, but split
substantial checks into focused scripts or Python unit tests under `tests/`.
All tests remain offline and credential-free.

### Required coverage

- env comments, quoting, empty values, malformed input, allowlisting, and
  precedence;
- template rendering and unresolved placeholders;
- valid/invalid numeric settings;
- no-channel startup and partial channel configuration;
- first alert, backoff cap, `MAX_ALERTS`, and `--once`;
- ACK polling, session match/mismatch, final message, and same-session restart;
- sequential and concurrent onstart;
- stale/reused PID fixtures and cleanup ownership;
- duplicate-log regression and log sanitization;
- fresh facts across repeated alerts;
- mocked SMTP, Telegram, and Twilio success, HTTP/provider failure, and timeout;
- public-IP lookup enabled, disabled, primary failure, and fallback;
- clean-checkout behavior without executable Git modes.

Use short configurable intervals and local mock servers; tests must not sleep
for production backoff durations or contact the internet.

### CI matrix

- current Ubuntu runner;
- at least Python 3.9 and the Python version in the supported Vast.ai image;
- optional ShellCheck as a separate, actionable job.

### Phase 4 acceptance criteria

- CI catches every verified defect listed in the baseline.
- CI makes no external network call and requires no secret.
- Failure output identifies the violated lifecycle or configuration invariant.

## Phase 5 — Operational validation and v1 release

**Priority:** P1  
**Depends on:** all previous phases

### Validation

- [ ] Deploy a pinned candidate revision to a disposable Vast.ai instance.
- [ ] Test Telegram and email; test SMS when it is part of the intended release.
- [ ] Stop/start without login and measure time to first alert.
- [ ] ACK during idle sleep and during each channel's mocked/realistic timeout.
- [ ] Restart the notifier in-session and confirm ACK remains valid.
- [ ] Stop/start again and confirm the prior ACK is rejected.
- [ ] Re-run onstart rapidly and confirm only one daemon remains.
- [ ] Inspect logs, runtime files, permissions, and process state.
- [ ] Record image/template, revision, channels, and observed timings.

### Release

- [ ] Confirm CI is green on the exact release commit.
- [ ] Confirm a real SPDX license is installed.
- [ ] Review security and deployment documentation.
- [ ] Confirm no placeholders or generated files are tracked.
- [ ] Document the supported Vast.ai template and known limitations.
- [ ] Tag the commit and configure production to use that tag or commit.

## Phase 6 — Post-v1 options

**Priority:** P2

### Phase 6 checklist

- [ ] Evaluate an external Vast.ai API watcher outside the instance.
- [ ] Add lightweight supervision if field data shows daemon crashes.
- [ ] Evaluate and add additional notification providers.
- [ ] Design optional remote ACK with authentication and replay protection.
- [ ] Add structured logs or metrics if use grows beyond one operator.

These additions should not weaken the file-based local fallback or expand the
v1 implementation before its lifecycle invariants are proven.

## Recommended implementation order

1. Green clean-checkout CI.
2. Logging, uptime, precedence, and validation fixes.
3. Session-bound ACK and concurrency-safe startup.
4. Config allowlist, permission checks, and pinned deployment.
5. Full behavioral test suite.
6. Real Vast.ai validation and tagged v1 release.

Do not combine all phases into one change. Prefer reviewable commits or pull
requests where each phase introduces its tests with the implementation.
