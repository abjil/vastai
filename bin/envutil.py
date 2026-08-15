"""Configuration parsing, precedence, validation, and sanitization."""

from __future__ import annotations

import base64
import os
import re
import shlex
from collections.abc import Mapping
from pathlib import Path
from typing import List, Optional
from urllib.parse import quote


_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_TRUE_VALUES = {"1", "yes", "true", "on"}
_FALSE_VALUES = {"0", "no", "false", "off"}

DEFAULTS = {
    "INSTANCE_NAME": "vastai",
    "INTERVAL_SEC": "60",
    "INTERVAL_MAX_SEC": "900",
    "ACK_POLL_SEC": "5",
    "MAX_ALERTS": "0",
    "WAKEUP_DRY_RUN": "0",
    "SMTP_TIMEOUT": "30",
    "CHANNEL_TIMEOUT_SEC": "30",
    "ERROR_DETAIL_MAX_CHARS": "2048",
    "LOG_MAX_BYTES": "1048576",
    "LOG_BACKUP_COUNT": "3",
}

# Credentials and message recipients remain file-only. These operational values
# may be overridden by the process environment for tests and deployment.
OPERATIONAL_OVERRIDE_KEYS = {
    "DATA_DIR",
    "ACK_FILE",
    "WAKEUP_LOG",
    "WAKEUP_ERROR_LOG",
    "WAKEUP_PID",
    "WAKEUP_RUNTIME",
    "WAKEUP_TEMPLATES",
    "STARTED_AT_FILE",
    "INSTANCE_NAME",
    "INTERVAL_SEC",
    "INTERVAL_MAX_SEC",
    "ACK_POLL_SEC",
    "MAX_ALERTS",
    "WAKEUP_DRY_RUN",
    "SMTP_TIMEOUT",
    "CHANNEL_TIMEOUT_SEC",
    "ERROR_DETAIL_MAX_CHARS",
    "LOG_MAX_BYTES",
    "LOG_BACKUP_COUNT",
    "WAKEUP_UPTIME_FILE",
}

_POSITIVE_INTEGERS = {
    "INTERVAL_SEC",
    "INTERVAL_MAX_SEC",
    "ACK_POLL_SEC",
    "SMTP_TIMEOUT",
    "CHANNEL_TIMEOUT_SEC",
    "ERROR_DETAIL_MAX_CHARS",
    "LOG_MAX_BYTES",
}
_NONNEGATIVE_INTEGERS = {"MAX_ALERTS", "LOG_BACKUP_COUNT"}
_BOOLEAN_KEYS = {"WAKEUP_DRY_RUN", "SMTP_TLS", "SMTP_SSL"}
_PATH_KEYS = {
    "DATA_DIR",
    "ACK_FILE",
    "WAKEUP_LOG",
    "WAKEUP_ERROR_LOG",
    "WAKEUP_PID",
    "WAKEUP_RUNTIME",
    "WAKEUP_TEMPLATES",
    "STARTED_AT_FILE",
}

_CHANNEL_REQUIREMENTS = {
    "email": ("SMTP_HOST", "SMTP_FROM", "SMTP_TO"),
    "telegram": ("TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID"),
    "sms": ("TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_FROM", "SMS_TO"),
}

SECRET_KEYS = {
    "SMTP_PASSWORD",
    "TELEGRAM_BOT_TOKEN",
    "TWILIO_AUTH_TOKEN",
}

# Keys that may be exported into Bash. Unknown file keys stay parsed but are
# not eval'd, so they cannot overwrite CLI flags or the process environment.
CONFIG_EXPORT_KEYS = (
    set(DEFAULTS)
    | OPERATIONAL_OVERRIDE_KEYS
    | {
        "ACK_FILE",
        "WAKEUP_LOG",
        "WAKEUP_ERROR_LOG",
        "WAKEUP_PID",
        "WAKEUP_RUNTIME",
        "WAKEUP_TEMPLATES",
        "STARTED_AT_FILE",
        "SMTP_HOST",
        "SMTP_PORT",
        "SMTP_TLS",
        "SMTP_SSL",
        "SMTP_USER",
        "SMTP_PASSWORD",
        "SMTP_FROM",
        "SMTP_FROM_NAME",
        "SMTP_TO",
        "SMTP_CC",
        "SMTP_BCC",
        "EMAIL_SUBJECT",
        "EMAIL_CONTENT_TYPE",
        "TELEGRAM_BOT_TOKEN",
        "TELEGRAM_CHAT_ID",
        "TWILIO_ACCOUNT_SID",
        "TWILIO_AUTH_TOKEN",
        "TWILIO_FROM",
        "SMS_TO",
    }
)

