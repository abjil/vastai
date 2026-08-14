# Notification channels

Configure channels in `wakeup.env`. Empty credentials disable that channel. At least one channel should be enabled.

The nag loop tries **Telegram, then email, then SMS** so a hung SMTP login does not delay the message you are most likely to see.

## Telegram (recommended)

1. In Telegram, talk to [@BotFather](https://t.me/BotFather), `/newbot`, copy the token.
2. Talk to [@userinfobot](https://t.me/userinfobot) (or similar) to get your numeric chat id, **or** message your new bot and then open `https://api.telegram.org/bot<TOKEN>/getUpdates`.
3. Set:

```bash
TELEGRAM_BOT_TOKEN='123456:ABC…'
TELEGRAM_CHAT_ID='123456789'
```

`TELEGRAM_CHAT_ID` may be a comma-separated list of chats (your account and a private group).

Test:

```sh
bin/send_telegram.sh /workspace/vastai-wakeup/wakeup.env /tmp/msg.txt
```

where `msg.txt` is a short plaintext file.

## Public SMTP email

Uses the generic `bin/send_email_from_template.sh` sender. It is **not** tied
to a LAN mail host. Point it at a public provider.

`SMTP_TO` (and `SMTP_CC` / `SMTP_BCC`) accept comma-separated addresses.

### Gmail

Use an [App Password](https://myaccount.google.com/apppasswords) (2FA required). Account password will not work.

```bash
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_TLS=1
SMTP_SSL=0
SMTP_USER='you@gmail.com'
SMTP_PASSWORD='xxxx xxxx xxxx xxxx'
SMTP_FROM='you@gmail.com'
SMTP_TO='you@gmail.com,other@example.com'
```

Mail from a rented GPU IP is often spam-foldered or rate-limited. Treat Gmail as a backup to Telegram. If you see `421` or auth errors, wait and/or use a transactional SMTP provider (Fastmail, Mailgun, Amazon SES).

### Implicit TLS (port 465)

```bash
SMTP_PORT=465
SMTP_TLS=0
SMTP_SSL=1
```

## Twilio SMS (optional)

```bash
TWILIO_ACCOUNT_SID='ACxxxxxxxx'
TWILIO_AUTH_TOKEN='…'
TWILIO_FROM='+15551234567'
SMS_TO='+15557654321,+15550001111'
```

Uses the public Twilio Messages API over HTTPS. Email-to-SMS carrier gateways are not implemented (they fail often from datacenter IPs).

## Dry run

```bash
WAKEUP_DRY_RUN=1
```

or `bin/wakeup.sh --dry-run --once` — renders bodies under `$DATA_DIR/runtime/` and does not send.
