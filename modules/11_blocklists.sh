#!/usr/bin/env bash
# 11_blocklists.sh — гео-списки routing (xray geosite/geoip) и firewall blocklist
# by popokole
#
# Два независимых списка (ТЗ 9):
#   • A — routing: geosite.dat + geoip.dat для Xray; российские сайты идут
#         напрямую с реального IP клиента, минуя ноду.
#   • B — firewall: IP-диапазоны известных сканеров и ботнетов; загружается
#         в nft set @blocklist4 (08_firewall.sh).
#
# Расписание: systemd-таймер раз в сутки в 01:00 МСК.
# При неудаче — старая версия не трогается, алерт в Telegram.

[ -n "${__NODER_BL_LOADED:-}" ] && return 0
__NODER_BL_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

readonly BL_DIR=/usr/local/share/xray
readonly BL_FW_FILE=/var/lib/noder/firewall-blocklist.txt
readonly BL_BAK_DIR=/var/backups/noder/blocklists

# ---------------------------------------------------------------------------
# Source URLs (state-overridable)
# ---------------------------------------------------------------------------

blocklists::__src() {
    # blocklists::__src <key>
    local key="$1"
    local v
    v="$(state::get "blocklist_sources.${key}")"
    if [ -z "$v" ] || [ "$v" = "null" ]; then
        v="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
parts = sys.argv[2].split('.')
cur = d
for p in parts:
    cur = cur.get(p, {})
print(cur if isinstance(cur, str) else '')
" "$NODER_HOME/data/blocklist_sources.json" "$key")"
    fi
    echo "$v"
}

# ---------------------------------------------------------------------------
# Download + validate
# ---------------------------------------------------------------------------

blocklists::__download_validated() {
    # blocklists::__download_validated <url> <dst> [min_bytes]
    local url="$1" dst="$2" min="${3:-1024}"
    local tmp="$(mktemp)"
    if ! curl -fsSL --connect-timeout 10 --max-time 120 -o "$tmp" "$url"; then
        rm -f "$tmp"
        return 1
    fi
    local size
    size="$(stat -c%s "$tmp" 2>/dev/null || stat -f%z "$tmp" 2>/dev/null)"
    if [ -z "$size" ] || [ "$size" -lt "$min" ]; then
        log_warn "Файл слишком маленький ($size байт): $url"
        rm -f "$tmp"
        return 1
    fi
    # Size sanity: if previous version exists, new must be ≥ 50% of old.
    if [ -f "$dst" ]; then
        local old; old="$(stat -c%s "$dst" 2>/dev/null || stat -f%z "$dst" 2>/dev/null)"
        if [ "$old" -gt 0 ] && [ "$size" -lt "$((old / 2))" ]; then
            log_warn "Новый файл $url меньше половины предыдущего ($size vs $old) — отказ"
            rm -f "$tmp"
            return 1
        fi
    fi
    # Backup current before overwrite
    install -d -m 0700 "$BL_BAK_DIR"
    if [ -f "$dst" ]; then
        cp -a "$dst" "$BL_BAK_DIR/$(basename "$dst").$(date +%Y%m%d_%H%M%S)"
    fi
    install -m 0644 "$tmp" "$dst"
    rm -f "$tmp"
    return 0
}

# ---------------------------------------------------------------------------
# Routing (list A) — geosite.dat + geoip.dat
# ---------------------------------------------------------------------------

