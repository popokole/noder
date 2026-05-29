#!/usr/bin/env bash
# 08_firewall.sh — nftables + fail2ban + in-kernel DDoS-фильтр + MSS clamp
# by popokole
#
# Архитектура:
#   • nftables — единая стена с default-drop на INPUT.
#   • SYN-flood и port-scan ловятся ПРЯМО В ЯДРЕ через nft sets + meter.
#     IP, постучавший на закрытый порт, попадает в @scanners на 24 часа.
#     IP, превысивший SYN-rate, попадает в @flood на 1 час.
#   • Это даёт пакет-rate производительность (~20× от fail2ban-цикла
#     лог→regex→exec). fail2ban остаётся ТОЛЬКО для SSH-jail'а (там
#     нужен контекст аутентификации, который kernel не видит).
#   • MSS clamp в forward + output — спасает от PMTUD-blackholes на
#     мобильных операторах с MTU=1280.
#   • Tier-aware conntrack: established — долгие таймауты, INVALID
#     отбрасывается сразу. (sysctl-часть — в 14_kernel.sh.)
#   • «Жёсткий режим» (per-IP rate-limit на Reality) — отдельный
#     toggle, выключен по умолчанию: мобильный CGNAT МТС/Мегафон
#     может пропустить тысячи легитимных клиентов с одного IP.

[ -n "${__NODER_FW_LOADED:-}" ] && return 0
__NODER_FW_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

readonly FW_CONF=/etc/nftables.conf
readonly FW_DROPSTAT=/var/lib/noder/firewall-stats.json
readonly F2B_JAIL=/etc/fail2ban/jail.d/noder-ssh.conf
readonly F2B_ACTION=/etc/fail2ban/action.d/noder-telegram.conf

# ---------------------------------------------------------------------------
# State lookups
# ---------------------------------------------------------------------------

firewall::__panel_ip() {
    local v
    v="$(state::get panel.ip 2>/dev/null)"
    [ -z "$v" ] || [ "$v" = "null" ] && v="$(state::get panel.host 2>/dev/null)"
    echo "$v"
}

firewall::__reality_port() {
    local v
    v="$(state::get reality.port 2>/dev/null)"
    [ -z "$v" ] || [ "$v" = "null" ] && v="443"
    echo "$v"
}

firewall::__node_port() {
    local v
    v="$(state::get panel.node_port 2>/dev/null)"
    [ -z "$v" ] && v=""
    echo "$v"
}

firewall::__ssh_port() {
    local p=22
    if [ -r /etc/ssh/sshd_config ]; then
        local found
        found="$(awk '/^Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config)"
        [ -n "$found" ] && p="$found"
    fi
    echo "$p"
}

firewall::__strict_mode() {
    local v
    v="$(state::get firewall.strict_mode 2>/dev/null)"
    [ "$v" = "true" ] && echo "1" || echo "0"
}

# ---------------------------------------------------------------------------
# Config generation
# ---------------------------------------------------------------------------

