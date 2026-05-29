#!/usr/bin/env python3
"""
panel_api.py — опциональная интеграция с API панели Remnawave.

По умолчанию ВЫКЛЮЧЕНА. Токен хранится зашифрованным (AES через Fernet,
ключ выводится из /etc/machine-id + соли из /etc/noder/.salt). Все вызовы
логируются в /var/log/noder/api.log, токен в логах маскируется.

Команды CLI:

    panel_api.py enable                      Интерактивный setup (URL, токен, UUID)
    panel_api.py disable                     Отключить (токен остаётся в state)
    panel_api.py change                      Изменить URL/токен/UUID
    panel_api.py test                        GET /api/auth/me — проверка токена
    panel_api.py show                        Показать текущие настройки (токен маскирован)
    panel_api.py auto                        Меню автодействий
    panel_api.py wipe                        Стереть токен и связанные данные
    panel_api.py register                    Зарегистрировать ноду в панели
    panel_api.py apply-regen                 PATCH inbound + POST /restart после regen
    panel_api.py apply-update                POST /restart после update

Эндпоинты Remnawave (приближённо к публичной OpenAPI):

    GET    /api/auth/me
    GET    /api/nodes
    POST   /api/nodes
    GET    /api/config-profiles
    PATCH  /api/config-profiles/{uuid}/inbounds/{inbound_uuid}
    POST   /api/nodes/{uuid}/restart
    POST   /api/nodes/{uuid}/disable
    POST   /api/nodes/{uuid}/enable

Конкретные сигнатуры могут отличаться между минорными версиями панели —
обновляется при появлении расхождений.

by popokole
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import logging
import os
import pathlib
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

NODER_HOME = pathlib.Path(os.environ.get("NODER_HOME", "/opt/noder"))
STATE_FILE = pathlib.Path(os.environ.get("NODER_STATE_FILE", "/etc/noder/state.json"))
SALT_FILE = pathlib.Path(os.environ.get("NODER_STATE_DIR", "/etc/noder")) / ".salt"
LOG_FILE = pathlib.Path(os.environ.get("NODER_LOG_DIR", "/var/log/noder")) / "api.log"

# ---------------------------------------------------------------------------
# Logging — token always masked
# ---------------------------------------------------------------------------

def _mask(s: str | None) -> str:
    if not s:
        return ""
    if len(s) <= 8:
        return "***"
    return f"{s[:4]}***{s[-4:]}"

def _setup_log():
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        filename=str(LOG_FILE), level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    return logging.getLogger("noder.api")

log = _setup_log()

# ---------------------------------------------------------------------------
# Token encryption
# ---------------------------------------------------------------------------

def _machine_id() -> bytes:
    for p in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        if pathlib.Path(p).exists():
            return pathlib.Path(p).read_text(encoding="utf-8").strip().encode()
    # Last resort — hostname (not actually secure, but allows dev/test)
    import socket
    return socket.gethostname().encode()


def _ensure_salt() -> bytes:
    if SALT_FILE.exists():
        return SALT_FILE.read_bytes()
    SALT_FILE.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    salt = secrets.token_bytes(32)
    SALT_FILE.write_bytes(salt)
    SALT_FILE.chmod(0o600)
    try:
        if os.geteuid() == 0:
            os.chown(SALT_FILE, 0, 0)
    except OSError:
        pass
    return salt


def _derive_key() -> bytes:
    # 32 bytes for Fernet (then base64 to make a Fernet key)
    raw = hashlib.scrypt(_machine_id(), salt=_ensure_salt(), n=2**14, r=8, p=1, dklen=32)
    return base64.urlsafe_b64encode(raw)


def encrypt_token(plain: str) -> str:
    from cryptography.fernet import Fernet
    return Fernet(_derive_key()).encrypt(plain.encode()).decode()


def decrypt_token(cipher: str) -> str:
    from cryptography.fernet import Fernet, InvalidToken
    try:
        return Fernet(_derive_key()).decrypt(cipher.encode()).decode()
    except InvalidToken:
        raise SystemExit("Не удалось расшифровать токен — возможно, /etc/machine-id или /etc/noder/.salt изменились")


# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

def state() -> dict:
    if not STATE_FILE.exists():
        return {}
    return json.loads(STATE_FILE.read_text(encoding="utf-8"))


def state_set(path: str, value) -> None:
    subprocess.run(
        ["python3", str(NODER_HOME / "modules" / "03_state.py"), "set", path,
         value if isinstance(value, str) else json.dumps(value)],
        check=True,
    )


def api_cfg() -> dict:
    return state().get("panel_api", {}) or {}


def api_base() -> str:
    base = api_cfg().get("base_url") or ""
    return base.rstrip("/")


def api_token() -> str:
    cipher = api_cfg().get("token_encrypted")
    if not cipher:
        raise SystemExit("API-токен не сохранён. Вызовите: noder api enable")
    return decrypt_token(cipher)


# ---------------------------------------------------------------------------
# HTTP client with retries
# ---------------------------------------------------------------------------

class ApiError(Exception):
    def __init__(self, code: int, body: str):
        super().__init__(f"HTTP {code}: {body[:200]}")
        self.code = code
        self.body = body


def _http(method: str, path: str, body=None, *, retries: int = 3, timeout: int = 20) -> dict:
    url = f"{api_base()}{path}"
    token = api_token()
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "User-Agent": "noder/1.0",
    }
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"

    last_err = None
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        log.info("%s %s tok=%s try=%d", method, path, _mask(token), attempt)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode(errors="replace")
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            body_text = e.read().decode(errors="replace") if hasattr(e, "read") else ""
            log.warning("HTTP %s on %s: %s", e.code, path, body_text[:200])
            if e.code in (401, 403):
                _disable_for_invalid_token(e.code, body_text)
                raise ApiError(e.code, body_text)
            if e.code in (404,):
                raise ApiError(e.code, body_text)
            if e.code >= 500 and attempt < retries:
                time.sleep(2 ** attempt)
                last_err = e
                continue
            raise ApiError(e.code, body_text)
        except urllib.error.URLError as e:
            log.warning("URL error %s on %s (attempt %d/%d)", e, path, attempt, retries)
            last_err = e
            if attempt < retries:
                time.sleep(2 ** attempt)
                continue
            raise ApiError(0, str(e))
    raise ApiError(0, str(last_err))


def _disable_for_invalid_token(code: int, body: str) -> None:
    """401/403: токен невалиден → автодействия отключаем, шлём TG-алерт."""
    state_set("panel_api.auto_apply_after_regen", False)
    state_set("panel_api.auto_apply_after_update", False)
    log.error("token invalid (%s) — autoactions disabled; body=%s", code, body[:200])
    _notify_tg("api_token_invalid", code=code)


def _notify_tg(event: str, **kv) -> None:
    tg = NODER_HOME / "modules" / "09_telegram.py"
    if not tg.exists():
        return
    args = ["python3", str(tg), "notify", "--event", event] + [f"{k}={v}" for k, v in kv.items()]
    subprocess.run(args, check=False, capture_output=True, timeout=15)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_enable(_args) -> int:
    if os.geteuid() != 0:
        sys.exit("требует root")
    print("⚠ ВНИМАНИЕ: токен даёт ПОЛНЫЙ доступ к панели. Подробнее — см. ТЗ 7.2.")
    input("Нажмите Enter для продолжения или Ctrl+C для отмены… ")

    url = input("URL панели (например https://panel.example.com): ").strip()
    raw = input("API-токен: ").strip()
    if not url or not raw:
        sys.exit("URL и токен обязательны")
    if not url.startswith("http"):
        url = "https://" + url

    enc = encrypt_token(raw)
    state_set("panel_api.enabled", True)
    state_set("panel_api.base_url", url)
    state_set("panel_api.token_encrypted", enc)

    print(f"  base_url:  {url}")
    print(f"  token:     {_mask(raw)} (зашифрован)")
    try:
        me = _http("GET", "/api/auth/me")
        print(f"  /api/auth/me: OK — {json.dumps(me, ensure_ascii=False)[:200]}")
        return 0
    except ApiError as e:
        print(f"  /api/auth/me: FAIL — {e}")
        return 1


def cmd_disable(_args) -> int:
    state_set("panel_api.enabled", False)
    print("panel_api.enabled = false (токен остаётся; чтобы стереть — `noder api wipe`)")
    return 0


def cmd_change(_args) -> int:
    return cmd_enable(_args)


def cmd_test(_args) -> int:
    try:
        me = _http("GET", "/api/auth/me")
        print(json.dumps(me, indent=2, ensure_ascii=False))
        return 0
    except ApiError as e:
        print(f"FAIL: {e}")
        return 1


def cmd_show(_args) -> int:
    cfg = api_cfg()
    masked = dict(cfg)
    masked["token_encrypted"] = _mask(cfg.get("token_encrypted") or "")
    print(json.dumps(masked, indent=2, ensure_ascii=False))
    return 0


def cmd_auto(_args) -> int:
    if os.geteuid() != 0:
        sys.exit("требует root")
    cfg = api_cfg()
    print("Что делать автоматически (наберите 1 или 0):")
    for k in ("auto_apply_after_regen", "auto_apply_after_update"):
        cur = cfg.get(k, False)
        v = input(f"  {k} [{cur}]: ").strip()
        if v in ("1", "y", "yes", "true"):
            state_set(f"panel_api.{k}", True)
        elif v in ("0", "n", "no", "false"):
            state_set(f"panel_api.{k}", False)
    cur = cfg.get("require_telegram_confirm", True)
    v = input(f"  require_telegram_confirm [{cur}]: ").strip()
    if v in ("0", "n", "no", "false"):
        state_set("panel_api.require_telegram_confirm", False)
        print("  ⚠ автоприменение без подтверждения — только для опытных")
    elif v in ("1", "y", "yes", "true", ""):
        state_set("panel_api.require_telegram_confirm", True)
    return 0


def cmd_wipe(_args) -> int:
    """Стереть токен и связанные данные. Файлы перезаписываются перед удалением."""
    if os.geteuid() != 0:
        sys.exit("требует root")
    for k in ("token_encrypted", "node_uuid", "config_profile_uuid", "inbound_uuid", "base_url"):
        state_set(f"panel_api.{k}", None)
    state_set("panel_api.enabled", False)
    if SALT_FILE.exists():
        # Перезаписываем соль случайными байтами и удаляем — токен невозможно расшифровать.
        size = SALT_FILE.stat().st_size or 32
        SALT_FILE.write_bytes(secrets.token_bytes(size))
        SALT_FILE.unlink()
    print("Все API-данные стёрты.")
    return 0


def cmd_register(_args) -> int:
    """Зарегистрировать ноду в панели (POST /api/nodes)."""
    s = state()
    name = s.get("node_name")
    panel = s.get("panel", {})
    ip = panel.get("ip")
    port = panel.get("node_port")
    if not (name and ip and port):
        sys.exit("В state.json не хватает node_name/panel.ip/panel.node_port")
    payload = {
        "name": name,
        "address": ip,
        "port": int(port),
        # Замечание: реальный формат полей зависит от версии панели Remnawave.
    }
    try:
        res = _http("POST", "/api/nodes", body=payload)
        node_uuid = res.get("uuid") or res.get("id") or (res.get("data") or {}).get("uuid")
        if node_uuid:
            state_set("panel_api.node_uuid", node_uuid)
        print(json.dumps(res, indent=2, ensure_ascii=False))
        return 0
    except ApiError as e:
        print(f"FAIL: {e}")
        return 1


def cmd_apply_regen(_args) -> int:
    """PATCH inbound с новыми Reality-параметрами + POST /restart."""
    cfg = api_cfg()
    profile = cfg.get("config_profile_uuid")
    inbound = cfg.get("inbound_uuid")
    node_uuid = cfg.get("node_uuid")
    if not (profile and inbound and node_uuid):
        sys.exit("Не заданы config_profile_uuid / inbound_uuid / node_uuid в state.panel_api")
    r = state().get("reality", {})
    payload = {
        "reality": {
            "dest": r.get("dest"),
            "serverNames": r.get("server_names"),
            "publicKey": r.get("public_key"),
            "privateKey": r.get("private_key"),
            "shortIds": r.get("short_ids"),
        }
    }
    try:
        _http("PATCH", f"/api/config-profiles/{profile}/inbounds/{inbound}", body=payload)
        _http("POST", f"/api/nodes/{node_uuid}/restart")
        _notify_tg("api_apply_ok", action="regen")
        print("ok")
        return 0
    except ApiError as e:
        _notify_tg("api_apply_fail", action="regen", code=e.code)
        print(f"FAIL: {e}")
        return 1


def cmd_apply_update(_args) -> int:
    node_uuid = api_cfg().get("node_uuid")
    if not node_uuid:
        sys.exit("Не задан node_uuid")
    try:
        _http("POST", f"/api/nodes/{node_uuid}/restart")
        _notify_tg("api_apply_ok", action="update")
        print("ok")
        return 0
    except ApiError as e:
        _notify_tg("api_apply_fail", action="update", code=e.code)
        print(f"FAIL: {e}")
        return 1


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="panel_api.py")
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name, fn in (("enable", cmd_enable), ("disable", cmd_disable),
                     ("change", cmd_change), ("test", cmd_test),
                     ("show", cmd_show), ("auto", cmd_auto),
                     ("wipe", cmd_wipe), ("register", cmd_register),
                     ("apply-regen", cmd_apply_regen), ("apply-update", cmd_apply_update)):
        sub.add_parser(name).set_defaults(func=fn)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
