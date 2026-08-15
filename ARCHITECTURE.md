# Architecture — Vast.ai wakeup notifier

## Status and scope

This document describes both the current implementation and the target
hardening direction. Statements marked **Target** are requirements that are not
yet guaranteed by the code. The implementation sequence and acceptance tests
are defined in [FIX_IMPLEMENTATION_PLAN.md](FIX_IMPLEMENTATION_PLAN.md).

The system is intentionally a small, single-operator utility. It has no
database, web server, account model, or application package dependencies.

## System context

A Vast.ai GPU instance using the NGC PyTorch + Jupyter template is already a
Docker container. SSH, Jupyter, the user onstart hook, and this notifier all run
inside that container.

```text
Vast.ai control plane
  │ starts instance and invokes onstart
  ▼
Vast.ai host
  └── docker run  nvcr.io/nvidia/pytorch_*/jupyter
        ├── sshd + tmux + jupyter
        ├── onstart.vastai.sh
        │     └── bin/onstart.sh
        │           └── bin/wakeup.sh
        ├── /workspace/vastai-wakeup/       persistent state
        └── outbound network
              ├── Telegram Bot API
              ├── public SMTP
              ├── Twilio Messages API
              └── optional public-IP lookup
```

The notifier cannot report failures that prevent the container or onstart hook
from running. External Vast.ai API monitoring would provide a separate failure
domain but is outside v1.

## Design decisions

### Run inside the existing container

Nested Docker and Compose add deployment assumptions without improving this
single-process workload. The supported model uses Vast.ai onstart and persistent
`/workspace` storage.

### Keep state file-based

The operator must be able to inspect and repair the notifier from a shell.
Configuration, ACK state, process state, rendered messages, and logs are files
under one data directory.

### Keep channel adapters independent

Each adapter receives an env file and rendered plaintext message. Adapter
failures are captured by the orchestrator so one provider cannot terminate the
alert loop.

### Separate session identity from process identity

**Target:** an acknowledgment belongs to a billed container session, while a
PID belongs only to one notifier process. Restarting the process must not erase
an ACK for the same session; starting a later container session must not reuse
the earlier ACK.

## Technology choices

| Layer | Choice | Reason |
| --- | --- | --- |
| Lifecycle and loop | Bash | Native to onstart and operator workflows |
| Config and templates | Python 3.9+ standard library | Reliable parsing without pip installation |
| SMTP | Python `smtplib` | STARTTLS/SSL and standard message construction |
| Telegram and SMS | Python `urllib` over HTTPS | No third-party runtime packages |
| Public-IP lookup | `curl` over HTTPS | Available in the supported image; lookup remains optional by design |
| State | Files under `/workspace` | Persistent, inspectable, and easy to recover |
| CI | GitHub Actions plus offline tests | Repeatable checks without live credentials |

## Component boundaries

| Component | Responsibility |
| --- | --- |
| `templates/onstart.vastai.sh` | Minimal Vast.ai UI bootstrap; select a reviewed source revision and invoke local startup |
| `bin/onstart.sh` | Validate startup inputs, coordinate one daemon, and launch it |
| `bin/wakeup.sh` | Session/ACK lifecycle, backoff, fact collection, rendering, and channel orchestration |
| `bin/envutil.py` | Canonical configuration parser and validation primitives |
| `bin/dump_env_shell.py` | Export an allowlisted subset of parsed configuration for Bash |
| `bin/render_template.py` | Replace `{{PLACEHOLDER}}` values in message templates |
| `bin/send_email_from_template.sh` | Send one rendered message through SMTP |
| `bin/send_telegram.sh` | Send one rendered message through Telegram |
| `bin/send_sms.sh` | Send one rendered message through Twilio |
| `bin/ack.sh` | Record acknowledgment for the current session |
| `bin/install-login-ack.sh` | Install optional SSH-triggered acknowledgment |
| `bin/selftest.sh` | Run offline syntax, configuration, lifecycle, and mocked-adapter checks |

The current email adapter contains a second env parser. **Target:** every
component uses `envutil.py` so quoting, validation, and precedence cannot drift.

## Persistent data model

Default `DATA_DIR=/workspace/vastai-wakeup`:

```text
/workspace/vastai-wakeup/
├── bin/ … templates/ …          source checkout
├── wakeup.env                   secrets; owner-readable only
├── session.id                   target: current container session identity
├── ACK                          target: acknowledged session identity
├── started_at                   notifier start timestamp
├── wakeup.pid                   process identity
├── wakeup.lock/                 target: startup exclusion
├── wakeup.log                   bounded persistent log
└── runtime/
      ├── facts.env
      └── {alert,acked}-{email,telegram,sms}.txt
```

`runtime/` contains hostname, container label, and public IP when enabled. It is
operationally useful but sensitive and must not be committed.

### Session and ACK invariant

**Current behavior:** `wakeup.sh` deletes any `ACK` whenever it starts unless
`--keep-ack` is used. This prevents a stale ACK from muting a later boot, but it
also revokes acknowledgment when the notifier is restarted within one boot.

**Target behavior:**

1. Derive or create a stable session identifier for the running container.
2. Store the identifier in `session.id`.
3. `ack.sh` writes that identifier to `ACK`.
4. The loop is acknowledged only when `ACK` matches `session.id`.
5. A new container session changes `session.id`, making old ACK content stale
   without deleting evidence during every process restart.

The session source must be verified on the supported Vast.ai image. Preferred
inputs are a stable container/boot identifier, with an atomically-created local
identifier as a documented fallback.

