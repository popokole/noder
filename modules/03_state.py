#!/usr/bin/env python3
"""
03_state.py — чтение, запись и валидация state.json для noder.

Использование:
    state.py init [--node-name NAME]      Создать пустой state.json с дефолтами.
    state.py get <jsonpath>                Прочитать значение (dot-separated, e.g. reality.port).
    state.py set <jsonpath> <value>        Записать значение (тип угадывается: bool/int/string/json).
    state.py dump [--mask]                 Вывести весь state (с маскированием секретов).
    state.py validate                      Проверить структуру.
    state.py backup                        Сохранить копию в /var/backups/noder/state/.
    state.py path                          Распечатать путь к файлу состояния.

Файл хранится в /etc/noder/state.json с правами 0600 root:root.
by popokole
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

STATE_PATH = Path(os.environ.get("NODER_STATE_FILE", "/etc/noder/state.json"))
BACKUP_DIR = Path(os.environ.get("NODER_BACKUP_DIR", "/var/backups/noder")) / "state"

SCHEMA_VERSION = "1.0"

# Keys whose values must never be printed in cleartext.
SECRET_KEYS = {
    "secret_key",
    "private_key",
    "token",
    "token_encrypted",
    "tg_token",
    "panel_token",
    "api_token",
}


DEFAULT_STATE: dict = {
    "version": SCHEMA_VERSION,
    "node_name": None,
    "installed_at": None,
    "mode": None,                       # "reality" | "selfsteal"
    "reality": {
        "port": None,
        "dest": None,
        "server_names": [],
        "private_key": None,
        "public_key": None,
        "short_ids": [],
    },
    "selfsteal": None,                  # {"domain": "...", "cert_dir": "..."}
    "panel": {
        "host": None,
        "ip": None,
        "node_port": None,
        "secret_key": None,
    },
    "panel_api": {
        "enabled": False,
        "base_url": None,
        "token_encrypted": None,
        "node_uuid": None,
        "config_profile_uuid": None,
        "inbound_uuid": None,
        "auto_apply_after_regen": False,
        "auto_apply_after_update": False,
        "require_telegram_confirm": True,
    },
    "telegram": {
        "enabled": False,
        "tg_token": None,
        "chat_id": None,
        "trusted_ids": [],
    },
    "ssh_hardening": False,
    "blocklist_last_update": None,
    "blocklist_sources": {
        "geosite_url": None,
        "geoip_url": None,
        "ru_bypass_url": None,
        "firewall_url": None,
    },
    "xray_version": None,
    "image_version": None,
}


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load() -> dict:
    if not STATE_PATH.exists():
        return json.loads(json.dumps(DEFAULT_STATE))  # deep copy
    try:
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise SystemExit(f"state.json corrupted: {e}")


def atomic_write(data: dict) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True, mode=0o750)
    # Write to tmp in the same dir for atomic rename.
    fd, tmp = tempfile.mkstemp(prefix=".state.", suffix=".json", dir=str(STATE_PATH.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.chmod(tmp, 0o600)
        # chown to root:root if we are root.
        if os.geteuid() == 0:
            try:
                os.chown(tmp, 0, 0)
            except OSError:
                pass
        os.replace(tmp, STATE_PATH)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def backup_current() -> Path | None:
    if not STATE_PATH.exists():
        return None
    try:
        BACKUP_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    except PermissionError as e:
        sys.stderr.write(f"warning: cannot create state backup dir {BACKUP_DIR}: {e}\n")
        return None
    stamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    dst = BACKUP_DIR / f"state-{stamp}.json"
    try:
        shutil.copy2(STATE_PATH, dst)
        os.chmod(dst, 0o600)
    except OSError as e:
        sys.stderr.write(f"warning: state backup failed: {e}\n")
        return None
    return dst


def _walk(obj: dict, path: list[str], create: bool = False):
    cur = obj
    for i, part in enumerate(path[:-1]):
        if isinstance(cur, list):
            cur = cur[int(part)]
            continue
        if part not in cur or cur[part] is None:
            if create:
                cur[part] = {}
            else:
                return None, None
        cur = cur[part]
    return cur, path[-1]


def get_path(obj: dict, dotted: str):
    if not dotted:
        return obj
    cur = obj
    for part in dotted.split("."):
        if isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                return None
            continue
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def set_path(obj: dict, dotted: str, value) -> None:
    parts = dotted.split(".")
    parent, last = _walk(obj, parts, create=True)
    if parent is None:
        raise KeyError(dotted)
    if isinstance(parent, list):
        parent[int(last)] = value
    else:
        parent[last] = value


def coerce_value(raw: str):
    """Best-effort type coercion for CLI values."""
    if raw.lower() in ("true", "false"):
        return raw.lower() == "true"
    if raw.lower() in ("null", "none", "~"):
        return None
    # JSON literal (objects, arrays, numbers, quoted strings)
    if raw and raw[0] in "[{\"":
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            pass
    # Integer
    try:
        if raw and (raw[0] in "-+0123456789"):
            return int(raw)
    except ValueError:
        pass
    return raw


def mask_secrets(obj):
    """Return a deep copy with secret values replaced by masked forms."""
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k in SECRET_KEYS and isinstance(v, str) and v:
                if len(v) <= 8:
                    out[k] = "***"
                else:
                    out[k] = f"{v[:4]}***{v[-4:]}"
            else:
                out[k] = mask_secrets(v)
        return out
    if isinstance(obj, list):
        return [mask_secrets(x) for x in obj]
    return obj


def cmd_init(args) -> int:
    if STATE_PATH.exists() and not args.force:
        sys.stderr.write(f"state.json already exists at {STATE_PATH}; use --force to overwrite\n")
        return 1
    backup_current()
    data = json.loads(json.dumps(DEFAULT_STATE))
    if args.node_name:
        data["node_name"] = args.node_name
    data["installed_at"] = now_utc()
    atomic_write(data)
    print(STATE_PATH)
    return 0


def cmd_get(args) -> int:
    data = load()
    value = get_path(data, args.path)
    if value is None:
        return 1
    if isinstance(value, (dict, list)):
        print(json.dumps(value, ensure_ascii=False))
    else:
        print(value if value is not None else "")
    return 0


def cmd_set(args) -> int:
    data = load()
    backup_current()
    set_path(data, args.path, coerce_value(args.value))
    atomic_write(data)
    return 0


def cmd_dump(args) -> int:
    data = load()
    if args.mask:
        data = mask_secrets(data)
    print(json.dumps(data, indent=2, ensure_ascii=False))
    return 0


def cmd_validate(_args) -> int:
    data = load()
    errors = []
    if data.get("version") != SCHEMA_VERSION:
        errors.append(f"unexpected version: {data.get('version')!r}")
    if data.get("node_name") in (None, ""):
        errors.append("node_name is empty")
    mode = data.get("mode")
    if mode not in (None, "reality", "selfsteal"):
        errors.append(f"invalid mode: {mode!r}")
    if mode == "reality":
        for k in ("port", "dest", "public_key", "private_key"):
            if not data.get("reality", {}).get(k):
                errors.append(f"reality.{k} is empty")
    if mode == "selfsteal" and not data.get("selfsteal"):
        errors.append("selfsteal block is empty")
    if errors:
        for e in errors:
            sys.stderr.write(f"ERROR: {e}\n")
        return 1
    print("ok")
    return 0


def cmd_backup(_args) -> int:
    dst = backup_current()
    if dst is None:
        sys.stderr.write("no state.json to backup\n")
        return 1
    print(dst)
    return 0


def cmd_path(_args) -> int:
    print(STATE_PATH)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="state.py", description="noder state.json manager")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init", help="create empty state.json with defaults")
    p_init.add_argument("--node-name")
    p_init.add_argument("--force", action="store_true")
    p_init.set_defaults(func=cmd_init)

    p_get = sub.add_parser("get", help="read value")
    p_get.add_argument("path")
    p_get.set_defaults(func=cmd_get)

    p_set = sub.add_parser("set", help="write value")
    p_set.add_argument("path")
    p_set.add_argument("value")
    p_set.set_defaults(func=cmd_set)

    p_dump = sub.add_parser("dump", help="print full state")
    p_dump.add_argument("--mask", action="store_true")
    p_dump.set_defaults(func=cmd_dump)

    p_val = sub.add_parser("validate", help="validate schema")
    p_val.set_defaults(func=cmd_validate)

    p_bak = sub.add_parser("backup", help="snapshot state.json")
    p_bak.set_defaults(func=cmd_backup)

    p_path = sub.add_parser("path", help="print state.json path")
    p_path.set_defaults(func=cmd_path)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
