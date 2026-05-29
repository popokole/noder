#!/usr/bin/env python3
"""
09_telegram.py — Telegram-бот ноды Remnawave.

Два режима:

    notify --event EVENT [--node NAME] [k=v ...]
        Однократно отправить сообщение в чат. Вызывается из других модулей
        (10_updates.sh, regen, blocklists, fail2ban-action и т.п.).

    daemon
        Постоянно работающий long-polling. Реагирует ТОЛЬКО на сообщения и
        callback-нажатия от Telegram-ID из whitelist (state.json
        telegram.trusted_ids ∪ data/trusted_tg_ids).

    setup
        Зарегистрировать systemd-юнит noder-tg.service и запустить его.

    setup-disable
        Остановить и удалить юнит.

    test
        Послать тестовое сообщение в чат и выйти.

Все строки на русском. В алертах используется имя ноды (state.node_name)
чтобы один бот мог обслуживать парк нод в одном чате.

Зависимости: только stdlib (urllib).

by popokole
"""

from __future__ import annotations

import argparse
import datetime
import html
import json
import logging
import os
import pathlib
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

NODER_HOME = pathlib.Path(os.environ.get("NODER_HOME", "/opt/noder"))
STATE_FILE = pathlib.Path(os.environ.get("NODER_STATE_FILE", "/etc/noder/state.json"))
LOG_FILE = pathlib.Path(os.environ.get("NODER_LOG_DIR", "/var/log/noder")) / "telegram.log"
TG_API = "https://api.telegram.org"
UPDATE_OFFSET_FILE = pathlib.Path("/var/lib/noder/tg-offset")

WATERMARK = "by popokole"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def _setup_logging():
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        filename=str(LOG_FILE),
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    return logging.getLogger("noder.tg")

log = _setup_logging()

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

def state() -> dict:
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def tg_token() -> str | None:
    return state().get("telegram", {}).get("tg_token")


def tg_chat() -> str | None:
    c = state().get("telegram", {}).get("chat_id")
    return str(c) if c is not None else None


def node_name() -> str:
    return state().get("node_name") or socket.gethostname()


def trusted_ids() -> set[int]:
    out: set[int] = set()
    for x in state().get("telegram", {}).get("trusted_ids") or []:
        try: out.add(int(x))
        except Exception: pass
    path = NODER_HOME / "data" / "trusted_tg_ids"
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                try: out.add(int(line))
                except Exception: pass
    return out


def mask_token(t: str) -> str:
    return f"{t[:4]}***{t[-4:]}" if t and len(t) > 8 else "***"

# ---------------------------------------------------------------------------
# HTTP — bare urllib
# ---------------------------------------------------------------------------

def _api_call(method: str, params: dict, timeout: int = 30) -> dict:
    token = tg_token()
    if not token:
        raise RuntimeError("telegram.tg_token не задан")
    url = f"{TG_API}/bot{token}/{method}"
    data = urllib.parse.urlencode(
        {k: (json.dumps(v) if isinstance(v, (dict, list)) else v) for k, v in params.items()}
    ).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode()
    parsed = json.loads(body)
    if not parsed.get("ok"):
        raise RuntimeError(f"Telegram API error: {parsed}")
    return parsed.get("result", {})


def _send(text: str, *, chat_id: str | None = None, reply_markup: dict | None = None,
          parse_mode: str = "HTML") -> dict | None:
    chat = chat_id or tg_chat()
    if not chat:
        log.warning("telegram.chat_id не задан; пропускаю отправку")
        return None
    params: dict[str, Any] = {
        "chat_id": chat, "text": text, "parse_mode": parse_mode,
        "disable_web_page_preview": True,
    }
    if reply_markup:
        params["reply_markup"] = reply_markup
    try:
        return _api_call("sendMessage", params)
    except Exception as e:
        log.error("sendMessage failed: %s", e)
        return None


def _answer_cb(callback_id: str, text: str = "", show_alert: bool = False) -> None:
    try:
        _api_call("answerCallbackQuery",
                  {"callback_query_id": callback_id, "text": text, "show_alert": show_alert},
                  timeout=10)
    except Exception as e:
        log.error("answerCallback failed: %s", e)


# ---------------------------------------------------------------------------
# Message templates (Russian)
# ---------------------------------------------------------------------------

def _prefix(emoji: str, host_ip: str | None = None) -> str:
    ip = host_ip or _get_primary_ip() or "?"
    return f"{emoji} <b>{html.escape(node_name())}</b> <code>({ip})</code>:"


