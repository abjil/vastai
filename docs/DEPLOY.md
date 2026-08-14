# Deploy on Vast.ai

## What you are deploying into

On the NGC PyTorch + Jupyter template, Vast.ai **builds a wrapper image and `docker run`s it**. Your SSH session is inside that container. Do **not** add a sidecar Compose stack unless you know the template mounts a Docker socket (this overlay does not).

Persistent files belong under **`/workspace`**. Put this project at `/workspace/vastai-wakeup`.

## 1. Copy or clone the files

**Until GitHub spinoff** (from HomeLAN):

```sh
# from a machine that can reach the instance, or paste via jupyter
rsync -a machines/vastai/ user@VAST_SSH:/workspace/vastai-wakeup/
```

**After GitHub spinoff**, prefer clone (also what onstart does):

```sh
git clone https://github.com/YOUR_USER/vastai-wakeup.git /workspace/vastai-wakeup
```

## 2. Create `wakeup.env`

```sh
cp /workspace/vastai-wakeup/templates/wakeup.env.example \
   /workspace/vastai-wakeup/wakeup.env
chmod 600 /workspace/vastai-wakeup/wakeup.env
```

Fill at least one channel. Telegram is the most reliable from a GPU datacenter IP. See [CHANNELS.md](CHANNELS.md).

## 3. Smoke-test without the loop

```sh
chmod +x /workspace/vastai-wakeup/bin/*.sh
/workspace/vastai-wakeup/bin/wakeup.sh --test-channels
```

You should get one message per configured channel. Check `wakeup.log` if not.

## 4. Vast.ai onstart

In the instance template / onstart script field, use [templates/onstart.vastai.sh](../templates/onstart.vastai.sh).

Until the GitHub repo exists, comment out the `git clone` block and keep a copy of the files on `/workspace` (workspace survives typical stop/start). Onstart then only needs:

```sh
exec /workspace/vastai-wakeup/bin/onstart.sh
```

`onstart.sh` will:

1. `chmod +x` the scripts (Git on Windows may not store executable bits)
2. **Remove leftover `ACK`**
3. Start `wakeup.sh` in the background, logging to `/workspace/vastai-wakeup/wakeup.log`

## 5. Confirm a real wake

1. Leave the instance with **no** SSH session and **no** `ACK` file.
2. Stop the instance, start it again.
3. Alerts should begin within about a minute, without you logging in.
4. SSH in, `touch /workspace/vastai-wakeup/ACK` (or use `bin/ack.sh`).
5. One “acked” message, then silence.
6. Stop/start again — nagging must resume (leftover ACK is deleted on start).

## 6. Optional auto-ack on SSH

```sh
/workspace/vastai-wakeup/bin/install-login-ack.sh
```

Vast.ai auto-starts tmux on SSH; `.bashrc` still runs, so the first login acks. Disable with `touch ~/.no_login_ack` or uninstall the snippet.

## Paths

| Item | Default |
|---|---|
| Install / data dir | `/workspace/vastai-wakeup` |
| Env file | `$DATA_DIR/wakeup.env` |
| ACK | `$DATA_DIR/ACK` |
| Log | `$DATA_DIR/wakeup.log` |

Override with `DATA_DIR` and `WAKEUP_ENV` in onstart if you use another disk mount.
