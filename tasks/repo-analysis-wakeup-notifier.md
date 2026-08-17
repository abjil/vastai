# Repository Analysis: Vast.ai wakeup notifier and training runner

Product Gate is **approved** (`tasks/state-wakeup-notifier.md`). This report
describes the existing repository against the approved v1 contract
(`tasks/prd-wakeup-notifier.md`, `tasks/scenarios-wakeup-notifier.feature`).
It does not change product requirements.

## 1. Scope of Inspection

Inspected the current wakeup-notifier codebase (Bash + Python stdlib, in-instance
onstart daemon) to see what can be reused for v1: `install.sh`, a separate
start script, public training-repo clone/update, `train.sh`, one-shot
lifecycle notices, keep flags, SSH→`KEEP_ALIVE`, and Vast.ai **stop** (not
destroy).

Not redesigned here: component filenames for the start script, how instance
id is obtained for stop, or whether leftover nag/ACK code is deleted vs
left unused.

## 2. Verified Repository Facts

- **Verified:** There is a real, non-greenfield codebase. No `package.json`,
  `pyproject.toml`, `requirements.txt`, or pip usage in `bin/` or `tests/`.
  Runtime is Bash, curl, and Python 3.9+ standard library
  (`README.md`, `ARCHITECTURE.md`).
- **Verified:** Default install/data path is `/workspace/vastai-wakeup`, not
  the approved `/workspace/vastai` (`docs/DEPLOY.md`,
  `templates/onstart.vastai.sh` `INSTALL_DIR`, `templates/wakeup.env.example`
  `DATA_DIR`, `docs/SPINOFF.md`).
- **Verified:** There is **no** `install.sh`. First-time deploy today is:
  clone, copy `wakeup.env`, `chmod +x`, optional onstart snippet
  (`README.md`, `docs/DEPLOY.md`).
- **Verified:** Host start today runs `templates/onstart.vastai.sh` →
  `bin/pin_revision.sh` → `bin/onstart.sh` → background `bin/wakeup.sh`
  (`templates/onstart.vastai.sh`, `bin/onstart.sh`). `wakeup.sh` is a **nag
  loop until ACK**, with `--once`, `--dry-run`, `--test-channels`,
  `--keep-ack` (`bin/wakeup.sh`).
- **Verified:** `WAKEUP_REVISION` is required in the onstart template; an
  unpinned moving branch is refused (`templates/onstart.vastai.sh`).
- **Verified:** One env file `wakeup.env`, parsed as data (not sourced as
  shell) by `bin/envutil.py`. Allowlisted keys only; reserved names
  (`PATH`, `HOME`, …) rejected. Credentials are file-only, not
  process-overridable (`bin/envutil.py`, `ARCHITECTURE.md`).
- **Verified:** At least one complete channel among email / Telegram / SMS
  is required for normal start (`_CHANNEL_REQUIREMENTS` in `bin/envutil.py`).
  SMS-only is already allowed if Twilio keys are complete.
- **Verified:** On Linux, a **secret-bearing** env file that is group- or
  other-readable raises `ConfigError` and **aborts** load (`check_env_file_permissions`
  in `bin/envutil.py`). Docs match that reject behavior (`docs/SECURITY.md`).
  Approved PRD says **warn and continue**. This is a contract vs code
  mismatch.
- **Verified:** Channel senders are separate processes: env file + rendered
  plaintext file (`bin/send_telegram.sh`, `bin/send_sms.sh`,
  `bin/send_email_from_template.sh`). Timeouts via `CHANNEL_TIMEOUT_SEC`.
  Failures of one adapter do not have to kill others because `wakeup.sh`
  invokes them independently.
- **Verified:** Templates use `{{PLACEHOLDER}}` via `bin/render_template.py`.
  Current templates are alert vs acked per channel, including ACK hints
  (`templates/alert-telegram.txt`). There are no templates for repo update,
  training started/stopped, or host shutting down.