def _get_primary_ip() -> str | None:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("1.1.1.1", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return None


def _btn(text: str, callback: str) -> dict:
    return {"text": text, "callback_data": callback}


def _keyboard(*rows: list[dict]) -> dict:
    return {"inline_keyboard": list(rows)}


# Render event → (text, reply_markup)

def render_event(event: str, kv: dict) -> tuple[str, dict | None]:
    if event == "install_done":
        s = state()
        r = s.get("reality", {})
        ip = _get_primary_ip() or "?"
        text = (
            f"{_prefix('✅')} нода установлена\n\n"
            f"<b>Параметры для Remnawave Panel</b>\n"
            f"<pre>"
            f"Адрес ноды:    {ip}:{s.get('panel',{}).get('node_port')}\n"
            f"Порт Reality:  {r.get('port')}\n"
            f"Dest:          {r.get('dest')}\n"
            f"Server names:  {','.join(r.get('server_names',[]))}\n"
            f"Public key:    {r.get('public_key')}\n"
            f"Short ID:      {','.join(r.get('short_ids',[]))}\n"
            f"Flow:          xtls-rprx-vision\n"
            f"</pre>\n"
            f"{WATERMARK}"
        )
        return text, None

    if event == "started":
        return f"{_prefix('✅')} {html.escape('нода успешно запущена')}", None

    if event == "restarted":
        return f"{_prefix('⚠️')} Xray перезапустился", None

    if event == "crashed":
        return f"{_prefix('❌')} контейнер упал, попытка автоперезапуска", None

    if event == "update_available":
        old, new = kv.get("xray_old", "?"), kv.get("xray_new", "?")
        kb = _keyboard(
            [_btn("Обновить сейчас", "update:now"),
             _btn("Отложить 24ч", "update:postpone"),
             _btn("Игнорировать", "update:ignore")],
        )
        text = (
            f"{_prefix('🔄')} обнаружена новая версия\n"
            f"Текущая: <code>{old}</code> → Новая: <code>{new}</code>"
        )
        return text, kb

    if event == "update_done":
        return f"{_prefix('🔄')} обновление завершено", None

    if event == "regen":
        kind = kv.get("kind", "?")
        text = (
            f"{_prefix('🔄')} параметры перегенерированы (<i>{kind}</i>)\n\n"
            f"<b>ВАЖНО:</b> клиенты не подключатся, пока не обновите параметры в панели.\n\n"
            f"Шаги:\n"
            f"1. Откройте Remnawave Panel → Config Profiles → ваш профиль\n"
            f"2. Найдите Inbound VLESS-Reality\n"
            f"3. Замените значения:\n"
            f"   • Dest, Server names, Public key, Short ID — см. <code>noder</code> → [7]\n"
            f"4. Сохраните Config Profile\n"
            f"5. Нажмите Apply на ноде в разделе Nodes\n\n"
            f"{WATERMARK}"
        )
        # Если включён API + auto_apply + require_telegram_confirm → кнопка
        s = state().get("panel_api", {})
        if s.get("enabled") and s.get("auto_apply_after_regen") and s.get("require_telegram_confirm", True):
            kb = _keyboard(
                [_btn("✓ Применить через API", "api:apply"),
                 _btn("✗ Только показать значения", "api:show_only")],
            )
            return text, kb
        return text, None

    if event == "blocklist_failed":
        which = kv.get("list", "?")
        kb = _keyboard([_btn("Повторить", f"bl:retry:{which}")])
        return (f"{_prefix('🌐')} обновление гео-списков <code>{which}</code> не удалось — "
                f"использую предыдущую версию", kb)

    if event == "traffic_drop":
        hours = kv.get("hours", "?")
        kb = _keyboard(
            [_btn("Сделать regen", "regen:full"),
             _btn("Игнорировать (норма)", "ignore")],
        )
        return (
            f"{_prefix('📉')} трафик упал до нуля {hours}ч назад\n"
            f"Это МОЖЕТ означать блокировку, а может — что просто никто не подключается.\n\n"
            f"Что попробовать:\n"
            f"• Проверить ноду с другого IP в РФ\n"
            f"• Сделать regen (сменит отпечаток)\n",
            kb,
        )

    if event == "f2b_ban":
        ip = kv.get("ip", "?")
        jail = kv.get("jail", "?")
        return f"{_prefix('🛡')} fail2ban забанил <code>{ip}</code> ({jail})", None

    if event == "f2b_unban":
        ip = kv.get("ip", "?")
        return f"{_prefix('🛡')} fail2ban разбанил <code>{ip}</code>", None

    if event == "ssh_rolled_back":
        return f"{_prefix('⚠️')} SSH-hardening откатан (не было подтверждения)", None

    # Generic fallthrough
    return f"{_prefix('ℹ️')} {html.escape(event)}", None


# ---------------------------------------------------------------------------
# Callback dispatch — runs ONLY for whitelisted users
# ---------------------------------------------------------------------------

def _run_noder_subcmd(args: list[str]) -> str:
    """Run a noder CLI command and return its short output (stdout+stderr)."""
    cmd = [str(NODER_HOME / "noder.sh"), *args]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        out = (proc.stdout + proc.stderr).strip()
        return (out[-1500:] if len(out) > 1500 else out) or "(no output)"
    except subprocess.TimeoutExpired:
        return "timeout"
    except Exception as e:
        return f"error: {e}"


def handle_callback(cb: dict) -> None:
    user_id = (cb.get("from") or {}).get("id")
    if user_id not in trusted_ids():
        log.warning("unauthorized callback from id=%s data=%s", user_id, cb.get("data"))
        _answer_cb(cb["id"], "Нет доступа", show_alert=True)
        return

    data = cb.get("data", "")
    log.info("callback from %s: %s", user_id, data)

    if data == "update:now":
        _answer_cb(cb["id"], "Запускаю обновление…")
        out = _run_noder_subcmd(["update", "image"])
        _send(f"{_prefix('🔄')} результат обновления:\n<pre>{html.escape(out)}</pre>")
        return

    if data == "update:postpone":
        _answer_cb(cb["id"], "Напомню через 24ч")
        # Простая «отметка» через файл; реальный re-alert обрабатывается timer'ом
        pathlib.Path("/var/lib/noder/update_postpone").write_text(
            str(int(time.time()) + 86400))
        return

    if data == "update:ignore":
        _answer_cb(cb["id"], "Ок, игнорирую")
        return

    if data == "regen:full":
        _answer_cb(cb["id"], "Регенерирую…")
        out = _run_noder_subcmd(["regen", "full"])
        _send(f"{_prefix('🔄')} regen завершён:\n<pre>{html.escape(out[-800:])}</pre>")
        return

    if data == "api:apply":
        _answer_cb(cb["id"], "Применяю через API…")
        out = _run_noder_subcmd(["api", "apply-regen"])
        _send(f"{_prefix('🔄')} API apply:\n<pre>{html.escape(out)}</pre>")
        return

    if data == "api:show_only":
        _answer_cb(cb["id"], "Показываю только значения")
        s = state(); r = s.get("reality", {})
        _send(
            f"{_prefix('ℹ️')} параметры для ручной вставки:\n"
            f"<pre>"
            f"Dest:         {r.get('dest')}\n"
            f"Server names: {','.join(r.get('server_names',[]))}\n"
            f"Public key:   {r.get('public_key')}\n"
            f"Short ID:     {','.join(r.get('short_ids',[]))}\n"
            f"</pre>"
        )
        return

    if data.startswith("bl:retry:"):
        which = data.split(":", 2)[2]
        _answer_cb(cb["id"], "Повторяю…")
        out = _run_noder_subcmd(["blocklists", which])
        _send(f"{_prefix('🌐')} retry результат:\n<pre>{html.escape(out[-800:])}</pre>")
        return

    if data == "ignore":
        _answer_cb(cb["id"], "Ок")
        return

    _answer_cb(cb["id"], "Не реализовано")


def handle_message(msg: dict) -> None:
    user_id = (msg.get("from") or {}).get("id")
    chat_id = (msg.get("chat") or {}).get("id")
    text = (msg.get("text") or "").strip()

    if user_id not in trusted_ids():
        log.warning("unauthorized message from id=%s text=%s", user_id, text)
        return

    if text in ("/start",):
        _send(
            f"Здравствуйте! Это бот мониторинга нод Remnawave.\n"
            f"Нода: <b>{html.escape(node_name())}</b>\n\n"
            f"Доступные команды:\n"
            f"  /status — health-check этой ноды\n"
            f"  /status_all — сводка по всем нодам (если бот общий)\n"
            f"  /list — список нод, активных в этом чате\n\n"
            f"{WATERMARK}",
            chat_id=str(chat_id),
        )
        return

    if text.startswith("/status"):
        # /status [NAME] — у нас один процесс на ноду, NAME игнорим
        out = _run_noder_subcmd(["health"])
        _send(f"<b>{html.escape(node_name())}</b>\n<pre>{html.escape(out[-3500:])}</pre>",
              chat_id=str(chat_id))
        return

    if text == "/list":
        _send(f"<b>{html.escape(node_name())}</b> (этот сервер)\n"
              f"Команда /list — пока возвращает только локальную ноду. "
              f"Сводка по парку — в следующих версиях.",
              chat_id=str(chat_id))
        return


# ---------------------------------------------------------------------------
# Long-polling daemon
# ---------------------------------------------------------------------------

def daemon_loop():
    log.info("daemon start: node=%s token=%s", node_name(), mask_token(tg_token() or ""))
    offset = 0
    if UPDATE_OFFSET_FILE.exists():
        try: offset = int(UPDATE_OFFSET_FILE.read_text() or "0")
        except Exception: offset = 0

    while True:
        try:
            res = _api_call("getUpdates",
                            {"timeout": 50, "offset": offset, "allowed_updates": ["message", "callback_query"]},
                            timeout=60)
            for update in res or []:
                offset = update["update_id"] + 1
                try:
                    if "callback_query" in update:
                        handle_callback(update["callback_query"])
                    elif "message" in update:
                        handle_message(update["message"])
                except Exception as e:
                    log.exception("handler failed: %s", e)
            UPDATE_OFFSET_FILE.parent.mkdir(parents=True, exist_ok=True)
            UPDATE_OFFSET_FILE.write_text(str(offset))
        except urllib.error.URLError as e:
            log.warning("getUpdates URL error: %s", e)
            time.sleep(10)
        except Exception as e:
            log.exception("getUpdates failed: %s", e)
            time.sleep(15)


# ---------------------------------------------------------------------------
# systemd unit
# ---------------------------------------------------------------------------

UNIT_PATH = pathlib.Path("/etc/systemd/system/noder-tg.service")

def setup_unit():
    if os.geteuid() != 0:
        sys.exit("setup требует root")
    UNIT_PATH.write_text(f"""[Unit]
Description=noder Telegram bot (long-polling)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=NODER_HOME={NODER_HOME}
ExecStart=/usr/bin/python3 {NODER_HOME}/modules/09_telegram.py daemon
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
""")
    subprocess.run(["systemctl", "daemon-reload"], check=False)
    subprocess.run(["systemctl", "enable", "--now", "noder-tg.service"], check=False)
    print(f"installed: {UNIT_PATH}")


def setup_disable_unit():
    if os.geteuid() != 0:
        sys.exit("setup-disable требует root")
    subprocess.run(["systemctl", "disable", "--now", "noder-tg.service"], check=False)
    if UNIT_PATH.exists():
        UNIT_PATH.unlink()
    subprocess.run(["systemctl", "daemon-reload"], check=False)
    print("noder-tg.service disabled and removed")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="09_telegram.py", description="noder Telegram bot")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_notify = sub.add_parser("notify", help="send a one-shot notification")
    p_notify.add_argument("--event", required=True)
    p_notify.add_argument("kv", nargs="*", help="extra k=v context")
    # Allow well-known flags from other modules
    for flag in ("xray-old", "xray-new", "image-changed", "node", "list", "kind", "value", "jail", "ip", "hours"):
        p_notify.add_argument(f"--{flag}", default=None)

    sub.add_parser("daemon", help="run long-polling forever").set_defaults()
    sub.add_parser("setup", help="install systemd unit").set_defaults()
    sub.add_parser("setup-disable", help="remove systemd unit").set_defaults()
    sub.add_parser("test", help="send a test message").set_defaults()

    args = parser.parse_args(argv)

    if args.cmd == "notify":
        kv = {}
        for raw in args.kv:
            if "=" in raw:
                k, v = raw.split("=", 1); kv[k.replace("-", "_")] = v
        for k in ("xray_old", "xray_new", "image_changed", "node", "list", "kind", "value", "jail", "ip", "hours"):
            v = getattr(args, k.replace("_", "-"), None) if hasattr(args, k.replace("_", "-")) else None
            v = v or getattr(args, k, None)
            if v is not None:
                kv[k] = v
        text, kb = render_event(args.event, kv)
        result = _send(text, reply_markup=kb)
        return 0 if result is not None else 1

    if args.cmd == "daemon":
        daemon_loop()
        return 0

    if args.cmd == "setup":
        setup_unit(); return 0
    if args.cmd == "setup-disable":
        setup_disable_unit(); return 0

    if args.cmd == "test":
        result = _send(f"{_prefix('🧪')} тест noder — связь есть, watermark: {WATERMARK}")
        return 0 if result is not None else 1

    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
