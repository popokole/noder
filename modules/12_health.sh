#!/usr/bin/env bash
# 12_health.sh — health-check ноды + детектор аномалий трафика
# by popokole

[ -n "${__NODER_HEALTH_LOADED:-}" ] && return 0
__NODER_HEALTH_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

readonly HEALTH_STATS_FILE=/var/lib/noder/traffic-stats.json
readonly HEALTH_TRAFFIC_DROP_HOURS=4

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

health::__line() {
    # health::__line <label> <ok|warn|fail> <value...>
    local label="$1" status="$2"; shift 2
    local mark colour
    case "$status" in
        ok)   mark="●"; colour="$C_GREEN" ;;
        warn) mark="●"; colour="$C_YELLOW" ;;
        fail) mark="●"; colour="$C_RED" ;;
        info) mark="·"; colour="$C_DIM" ;;
        *)    mark="?"; colour="$C_DIM" ;;
    esac
    printf '  %s%s%s %-26s %s\n' "$colour" "$mark" "$C_RESET" "$label" "$*"
}

health::__container_status() {
    docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null || echo "absent"
}

health::__xray_running() {
    docker exec remnanode pgrep -f xray >/dev/null 2>&1
}

health::__port_listening() {
    local port="$1"
    [ -z "$port" ] && return 1
    ss -tln 2>/dev/null | awk -v p=":$port" '$4 ~ p {found=1} END {exit !found}'
}

health::__tls_to_dest() {
    local dest="$1"
    [ -z "$dest" ] && return 1
    NODER_HOME="$NODER_HOME" python3 "$NODER_HOME/modules/05_reality.py" validate "$dest" 2>/dev/null \
        | python3 -c 'import json,sys; r=json.load(sys.stdin); sys.exit(0 if r.get("tls13") else 1)'
}

health::__panel_reachable() {
    local host="$1" port="$2"
    [ -z "$host" ] || [ -z "$port" ] && return 1
    timeout 5 bash -c "</dev/tcp/$host/$port" 2>/dev/null
}

health::__cpu_ram() {
    local cpu ram
    cpu="$(awk '/cpu / {usage=($2+$4)*100/($2+$4+$5)} END {printf "%.1f%%", usage}' /proc/stat)"
    ram="$(free -m | awk '/Mem:/ {printf "%d/%dMB (%d%%)", $3, $2, $3*100/$2}')"
    echo "CPU $cpu · RAM $ram"
}

health::__log_size() {
    local size_node size_noder
    size_node="$(du -sh /opt/remnanode 2>/dev/null | awk '{print $1}')"
    size_noder="$(du -sh "$NODER_LOG_DIR" 2>/dev/null | awk '{print $1}')"
    echo "node=$size_node · noder=$size_noder"
}

health::__active_connections() {
    local port="$1"
    [ -z "$port" ] && { echo 0; return; }
    ss -tn state established "sport = :$port" 2>/dev/null | tail -n +2 | wc -l
}