RESERVED_EXPORT_KEYS = {
    "DRY_RUN",
    "ONCE",
    "KEEP_ACK",
    "TEST_CHANNELS",
    "PATH",
    "HOME",
    "PYTHONPATH",
    "PYTHON",
    "IFS",
    "BASH",
    "BASH_ENV",
    "ENV",
    "CDPATH",
    "SHELLOPTS",
    "BASHOPTS",
    "LD_PRELOAD",
    "LD_LIBRARY_PATH",
}

_DERIVED_SECRET_PAIRS = (
    ("TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN"),
)


class ConfigError(ValueError):
    """Raised when wakeup configuration is malformed or inconsistent."""


def parse_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    text = path.read_text(encoding="utf-8")
    for line_number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].lstrip()
        if "=" not in line:
            raise ConfigError(f"{path}:{line_number}: expected KEY=VALUE")
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip()
        if not _KEY_RE.match(key):
            raise ConfigError(f"{path}:{line_number}: invalid key {key!r}")
        try:
            parts = shlex.split(val, posix=True)
        except ValueError as exc:
            raise ConfigError(f"{path}:{line_number}: {exc}") from exc
        if len(parts) > 1:
            raise ConfigError(
                f"{path}:{line_number}: quote values containing whitespace"
            )
        val = parts[0] if parts else ""
        env[key] = val
    return env


def bool_env(env: dict[str, str], key: str, default: bool = False) -> bool:
    value = str(env.get(key, ""))
    if value == "":
        return default
    return value.strip().lower() in _TRUE_VALUES


def split_list(value: str) -> list[str]:
    if not value:
        return []
    return [x.strip() for x in value.replace(";", ",").split(",") if x.strip()]


def shell_exports(env: dict[str, str]) -> str:
    lines = []
    for key, val in env.items():
        if key not in CONFIG_EXPORT_KEYS or key in RESERVED_EXPORT_KEYS:
            continue
        if not _KEY_RE.match(key):
            continue
        lines.append(f"{key}={shlex.quote(val)}")
    return "\n".join(lines) + ("\n" if lines else "")


def load_config(
    path: Path,
    *,
    root_dir: Optional[Path] = None,
    environ: Optional[Mapping[str, str]] = None,
    require_channel: bool = False,
    dry_run: bool = False,
) -> dict[str, str]:
    """Load defaults, file values, and documented operational overrides."""

    config = dict(DEFAULTS)
    config.update(parse_env(path))

    source_env = os.environ if environ is None else environ
    for key in OPERATIONAL_OVERRIDE_KEYS:
        if key in source_env:
            config[key] = str(source_env[key])

    root = (root_dir or path.resolve().parent).resolve()
    data_dir = config.get("DATA_DIR") or str(root)
    config["DATA_DIR"] = data_dir
    config.setdefault("ACK_FILE", str(Path(data_dir) / "ACK"))
    config.setdefault("WAKEUP_LOG", str(Path(data_dir) / "wakeup.log"))
    config.setdefault("WAKEUP_ERROR_LOG", str(Path(data_dir) / "wakeup-error.log"))
    config.setdefault("WAKEUP_PID", str(Path(data_dir) / "wakeup.pid"))
    config.setdefault("WAKEUP_RUNTIME", str(Path(data_dir) / "runtime"))
    config.setdefault("WAKEUP_TEMPLATES", str(root / "templates"))
    config.setdefault("STARTED_AT_FILE", str(Path(data_dir) / "started_at"))

    validate_config(
        config,
        require_channel=require_channel,
        dry_run=dry_run or bool_env(config, "WAKEUP_DRY_RUN"),
    )
    return config