firewall::__render_config() {
    # Все subshell-ы здесь дублируются с '|| echo ...' — под `set -Eeuo
    # pipefail` любой 127/100/2 в `$(...)` пробрасывался в trap ERR (хоть
    # nftables в итоге применялся успешно). Делаем функцию полностью
    # идемпотентной: что бы ни вернули helper'ы — рендер не падает.
    local panel_ip ssh_port reality_port node_port strict
    panel_ip="$(firewall::__panel_ip 2>/dev/null || echo "")"
    ssh_port="$(firewall::__ssh_port 2>/dev/null || echo 22)"
    reality_port="$(firewall::__reality_port 2>/dev/null || echo 443)"
    node_port="$(firewall::__node_port 2>/dev/null || echo "")"
    strict="$(firewall::__strict_mode 2>/dev/null || echo 0)"

    # Resolve panel host → IPv4 / IPv6 (if hostname given).
    local panel_v4="" panel_v6=""
    if [[ "$panel_ip" =~ ^[0-9.]+$ ]]; then
        panel_v4="$panel_ip"
    elif [[ "$panel_ip" =~ : ]]; then
        panel_v6="$panel_ip"
    elif [ -n "$panel_ip" ]; then
        # getent + awk под pipefail может вернуть != 0 даже при success
        # (awk { exit } считается провалом для bash). Гасим через || true.
        panel_v4="$(getent ahostsv4 "$panel_ip" 2>/dev/null | awk '{print $1; exit}' || true)"
        panel_v6="$(getent ahostsv6 "$panel_ip" 2>/dev/null | awk '{print $1; exit}' || true)"
    fi

    # Public ports that are intentionally open — anything else is a scanner.
    local pub_ports="$ssh_port, $reality_port"
    if [ -n "$node_port" ]; then
        pub_ports="$pub_ports, $node_port"
    fi

    # Optional per-IP rate-limit on Reality (strict mode only).
    local reality_rule
    if [ "$strict" = "1" ]; then
        reality_rule=$(cat <<EOF
        # STRICT mode: per-IP rate-limit on Reality (warning: hurts mobile CGNAT)
        tcp dport $reality_port ct state new \\
            add @scanners4 { ip saddr limit rate over 200/minute burst 50 packets } \\
            counter drop
        tcp dport $reality_port ct state new \\
            add @scanners6 { ip6 saddr limit rate over 200/minute burst 50 packets } \\
            counter drop
EOF
)
    else
        reality_rule="        # (strict mode off — Reality accepts all new conns; SYN-flood detection still applies)"
    fi

    # NODE_PORT: allow ONLY from the panel IP. Anyone else → scanners.
    local node_rule_v4="" node_rule_v6=""
    if [ -n "$node_port" ]; then
        if [ -n "$panel_v4" ]; then
            node_rule_v4="        ip saddr $panel_v4 tcp dport $node_port counter accept"
        fi
        if [ -n "$panel_v6" ]; then
            node_rule_v6="        ip6 saddr $panel_v6 tcp dport $node_port counter accept"
        fi
    fi

    cat <<EOF
#!/usr/sbin/nft -f
# /etc/nftables.conf — managed by noder
# by popokole

flush ruleset

table inet noder {

    # ------------------------------------------------------------------
    # Auto-expiring blocklists — dynamic so rules can 'add @set { ... }'
    # ------------------------------------------------------------------
    set scanners4 { type ipv4_addr; flags dynamic, timeout; size 65535; timeout 24h; }
    set scanners6 { type ipv6_addr; flags dynamic, timeout; size 65535; timeout 24h; }

    # Dynamic rate-limiting sets — element appears when its rate is exceeded
    # and self-evicts after the timeout. Acts as a soft per-IP rate-limit.
    set synflood4 { type ipv4_addr; flags dynamic, timeout; size 65535; timeout 1h; }
    set synflood6 { type ipv6_addr; flags dynamic, timeout; size 65535; timeout 1h; }

    # External blocklist (list B — managed by 11_blocklists.sh): CIDR ranges
    set blocklist4 { type ipv4_addr; flags interval; }
    set blocklist6 { type ipv6_addr; flags interval; }

    # ------------------------------------------------------------------
    # Input — default DROP
    # ------------------------------------------------------------------
    chain input {
        type filter hook input priority filter; policy drop;

        # Loopback always allowed
        iif lo accept

        # Drop invalid before anything else (tier-aware conntrack)
        ct state invalid counter drop

        # Established/related: hot path
        ct state established,related accept

        # Already-banned scanners and flooders → drop immediately
        ip  saddr @scanners4 counter drop
        ip6 saddr @scanners6 counter drop
        ip  saddr @synflood4 counter drop
        ip6 saddr @synflood6 counter drop
        ip  saddr @blocklist4 counter drop
        ip6 saddr @blocklist6 counter drop

        # ICMP — rate-limited (echo replies for monitoring)
        meta l4proto icmp  icmp  type echo-request limit rate 5/second accept
        meta l4proto icmpv6 icmpv6 type { nd-neighbor-solicit, nd-router-advert, nd-neighbor-advert, echo-request } limit rate 10/second accept

        # ------------------------------------------------------------------
        # SYN-flood detection — dynamic set acts as the rate-limiter:
        # element appears when source IP exceeds rate, drops follow until
        # the timeout elapses. Pure kernel-path, no userspace involved.
        # ------------------------------------------------------------------
        tcp flags & (fin|syn|rst|ack) == syn \\
            add @synflood4 { ip saddr limit rate over 60/second burst 20 packets } \\
            counter drop
        tcp flags & (fin|syn|rst|ack) == syn \\
            add @synflood6 { ip6 saddr limit rate over 60/second burst 20 packets } \\
            counter drop

        # ------------------------------------------------------------------
        # SSH — fail2ban handles brute-force at app layer
        # Also light rate-limit here to stop blunt scanners cheaply.
        # ------------------------------------------------------------------
        tcp dport $ssh_port ct state new limit rate 10/minute burst 5 packets counter accept
        tcp dport $ssh_port ct state new counter add @scanners4 { ip saddr timeout 1h } drop

        # ------------------------------------------------------------------
        # Reality inbound — public
        # ------------------------------------------------------------------
$reality_rule
        tcp dport $reality_port counter accept

        # ------------------------------------------------------------------
        # NODE_PORT — only the panel IP may reach it. Anyone else: scanner.
        # ------------------------------------------------------------------
$node_rule_v4
$node_rule_v6

        # ------------------------------------------------------------------
        # Port-scan honeypot:
        # Anything touching a port that is NOT in the publicly-allowed list
        # is, by definition, a scanner. Ban for 24h, then drop. The set's
        # default timeout applies, so we don't need to spell it here.
        # ------------------------------------------------------------------
        meta nfproto ipv4 tcp dport != { $pub_ports } add @scanners4 { ip saddr } counter drop
        meta nfproto ipv6 tcp dport != { $pub_ports } add @scanners6 { ip6 saddr } counter drop
        meta nfproto ipv4 meta l4proto udp           add @scanners4 { ip saddr } counter drop
        meta nfproto ipv6 meta l4proto udp           add @scanners6 { ip6 saddr } counter drop

        # Catch-all — log + drop (rate-limited so it can't fill the journal)
        limit rate 1/second counter log prefix "noder-drop: " level warn
        counter drop
    }

    # ------------------------------------------------------------------
    # Forward — MSS clamp for any traffic we forward
    # ------------------------------------------------------------------
    chain forward {
        type filter hook forward priority filter; policy accept;
        tcp flags syn / syn,rst tcp option maxseg size set rt mtu
    }

    # ------------------------------------------------------------------
    # Output — also clamp MSS on TCP we originate (defends against
    # PMTUD blackholes when xray makes upstream conns).
    # ------------------------------------------------------------------
    chain output {
        type filter hook output priority filter; policy accept;
        tcp flags syn / syn,rst tcp option maxseg size set rt mtu
    }
}
EOF
}

