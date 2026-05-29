#!/usr/bin/env bash
# 06_regen.sh — перегенерация параметров Reality + инструкция в Telegram
# by popokole
#
# Что меняется: short-id, keypair, dest-маска, порт (выборочно).
# Что НЕ меняется: имя ноды, panel_ip, NODE_PORT, SECRET_KEY (связь с панелью).
#
# Сценарий A (по умолчанию): TG-сообщение с пошаговой инструкцией для ручной
#   вставки новых параметров в Config Profile панели.
# Сценарий B (panel_api.enabled=true + auto_apply_after_regen=true): inline-
#   кнопка [✓ Применить] в TG → 09_telegram callback → panel_api::apply_regen.

[ -n "${__NODER_REGEN_LOADED:-}" ] && return 0
__NODER_REGEN_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

readonly REGEN_BAK=/var/backups/noder/regen

regen::__backup_current() {
    install -d -m 0700 "$REGEN_BAK"
    local stamp; stamp="$(date +%Y-%m-%d_%H-%M-%S)"
    python3 "$NODER_HOME/modules/03_state.py" dump > "$REGEN_BAK/state-${stamp}.json" 2>/dev/null
    chmod 0600 "$REGEN_BAK/state-${stamp}.json"
    echo "$REGEN_BAK/state-${stamp}.json"
}

# ---------------------------------------------------------------------------
# Atomic regen primitives
# ---------------------------------------------------------------------------

regen::short_id() {
    require_root
    state::exists || die "$(t menu.not_installed_hint)"
    local old; old="$(state::get reality.short_ids)"
    regen::__backup_current >/dev/null
    local new
    new="$(python3 "$NODER_HOME/modules/04_random.py" short-id)"
    python3 "$NODER_HOME/modules/03_state.py" set reality.short_ids "[\"$new\"]" >/dev/null
    log_ok "Новый short_id: $new (старый: $old)"
    regen::__post_apply short_id "$new"
}

regen::dest() {
    require_root
    state::exists || die "$(t menu.not_installed_hint)"
    regen::__backup_current >/dev/null
    local mask
    mask="$(NODER_HOME="$NODER_HOME" python3 "$NODER_HOME/modules/04_random.py" mask)"
    local new_dest new_sn
    new_dest="$(echo "$mask" | python3 -c 'import json,sys; m=json.load(sys.stdin); print(m["domain"]+":443")')"
    new_sn="$(echo "$mask" | python3 -c 'import json,sys; m=json.load(sys.stdin); print(",".join(m["server_names"]))')"
    python3 "$NODER_HOME/modules/03_state.py" set reality.dest "$new_dest" >/dev/null
    python3 "$NODER_HOME/modules/03_state.py" set reality.server_names \
        "[$(echo "$new_sn" | awk -F, '{for(i=1;i<=NF;i++)printf "%s\"%s\"", (i==1?"":","), $i}')]" >/dev/null
    log_ok "Новая dest-маска: $new_dest"
    regen::__post_apply dest "$new_dest"
}

regen::port() {
    require_root
    state::exists || die "$(t menu.not_installed_hint)"
    regen::__backup_current >/dev/null
    local new
    new="$(python3 "$NODER_HOME/modules/04_random.py" port)"
    python3 "$NODER_HOME/modules/03_state.py" set reality.port "$new" >/dev/null
    log_ok "Новый порт: $new"
    source "$NODER_HOME/modules/08_firewall.sh"
    firewall::apply
    regen::__post_apply port "$new"
}

regen::full() {
    require_root
    state::exists || die "$(t menu.not_installed_hint)"
    regen::__backup_current >/dev/null
    local keys priv pub
    keys="$(python3 "$NODER_HOME/modules/05_reality.py" keygen)"
    priv="$(echo "$keys" | python3 -c 'import json,sys; print(json.load(sys.stdin)["private_key"])')"
    pub="$(echo "$keys" | python3 -c 'import json,sys; print(json.load(sys.stdin)["public_key"])')"
    python3 "$NODER_HOME/modules/03_state.py" set reality.private_key "$priv" >/dev/null
    python3 "$NODER_HOME/modules/03_state.py" set reality.public_key  "$pub" >/dev/null
    regen::short_id
    regen::dest
}

regen::rollback() {
    require_root
    local last
    last="$(ls -1t "$REGEN_BAK"/state-*.json 2>/dev/null | head -1)"
    [ -z "$last" ] && die "Нет бэкапа regen"
    log_info "Откатываюсь к $last"
    cp -a "$last" "$NODER_STATE_FILE"
    chmod 0600 "$NODER_STATE_FILE"
    source "$NODER_HOME/modules/08_firewall.sh"; firewall::apply
    source "$NODER_HOME/modules/07_node.sh"; node::restart 2>/dev/null || true
    log_ok "Откат выполнен. Не забудьте обновить параметры в панели обратно."
}

# ---------------------------------------------------------------------------
# After-apply: notify + restart container + (optional) API apply
# ---------------------------------------------------------------------------

regen::__post_apply() {
    local kind="$1" new="$2"
    source "$NODER_HOME/modules/07_node.sh"
    node::restart 2>/dev/null || true

    # Сценарий B: автоприменение через panel API (если включено)
    local api_enabled auto require_confirm
    api_enabled="$(state::get panel_api.enabled)"
    auto="$(state::get panel_api.auto_apply_after_regen)"
    require_confirm="$(state::get panel_api.require_telegram_confirm)"

    if [ "$api_enabled" = "true" ] && [ "$auto" = "true" ] && [ "$require_confirm" != "true" ]; then
        if [ -f "$NODER_HOME/modules/panel_api.py" ]; then
            log_info "Автоприменение через API…"
            python3 "$NODER_HOME/modules/panel_api.py" apply-regen 2>&1 | tee -a "$NODER_LOG_FILE" || true
        fi
        return 0
    fi

    # Сценарий A или B+require_confirm: алерт в Telegram
    if [ -x "$NODER_HOME/modules/09_telegram.py" ]; then
        python3 "$NODER_HOME/modules/09_telegram.py" notify \
            --event regen --kind "$kind" --value "$new" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# CLI dispatcher
# ---------------------------------------------------------------------------

regen::run() {
    case "${1:-full}" in
        short-id|short_id) regen::short_id ;;
        dest)              regen::dest ;;
        port)              regen::port ;;
        full|"")           regen::full ;;
        rollback)          regen::rollback ;;
        *)                 die "noder regen: неизвестная команда: ${1:-}" ;;
    esac
}

regen::run_all() {
    # Заготовка для regen-all (через SSH к другим нодам) — см. ТЗ 7.9.
    log_warn "regen-all требует SSH-цепочки, не реализовано в текущей версии"
}