def validate_config(
    config: Mapping[str, str],
    *,
    require_channel: bool = False,
    dry_run: bool = False,
) -> None:
    errors: list[str] = []

    for key in sorted(_POSITIVE_INTEGERS):
        value = str(config.get(key, ""))
        try:
            number = int(value)
        except ValueError:
            errors.append(f"{key} must be a positive integer (got {value!r})")
            continue
        if number <= 0:
            errors.append(f"{key} must be greater than zero (got {value!r})")

    for key in sorted(_NONNEGATIVE_INTEGERS):
        value = str(config.get(key, ""))
        try:
            number = int(value)
        except ValueError:
            errors.append(f"{key} must be a non-negative integer (got {value!r})")
            continue
        if number < 0:
            errors.append(f"{key} must not be negative (got {value!r})")

    smtp_port = str(config.get("SMTP_PORT", ""))
    if smtp_port:
        try:
            if int(smtp_port) <= 0:
                raise ValueError
        except ValueError:
            errors.append(f"SMTP_PORT must be a positive integer (got {smtp_port!r})")

    for key in sorted(_BOOLEAN_KEYS):
        value = str(config.get(key, ""))
        if value and value.strip().lower() not in _TRUE_VALUES | _FALSE_VALUES:
            errors.append(
                f"{key} must be one of 1/0, yes/no, true/false, or on/off"
            )

    try:
        if int(config.get("INTERVAL_MAX_SEC", "0")) < int(
            config.get("INTERVAL_SEC", "0")
        ):
            errors.append("INTERVAL_MAX_SEC must be >= INTERVAL_SEC")
    except ValueError:
        pass

    if bool_env(dict(config), "SMTP_TLS") and bool_env(dict(config), "SMTP_SSL"):
        errors.append("SMTP_TLS and SMTP_SSL cannot both be enabled")

    for key in sorted(_PATH_KEYS):
        if not str(config.get(key, "")).strip():
            errors.append(f"{key} must not be empty")

    if require_channel:
        enabled_channels: list[str] = []
        for channel, required_keys in _CHANNEL_REQUIREMENTS.items():
            present = [
                key for key in required_keys if str(config.get(key, "")).strip()
            ]
            if present and len(present) != len(required_keys):
                missing = [key for key in required_keys if key not in present]
                errors.append(
                    f"incomplete {channel} configuration; "
                    f"missing {', '.join(missing)}"
                )
            elif len(present) == len(required_keys):
                enabled_channels.append(channel)

        smtp_user = str(config.get("SMTP_USER", "")).strip()
        smtp_password = str(config.get("SMTP_PASSWORD", "")).strip()
        if bool(smtp_user) != bool(smtp_password):
            errors.append("SMTP_USER and SMTP_PASSWORD must be set together")

        if not dry_run and not enabled_channels:
            errors.append("at least one complete notification channel is required")

    if errors:
        raise ConfigError("; ".join(errors))


def _secret_variants(value: str) -> list[str]:
    variants = {value}
    if not value:
        return []
    variants.add(quote(value, safe=""))
    variants.add(base64.b64encode(value.encode("utf-8")).decode("ascii"))
    return [item for item in variants if item]


def _derived_secrets(config: Mapping[str, str]) -> list[str]:
    derived: list[str] = []
    for left_key, right_key in _DERIVED_SECRET_PAIRS:
        left = str(config.get(left_key, "")).strip()
        right = str(config.get(right_key, "")).strip()
        if left and right:
            pair = f"{left}:{right}"
            derived.append(pair)
            derived.append(base64.b64encode(pair.encode("utf-8")).decode("ascii"))
    return derived


def sanitize_detail(
    text: str,
    *,
    config: Optional[Mapping[str, str]] = None,
    secrets: Optional[List[str]] = None,
    limit: int = 2048,
) -> str:
    """Redact configured credentials and bound provider-controlled detail."""

    cleaned = text.replace("\x00", "").replace("\r\n", "\n").replace("\r", "\n")
    sensitive_values = list(secrets or [])
    if config is not None:
        sensitive_values.extend(str(config.get(key, "")) for key in SECRET_KEYS)
        sensitive_values.extend(_derived_secrets(config))
    expanded: list[str] = []
    for value in sensitive_values:
        expanded.extend(_secret_variants(str(value)))
    for value in sorted({item for item in expanded if item}, key=len, reverse=True):
        cleaned = cleaned.replace(value, "[REDACTED]")
    if len(cleaned) > limit:
        suffix = "\n...[truncated]"
        cleaned = cleaned[: max(0, limit - len(suffix))] + suffix
    return cleaned
