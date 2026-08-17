# Task Description: Vast.ai wakeup notifier

This file is provenance. It records the original request and source documents
without rewriting them into a new product. Clarification belongs in
`prd-wakeup-notifier.md`.

## Original request

> use @.cursor/rules/start-feature.mdc
> analyze @README.md and @old-PRD.md to capture the goal of the project and to
> design a draft PRD

Do not implement code in this phase. Do not create architecture or
implementation tasks. Capture the project goal from the cited sources and
produce a draft PRD under `/tasks/`.

## User-supplied references

- `README.md` — current public project description (marked **Initial draft**)
- `old-PRD.md` — prior Product Requirements Document for the same product
- `.cursor/rules/start-feature.mdc` — workflow for this phase

Cited by those sources but not supplied as the analysis target:

- `FIX_IMPLEMENTATION_PLAN.md` — hardening required before treating the
  notifier as a dependable billing safeguard
- `docs/DEPLOY.md`, `docs/CHANNELS.md`, `docs/SECURITY.md`
- Public repository: `https://github.com/abjil/vastai`

## Problem statement (as stated)

From `README.md`:

> Nags you over **email, Telegram, and optionally SMS** when a Vast.ai GPU
> instance comes back online and starts billing, until you create an ACK file
> (or SSH in).
>
> Vast.ai does not reliably tell you that a stopped instance is running again.
> This notifier runs **inside the instance** (the PyTorch/Jupyter template *is*
> a Docker container) via onstart.

From `old-PRD.md`:

> When a Vast.ai GPU instance comes back from stop/offline, billing starts
> immediately and Vast.ai may not produce a notification the operator will see.
> This project runs inside the Vast.ai instance and repeatedly notifies the
> operator over Telegram, public SMTP email, and optionally SMS until that
> specific running session is acknowledged.
>
> This is a secondary safety mechanism, not an authoritative billing monitor.
> Because it runs inside the instance, it depends on the container, persistent
> workspace, networking, and Vast.ai onstart hook all working.

Product status (both sources):

> The project is now public, but CI and lifecycle hardening must be completed
> before treating it as a dependable billing safeguard.

`old-PRD.md` additionally states the published repo is an initial
operator-focused implementation that still requires the hardening work in
`FIX_IMPLEMENTATION_PLAN.md`.

## Explicitly stated goals

From `old-PRD.md` Goals:

1. Start alerting as soon as the instance container and network are usable.
2. Continue alerting until the current running session is acknowledged.
3. Prefer Telegram, retain public SMTP as a second path, and support Twilio SMS
   as an optional additional path.
4. Keep secrets and settings in one uncommitted file on persistent storage.
5. Support repeatable deployment from the public GitHub repository through a
   small Vast.ai onstart snippet.
6. Detect configuration, lifecycle, and delivery failures through automated
   tests and actionable logs.

From `old-PRD.md` Product principles:

1. Fail visibly.
2. Session-scoped acknowledgment.
3. Minimal footprint (facilities already present in the Vast.ai
   PyTorch/Jupyter image; no database or nested container stack).
4. Independent delivery paths.
5. Inspectable operation (simple files after login).

From `README.md` intended operator outcome:

- Clone to `/workspace/vastai-wakeup`, configure `wakeup.env`, test channels,
  install onstart, and stop alerts for the current session via `ack.sh` (or a
  correctly formatted ACK file). Optional SSH login auto-ack is available.

## Explicitly stated constraints

- Runs **inside** the Vast.ai instance via onstart; the PyTorch/Jupyter
  template is a Docker container.
- Runtime: bash, curl, and Python 3.9+ on the supported
  `nvcr.io/nvidia/pytorch` + Vast.ai Jupyter overlay. **No pip packages.**
- Single operator or trusted small team. Not a multi-tenant notification
  service.
- Secondary safety mechanism, not an authoritative billing monitor. It cannot
  notify if the instance cannot boot or reach the network.
- Secrets and settings live in uncommitted `wakeup.env` on persistent storage;
  file mode `0600`.
- Secrets must never be placed in command arguments, logs, rendered messages,
  or the Vast.ai onstart field.
