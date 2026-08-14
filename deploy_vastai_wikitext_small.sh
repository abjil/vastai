#!/usr/bin/env bash
# End-to-end Vast.ai deployment for WikiText-103 small-model training.
#
# Usage (on the rented instance):
#   bash deploy_vastai_wikitext_small.sh
#   bash deploy_vastai_wikitext_small.sh --stop <instance_id>
#
# Progress is written to stdout and /workspace/deploy_wikitext.log.
# If you SSH in after onstart started the script, run:
#   tail -f /workspace/deploy_wikitext.log
#
# Or:
#   VAST_INSTANCE_ID=12345 STOP_AFTER_TRAINING=1 bash deploy_vastai_wikitext_small.sh
#
# Optional stop after training (--stop or STOP_AFTER_TRAINING=1):
#   export VAST_API_KEY=...   # required when stopping via API
# The first interactive run securely prompts for WANDB_API_KEY and saves it
# to /workspace/tbp-mHC/.env for subsequent runs.
# Legacy: SKIP_VAST_STOP=1 disables stop even if --stop is set.

set -euo pipefail

LOG_FILE="${DEPLOY_LOG:-/workspace/deploy_wikitext.log}"
mkdir -p "$(dirname "${LOG_FILE}")"
# Mirror stdout/stderr to a log file so progress is visible over SSH and after
# onstart detaches. Disable with DEPLOY_NO_TEE=1.
if [[ "${DEPLOY_NO_TEE:-0}" != "1" ]]; then
  exec > >(tee -a "${LOG_FILE}") 2>&1
fi
echo "=== Deploy log: ${LOG_FILE} (tail -f ${LOG_FILE}) ==="

export PYTHONUNBUFFERED=1

STOP_AFTER_TRAINING="${STOP_AFTER_TRAINING:-0}"
INSTANCE_ID="${VAST_INSTANCE_ID:-}"

usage() {
  echo "Usage: $0 [--stop] [<vast_instance_id>]"
  echo "   or: STOP_AFTER_TRAINING=1 VAST_INSTANCE_ID=<id> $0"
  echo
  echo "  --stop    Stop the Vast.ai instance after training (needs VAST_API_KEY)."
  echo "            Default: leave the instance running."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop)
      STOP_AFTER_TRAINING=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -n "${INSTANCE_ID}" ]]; then
        echo "Error: unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      INSTANCE_ID="$1"
      shift
      ;;
  esac
done

if [[ "${SKIP_VAST_STOP:-0}" == "1" ]]; then
  STOP_AFTER_TRAINING=0
fi

if [[ "${STOP_AFTER_TRAINING}" == "1" && -z "${INSTANCE_ID}" ]]; then
  echo "Error: --stop requires a vast instance id." >&2
  usage >&2
  exit 1
fi

REPO_DIR="/workspace/tbp-mHC"
ENV_FILE="${REPO_DIR}/.env"
TRAINING_SCRIPT="${REPO_DIR}/train_local_wikitext_small.sh"
DATA_DIR="${REPO_DIR}/data/wikitext-103-raw-v1"
GDOWN_ID="1FdCBv9LOb8--BosHhtajc7zk_1HpjnwZ"
ARCHIVE_NAME="wikitext-103-raw-v1.7z"

stop_instance() {
  if [[ "${STOP_AFTER_TRAINING}" != "1" ]]; then
    return 0
  fi

  echo "Stopping vast.ai instance ${INSTANCE_ID}..."

  if [[ -n "${VAST_API_KEY:-}" ]]; then
    if curl -fsS -X PUT "https://console.vast.ai/api/v0/instances/${INSTANCE_ID}/" \
      -H "Accept: application/json" \
      -H "Authorization: Bearer ${VAST_API_KEY}" \
      -H "Content-Type: application/json" \
      -d '{"state": "stopped"}'; then
      echo
      echo "Stop request sent via Vast.ai API."
      return 0
    fi
    echo "Warning: Vast.ai API stop request failed."
  fi

  if command -v vastai >/dev/null 2>&1; then
    vastai stop instance "${INSTANCE_ID}" && return 0
    echo "Warning: vastai CLI failed to stop instance ${INSTANCE_ID}."
    return 0
  fi

  echo "Warning: cannot stop instance ${INSTANCE_ID} (set VAST_API_KEY or install vastai CLI)."
}

echo "=== Installing system packages ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y p7zip-full mc git

echo "=== Installing Python packages ==="
export PIP_ROOT_USER_ACTION=ignore
pip install --upgrade pip
# Do not pip-install vastai here: it pins cryptography and fails on NGC/Ubuntu
# images where cryptography is owned by apt. stop_instance uses the REST API.
pip install numpy transformers datasets tiktoken wandb tqdm einops gdown

echo "=== Cloning repository ==="
mkdir -p /workspace
if [[ -d "${REPO_DIR}/.git" ]]; then
  git -C "${REPO_DIR}" pull --ff-only
else
  git clone https://github.com/alyubinin/tbp-mHC "${REPO_DIR}"
fi

echo "=== Configuring Weights & Biases ==="
if [[ -z "${WANDB_API_KEY:-}" && -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

if [[ -z "${WANDB_API_KEY:-}" ]]; then
  if [[ ! -t 0 && ! -t 1 ]]; then
    echo "Error: WANDB_API_KEY is missing and no interactive terminal is available." >&2
    echo "Set WANDB_API_KEY in the environment before running this script." >&2
    exit 1
  fi

  read -r -s -p "Enter WANDB_API_KEY: " WANDB_API_KEY </dev/tty
  echo
  if [[ -z "${WANDB_API_KEY}" ]]; then
    echo "Error: WANDB_API_KEY cannot be empty." >&2
    exit 1
  fi
fi

if [[ ! -f "${ENV_FILE}" ]] || ! grep -q '^WANDB_API_KEY=' "${ENV_FILE}"; then
  printf 'WANDB_API_KEY=%q\n' "${WANDB_API_KEY}" >> "${ENV_FILE}"
fi
chmod 600 "${ENV_FILE}"

export WANDB_API_KEY
wandb login --relogin "${WANDB_API_KEY}"

echo "=== Downloading WikiText-103 dataset archive ==="
mkdir -p "${DATA_DIR}"
cd "${DATA_DIR}"
if [[ ! -f "${ARCHIVE_NAME}" ]]; then
  gdown "${GDOWN_ID}" -O "${ARCHIVE_NAME}"
fi

echo "=== Extracting dataset ==="
if [[ ! -f "${DATA_DIR}/train.bin" ]]; then
  7z x "${ARCHIVE_NAME}" -y -bb1
else
  echo "train.bin already exists — skipping extraction"
fi

if [[ ! -f "${DATA_DIR}/train.bin" ]]; then
  echo "Error: train.bin not found under ${DATA_DIR} after extraction."
  exit 1
fi

echo "=== GPU check ==="
nvidia-smi
python -c "import torch; [print(f'GPU {i}: {torch.cuda.get_device_name(i)}') for i in range(torch.cuda.device_count())]"

echo "=== Starting training ==="
set +e
# Line-buffer torchrun/Python so loss lines appear as they are emitted.
stdbuf -oL -eL bash "${TRAINING_SCRIPT}"
training_exit=$?
set -e

echo "=== Training finished (exit code: ${training_exit}) ==="
if [[ "${STOP_AFTER_TRAINING}" == "1" ]]; then
  stop_instance
else
  echo "Instance left running (pass --stop <id> to stop after training)."
fi
exit "${training_exit}"
