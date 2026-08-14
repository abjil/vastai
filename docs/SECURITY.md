# Security notes

- **`wakeup.env` holds SMTP, Telegram, and Twilio secrets.** Mode `600`. Never commit it. It is listed in `.gitignore`.
- Copy `templates/wakeup.env.example` only; that file has placeholders, not live passwords.
- Do not bake secrets into the Vast.ai onstart text field if the template is shared or logged. Keep secrets in `/workspace/vastai-wakeup/wakeup.env` on the instance disk.
- After GitHub spinoff, the **repo is public**. Assume every file except `.gitignore`d env files is world-readable on the internet.
- Telegram bot tokens are credentials. If leaked, revoke via BotFather.
- Gmail app passwords are credentials. Revoke in Google account settings if leaked.
- The nag loop sends instance hostname, Vast.ai container label, and public IP in the message body. That is intentional (so you can SSH) and is sensitive. Use a private Telegram chat, not a public channel.
- `install-login-ack.sh` only writes a `touch ACK` snippet. It does not weaken SSH. Vast.ai already sets `PasswordAuthentication no` in its overlay.
- `send_email_from_template.sh` uses the default SSL context (certificate verification on). Do not disable that for “convenience” on public SMTP.