- Deployment must use a reviewed release, tag, or commit — not an unpinned
  moving branch on every boot.
- Persistent `/workspace` outlives the container session; a stale ACK must
  never silence alerts for a later billed session.
- Empty `touch ACK` is ignored unless compatibility mode (`--keep-ack` or
  `WAKEUP_LEGACY_EMPTY_ACK=1`) is enabled.
- Optional SSH auto-ack is opt-in; any SSH session with `SSH_CONNECTION` can
  stop alerts.
- License: MIT.

Out of scope for v1 (`old-PRD.md`):

- Nested Docker or sidecar containers.
- Replacing Vast.ai's own notification or billing systems.
- A web UI, database, account system, or remote ACK API.
- Guaranteed notification when the instance cannot boot or reach the network.
- External Vast.ai API polling (complementary future safeguard; different
  failure domain).

## Required deliverables (this workflow phase)

- `tasks/td-wakeup-notifier.md` (this file)
- `tasks/state-wakeup-notifier.md`
- `tasks/prd-wakeup-notifier.md` (draft PRD)

The original sources also describe product deliverables for the notifier
itself (operator scripts, env template, docs, tests, public GitHub repo).
Those belong to the product, not to this requirements-capture phase.

## External acceptance conditions (as stated)

From `old-PRD.md` Success criteria:

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

From `README.md` Tests:

- `bash bin/selftest.sh` is the operator entry point.
- CI runs offline tests on Python 3.9 and 3.10 with no credentials and no
  external network access, plus a separate ShellCheck job.

From `README.md` How it works (lifecycle contract):

```text
instance start → onstart launches wakeup.sh → stale ACK is rejected → loop
    email + telegram + sms, with backoff
you SSH in → ack.sh writes this session's token to ACK → loop sends “acked”
    and exits
notifier restart in the same session → matching ACK remains valid
next stop/start → prior-session ACK does not apply → nagging starts again
```

Additional stated numeric / behavioral defaults from `old-PRD.md`:

- First alert attempt begins immediately after successful startup.
- Alert intervals start at 60 seconds, double after each cycle, and cap at 15
  minutes by default.
- `MAX_ALERTS=0` means no send limit. A positive value stops further sends but
  keeps the daemon available to observe ACK and log its state.
- Creating a valid ACK is observed within `ACK_POLL_SEC` when idle; default is
  5 seconds.
- At most one final acknowledgment message per session, then successful exit.
- TLS certificate verification remains enabled for SMTP and HTTPS.

## Stated operator tools and flows

Tools named in the sources:

- `bin/wakeup.sh` — nag loop; supports `--test-channels`, `--once`, `--dry-run`
- `bin/onstart.sh` — called from Vast.ai onstart
- `bin/ack.sh` — acknowledge current session
- `bin/send_email_from_template.sh`, `bin/send_telegram.sh`, `bin/send_sms.sh`
- `bin/install-login-ack.sh` / `--uninstall`
- `templates/wakeup.env.example`
- `bin/selftest.sh` and `tests/`

First-deployment flow (`old-PRD.md`):

1. Clone `https://github.com/abjil/vastai` to `/workspace/vastai-wakeup`.
2. Create `wakeup.env`, set mode `0600`, and configure at least one channel.
3. Run `bin/wakeup.sh --test-channels`.
4. Install the reviewed onstart snippet.
5. Perform a real unattended stop/start test before relying on the notifier.

## Unresolved language (kept as-is)

These phrases are uncertain or internally tensioned in the sources. Do not
treat a later rewrite as having resolved them unless the user confirms.

1. **"dependable billing safeguard"** — both sources say the project must not
   be treated as one until CI and lifecycle hardening are completed, but they
   do not define a separate acceptance bar beyond the listed success criteria
   and `FIX_IMPLEMENTATION_PLAN.md` (not analyzed as a source for this TD).
2. **"Prefer Telegram"** vs **"at least SMTP_* or TELEGRAM_*"** — preference
   versus minimum viable channel set.
3. **"until you create an ACK file (or SSH in)"** (`README.md`) vs optional
   SSH auto-ack that is **explicitly opt-in** and warns that any matching SSH
   login can silence alerts (`old-PRD.md` / `README.md` optional section).