health::__blocklist_age() {
    local last
    last="$(state::get blocklist_last_update)"
    if [ -z "$last" ] || [ "$last" = "null" ]; then
        echo "никогда"
        return
    fi
    local age
    age="$(python3 -c "
import sys, datetime
try:
    ts = datetime.datetime.strptime('$last', '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    delta = datetime.datetime.now(datetime.timezone.utc) - ts
    h = int(delta.total_seconds() / 3600)
    print(f'{h}ч назад')
except Exception:
    print('неизвестно')
")"
    echo "$age"
}

# ---------------------------------------------------------------------------
# Traffic anomaly detector — лёгкий sliding-window
# ---------------------------------------------------------------------------

health::record_traffic_sample() {
    install -d -m 0700 "$(dirname "$HEALTH_STATS_FILE")"
    local port; port="$(state::get reality.port)"
    local conns; conns="$(health::__active_connections "$port")"
    python3 - <<PY
import json, datetime, pathlib
p = pathlib.Path("$HEALTH_STATS_FILE")
data = {"samples": []}
if p.exists():
    try: data = json.loads(p.read_text())
    except Exception: pass
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
data["samples"].append({"ts": now, "connections": $conns})
# keep last 7 days worth (every 30 min ⇒ ≤ 336 samples)
data["samples"] = data["samples"][-400:]
p.write_text(json.dumps(data))
p.chmod(0o600)
PY
}

health::check_traffic_anomaly() {
    [ -r "$HEALTH_STATS_FILE" ] || return 0
    python3 - <<PY
import json, datetime, pathlib, sys
p = pathlib.Path("$HEALTH_STATS_FILE")
try:
    data = json.loads(p.read_text())
except Exception:
    sys.exit(0)
samples = data.get("samples", [])
if len(samples) < 24:  # need at least ~12h of history
    sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
recent_zero_hours = 0
for s in reversed(samples):
    if s.get("connections", 0) > 0:
        break
    ts = datetime.datetime.fromisoformat(s["ts"])
    if (now - ts).total_seconds() > 3600 * $HEALTH_TRAFFIC_DROP_HOURS:
        break
    recent_zero_hours = (now - ts).total_seconds() / 3600
# baseline avg from older samples (excluding the recent zero streak)
older = [s["connections"] for s in samples[:-16] if s.get("connections", 0) > 0]
if not older:
    sys.exit(0)
avg = sum(older) / len(older)
if recent_zero_hours >= $HEALTH_TRAFFIC_DROP_HOURS and avg > 1:
    print(f"trafficdrop:{recent_zero_hours:.1f}h:baseline={avg:.1f}")
    sys.exit(2)
PY
}

# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

health::report() {
    ui::clear
    ui::header "$(t health.title)"

    if ! state::exists; then
        log_warn "$(t menu.not_installed_hint)"
        ui::footer
        return
    fi

    local name port dest panel_host panel_node_port
    name="$(state::get node_name)"
    port="$(state::get reality.port)"
    dest="$(state::get reality.dest)"
    panel_host="$(state::get panel.host)"
    panel_node_port="$(state::get panel.node_port)"

    printf '  Нода: %s%s%s\n\n' "$C_BOLD" "$name" "$C_RESET"

    # 1. Container
    local cs; cs="$(health::__container_status)"
    case "$cs" in
        running)  health::__line "$(t health.container)" ok   "running" ;;
        exited)   health::__line "$(t health.container)" fail "exited"  ;;
        absent)   health::__line "$(t health.container)" fail "контейнер отсутствует" ;;
        restarting) health::__line "$(t health.container)" warn "restarting" ;;
        *)        health::__line "$(t health.container)" warn "$cs" ;;
    esac

    # 2. Xray process
    if health::__xray_running; then
        health::__line "$(t health.xray_proc)" ok "активен"
    else
        health::__line "$(t health.xray_proc)" fail "не активен"
    fi

    # 3. Port listening
    if health::__port_listening "$port"; then
        health::__line "$(t health.port_listen)" ok "слушает :$port"
    else
        health::__line "$(t health.port_listen)" fail "порт :$port не слушает"
    fi

    # 4. TLS to dest
    if [ -n "$dest" ]; then
        if health::__tls_to_dest "$dest"; then
            health::__line "$(t health.tls_dest)" ok "TLS 1.3 OK → $dest"
        else
            health::__line "$(t health.tls_dest)" warn "TLS handshake к $dest не подтверждён"
        fi
    fi

    # 5. Panel reachability
    if health::__panel_reachable "$panel_host" "$panel_node_port"; then
        health::__line "$(t health.panel_reachable)" ok "$panel_host:$panel_node_port"
    else
        health::__line "$(t health.panel_reachable)" warn "$panel_host:$panel_node_port не отвечает"
    fi

    # 6. Resources
    health::__line "$(t health.resources)" info "$(health::__cpu_ram)"
    health::__line "$(t health.log_size)"  info "$(health::__log_size)"

    # 7. Active connections
    local conns; conns="$(health::__active_connections "$port")"
    health::__line "$(t health.connections)" info "$conns"

    # 8. Timers
    local timers; timers="$(systemctl list-timers --no-pager 2>/dev/null | grep -c noder-)"
    health::__line "$(t health.timers)" info "$timers активных"

    # 9. Blocklist age
    health::__line "$(t health.blocklist_age)" info "$(health::__blocklist_age)"

    # 10. Anomaly check
    local anomaly; anomaly="$(health::check_traffic_anomaly || true)"
    if [ -n "$anomaly" ]; then
        echo
        local hours; hours="$(echo "$anomaly" | cut -d: -f2)"
        log_warn "📉 трафик упал до нуля ${hours} (см. п.11 ТЗ — возможна блокировка)"
    fi

    ui::footer
}