# ---------------------------------------------------------------------------
# Apply / status / blocklist sync
# ---------------------------------------------------------------------------

firewall::apply() {
    require_root
    need_command nft
    log_info "Применяю nftables…"

    backup_file "$FW_CONF"
    local tmp
    tmp="$(mktemp)"
    firewall::__render_config > "$tmp"

    # Validate first — never overwrite a working ruleset with a broken one.
    if ! nft -c -f "$tmp" 2>/tmp/noder-nft.err; then
        log_error "nftables config не прошёл валидацию:"
        sed 's/^/    /' /tmp/noder-nft.err >&2
        rm -f "$tmp"
        return 1
    fi

    install -m 0644 "$tmp" "$FW_CONF"
    rm -f "$tmp"

    systemctl enable nftables >/dev/null 2>&1 || true
    if ! systemctl restart nftables; then
        log_error "systemctl restart nftables упал, пробую nft -f"
        nft -f "$FW_CONF"
    fi

    log_ok "nftables применён"
}

firewall::sync_blocklist() {
    # $1 = path to CIDR file (one CIDR per line, IPv4)
    # Loads into @blocklist4 atomically.
    require_root
    local src="$1"
    [ -r "$src" ] || die "blocklist file not readable: $src"
    log_info "Загружаю $(wc -l < "$src") CIDR в @blocklist4…"
    nft -- flush set inet noder blocklist4 || true
    # Add in chunks to avoid command-line length limits.
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$src" \
        | awk 'BEGIN{ORS=", "} {print $0}' \
        | tr -d '\n' \
        | sed 's/, $//' \
        | xargs -I {} nft add element inet noder blocklist4 "{ {} }" 2>/dev/null || true
    log_ok "blocklist4 обновлён"
}