- **Verified:** SSH auto-ack is **opt-in** via `bin/install-login-ack.sh`
  appending a `~/.bashrc` snippet gated on `SSH_CONNECTION` and
  `~/.no_login_ack`. It runs `ack.sh`, not a keep-flag touch
  (`bin/install-login-ack.sh`). Approved v1: install enables SSH→empty
  `/workspace/KEEP_ALIVE`, with a disable path.
- **Verified:** Process coordination uses `bin/session_id.py` (session
  token, `mkdir` lock, PID verify, stop only the verified daemon) and
  `bin/lib.sh` (log rotation, writable-path checks). `onstart.sh` `nohup`s
  `wakeup.sh` so the nag loop is not the onstart foreground process.
- **Verified:** No Vast.ai stop/destroy client exists in `bin/`. The only
  stop implementation is `deploy_vastai_wikitext_small.sh`: `PUT
  https://console.vast.ai/api/v0/instances/${INSTANCE_ID}/` with
  `Authorization: Bearer ${VAST_API_KEY}` and body `{"state": "stopped"}`,
  plus optional `vastai` CLI. It requires `VAST_INSTANCE_ID`.
- **Verified:** `deploy_vastai_wikitext_small.sh` is a **different** training
  deploy: hardcoded `https://github.com/alyubinin/tbp-mHC` →
  `/workspace/tbp-mHC`, `git pull --ff-only`, `apt-get`/`pip install`,
  `train_local_wikitext_small.sh` (not `train.sh`), sources `.env` as
  shell. That violates this project's no-pip / env-as-data rules if reused
  as-is.
- **Verified:** `git` is already a deployment assumption (`docs/DEPLOY.md`
  clone, `bin/pin_revision.sh`).
- **Verified:** `.gitignore` excludes `wakeup.env`, ACK/session/log/runtime
  artifacts. Keep-flag filenames are not listed. No `AGENTS.md`.

## 3. Existing Related Implementations

| Concern | Existing code | Fit to approved v1 |
| --- | --- | --- |
| Channel send | `bin/send_*.sh` + `envutil` + templates | Reuse for one-shot lifecycle messages |
| Config parse | `bin/envutil.py`, `dump_env_shell.py` | Reuse; extend allowlist; **second** training-URL file is new |
| One daemon / no overlap | `onstart.sh` + `session_id.py` | Reuse pattern for the start script (training must not overlap) |
| Pin this repo | `pin_revision.sh`, onstart template | Reuse for this project; not for the training repo |
| SSH hook | `install-login-ack.sh` | Analogous install/uninstall/disable; **behavior** must change to `KEEP_ALIVE` |
| ACK / nag loop | `wakeup.sh`, `ack.sh`, session ACK files | **Superseded** by one-shot events + keep flags |
| Git update training | `deploy_vastai_wikitext_small.sh` `git pull --ff-only` | **Does not** discard tracked edits or keep untracked-only policy as specified |
| Instance stop | same deploy script REST PUT | Closest analog; needs instance id + API key; must not destroy |
| Public IP | `wakeup.sh` `resolve_public_ip`, `PUBLIC_IP_LOOKUP=0` | Matches v1 optional/off-by-default |
| Tests / mocks | `tests/mock_http.py`, `mock_smtp.py`, `tests/helpers.sh` | Reuse for channels; **no** git/`train.sh`/stop mocks yet |

## 4. Architecture / Dependency Constraints

Architecture must stay inside these observed constraints unless the product
contract explicitly overrides them (path `/workspace/vastai` **does**
override the current default directory name):

1. **No pip / no extra runtime packages** for this project (`README.md`).
   Training repo may install its own deps inside `train.sh`; this repo only
   launches that script.
2. **Bash + Python 3.9+ stdlib + curl** on
   `nvcr.io/nvidia/pytorch` + Vast.ai Jupyter overlay.
