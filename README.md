# Vast.ai wakeup notifier

Nags you over **email, Telegram, and optionally SMS** when a Vast.ai GPU instance comes back online and starts billing, until you create an ACK file (or SSH in).

Vast.ai does not reliably tell you that a stopped instance is running again. This notifier runs **inside the instance** (the PyTorch/Jupyter template *is* a Docker container) via onstart.

> **HomeLAN staging.** This folder is `machines/vastai` in the private HomeLAN repo. It is written so the directory can be copied to a **public GitHub repo** and deployed with `git clone` from Vast.ai onstart. See [docs/SPINOFF.md](docs/SPINOFF.md).

## How it works

```text
instance start → onstart deletes leftover ACK → wakeup.sh loops
    email + telegram + sms, with backoff
you SSH in → touch ACK → loop sends “acked” and exits
next stop/start → leftover ACK is deleted → nagging starts again
```

## Quick start (on the Vast.ai instance)

```sh
# After GitHub spinoff, clone instead of copying:
# git clone https://github.com/YOUR_USER/vastai-wakeup.git /workspace/vastai-wakeup

install -d -m 755 /workspace/vastai-wakeup
# copy this project tree there, then:
cp /workspace/vastai-wakeup/templates/wakeup.env.example \
   /workspace/vastai-wakeup/wakeup.env
chmod 600 /workspace/vastai-wakeup/wakeup.env
# edit wakeup.env — at least SMTP_* or TELEGRAM_* 

chmod +x /workspace/vastai-wakeup/bin/*.sh
/workspace/vastai-wakeup/bin/wakeup.sh --test-channels
```

Paste [templates/onstart.vastai.sh](templates/onstart.vastai.sh) into the Vast.ai **onstart** field (set `WAKEUP_REPO_URL` after spinoff).

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
|---|---|
| `bin/wakeup.sh` | Nag loop |
| `bin/onstart.sh` | Called from Vast.ai onstart |
| `bin/send_email_from_template.sh` | Public SMTP (copied from HomeLAN) |
| `bin/send_telegram.sh` / `bin/send_sms.sh` | Optional channels |
| `templates/wakeup.env.example` | Settings + secrets template |
| `docs/DEPLOY.md` | Vast.ai install |
| `docs/CHANNELS.md` | Gmail, Telegram, Twilio |
| `PRD.md` / `ARCHITECTURE.md` | Product and design |

## Requirements

bash, python3, curl — already on `nvcr.io/nvidia/pytorch` + Vast.ai Jupyter overlay. No pip packages.

## Tests

```sh
bash bin/selftest.sh
```

## License

Not chosen yet. Add one on GitHub spinoff (see `LICENSE.txt`).
