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

For production deployment, check out a reviewed tag or commit. Vast.ai onstart
requires `WAKEUP_REVISION` and will not start from a moving branch:

```sh
export WAKEUP_REVISION=<REVIEWED_TAG_OR_COMMIT>
git checkout --detach "$WAKEUP_REVISION"
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

Command-line options take precedence over documented operational environment
overrides, followed by `wakeup.env` and built-in defaults. Operational
overrides cover paths, timing, instance name, dry-run, and timeouts.
Credentials and recipients remain file-only.

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

`bin/selftest.sh` is the operator entry point. Focused offline cases live
under `tests/` and are the same suite CI runs on Python 3.9 and 3.10 with
no credentials and no external network access.

Expected results:

- selftest and dry-run exit successfully;
- one message arrives through every configured channel;
- no credential appears in `wakeup.log` or `runtime/`;
- `wakeup.env` remains mode `0600`.

Do not proceed if a configured channel fails.

## 4. Configure Vast.ai onstart

Keep deployment updates separate from instance startup. The reviewed checkout
should already exist on persistent storage before onstart runs.

The Vast.ai onstart field should pin a reviewed revision:

```sh
export WAKEUP_REVISION=<REVIEWED_TAG_OR_COMMIT>
exec bash /workspace/vastai-wakeup/templates/onstart.vastai.sh
```

The [onstart template](../templates/onstart.vastai.sh) fetches and detaches
that revision, then starts the notifier. If the revision cannot be obtained,
startup fails and does not run a stale checkout.

Startup behavior:

1. `onstart.sh` restores executable bits and validates `wakeup.env`.
2. It acquires `wakeup.lock`, verifies any existing daemon, and starts
   `wakeup.sh` only when this session does not already have a healthy process.
3. `wakeup.sh` records `session.id` and treats `ACK` as valid only when the
   file contains that session token. An empty leftover ACK is ignored.
4. Re-running onstart sequentially or concurrently leaves one daemon.

## 5. Verify a real unattended wake

This test is a release gate and cannot be replaced by CI:

1. Confirm at least one channel works with `--test-channels`.
2. Leave the instance with no interactive SSH or Jupyter session.
3. Stop the instance and start it again.
4. Verify the first Telegram or email arrives within two minutes without login.
5. SSH in and run `/workspace/vastai-wakeup/bin/ack.sh`.
6. Verify the final acknowledgment message and absence of later alerts.
7. Restart only the notifier during the same container session and verify the
   session remains acknowledged.
8. Stop/start the instance again and verify alerts resume for the new session.
9. Inspect `wakeup.log` for channel failures, duplicate records, or credentials.

Record the tested Vast.ai image/template and reviewed Git revision.

## 6. Optional SSH auto-ack

```sh
/workspace/vastai-wakeup/bin/install-login-ack.sh
```

This is intentionally opt-in. Installation prints the exact trigger
(`SSH_CONNECTION`) and the risk that automation or another SSH login will
acknowledge the current session. Do not install it when multiple people or
unattended SSH jobs access the instance.

Temporary disable: `touch ~/.no_login_ack`.  
Uninstall: `/workspace/vastai-wakeup/bin/install-login-ack.sh --uninstall`.

## Paths

| Item | Default |
| --- | --- |
| Install/data directory | `/workspace/vastai-wakeup` |
| Env file | `$DATA_DIR/wakeup.env` |
| ACK | `$DATA_DIR/ACK` (must contain the current session token) |
| Session id | `$DATA_DIR/session.id` |
| Final-ack marker | `$DATA_DIR/acked.session` |
| PID | `$DATA_DIR/wakeup.pid` |
| Startup lock | `$DATA_DIR/wakeup.lock/` |
| Application log | `$DATA_DIR/wakeup.log` |
| Mirrored stdout/stderr | `$DATA_DIR/wakeup-error.log` |
| Rendered runtime data | `$DATA_DIR/runtime/` |

Both persistent logs rotate at 1 MiB and retain three numbered backups by
default. Override the policy with `LOG_MAX_BYTES` and `LOG_BACKUP_COUNT`.

## Updating

1. Stop or acknowledge the notifier.
2. Review a specific release, tag, or commit.
3. Fetch and check out that revision explicitly.
4. Re-run offline tests and `--test-channels`.
5. Perform the unattended wake test for lifecycle-affecting changes.

Do not make `git pull ... || true` part of normal onstart; a failed update must
not silently execute an unknown stale revision.
