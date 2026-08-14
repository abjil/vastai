#!/usr/bin/env bash
# End-to-end Vast.ai deployment for WikiText-103 small-model training.
#
# Usage (on the rented instance):
#   export WANDB_API_KEY=...          # optional but recommended
#   export VAST_API_KEY=...           # required to stop the instance
#   bash deploy_vastai_wikitext_small.sh <instance_id>
#
# Progress is written to stdout and /workspace/deploy_wikitext.log.
# If you SSH in after onstart started the script, run:
#   tail -f /workspace/deploy_wikitext.log
#
# Or:
#   VAST_INSTANCE_ID=12345 bash deploy_vastai_wikitext_small.sh
#
# Set SKIP_VAST_STOP=1 to keep the instance running after training completes.

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

INSTANCE_ID="${1:-${VAST_INSTANCE_ID:-}}"
REPO_DIR="/workspace/tbp-mHC"
TRAINING_SCRIPT="${REPO_DIR}/train_local_wikitext_small.sh"
DATA_DIR="${REPO_DIR}/data/wikitext-103-raw-v1"
GDOWN_ID="1FdCBv9LOb8--BosHhtajc7zk_1HpjnwZ"
ARCHIVE_NAME="wikitext-103-raw-v1.7z"

if [[ -z "${INSTANCE_ID}" ]]; then
  echo "Usage: $0 <vast_instance_id>"
  echo "   or: VAST_INSTANCE_ID=<id> $0"
  exit 1
fi

stop_instance() {
  if [[ "${SKIP_VAST_STOP:-0}" == "1" ]]; then
    echo "SKIP_VAST_STOP=1 — leaving instance ${INSTANCE_ID} running."
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

if [[ -n "${WANDB_API_KEY:-}" ]]; then
  echo "=== Configuring Weights & Biases ==="
  wandb login --relogin "${WANDB_API_KEY}"
fi

echo "=== Cloning repository ==="
mkdir -p /workspace
if [[ -d "${REPO_DIR}/.git" ]]; then
  git -C "${REPO_DIR}" pull --ff-only
else
  git clone https://github.com/alyubinin/tbp-mHC "${REPO_DIR}"
fi

echo "=== Downloading WikiText-103 parquet archive ==="
mkdir -p "${DATA_DIR}/parquet"
cd "${DATA_DIR}"
if [[ ! -f "${ARCHIVE_NAME}" ]]; then
  gdown "${GDOWN_ID}" -O "${ARCHIVE_NAME}"
fi

echo "=== Extracting parquet files ==="
7z x "${ARCHIVE_NAME}" -y -bb1
if compgen -G "${DATA_DIR}/*.parquet" > /dev/null; then
  mv -f "${DATA_DIR}"/*.parquet "${DATA_DIR}/parquet/"
fi
if ! compgen -G "${DATA_DIR}/parquet/*.parquet" > /dev/null; then
  echo "Error: no parquet files found under ${DATA_DIR}/parquet after extraction."
  exit 1
fi

echo "=== Preparing tokenized dataset ==="
cd "${REPO_DIR}"
if [[ ! -f "${DATA_DIR}/train.bin" ]]; then
  python "${DATA_DIR}/prepare.py"
else
  echo "train.bin already exists — skipping prepare.py"
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
stop_instance
exit "${training_exit}"
