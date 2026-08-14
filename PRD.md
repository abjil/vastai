# Product Requirements Document — Vast.ai wakeup notifier

## Executive Summary

When a Vast.ai GPU instance comes back from stop/offline, billing starts immediately and Vast.ai does not reliably surface that event. This project is a small notifier that runs **inside** the Vast.ai instance (which is already a Docker container), and nags the operator over public SMTP email, Telegram, and optionally SMS until they acknowledge by creating a flag file. The package is staged here under HomeLAN so it can later be copied to a public GitHub repository for easy `git clone` from Vast.ai onstart.

## User Personas

- **GPU renter (primary).** Starts and stops Vast.ai instances, sometimes after hours. Needs a loud, repeating alert the moment the instance is actually running, because the hourly fee is already ticking.
- **Same person on SSH.** Logs in to start a training job. Wants one obvious action (`touch ACK`, or automatic ack on SSH) that silences the alerts for this boot only.

## Problem

- Vast.ai instance start ≠ a notification the operator will see.
- Email from a rented datacenter IP can land in spam; a single message is easy to miss.
- A leftover “I already acked” file on a persistent `/workspace` disk would silence the *next* wake, which is the failure mode this product exists to prevent.

## Goals

1. Start nagging as soon as the instance (container) starts.
2. Keep nagging until the operator acks **this** boot.
3. Use a public SMTP server (not a LAN mail host), plus Telegram as the reliable channel, plus optional SMS.
4. Read all secrets and settings from one `.env` file on a persistent path.
5. Be deployable from GitHub with a Vast.ai onstart snippet after spinoff.

## Out of scope (this version)

- Nested Docker / sidecar containers (the Vast.ai PyTorch/Jupyter overlay *is* the container).
- Vast.ai account API polling from a home machine (complementary, not this product).
- A local LAN SMTP server.
- Changing Vast.ai’s own notification product.

## Core Features

### Must have

- **Boot-time daemon** started from Vast.ai onstart (or equivalent).
- **Repeating alerts** with backoff, until an ACK file appears.
- **ACK file** on a persistent data directory; operator can `touch` it from SSH.
- **Discard leftover ACK on start** so a previous session cannot mute a new wake.
- **Public SMTP** via the existing HomeLAN `send_email_from_template.sh` (STARTTLS/SSL, auth, multi-recipient).
- **Telegram Bot API** messages when token and chat id are set.
- **Settings from `.env`**, never baked into the image or committed.
- **Logs** on the data directory so a silent SMTP failure is still visible after login.
- **Chunked sleep** so an ACK is noticed within a few seconds, not at the end of a 15-minute backoff.

### Nice to have

- **Twilio SMS** when credentials are present.
- **Auto-ack on SSH login** via a `.bashrc` snippet (optional).
- **Final “acked, stopping” message** with elapsed time and alert count.
- **`--once` / `--test-channels`** for setup without entering the nag loop.
- **Dry-run** that writes rendered messages but does not send.

## Non-Functional Requirements

- **Dependencies:** bash, python3, curl — all present on `nvcr.io/nvidia/pytorch` + Vast.ai Jupyter overlay.
- **SMTP politeness:** default interval 60s, doubling to a cap (default 15 min). Never stop entirely unless `MAX_ALERTS` is set; a silent give-up is worse than extra mail.
- **Channel isolation:** Telegram/SMS/email failures must not abort the loop or skip the other channels.
- **Secrets:** `wakeup.env` mode `600`; listed in `.gitignore`; documented as “do not commit”.
- **Idempotent onstart:** one nag loop per boot; pid file for the current process.
- **Windows-edited repo:** do not rely on Git executable bits; onstart `chmod +x`.

## User Flow

### A. Instance wakes (happy path)

1. Vast.ai starts the instance container and runs onstart.
2. Onstart removes any leftover `ACK`, then starts `wakeup.sh` in the background.
3. Operator receives Telegram (and email, and SMS if configured) every minute, then less often.
4. Operator SSHs in, starts work, and `touch /workspace/vastai-wakeup/ACK` (or auto-ack on login).
5. Loop sends one “acked” message and exits. Billing-awareness problem is solved for this session.

### B. Next stop/start

1. Persistent disk still has last session’s `ACK`.
2. Onstart deletes it before the loop starts.
3. Nagging begins again.

### C. First-time setup

1. Copy this folder (or `git clone` after GitHub spinoff) onto `/workspace/vastai-wakeup`.
2. Copy `templates/wakeup.env.example` to `wakeup.env`, fill SMTP and Telegram.
3. Run `bin/wakeup.sh --test-channels`.
4. Paste `templates/onstart.vastai.sh` into the Vast.ai onstart field (edit repo URL after spinoff).
5. Stop and start the instance once to confirm alerts fire without a login.

## Success criteria

- After a stop→start with no SSH, at least one Telegram or email arrives within two minutes.
- Creating `ACK` stops further alerts within 10 seconds.
- A second stop→start nags again even if `ACK` was left on disk.
- `bin/selftest.sh` passes in GitHub Actions without live credentials.
