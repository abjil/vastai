# Shared helpers. Source from other scripts in this directory.
# shellcheck shell=bash

eval_shell_exports() {
  local output=$1
  local line
  local assignments=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]+= ]]; then
      assignments+="$line"$'\n'
    elif [[ -n "$line" ]]; then
      printf '%s\n' "$line" >&2
    fi
  done <<< "$output"
  # Assignments are KEY=VALUE lines only; reserved names are rejected earlier.
  # shellcheck disable=SC2294
  eval "$assignments"
}

resolve_python() {
  local c
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "import sys" >/dev/null 2>&1; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  echo "ERROR: python3 (or python) is required." >&2
  return 1
}

rotate_log_file() {
  local file=$1
  local max_bytes=$2
  local backups=$3
  local size=0
  local i

  [[ -f "$file" ]] || return 0
  size=$(wc -c < "$file" 2>/dev/null || printf '0')
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  if ((size < max_bytes)); then
    return 0
  fi

  if ((backups == 0)); then
    : > "$file"
    return 0
  fi

  rm -f "$file.$backups"
  for ((i = backups - 1; i >= 1; i--)); do
    if [[ -f "$file.$i" ]]; then
      mv -f "$file.$i" "$file.$((i + 1))"
    fi
  done
  mv -f "$file" "$file.1"
}

acquire_log_lock() {
  local lock=$1
  local i
  local old_pid

  for ((i = 0; i < 40; i++)); do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "$$" > "$lock/pid"
      return 0
    fi
    if [[ -f "$lock/pid" ]]; then
      old_pid=$(tr -d '[:space:]' < "$lock/pid" 2>/dev/null || true)
      if [[ "$old_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$old_pid" 2>/dev/null; then
        rm -rf "$lock"
        continue
      fi
    fi
    sleep 0.05
  done
  return 1
}

release_log_lock() {
  local lock=$1
  rm -rf "$lock"
}

append_raw_log() {
  local file=$1
  local max_bytes=$2
  local backups=$3
  local text=$4
  local lock="${file}.lock"
  local locked=0

  mkdir -p "$(dirname "$file")"
  if acquire_log_lock "$lock"; then
    locked=1
  fi
  rotate_log_file "$file" "$max_bytes" "$backups"
  printf '%s\n' "$text" >> "$file"
  if [[ "$locked" -eq 1 ]]; then
    release_log_lock "$lock"
  fi
}

log_message() {
  local file=$1
  local max_bytes=$2
  local backups=$3
  local message=$4
  local line

  line="$(date -u +'%Y-%m-%d %H:%M:%S UTC'): $message"
  append_raw_log "$file" "$max_bytes" "$backups" "$line"
  printf '%s\n' "$line"
}

ensure_writable_dir() {
  local directory=$1
  local probe

  mkdir -p "$directory" || return 1
  probe="$directory/.wakeup-write-test.$$"
  : > "$probe" || return 1
  rm -f "$probe"
}

ensure_writable_parent() {
  local path=$1
  ensure_writable_dir "$(dirname "$path")"
}

ensure_writable_path() {
  local path=$1
  ensure_writable_parent "$path" || return 1
  [[ ! -e "$path" || -w "$path" ]]
}

ensure_templates_readable() {
  local directory=$1
  local name
  local names=(
    alert-email.txt alert-telegram.txt alert-sms.txt
    acked-email.txt acked-telegram.txt acked-sms.txt
  )

  [[ -d "$directory" && -r "$directory" ]] || return 1
  for name in "${names[@]}"; do
    [[ -r "$directory/$name" ]] || return 1
  done
}
