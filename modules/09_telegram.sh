#!/usr/bin/env bash
# 09_telegram.sh — bash-обёртки для menu::telegram, делегирует на 09_telegram.py
# by popokole
#
# Сам Telegram-бот живёт в 09_telegram.py (long-polling демон, notify-режим,
# inline-кнопки). Здесь только функции для интерактивного меню noder'а:
# редактирование state.json + рестарт systemd-юнита.

[ -n "${__NODER_TG_LOADED:-}" ] && return 0
__NODER_TG_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

readonly TG_PY="$NODER_HOME/modules/09_telegram.py"
readonly TG_UNIT=/etc/systemd/system/noder-tg.service
readonly TG_TRUSTED_FILE="$NODER_HOME/data/trusted_tg_ids"

# ---------------------------------------------------------------------------
# Internal: restart systemd unit if it exists, без падений
# ---------------------------------------------------------------------------
tg::__restart_unit() {
    if [ -f "$TG_UNIT" ]; then
        systemctl restart noder-tg.service 2>/dev/null \
            && log_info "noder-tg.service перезапущен" \
            || log_warn "noder-tg.service не удалось перезапустить (см. journalctl -u noder-tg)"
    fi
}

# ---------------------------------------------------------------------------
# [1] Включить интеграцию
# ---------------------------------------------------------------------------
tg::enable() {
    require_root
    state::exists || die "$(t menu.not_installed_hint)"

    log_info "Включение Telegram-интеграции"

    local cur_token cur_chat
    cur_token="$(state::get telegram.tg_token)"
    cur_chat="$(state::get telegram.chat_id)"

    local token
    if [ -n "$cur_token" ] && [ "$cur_token" != "null" ]; then
        log_info "Уже сохранён токен: $(mask_secret "$cur_token")"
        if ui::confirm "Использовать существующий?"; then
            token="$cur_token"
        fi
    fi
    if [ -z "$token" ]; then
        ui::prompt_secret token "Токен Telegram-бота (BotFather)"
    fi
    [ -z "$token" ] && die "Токен не задан"

    local chat
    if [ -n "$cur_chat" ] && [ "$cur_chat" != "null" ]; then
        log_info "Сохранён chat_id: $cur_chat"
        if ui::confirm "Оставить?"; then
            chat="$cur_chat"
        fi
    fi
    if [ -z "$chat" ]; then
        ui::prompt chat "Chat ID для алертов (от @userinfobot)"
    fi
    [ -z "$chat" ] && die "Chat ID не задан"

    python3 "$NODER_HOME/modules/03_state.py" set telegram.enabled  true        >/dev/null
    python3 "$NODER_HOME/modules/03_state.py" set telegram.tg_token "$token"    >/dev/null
    python3 "$NODER_HOME/modules/03_state.py" set telegram.chat_id  "$chat"     >/dev/null

    # Автодобавим chat_id в whitelist (это сам админ)
    if [[ "$chat" =~ ^-?[0-9]+$ ]]; then
        tg::__add_trusted "$chat"
    fi

    # Поднимаем systemd-демон (даже если уже стоит — переинсталлируется)
    log_info "Установка noder-tg.service…"
    python3 "$TG_PY" setup

    # Пробуем тест-сообщение
    if ui::confirm "Отправить тестовое сообщение в чат?"; then
        tg::test
    fi
}

# ---------------------------------------------------------------------------
# [2] Выключить интеграцию (без удаления токена из state)
# ---------------------------------------------------------------------------
tg::disable() {
    require_root
    if [ -f "$TG_UNIT" ]; then
        python3 "$TG_PY" setup-disable
    fi
    python3 "$NODER_HOME/modules/03_state.py" set telegram.enabled false >/dev/null
    log_ok "Telegram-интеграция выключена (токен в state.json сохранён)"
}

# ---------------------------------------------------------------------------
# [3] Изменить токен
# ---------------------------------------------------------------------------
tg::change_token() {
    require_root
    state::exists || die "$(t menu.not_installed_hint)"

    local cur new
    cur="$(state::get telegram.tg_token)"
    [ -n "$cur" ] && [ "$cur" != "null" ] && log_info "Текущий: $(mask_secret "$cur")"

    ui::prompt_secret new "Новый токен Telegram-бота"
    [ -z "$new" ] && { log_warn "Не введено — отмена"; return; }

    python3 "$NODER_HOME/modules/03_state.py" set telegram.tg_token "$new" >/dev/null
    log_ok "Токен обновлён ($(mask_secret "$new"))"

    tg::__restart_unit
}

# ---------------------------------------------------------------------------
# [4] Изменить chat_id
# ---------------------------------------------------------------------------
tg::change_chat() {
    require_root
    state::exists || die "$(t menu.not_installed_hint)"

    local cur new
    cur="$(state::get telegram.chat_id)"
    [ -n "$cur" ] && [ "$cur" != "null" ] && log_info "Текущий chat_id: $cur"

    ui::prompt new "Новый chat_id (можно отрицательный для канала/группы)"
    [ -z "$new" ] && { log_warn "Не введено — отмена"; return; }

    if ! [[ "$new" =~ ^-?[0-9]+$ ]]; then
        die "chat_id должен быть числом (возможно отрицательным)"
    fi

    python3 "$NODER_HOME/modules/03_state.py" set telegram.chat_id "$new" >/dev/null
    log_ok "chat_id обновлён: $new"

    # Если новый чат — личка пользователя, добавим в whitelist
    if [[ "$new" =~ ^[0-9]+$ ]]; then
        if ui::confirm "Добавить $new в whitelist trusted_ids (кому разрешено управлять ботом)?"; then
            tg::__add_trusted "$new"
        fi
    fi

    tg::__restart_unit
}