4. **"warns or fails"** when `wakeup.env` permissions are broader than `0600`
   — warn and continue, or fail startup, is not chosen.
5. **"Initial draft"** / "initial operator-focused implementation" — the
   sources describe both intended v1 behavior and a not-yet-dependable
   published state. Whether this PRD describes the intended completed v1
   product, or only currently shipped behavior, is not stated in the user
   request.
6. **Empty ACK compatibility mode** — documented, but not stated whether it
   remains a supported v1 behavior or a temporary compatibility switch.
7. **Public-IP discovery** — "optional" with documented third-party
   disclosure; not stated whether it is a required capability or merely
   allowed.
8. **Jupyter operator** — listed as a user who needs "one obvious action" to
   ACK; the sources do not define a Jupyter-specific ACK path beyond writing
   the ACK file / running `ack.sh`.
9. **Process ownership / stale PID / env parsing / template editing /
   precedence of process overrides** — specified as product requirements in
   `old-PRD.md` Functional requirements. Some of these are close to
   implementation; they are retained because they were stated as required
   observable behavior, not invented here.

## User amendment 2026-08-16 — training deploy, run, and shutdown

Recorded faithfully. Do not treat this as having rewritten the earlier
README / old-PRD provenance above.

> I would like to change the intention for how the project works. The
> deployment to vast.ai host should be done by cloning the git repo of this
> project and running install.sh. There should be environment file describing
> the training repo. On deployment/host restart training repo should be
> cloned/updated and inside it train.sh should run the training. Notifications
> for the host wake up should still be sent as intended, also notifications
> about train repo update, start of the training, and finishing the training.
> After training is finished the host is to be shutdown, unless a special flag
> is created.

### Explicitly stated goals (amendment)

- Deploy to a Vast.ai host by cloning **this** project's git repo and running
  `install.sh`.
- An environment file describes the **training repo**.
- On deployment and on host restart: clone or update the training repo, then
  run `train.sh` inside it.
- Keep host-wakeup notifications as previously intended.
- Also notify: training-repo update, training start, training finish.
- After training finishes, shut the host down unless a special flag is
  created.

### Unresolved language in the amendment

Kept as-is (clarification belongs in the PRD):

- **"environment file describing the training repo"** — which keys, whether
  this is the same file as channel secrets, which git ref, private-repo auth.
- **"cloned/updated"** — first clone vs later pull/reset; dirty local tree;
  failure behavior.
- **"inside it train.sh"** — path, arguments, success vs failure.
- **"notifications about train repo update, start of the training, and
  finishing the training"** — one-shot vs nag; same channels; what text /
  outcome is required.
- **"the host is to be shutdown"** — stop vs destroy vs OS halt; billing
  intent; how shutdown is requested on Vast.ai.
- **"unless a special flag is created"** — name, location, empty vs
  token-scoped, when it may be created, whether it survives stop/start.
- **"On deployment/host restart"** vs **`install.sh`** — whether `install.sh`
  is first-time wiring only, and what runs automatically on later restarts.

## User answers 2026-08-16 — training-amendment questions

Recorded faithfully:

> 1. On restart it should send one message for each host up/repo
>    update/training started/training stopped/host is shutting down
> 2. Clarify
> 3. only git URL, public repos only for now
> 4. different file
> 5. under /workspace
> 6. yes, train.sh at repo root, no extra args. If missing - shutdown (unless
>    keep flag)
> 7. Clarify
> 8. notify -> skip training -> shut down (depends on the setting)
> 9. empty file is fine, created any time, two different flags, KEEP_ALIVE and
>    KEEP_ALIVE_PERMANENT
> 10. don't destroy, env file has API key
> 11. install.sh first time only, cloning/training start done in separate
>     script

## User answers 2026-08-16 — remaining confirmations

Recorded faithfully:

> 2. SSH automakes KEEP_ALIVE flag
> 7. Should send training stopped (marked as failed), then host is shutting
>    down and stop the instance, unless a keep flag is there
> Confirming
> 1. Yes, exactly
> 2. discard local edits, but keep all new files


