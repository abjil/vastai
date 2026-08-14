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
you SSH in → touch ACK → loop sends “acked” and exits
next stop/start → prior-session ACK does not apply → nagging starts again
```

The session-bound ACK behavior shown above is the target design. The initial
implementation deletes ACK whenever the notifier process starts, so restarting
the notifier within one container session can resume alerts.

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

Follow [docs/DEPLOY.md](docs/DEPLOY.md) to select a reviewed revision, test
channels, and configure the Vast.ai onstart field. Do not pull an unreviewed
moving branch on every boot.

Stop alerts for this boot:

```sh
/workspace/vastai-wakeup/bin/ack.sh
# or:  touch /workspace/vastai-wakeup/ACK
```

Optional: ack automatically on SSH login:

```sh
/workspace/vastai-wakeup/bin/install-login-ack.sh
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

## License

MIT. See [LICENSE.txt](LICENSE.txt).