3. **Env files are data**, one shared parser, no `source` of operator env
   (`bin/envutil.py`). Do not copy `deploy_vastai_wikitext_small.sh`'s
   `source .env`.
4. **Secrets not in argv, logs, templates, or onstart text**
   (`docs/SECURITY.md`). `VAST_API_KEY` must join `SECRET_KEYS` if stored
   in the orchestrator env file.
5. **Channel adapters stay independent** with bounded timeouts.
6. **TLS verification stays on** for SMTP/HTTPS (`docs/SECURITY.md`).
7. **This project's checkout is pinned** (`WAKEUP_REVISION` / reviewed
   tag); do not `git pull` a moving branch on boot
   (`templates/onstart.vastai.sh`).
8. **Windows-safe**: restore `chmod +x`; `bash -n`; `.gitattributes` `eol=lf`.
9. **Long work must not rely on staying in the Vast.ai onstart foreground.**
   Current code backgrounds `wakeup.sh` with `nohup`. Training can run for
   hours; the start script almost certainly needs the same detach-or-exec
   pattern (inference, see §9).
10. **CI stays credential-free and offline** except loopback mocks
    (`.github/workflows/ci.yml` sets dummy HTTP(S) proxies).

## 5. Test and Verification Tooling

- **Operator / CI entry:** `bash bin/selftest.sh` (`README.md`,
  `.github/workflows/ci.yml`).
- **selftest:** `bash -n` on `bin/*.sh`, `tests/*.sh`,
  `templates/onstart.vastai.sh`; `chmod +x`; `python3 -m py_compile` listed
  modules; then `tests/run.sh`.
- **Python:** `python3 -m unittest discover -s tests -p 'test_*.py'`
  (`tests/test_envutil.py`, `test_session_id.py`, `test_templates.py`).
- **Bash behavioral:** `tests/test_{channels,public_ip,login_ack,loop,clean_checkout,config,ack,pin,logging,lifecycle}.sh`.
- **Mocks:** local HTTP (`tests/mock_http.py`) for Telegram, Twilio,
  public-IP; local SMTP (`tests/mock_smtp.py`).
- **Lint:** ShellCheck job, `--severity=warning -x`, plus `.shellcheckrc`
  (`disable=SC2154` for dumped exports).
- **Matrix:** GitHub Actions Python 3.9 and 3.10, `ubuntu-latest`.
- **Not present:** git-update tests matching “reset tracked, keep untracked”;
  `train.sh` missing/non-zero; keep-flag leftover vs permanent; Vast.ai stop
  mock; `install.sh`.
- **Manual gate (docs):** real Vast.ai stop/start (`docs/DEPLOY.md`). Still
  required by PRD BR-05.

## 6. Likely Change Surface

- **New:** `install.sh` (first-time only: env examples, onstart wiring, SSH
  keep hook). Separate start script (clone/update, `train.sh`, one-shot
  notices, stop decision). Training-repo env example (public git URL only).
- **Extend:** `bin/envutil.py` allowlist (`VAST_API_KEY`, instance id if
  file-based, training URL if merged parser is used); `SECRET_KEYS`;
  two-file load; permission policy vs PRD.
- **Reuse with behavior change:** `install-login-ack.sh` → create
  `/workspace/KEEP_ALIVE`; `onstart.sh` / onstart template to launch the
  start script instead of (or in addition to retiring) the nag daemon;
  default `DATA_DIR` / `INSTALL_DIR` → `/workspace/vastai`.
- **New templates** for five lifecycle events × channels (or shared body +
  subject).
- **Stop helper** modeled on `deploy_vastai_wikitext_small.sh` REST call,
  without pip/CLI as a required dependency.
- **Tests:** mock git checkout, fake `train.sh`, keep flags, mocked stop
  HTTP, leftover `KEEP_ALIVE` vs `KEEP_ALIVE_PERMANENT`.
- **Docs:** `README.md`, `docs/DEPLOY.md`, `ARCHITECTURE.md` still describe
  nag-until-ACK and `/workspace/vastai-wakeup`.
