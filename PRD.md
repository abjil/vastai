# Product Requirements Document — Vast.ai wakeup notifier

## Product status

The project is published at `https://github.com/abjil/vastai`. It is an initial
operator-focused implementation that still requires the hardening work in
[FIX_IMPLEMENTATION_PLAN.md](FIX_IMPLEMENTATION_PLAN.md) before it should be
treated as a dependable billing safeguard.

## Executive summary

When a Vast.ai GPU instance comes back from stop/offline, billing starts
immediately and Vast.ai may not produce a notification the operator will see.
This project runs inside the Vast.ai instance and repeatedly notifies the
operator over Telegram, public SMTP email, and optionally SMS until that
specific running session is acknowledged.

This is a secondary safety mechanism, not an authoritative billing monitor.
Because it runs inside the instance, it depends on the container, persistent
workspace, networking, and Vast.ai onstart hook all working.

## Users

- **GPU renter (primary).** Starts and stops Vast.ai instances, sometimes after
  hours, and needs a visible alert when compute starts billing again.
- **Operator over SSH or Jupyter.** Connects to use the instance and needs one
  obvious action that acknowledges the current running session.

The product is designed for a single operator or trusted small team. It is not
a multi-tenant notification service.

## Problem

- Instance start does not guarantee a timely, visible Vast.ai notification.
- A single email may be delayed, rate-limited, or placed in spam.
- Persistent `/workspace` storage outlives the container session. A stale ACK
  must never silence alerts for a later billed session.
- A notifier that silently crashes or starts without a working channel creates
  false confidence.

## Product principles

1. **Fail visibly.** Invalid configuration and lack of usable channels must be
   obvious during setup and in persistent logs.
2. **Session-scoped acknowledgment.** An ACK belongs to one detected running
   session, not merely to the existence of a file.
3. **Minimal footprint.** Use facilities already present in the Vast.ai
   PyTorch/Jupyter image; do not require a database or nested container stack.
4. **Independent delivery paths.** A failure in one channel must not prevent
   attempts through the others.
5. **Inspectable operation.** State, rendered messages, and logs remain simple
   files that an operator can inspect after login.

## Goals

1. Start alerting as soon as the instance container and network are usable.
2. Continue alerting until the current running session is acknowledged.
3. Prefer Telegram, retain public SMTP as a second path, and support Twilio SMS
   as an optional additional path.
4. Keep secrets and settings in one uncommitted file on persistent storage.
5. Support repeatable deployment from the public GitHub repository through a
   small Vast.ai onstart snippet.
6. Detect configuration, lifecycle, and delivery failures through automated
   tests and actionable logs.

## Out of scope for v1

- Nested Docker or sidecar containers.
- Replacing Vast.ai's own notification or billing systems.
- A web UI, database, account system, or remote ACK API.
- Guaranteed notification when the instance cannot boot or reach the network.
- External Vast.ai API polling. This remains a complementary future safeguard
  because it has a different failure domain.

## Functional requirements

### Startup and lifecycle

- Vast.ai onstart launches exactly one notifier process for the current
  container session.
- Startup validates required files, writable paths, numeric settings, and at
  least one fully configured notification channel.
- Process ownership is verified before replacing an existing daemon; a stale
  PID must not cause an unrelated process to be killed.
- The notifier records a session identifier. A previous session's ACK does not
  apply to a new session, while restarting the notifier in the same session
  does not revoke an existing ACK.
- The daemon removes its own PID/lock state on normal exit and provides enough
  information to diagnose abnormal termination.

### Alerting

- The first alert attempt begins immediately after successful startup.
- Alert intervals start at 60 seconds, double after each cycle, and cap at 15
  minutes by default.
- Telegram, email, and SMS adapters have bounded timeouts and report success or
  failure independently.
- An ACK prevents any new alert cycle. In-flight network requests may complete,
  but channel timeouts must bound the delay.
- `MAX_ALERTS=0` means no send limit. A positive value stops further sends but
  keeps the daemon available to observe ACK and log its state.

### Acknowledgment

- The operator can acknowledge using `bin/ack.sh`.
- Direct file creation remains supported when the documented session format is
  followed.
- Optional SSH auto-ack is explicitly opt-in and warns that any matching SSH
  login, including automation, can silence alerts.
- The notifier sends at most one final acknowledgment message per session and
  exits successfully.

### Configuration and operator tools

- `wakeup.env` is parsed without executing arbitrary shell content.
- Only documented configuration keys are accepted for shell export.
- Explicit process overrides have one documented, consistently implemented
  precedence rule across all commands.
- `--test-channels`, `--once`, and `--dry-run` remain available for setup and
  diagnosis.
- Message templates remain editable without changing channel code.

## Non-functional requirements

### Reliability

- Creating a valid ACK is observed within `ACK_POLL_SEC` when the notifier is
  idle; default is 5 seconds.
- Every external request has a finite timeout.
- Channel failures do not terminate the main loop.
- Startup is concurrency-safe and repeatable.
- Persistent logs do not grow without a documented bound or rotation policy.

### Security and privacy

- `wakeup.env` is excluded from Git and must be readable only by its owner.
  Startup warns or fails when permissions are broader than `0600`.
- Secrets are never placed in command arguments, logs, rendered messages, or
  the Vast.ai onstart field.
- TLS certificate verification remains enabled for SMTP and HTTPS.
- Public-IP discovery is optional and its third-party disclosure is documented.
- Deployment uses a reviewed release, tag, or commit rather than executing an
  unpinned moving branch on every boot.

### Portability and maintainability

- Runtime dependencies are Bash, curl, and Python 3.9+ standard library
  facilities available in the supported Vast.ai image.
- A clean Git checkout must work without relying on executable bits preserved
  by a Windows client.
- Configuration parsing has one implementation shared by every channel.
- Repository-generated files such as `__pycache__` and `*.pyc` are not tracked.

### Observability

- Logs use UTC timestamps and one record per event.
- Channel attempts identify the channel, outcome, and bounded error detail
  without exposing credentials.
- Alert facts such as host uptime are refreshed for every alert.

## User flows

### First deployment

1. Clone `https://github.com/abjil/vastai` to
   `/workspace/vastai-wakeup`.
2. Create `wakeup.env`, set mode `0600`, and configure at least one channel.
3. Run `bin/wakeup.sh --test-channels`.
4. Install the reviewed onstart snippet.
5. Perform a real unattended stop/start test before relying on the notifier.

### Instance starts

1. Vast.ai starts the container and invokes onstart.
2. Bootstrap validates configuration and ensures one notifier instance.
3. The notifier identifies the session and ignores ACK state from older
   sessions.
4. It immediately attempts each configured channel and then applies backoff.
5. The operator acknowledges; the notifier records the ACK for this session,
   sends a final message, and exits.

### Notifier restarts in the same session

1. Bootstrap verifies whether a notifier is already running.
2. If a restart is required, it retains the current session identity.
3. An ACK already issued for that session remains effective.

## Success criteria

- A real unattended stop/start produces at least one Telegram or email attempt
  within two minutes.
- A valid ACK is observed within the configured poll interval while idle, and
  no new alert cycle starts afterward.
- Re-running onstart concurrently or repeatedly leaves exactly one notifier.
- Restarting the notifier in one session does not clear that session's ACK.
- A later stop/start alerts again even when old ACK state remains on disk.
- Missing channels, malformed numeric settings, or unsafe secret-file
  permissions fail setup with an actionable message.
- A clean checkout passes CI without credentials, including lifecycle,
  configuration, ACK, logging, and mocked channel-failure tests.
