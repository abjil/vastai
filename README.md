# Vast.ai wakeup notifier

Nags you over **email, Telegram, and optionally SMS** when a Vast.ai GPU instance comes back online and starts billing, until you create an ACK file (or SSH in).

Vast.ai does not reliably tell you that a stopped instance is running again. This notifier runs **inside the instance** (the PyTorch/Jupyter template *is* a Docker container) via onstart.

> **Initial draft.** The project is now public, but CI and lifecycle hardening
> must be completed before treating it as a dependable billing safeguard. See
> [FIX_IMPLEMENTATION_PLAN.md](FIX_IMPLEMENTATION_PLAN.md).

## How it works

```text
instance start → onstart launches wakeup.sh → stale ACK is rejected → loop
    email + telegram + sms, with backoff
you SSH in → ack.sh writes this session's token to ACK → loop sends “acked”
    and exits
notifier restart in the same session → matching ACK remains valid
next stop/start → prior-session ACK does not apply → nagging starts again
```

## Quick start (on the Vast.ai instance)

```sh
git clone https://github.com/abjil/vastai /workspace/vastai-wakeup
cp /workspace/vastai-wakeup/templates/wakeup.env.example \
   /workspace/vastai-wakeup/wakeup.env
chmod 600 /workspace/vastai-wakeup/wakeup.env
# edit wakeup.env — at least SMTP_* or TELEGRAM_* 

chmod +x /workspace/vastai-wakeup/bin/*.sh
/workspace/vastai-wakeup/bin/wakeup.sh --test-channels
```

Follow [docs/DEPLOY.md](docs/DEPLOY.md) to set `WAKEUP_REVISION` to a reviewed
tag or commit, test channels, and configure the Vast.ai onstart field. Do not
pull an unreviewed moving branch on every boot.

Stop alerts for this session:

```sh
/workspace/vastai-wakeup/bin/ack.sh
# or write the current session token:
# printf '%s\n' "$(cat /workspace/vastai-wakeup/session.id)" \
#   > /workspace/vastai-wakeup/ACK
```

An empty `touch ACK` is ignored unless compatibility mode (`--keep-ack` or
`WAKEUP_LEGACY_EMPTY_ACK=1`) is enabled.

Optional: ack automatically on SSH login. Installation prints the trigger and
risk; any SSH session with `SSH_CONNECTION` can stop alerts.

```sh
/workspace/vastai-wakeup/bin/install-login-ack.sh
# uninstall:  /workspace/vastai-wakeup/bin/install-login-ack.sh --uninstall
```

## Layout

| Path | Purpose |
| --- | --- |
| `bin/wakeup.sh` | Nag loop |
| `bin/onstart.sh` | Called from Vast.ai onstart |
| `bin/send_email_from_template.sh` | Generic public SMTP sender |
| `bin/send_telegram.sh` / `bin/send_sms.sh` | Optional channels |
| `templates/wakeup.env.example` | Settings + secrets template |
| `docs/DEPLOY.md` | Vast.ai install |
| `docs/CHANNELS.md` | Gmail, Telegram, Twilio |
| `docs/SECURITY.md` | Threat model and secret handling |
| `PRD.md` / `ARCHITECTURE.md` | Product and design |
| `FIX_IMPLEMENTATION_PLAN.md` | Prioritized hardening and release plan |

## Requirements

bash, curl, and Python 3.9+ — available on the supported
`nvcr.io/nvidia/pytorch` + Vast.ai Jupyter overlay. No pip packages.

## Tests

```sh
bash bin/selftest.sh
```

`bin/selftest.sh` is the operator entry point. Focused offline cases live under
`tests/` and use local HTTP/SMTP mocks. CI runs that suite on Python 3.9 and
3.10 with no credentials and no external network access, plus a separate
ShellCheck job.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