- **Likely retire or stop advertising:** `ack.sh` nag ACK, `--keep-ack`
  as host ACK, alert backoff loop as the host-start path (PRD NG-11).

## 7. Reusable Components / Modules

- `bin/envutil.py`, `dump_env_shell.py`, `lib.sh` `eval_shell_exports`
- `bin/send_email_from_template.sh`, `send_telegram.sh`, `send_sms.sh`
- `bin/render_template.py`, `sanitize_output.py`
- `bin/session_id.py` lock / daemon-status / verified stop
- `bin/pin_revision.sh` for **this** repo only
- `bin/lib.sh` logging/rotation/writable checks
- `tests/mock_http.py`, `mock_smtp.py`, `tests/helpers.sh`, `tests/run.sh`
- `bin/install-login-ack.sh` as a pattern for bashrc snippet install/uninstall
- Stop URL/method in `deploy_vastai_wikitext_small.sh` as **evidence of an
  existing API shape**, not as a script to keep as the v1 start path

## 8. Risks and Compatibility Concerns

- **Path rename:** existing operators and onstart snippets use
  `/workspace/vastai-wakeup`. Approved default is `/workspace/vastai`.
- **Permissions:** code **fails** insecure `wakeup.env`; PRD **warns and
  continues**. Architecture must pick an implementation that matches the
  PRD or the Product Gate must be reopened.
- **Product vs shipped behavior:** nag-until-ACK, `ack.sh`, and
  session-token ACK are the current public contract (`README.md`). v1
  replaces them. Residual ACK tests (`tests/test_ack.sh`, `test_loop.sh`)
  will not describe the new start path.
- **`deploy_vastai_wikitext_small.sh`:** tempting to reuse; it pulls a
  private-purpose training stack, uses `pip`, `git pull --ff-only` (fails
  or keeps dirty tracked files), and sources env as shell. Using it as the
  start script would violate several constraints.
- **Stop API:** needs an **instance id** as well as `VAST_API_KEY`. The
  notifier never reads instance id today. If the key is in env but id is
  missing, stop cannot match SC-01.
- **Training duration vs onstart:** if the start script is not detached,
  Vast.ai may kill onstart while `train.sh` runs (not proven; see §9).
- **SSH hook:** current hook is opt-in after deploy; PRD says install
  enables it, with disable. Any SSH (including automation) will skip stop
  for that start (`SC-17`).
- **Git update:** `git reset --hard` (inference) discards tracked edits and
  keeps untracked files; `git clean` would delete new files and must not be
  the unattended update. `git pull --ff-only` does not match SC-12.
- **Two env files:** parser is built for one allowlisted file. Training URL
  file must not be executed as shell and should not export `PATH`.
- **Channel `--test-channels`:** implemented on `wakeup.sh` and currently
  implies `--once` and `--keep-ack`. v1 still requires channel test without
  training or stop (`SC-08`).

## 9. Unknowns / Inferences

- **Unknown:** Whether Vast.ai kills a long-running onstart process after a
  timeout. **Inference:** `onstart.sh` backgrounds `wakeup.sh` because
  onstart is expected to return; the training start script should be
  similarly detached and locked.
- **Unknown:** Where `VAST_INSTANCE_ID` comes from on a real instance
  (env, Vast.ai metadata file, API lookup). Only the standalone deploy
  script documents `VAST_INSTANCE_ID`.
- **Unknown:** Whether `console.vast.ai/api/v0/instances/{id}/` with
  `{"state":"stopped"}` is still the supported stop API; it is the only
  in-repo evidence.
- **Unknown:** Whether `git`/`git reset` are always present on the supported
  image without `apt-get` (clone instructions assume git).
- **Inference:** Keep flags at `/workspace/KEEP_ALIVE` sit **outside**
  `DATA_DIR` if `DATA_DIR` remains the project checkout; leftover
  `KEEP_ALIVE` clearing must not delete `KEEP_ALIVE_PERMANENT`.