blocklists::update_routing() {
    require_root
    install -d -m 0755 "$BL_DIR"
    local site_url ip_url
    site_url="$(blocklists::__src routing.geosite_url)"
    ip_url="$(blocklists::__src routing.geoip_url)"
    local ok=1
    if [ -n "$site_url" ]; then
        log_info "geosite ← $site_url"
        blocklists::__download_validated "$site_url" "$BL_DIR/geosite.dat" 1048576 \
            && log_ok "geosite.dat обновлён" \
            || { log_warn "geosite не обновился"; ok=0; }
    fi
    if [ -n "$ip_url" ]; then
        log_info "geoip ← $ip_url"
        blocklists::__download_validated "$ip_url" "$BL_DIR/geoip.dat" 524288 \
            && log_ok "geoip.dat обновлён" \
            || { log_warn "geoip не обновился"; ok=0; }
    fi
    if [ "$ok" -eq 1 ]; then
        # Перезапуск контейнера, чтобы Xray перечитал geo-файлы
        source "$NODER_HOME/modules/07_node.sh"
        node::restart 2>/dev/null || true
    else
        if [ -x "$NODER_HOME/modules/09_telegram.py" ]; then
            python3 "$NODER_HOME/modules/09_telegram.py" notify --event blocklist_failed --list routing 2>/dev/null || true
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Firewall (list B) — blocklist of bad IPs/CIDRs
# ---------------------------------------------------------------------------

blocklists::update_firewall() {
    require_root
    local url; url="$(blocklists::__src firewall.blocklist_url)"
    [ -z "$url" ] && { log_warn "URL firewall-blocklist не задан"; return 0; }

    log_info "Firewall blocklist ← $url"
    install -d -m 0700 "$(dirname "$BL_FW_FILE")"
    if blocklists::__download_validated "$url" "$BL_FW_FILE" 1024; then
        log_ok "Скачано $(wc -l < "$BL_FW_FILE") строк"
        source "$NODER_HOME/modules/08_firewall.sh"
        firewall::sync_blocklist "$BL_FW_FILE" || log_warn "Загрузка в nft не удалась"
    else
        log_warn "firewall-blocklist не обновился"
        if [ -x "$NODER_HOME/modules/09_telegram.py" ]; then
            python3 "$NODER_HOME/modules/09_telegram.py" notify --event blocklist_failed --list firewall 2>/dev/null || true
        fi
    fi
}

# ---------------------------------------------------------------------------
# Public
# ---------------------------------------------------------------------------

blocklists::update_all() {
    blocklists::update_routing
    blocklists::update_firewall
    python3 "$NODER_HOME/modules/03_state.py" set blocklist_last_update \
        "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" >/dev/null || true
}

blocklists::show_sources() {
    echo "Текущие источники:"
    for k in routing.geosite_url routing.geoip_url routing.ru_bypass_url firewall.blocklist_url; do
        printf '  %-25s %s\n' "$k" "$(blocklists::__src "$k")"
    done
}

blocklists::edit_sources() {
    require_root
    for k in routing.geosite_url routing.geoip_url firewall.blocklist_url; do
        local cur new
        cur="$(blocklists::__src "$k")"
        ui::prompt new "URL для $k" "$cur"
        if [ -n "$new" ] && [ "$new" != "$cur" ]; then
            python3 "$NODER_HOME/modules/03_state.py" set "blocklist_sources.${k}" "\"$new\""
            log_ok "$k обновлён"
        fi
    done
}

blocklists::rollback() {
    require_root
    local last
    last="$(ls -1t "$BL_BAK_DIR"/geosite.dat.* 2>/dev/null | head -1)"
    if [ -n "$last" ]; then
        cp -a "$last" "$BL_DIR/geosite.dat" && log_ok "geosite откатан с $last"
    fi
    last="$(ls -1t "$BL_BAK_DIR"/geoip.dat.* 2>/dev/null | head -1)"
    if [ -n "$last" ]; then
        cp -a "$last" "$BL_DIR/geoip.dat" && log_ok "geoip откатан с $last"
    fi
    source "$NODER_HOME/modules/07_node.sh"
    node::restart 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# systemd-таймер
# ---------------------------------------------------------------------------

blocklists::install_timer() {
    require_root
    cat > /etc/systemd/system/noder-blocklists.service <<EOF
[Unit]
Description=noder blocklist update
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$NODER_HOME/noder.sh blocklists update
EOF

    cat > /etc/systemd/system/noder-blocklists.timer <<'EOF'
[Unit]
Description=noder daily blocklist update

[Timer]
OnCalendar=*-*-* 01:00:00 Europe/Moscow
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now noder-blocklists.timer
    log_ok "noder-blocklists.timer установлен (01:00 МСК ежедневно)"
}
