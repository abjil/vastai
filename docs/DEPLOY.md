# Deploy on Vast.ai

## Readiness notice

The repository is public, but the initial draft has not yet met the release
gates in [FIX_IMPLEMENTATION_PLAN.md](../FIX_IMPLEMENTATION_PLAN.md). In
particular, CI must pass from a clean checkout and the lifecycle fixes must be
completed before this should be relied on as a billing safeguard.

## Runtime environment

On the NGC PyTorch + Jupyter template, Vast.ai builds and runs a wrapper
container. SSH and Jupyter sessions are inside that container. Do not add a
nested Compose stack for this notifier.

Persistent files belong under `/workspace`. The default installation and data
directory is `/workspace/vastai-wakeup`.

## 1. Install a reviewed revision

Clone the public repository:

```sh
git clone https://github.com/abjil/vastai \
  /workspace/vastai-wakeup
cd /workspace/vastai-wakeup
```

For production deployment, check out a reviewed tag or commit rather than
pulling the moving `main` branch during every boot:

```sh
git checkout --detach <REVIEWED_REVISION>
```

Do not place credentials in the clone URL or onstart script.

## 2. Create configuration

```sh
cp /workspace/vastai-wakeup/templates/wakeup.env.example \
   /workspace/vastai-wakeup/wakeup.env
chmod 600 /workspace/vastai-wakeup/wakeup.env
```

Configure at least one complete channel. Telegram is usually the most reliable
from a GPU datacenter IP. See [CHANNELS.md](CHANNELS.md).

Review path settings carefully. Until the configuration-precedence fixes are
implemented, prefer the default `DATA_DIR` and `ACK_FILE` values so
`wakeup.sh`, `ack.sh`, and login auto-ack cannot disagree.

## 3. Run offline and channel checks

The shell files may not retain executable bits when the repository is edited
from Windows:

```sh
chmod +x /workspace/vastai-wakeup/bin/*.sh
cd /workspace/vastai-wakeup
bash bin/selftest.sh
bin/wakeup.sh --dry-run --once --keep-ack
bin/wakeup.sh --test-channels
```

Expected results:

- selftest and dry-run exit successfully;
- one message arrives through every configured channel;
- no credential appears in `wakeup.log` or `runtime/`;
- `wakeup.env` remains mode `0600`.

Do not proceed if a configured channel fails.

## 4. Configure Vast.ai onstart

Keep deployment updates separate from instance startup. The reviewed checkout
should already exist on persistent storage before onstart runs.

The minimal onstart command is:

```sh
exec /workspace/vastai-wakeup/bin/onstart.sh
```

The [onstart template](../templates/onstart.vastai.sh) assumes the reviewed
checkout is already present. It intentionally does not clone, pull, or execute
a moving branch during instance startup.

Current startup behavior:

1. `onstart.sh` restores executable bits and checks for `wakeup.env`.
2. It handles the existing PID file and launches `wakeup.sh`.
3. `wakeup.sh`, not `onstart.sh`, removes legacy ACK state and starts the loop.

The PID/session handling is scheduled for hardening; avoid manually invoking
onstart concurrently.

## 5. Verify a real unattended wake

This test is a release gate and cannot be replaced by CI:

1. Confirm at least one channel works with `--test-channels`.
2. Leave the instance with no interactive SSH or Jupyter session.
3. Stop the instance and start it again.
4. Verify the first Telegram or email arrives within two minutes without login.
5. SSH in and run `/workspace/vastai-wakeup/bin/ack.sh`.
6. Verify the final acknowledgment message and absence of later alerts.
7. Restart only the notifier during the same container session and verify the
   session remains acknowledged after session-bound ACK is implemented.
8. Stop/start the instance again and verify alerts resume for the new session.
9. Inspect `wakeup.log` for channel failures, duplicate records, or credentials.

Record the tested Vast.ai image/template and reviewed Git revision.

## 6. Optional SSH auto-ack

```sh
/workspace/vastai-wakeup/bin/install-login-ack.sh
```

This is intentionally opt-in. Any SSH session with `SSH_CONNECTION`, including
automation, can acknowledge the notifier. Do not install it when multiple
people or unattended SSH jobs access the instance. Disable the installed
snippet with `touch ~/.no_login_ack` or remove the marked block from
`~/.bashrc`.

## Paths

| Item | Default |
| --- | --- |
| Install/data directory | `/workspace/vastai-wakeup` |
| Env file | `$DATA_DIR/wakeup.env` |
| ACK | `$DATA_DIR/ACK` |
| PID | `$DATA_DIR/wakeup.pid` |
| Log | `$DATA_DIR/wakeup.log` |
| Rendered runtime data | `$DATA_DIR/runtime/` |

Path overrides are supported by design, but should be used only after the
precedence tests in the implementation plan pass.

## Updating

1. Stop or acknowledge the notifier.
2. Review a specific release, tag, or commit.
3. Fetch and check out that revision explicitly.
4. Re-run offline tests and `--test-channels`.
5. Perform the unattended wake test for lifecycle-affecting changes.

Do not make `git pull ... || true` part of normal onstart; a failed update must
not silently execute an unknown stale revision.