- **Inference:** Session identity in `session_id.py` is still useful to
  ignore leftover `KEEP_ALIVE` across stop/start, even without ACK.
- **Unknown:** Fate of `deploy_vastai_wikitext_small.sh` (leave as unrelated
  operator script vs remove vs ignore). Not specified in the PRD.

## 10. Evidence

### Paths inspected

- `README.md`, `ARCHITECTURE.md`, `FIX_IMPLEMENTATION_PLAN.md`,
  `docs/DEPLOY.md`, `docs/SECURITY.md`, `docs/CHANNELS.md`, `docs/SPINOFF.md`
- `bin/wakeup.sh`, `bin/onstart.sh`, `bin/lib.sh`, `bin/envutil.py`,
  `bin/dump_env_shell.py`, `bin/session_id.py`, `bin/render_template.py`,
  `bin/pin_revision.sh`, `bin/install-login-ack.sh`, `bin/ack.sh` (presence),
  `bin/send_telegram.sh`, `bin/selftest.sh`
- `templates/onstart.vastai.sh`, `templates/wakeup.env.example`,
  `templates/alert-telegram.txt`
- `tests/run.sh`, `tests/helpers.sh`, `tests/mock_http.py`, listed
  `tests/test_*.sh`
- `deploy_vastai_wikitext_small.sh`
- `.github/workflows/ci.yml`, `.gitignore`, `.shellcheckrc`, `.gitattributes`
- Approved: `tasks/state-wakeup-notifier.md`, `tasks/prd-wakeup-notifier.md`,
  `tasks/scenarios-wakeup-notifier.feature`

### Configuration files inspected

- `templates/wakeup.env.example`
- `.github/workflows/ci.yml`
- `.gitignore`
- `.shellcheckrc`
- `.gitattributes`

No `package.json` / `pyproject.toml` / `requirements.txt`.

### Commands discovered

- `bash bin/selftest.sh` — operator and CI test entry
- `bash tests/run.sh` — unittest + `tests/test_*.sh`
- `bin/wakeup.sh --test-channels` / `--dry-run` / `--once` / `--keep-ack`
- `bin/ack.sh`
- `bin/install-login-ack.sh` / `--uninstall`
- `bash templates/onstart.vastai.sh` (requires `WAKEUP_REVISION`)
- `bin/pin_revision.sh --repo DIR REVISION`
- CI: `bash bin/selftest.sh`; `shellcheck --severity=warning -x bin/*.sh tests/*.sh templates/onstart.vastai.sh`

## Constraints the architecture phase must respect

1. Fit the existing Bash/Python-stdlib/curl in-instance layout; do not add
   pip, a web stack, or nested Docker.
2. Reuse channel adapters, env parser, logging, locks, pin-revision, and
   test mocks; do not invent a second notification stack.
3. Default path `/workspace/vastai` (product) vs today's
   `/workspace/vastai-wakeup` (code/docs) must be an explicit migration.
4. Implement **warn-and-continue** for loose env mode if the PRD stands;
   current code **rejects**.
5. `install.sh` must not clone/train; a **separate** start script does
   clone/update/`train.sh`/notices/stop; onstart must invoke that script
   without overlapping runs.
6. Training git: public URL, default branch, `/workspace/<repo-name>`,
   discard tracked edits, **keep untracked files** — not `git pull --ff-only`
   and not `git clean`.
7. One-shot notices only; no nag-until-ACK on the host-start path. SSH
   creates `KEEP_ALIVE` only. Stop via API, never destroy. Need a defined
   instance-id source plus `VAST_API_KEY` in the orchestrator env file.
8. CI remains offline, credential-free, Python 3.9/3.10 + ShellCheck;
   new paths need mocks (git, `train.sh`, stop, keep flags).
9. Detach long-running training from onstart the way `wakeup.sh` is
   already backgrounded, unless architecture proves onstart may block for
   the full train duration.
