# Security model

## Scope

This notifier protects against missed billing-awareness events. It is not a
security boundary against a compromised Vast.ai host or container. A process
with root access to the instance can read the notifier's credentials and alter
its state.

The repository is public at `https://github.com/abjil/vastai`. Treat every
tracked file as world-readable.

## Assets

- SMTP credentials or app password
- Telegram bot token and private chat identifiers
- Twilio account SID, auth token, and phone numbers
- instance hostname, Vast.ai container label, and public IP
- ACK/session state that controls whether alerts continue

## Secrets at rest

`wakeup.env` contains credentials in plaintext on persistent storage.

- Copy only `templates/wakeup.env.example`; never commit a populated env file.
- Store the real file at `/workspace/vastai-wakeup/wakeup.env`.
- Set owner-only permissions:

  ```sh
  chmod 600 /workspace/vastai-wakeup/wakeup.env
  ```

- Do not place credentials in the Vast.ai onstart field, repository URL,
  command-line arguments, logs, or message templates.
- The current implementation documents mode `0600` but does not enforce it.
  Enforcement is a release-blocking item in
  [FIX_IMPLEMENTATION_PLAN.md](../FIX_IMPLEMENTATION_PLAN.md).

Anyone who can read the persistent workspace may also read rendered messages
under `runtime/` and the operational log. Those files contain instance
metadata even when they do not contain credentials.

## Configuration loading

The env file must be treated as data, not as a shell script. Values are
shell-quoted before the current loader evaluates generated assignments, which
prevents direct value injection. However, the current loader accepts arbitrary
valid variable names and could overwrite `PATH`, `HOME`, or `PYTHONPATH`.

The target design exports only documented keys and uses one parser and
precedence rule across `wakeup.sh`, `ack.sh`, login-ack installation, and every
channel adapter.

Do not add shell commands, command substitutions, or unrelated environment
variables to `wakeup.env`.

## Network and message privacy

- SMTP uses Python's default SSL context with certificate verification.
- Telegram and Twilio use HTTPS with default certificate verification.
- Do not disable TLS verification to work around provider errors.
- Messages may contain hostname, container label, public IP, and ACK
  instructions. Send them only to private email recipients, Telegram chats, and
  phone numbers.
- Public-IP discovery currently contacts `ifconfig.me` and
  `icanhazip.com`. This discloses an instance request to those providers on each
  alert cycle. The target design makes this lookup optional.
- Provider error responses can contain account or recipient metadata. Logged
  error detail should be bounded and sanitized.

## Deployment supply chain

The onstart hook executes with access to the workspace and notification
credentials. Do not automatically execute an unreviewed moving branch.

For production use:

1. Review the release or commit.
2. Pin the onstart deployment to that tag or commit.
3. Update deliberately after reviewing changes.
4. Avoid `git pull ... || true`, which can silently retain stale code.

GitHub Actions should use pinned major versions at minimum. A future
high-assurance release may pin third-party actions by commit SHA.

## ACK and SSH auto-ack

ACK state controls whether billing alerts continue. Protect the data directory
from untrusted users.

`install-login-ack.sh` is optional. Its trigger is the presence of
`SSH_CONNECTION`; therefore any qualifying SSH login—including automation or a
different trusted operator—can silence alerts. Enable it only when that
behavior matches the instance's access model. The `~/.no_login_ack` opt-out
does not replace careful installation.

The target session-bound ACK design prevents stale state from acknowledging a
later container session.

## Credential rotation

If a credential may have leaked:

- Telegram: revoke/regenerate the token through BotFather.
- Gmail: revoke the app password in Google account settings.
- Twilio: rotate the auth token in the Twilio console.
- Review message recipients and persistent logs/runtime files.
- Replace `wakeup.env`, restore mode `0600`, and run `--test-channels`.

## Reporting and review

Before a release, verify:

- no populated env file or generated runtime artifact is tracked;
- CI passes from a clean checkout;
- logs do not contain credentials;
- channel tests use intended private recipients;
- the deployed revision is pinned and reviewed;
- the real stop/start test succeeds without an interactive login.
