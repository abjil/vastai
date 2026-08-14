# Architecture — Vast.ai wakeup notifier

## Context

A Vast.ai GPU instance on the NGC PyTorch + Jupyter template is **already a Docker container**. Logs show Vast.ai wrapping `nvcr.io/nvidia/pytorch:…` and `docker run` of `…/jupyter`. SSH lands inside that container. Nested Compose is not assumed and is not required.

```text
Vast.ai host
  └── docker run  nvcr.io/nvidia/pytorch_*/jupyter
        ├── sshd + tmux + jupyter          (Vast.ai overlay)
        ├── onstart.sh                     (user)
        └── wakeup.sh  ──►  SMTP / Telegram / Twilio
              ▲
              └── /workspace/vastai-wakeup/ACK
```

`/workspace` is the usual persistent path on Jupyter templates. Scripts and `wakeup.env` live there so they survive stop/start.

## Tech stack

| Layer | Choice | Why |
|---|---|---|
| Shell | Bash | Onstart and operators already use it |
| SMTP | `bin/send_email_from_template.sh` (python3 `smtplib`) | Copied from HomeLAN GPD/backupserver; public SMTP, not LAN-specific |
| Telegram / SMS | `curl` + HTTPS APIs | No extra packages on the NGC image |
| Config | `wakeup.env` KEY=VALUE | Same style as HomeLAN `*_sync_email.env` |
| CI | GitHub Actions, `bin/selftest.sh` | Spinoff-ready; no secrets required |

No database, no web server, no extra Python packages.

## Runtime components

| File | Role |
|---|---|
| `bin/onstart.sh` | Instance entry: chmod, pid cleanup, **delete leftover ACK**, start daemon |
| `bin/wakeup.sh` | Nag loop, backoff, template render, channel dispatch |
| `bin/lib.sh` / `envutil.py` / `dump_env_shell.py` | Shared `.env` parse and python discovery |
| `bin/render_template.py` | `{{PLACEHOLDER}}` substitution |
| `bin/send_email_from_template.sh` | SMTP send from a rendered file |
| `bin/send_telegram.sh` | Telegram `sendMessage` |
| `bin/send_sms.sh` | Twilio Messages API |
| `bin/ack.sh` | `touch` the ACK file |
| `bin/install-login-ack.sh` | Optional `.bashrc` auto-ack on SSH |
| `bin/selftest.sh` | Syntax, parse, render, dry-run (no live sends) |

## Data on disk

Default `DATA_DIR=/workspace/vastai-wakeup`:

```text
/workspace/vastai-wakeup/
├── bin/ … templates/ …          # clone or copy of this project
├── wakeup.env                   # secrets, mode 600 (not in git)
├── ACK                          # present ⇒ stop nagging this boot
├── started_at                   # unix timestamp of this loop
├── wakeup.pid
├── wakeup.log
└── runtime/                     # rendered bodies, last send status
```

### ACK semantics

| Event | ACK |
|---|---|
| Onstart / daemon start | **Deleted** (previous session must not mute this wake) |
| Operator login | Created (`touch` or bashrc hook) |
| Loop sees ACK | Sends one “acked” notification, then exits |
| Instance stop | File may remain on persistent disk — next onstart deletes it |

`--keep-ack` skips deletion for local tests.

## Alert loop

```text
start
  write started_at, pid
  alert_num = 0
  interval = INTERVAL_SEC
  loop:
    if ACK exists → render acked templates → notify → exit 0
    if MAX_ALERTS > 0 and alert_num >= MAX_ALERTS → log, sleep interval, continue
    alert_num += 1
    render email (and short telegram/sms text)
    send telegram, email, sms independently (log failures)
    sleep in 5s slices until interval elapsed or ACK appears
    interval = min(interval * 2, INTERVAL_MAX_SEC)
```

Telegram is attempted first: datacenter SMTP is the flaky channel.

## Configuration

`wakeup.env` is parsed by `envutil.py` (comment lines, optional `export`, `shlex` quoting). Process environment can override non-secret SMTP keys the same way `send_email_from_template.sh` already does.

Channel enablement is “credentials present”:

- Email: `SMTP_HOST`, `SMTP_FROM`, `SMTP_TO`
- Telegram: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`
- SMS: `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM`, `SMS_TO`

If none are enabled, the daemon logs an error and still waits on ACK (so a misconfig is visible in `wakeup.log` after SSH).

## Folder layout (this package = future GitHub repo root)

```text
machines/vastai/          # HomeLAN staging path
├── README.md
├── PRD.md
├── ARCHITECTURE.md
├── LICENSE.txt           # placeholder note until spinoff chooses a license
├── .gitignore
├── .github/workflows/ci.yml
├── docs/
│   ├── DEPLOY.md
│   ├── CHANNELS.md
│   ├── SECURITY.md
│   └── SPINOFF.md
├── bin/
└── templates/
```

After spinoff, the GitHub repository root is the contents of this directory.

## Development / test

There is no application HTTP port. Verification:

```sh
bash bin/selftest.sh
bin/wakeup.sh --test-channels   # needs a filled wakeup.env
```

GitHub Actions runs `selftest.sh` on Ubuntu (syntax, env parse, template render). It does not send live mail.