# ---------------------------------------------------------------------------
# [5] Управление whitelist trusted_ids
# ---------------------------------------------------------------------------
tg::__list_trusted() {
    python3 - "$NODER_STATE_FILE" "$TG_TRUSTED_FILE" <<'PY'
import json, pathlib, sys
state_f, file_f = sys.argv[1], sys.argv[2]
ids = set()
try:
    for x in (json.loads(pathlib.Path(state_f).read_text()).get("telegram", {}) or {}).get("trusted_ids") or []:
        try: ids.add(int(x))
        except Exception: pass
except Exception: pass
p = pathlib.Path(file_f)
if p.exists():
    for line in p.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            try: ids.add(int(line))
            except Exception: pass
for i in sorted(ids):
    print(i)
PY
}

tg::__add_trusted() {
    local id="$1"
    [[ "$id" =~ ^-?[0-9]+$ ]] || { log_warn "Не число: $id"; return 1; }
    # Add to state.json (jsonpath append)
    python3 - "$NODER_HOME/modules/03_state.py" "$id" <<'PY'
import json, subprocess, sys, pathlib, os
state_py, new_id = sys.argv[1], int(sys.argv[2])
state_file = os.environ.get("NODER_STATE_FILE", "/etc/noder/state.json")
data = json.loads(pathlib.Path(state_file).read_text())
data.setdefault("telegram", {}).setdefault("trusted_ids", [])
if new_id not in data["telegram"]["trusted_ids"]:
    data["telegram"]["trusted_ids"].append(new_id)
    pathlib.Path(state_file).write_text(json.dumps(data, indent=2, ensure_ascii=False))
PY
    log_ok "$id добавлен в trusted_ids"
    tg::__restart_unit
}

tg::__del_trusted() {
    local id="$1"
    python3 - "$id" <<'PY'
import json, sys, pathlib, os
state_file = os.environ.get("NODER_STATE_FILE", "/etc/noder/state.json")
target = int(sys.argv[1])
data = json.loads(pathlib.Path(state_file).read_text())
ids = data.get("telegram", {}).get("trusted_ids", []) or []
data.setdefault("telegram", {})["trusted_ids"] = [i for i in ids if int(i) != target]
pathlib.Path(state_file).write_text(json.dumps(data, indent=2, ensure_ascii=False))
PY
    log_ok "$id удалён из trusted_ids"
    tg::__restart_unit
}

tg::trusted() {
    require_root
    while true; do
        ui::clear
        ui::header "Whitelist Telegram-ID"
        echo "  Эти ID могут управлять ботом (нажимать inline-кнопки, /status и т.п.)"
        echo "  Сообщения от других ID игнорируются."
        echo
        echo "  Текущий список:"
        local ids
        ids="$(tg::__list_trusted)"
        if [ -z "$ids" ]; then
            echo "    (пусто)"
        else
            echo "$ids" | sed 's/^/    /'
        fi
        echo
        echo "  [1] Добавить ID"
        echo "  [2] Удалить ID"
        echo "  [0] Назад"
        ui::footer
        local c; ui::prompt c "$(t ui.choose_option)"
        case "$c" in
            1) local new; ui::prompt new "Telegram User ID (от @userinfobot)"; [ -n "$new" ] && tg::__add_trusted "$new"; ui::pause ;;
            2) local rm; ui::prompt rm "Какой ID удалить"; [ -n "$rm" ] && tg::__del_trusted "$rm"; ui::pause ;;
            0) return ;;
            *) log_warn "$(t ui.invalid_choice)"; ui::pause ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# [6] Тест
# ---------------------------------------------------------------------------
tg::test() {
    require_root
    state::exists || die "$(t menu.not_installed_hint)"
    local tok; tok="$(state::get telegram.tg_token)"
    [ -z "$tok" ] || [ "$tok" = "null" ] && die "Токен не настроен. Сначала [1] Включить интеграцию."
    log_info "Отправляю тест-сообщение…"
    if python3 "$TG_PY" test; then
        log_ok "Сообщение доставлено"
    else
        log_error "Не удалось отправить — проверьте токен и chat_id"
    fi
}

# ---------------------------------------------------------------------------
# [7] Показать настройки (маскированно)
# ---------------------------------------------------------------------------
tg::show() {
    state::exists || die "$(t menu.not_installed_hint)"
    echo
    echo "── Telegram-настройки ──"
    python3 - <<'PY'
import json, os, pathlib
state_file = os.environ.get("NODER_STATE_FILE", "/etc/noder/state.json")
data = json.loads(pathlib.Path(state_file).read_text())
tg = data.get("telegram", {}) or {}
tok = tg.get("tg_token") or ""
masked = f"{tok[:4]}***{tok[-4:]}" if tok and len(tok) > 8 else ("***" if tok else "(не задан)")
print(f"  enabled:     {tg.get('enabled')}")
print(f"  tg_token:    {masked}")
print(f"  chat_id:     {tg.get('chat_id') or '(не задан)'}")
ids = tg.get('trusted_ids') or []
print(f"  trusted_ids: {ids if ids else '(пусто)'}")
PY
    echo
    if systemctl is-active --quiet noder-tg.service 2>/dev/null; then
        echo "  systemd unit noder-tg.service: ${C_GREEN}active${C_RESET}"
    else
        echo "  systemd unit noder-tg.service: ${C_DIM}не запущен${C_RESET}"
    fi
    echo
}