firewall::status() {
    require_root
    need_command nft

    echo "── nftables ──"
    nft list ruleset 2>/dev/null | head -80 || echo "(nft пустой)"
    echo
    echo "── sets ──"
    for s in scanners4 scanners6 synflood4 synflood6 blocklist4 blocklist6; do
        local n
        n="$(nft list set inet noder "$s" 2>/dev/null | grep -c 'elements =' || echo 0)"
        if [ "$n" -gt 0 ]; then
            local sz
            sz="$(nft list set inet noder "$s" 2>/dev/null | awk '/elements/ {gsub(/[^,]/,""); print length($0)+1; exit}')"
            printf '  %-12s ~%s\n' "$s" "${sz:-?}"
        else
            printf '  %-12s (пусто)\n' "$s"
        fi
    done
    echo
    echo "── conntrack ──"
    printf '  count / max: %s / %s\n' \
        "$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null)" \
        "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# Strict mode toggle
# ---------------------------------------------------------------------------

firewall::set_strict_mode() {
    # $1 = on | off
    require_root
    case "$1" in
        on|1|true)
            state::set firewall.strict_mode true
            log_ok "Жёсткий режим включён — Reality теперь имеет per-IP rate-limit (200/мин)."
            log_warn "Внимание: мобильный CGNAT (МТС/Мегафон/Билайн) может пройти этот лимит на одном IP."
            ;;
        off|0|false)
            state::set firewall.strict_mode false
            log_ok "Жёсткий режим выключен — Reality пропускает любые подключения."
            ;;
        *) die "expected on|off, got: $1" ;;
    esac
    firewall::apply
}

# ---------------------------------------------------------------------------
# fail2ban — ONLY for SSH (NODE_PORT is handled in kernel via nft)
# ---------------------------------------------------------------------------

firewall::install_fail2ban() {
    require_root
    need_command fail2ban-client

    backup_file "$F2B_JAIL"
    cat > "$F2B_JAIL" <<EOF
# /etc/fail2ban/jail.d/noder-ssh.conf — managed by noder
# by popokole
[sshd]
enabled = true
port = $(firewall::__ssh_port)
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 24h
action = nftables-multiport[name=sshd, port=ssh, protocol=tcp]
         noder-telegram[name=sshd]
EOF

    backup_file "$F2B_ACTION"
    cat > "$F2B_ACTION" <<'EOF'
# /etc/fail2ban/action.d/noder-telegram.conf — managed by noder
# by popokole
[Definition]
actionban = /opt/noder/scripts/f2b-tg.sh ban "<name>" "<ip>"
actionunban = /opt/noder/scripts/f2b-tg.sh unban "<name>" "<ip>"
EOF

    install -d -m 0755 "$NODER_HOME/scripts"
    cat > "$NODER_HOME/scripts/f2b-tg.sh" <<'EOF'
#!/usr/bin/env bash
# Forward fail2ban events to Telegram via 09_telegram.py (if configured).
# by popokole
set -euo pipefail
event="$1"; jail="$2"; ip="$3"
NODER_HOME="${NODER_HOME:-/opt/noder}"
if [ -x "$NODER_HOME/modules/09_telegram.py" ]; then
    "$NODER_HOME/modules/09_telegram.py" notify --event "f2b_$event" --jail "$jail" --ip "$ip" 2>/dev/null || true
fi
EOF
    chmod 0755 "$NODER_HOME/scripts/f2b-tg.sh"

    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban
    log_ok "fail2ban настроен (только jail для SSH; NODE_PORT защищён kernel-фильтром)"
}

# ---------------------------------------------------------------------------
# Combined apply (called from install flow)
# ---------------------------------------------------------------------------

firewall::run() {
    firewall::apply
    firewall::install_fail2ban
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------

firewall::menu() {
    while true; do
        ui::clear
        ui::header "Firewall и DDoS-фильтр"
        local sm; sm="$(firewall::__strict_mode)"
        echo "  Жёсткий режим (per-IP rate-limit на Reality): $( [ "$sm" = "1" ] && echo "${C_GREEN}ВКЛ${C_RESET}" || echo "${C_DIM}ВЫКЛ${C_RESET}" )"
        echo
        printf '  [1] Применить (re-apply) nftables\n'
        printf '  [2] Включить жёсткий режим\n'
        printf '  [3] Выключить жёсткий режим\n'
        printf '  [4] Статус (правила, sets, conntrack)\n'
        printf '  [5] Переустановить fail2ban на SSH\n'
        printf '  [6] Очистить @scanners (разбанить всех)\n'
        printf '  [0] Назад\n'
        ui::footer
        local c; ui::prompt c "$(t ui.choose_option)"
        case "$c" in
            1) firewall::apply; ui::pause ;;
            2) firewall::set_strict_mode on; ui::pause ;;
            3) firewall::set_strict_mode off; ui::pause ;;
            4) firewall::status; ui::pause ;;
            5) firewall::install_fail2ban; ui::pause ;;
            6) require_root; nft flush set inet noder scanners4 2>/dev/null || true; nft flush set inet noder scanners6 2>/dev/null || true; log_ok "Очищено"; ui::pause ;;
            0) return ;;
            *) log_warn "$(t ui.invalid_choice)"; ui::pause ;;
        esac
    done
}