## Startup and process coordination

### Current sequence

1. `templates/onstart.vastai.sh` invokes `bin/onstart.sh`.
2. `onstart.sh` verifies `wakeup.env`, applies executable bits, checks a PID
   file, sends `TERM` to that PID when it exists, and starts `wakeup.sh` through
   `nohup`.
3. `wakeup.sh` loads configuration, deletes `ACK`, writes PID/start files, and
   enters the alert loop.

This sequence has known races: PID reuse can target an unrelated process, two
startups can overlap, and a terminating old process can remove a newer PID
file.

### Target sequence

1. Acquire an atomic startup lock.
2. Parse and validate configuration before changing running state.
3. If a PID file exists, verify both liveness and process ownership.
4. If the correct daemon is already healthy for this session, return success
   without restarting it.
5. Otherwise terminate it, wait with a bound, and escalate only to that
   verified process when necessary.
6. Start the daemon and atomically publish its PID.
7. Confirm it remains alive long enough to report startup success.
8. Release the startup lock.

A trap may remove a PID file only when the file still contains the exiting
process's PID.

## Configuration model

`wakeup.env` accepts simple `KEY=VALUE` assignments with comments and quoted
values. It is data, not a shell program.

### Implemented precedence

1. Command-line options override all other sources.
2. Explicit process environment overrides file values only for documented,
   non-secret operational keys.
3. `wakeup.env` supplies persistent values and credentials.
4. Built-in defaults apply last.

The shared Python parser now supplies effective configuration to the main loop,
ACK tools, and all channel adapters. Credentials and recipients are not
process-overridable.

Unknown keys are still accepted in the file, but only documented configuration
keys are exported into Bash. Reserved names such as `DRY_RUN`, `ONCE`, `PATH`,
`HOME`, and `PYTHONPATH` are never exported. Phase 3 will add unknown-key
warnings.

### Implemented validation

Before lifecycle state changes, startup validates:

- required and writable paths;
- positive integer intervals, polling, and timeouts;
- `INTERVAL_MAX_SEC >= INTERVAL_SEC`;
- non-negative `MAX_ALERTS`;
- complete credential sets for enabled channels;
- at least one usable channel for normal operation.

Dry-run rendering may operate without live credentials.
Owner-only permission enforcement for `wakeup.env` remains Phase 3 work.

## Alert control flow

```text
start
  validate config and session
  publish process state
  alert_num = 0
  interval = INTERVAL_SEC
  loop:
    if ACK matches session:
      render current facts
      send one final acknowledgment notification
      exit 0

    if sends remain enabled:
      alert_num += 1
      collect fresh facts
      render messages
      attempt Telegram, email, and SMS independently

    if --once:
      exit 0

    wait in ACK_POLL_SEC slices
    interval = min(interval * 2, INTERVAL_MAX_SEC)
```

Telegram remains first because datacenter SMTP is comparatively unreliable.
Adapters are sequential in v1. Each adapter therefore needs a finite timeout;
ACK prevents a new cycle but does not cancel an already-running network call.

## Error handling and observability

- Configuration failures stop startup with a non-zero exit and a specific
  operator-facing message.
- Channel failures are logged and do not terminate the loop.
- Public-IP lookup failure yields `unknown`; it does not block notifications.
- Facts such as uptime are recomputed for every alert.
- `wakeup.sh` owns daemon log writes. The launcher redirects only unexpected
  bootstrap output, avoiding duplicate records.
- Application and mirrored-output logs rotate at 1 MiB with three backups by
  default.
- Logged provider errors are credential-redacted and truncated to 2 KiB by
  default.

The daemon is not supervised by systemd inside the supported container.
**Target:** bootstrap detects immediate startup failure. Longer-term supervision
is optional unless field testing shows crashes are a material risk.

## Security boundaries

- The public repository is untrusted input until a revision is reviewed.
  Deployment should pin a release, tag, or commit instead of pulling a moving
  branch on every boot.
- `wakeup.env`, rendered messages, and logs are trusted-operator files on a
  persistent disk; they are not encrypted at rest.
- Anyone with root access inside the instance can read credentials. This tool
  does not defend against a compromised container.
- Public-IP lookup discloses the instance's request to a third party and must be
  optional.
- SSH auto-ack is opt-in because automated or unintended SSH sessions also set
  `SSH_CONNECTION`.

See [docs/SECURITY.md](docs/SECURITY.md) for operator controls.

## Repository layout

```text
vastai/
├── README.md
├── PRD.md
├── ARCHITECTURE.md
├── FIX_IMPLEMENTATION_PLAN.md
├── LICENSE.txt
├── .github/workflows/ci.yml
├── docs/
│   ├── DEPLOY.md
│   ├── CHANNELS.md
│   ├── SECURITY.md
│   └── SPINOFF.md
├── bin/
└── templates/
```

The public repository is `https://github.com/abjil/vastai`.

## Verification strategy

CI must run from a clean checkout and remain credential-free. It should cover:

- Bash and Python syntax;
- env parsing, allowlisting, precedence, and invalid input;
- template rendering and unresolved-token detection;
- ACK/session transitions and same-session restart;
- concurrent startup, stale PID, and PID ownership;
- backoff and `MAX_ALERTS` with short test intervals;
- one-record logging and refreshed uptime;
- mocked success, timeout, and failure for every channel adapter;
- a full dry-run startup/ACK/exit path.

Live channel smoke tests and a real unattended Vast.ai stop/start remain manual
release gates because CI must not depend on production credentials.
