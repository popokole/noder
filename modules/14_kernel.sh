#!/usr/bin/env bash
# 14_kernel.sh — установка XanMod (BBRv3) + sysctl-тюнинг + boot-watchdog
# by popokole
#
# Стратегия:
#  • Auto-detect виртуализации через systemd-detect-virt.
#  • KVM / bare-metal / vmware / xen → XanMod (BBRv3) + sysctl.
#  • OpenVZ / LXC / Docker → XanMod пропускается, остаётся stock-ядро +
#    BBR(v1) + sysctl + nftables. Это даёт ~80% эффекта без риска.
#  • ARM64 → то же что OpenVZ (XanMod ARM64-сборки нестабильны).
#  • Перед reboot ставим стабильное ядро как default, XanMod — как
#    `grub-reboot` (одноразовый next-boot). После успешной загрузки
#    XanMod systemd-сервис ждёт 10 минут и делает XanMod default.
#    Если XanMod не взлетит — следующий boot вернёт на stock.

[ -n "${__NODER_KERNEL_LOADED:-}" ] && return 0
__NODER_KERNEL_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

readonly KERNEL_SYSCTL_FILE=/etc/sysctl.d/99-noder-net.conf
readonly KERNEL_MODPROBE_FILE=/etc/modprobe.d/noder-conntrack.conf
readonly KERNEL_STATE_FILE=/var/lib/noder/kernel-state.json
readonly KERNEL_BOOT_OK_UNIT=/etc/systemd/system/noder-boot-ok.service
readonly KERNEL_PROMOTE_DELAY="${NODER_KERNEL_PROMOTE_DELAY:-600}"  # 10 min watchdog

# ---------------------------------------------------------------------------
# Environment detection
# ---------------------------------------------------------------------------

kernel::detect_virt() {
    # Returns: kvm | qemu | xen | vmware | hyperv | bare | openvz | lxc | docker | unknown
    local v
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        v="$(systemd-detect-virt 2>/dev/null || echo unknown)"
    else
        v="unknown"
    fi
    case "$v" in
        none)              echo "bare" ;;
        kvm|qemu|microsoft|vmware|xen|amazon|google|oracle|parallels|bochs|bhyve)
                           echo "kvm" ;;
        openvz)            echo "openvz" ;;
        lxc|lxc-libvirt)   echo "lxc" ;;
        docker|podman|systemd-nspawn|wsl)
                           echo "container" ;;
        *)                 echo "$v" ;;
    esac
}

kernel::current_cpu_level() {
    # Linux x86-64-v1 / v2 / v3 / v4 microarch level.
    # v3 ≈ AVX2; v4 ≈ AVX-512. XanMod ships matching packages.
    if [ -r /proc/cpuinfo ]; then
        local flags
        flags="$(awk -F': ' '/^flags/ {print $2; exit}' /proc/cpuinfo)"
        echo "$flags" | grep -qw avx512f && { echo "x64v4"; return 0; }
        echo "$flags" | grep -qw avx2    && { echo "x64v3"; return 0; }
        echo "$flags" | grep -qw sse4_2  && { echo "x64v2"; return 0; }
    fi
    echo "x64v1"
}

kernel::can_install_xanmod() {
    # Echoes "yes" or a reason for "no".
    local arch virt
    arch="${NODER_ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}"
    virt="$(kernel::detect_virt)"

    case "$arch" in
        amd64|x86_64) ;;
        *) echo "no:arch:$arch"; return 0 ;;
    esac

    case "$virt" in
        openvz|lxc|container) echo "no:virt:$virt"; return 0 ;;
    esac

    # Ubuntu only — XanMod packaging assumes Debian/Ubuntu.
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian) ;;
            *) echo "no:os:${ID:-unknown}"; return 0 ;;
        esac
    fi

    echo "yes"
}

# ---------------------------------------------------------------------------
# sysctl + modprobe — applied unconditionally on every env
# ---------------------------------------------------------------------------

kernel::__bbr_module() {
    # Choose the best congestion control available on the running kernel.
    #   • XanMod ships bbr3 (module: tcp_bbr; sysctl value: bbr or bbr3)
    #   • Mainline ≥ 5.4 ships bbr (v1) as `tcp_bbr`
    # We check what the kernel actually accepts.
    local available
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")"
    for cc in bbr3 bbr2 bbr; do
        if echo " $available " | grep -q " $cc "; then
            echo "$cc"
            return 0
        fi
    done
    # Try to load the module on-demand.
    modprobe tcp_bbr 2>/dev/null || true
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")"
    if echo " $available " | grep -q " bbr "; then
        echo "bbr"
        return 0
    fi
    echo "cubic"
}

kernel::apply_sysctl() {
    require_root
    local cc
    cc="$(kernel::__bbr_module)"
    log_info "Применяю sysctl (congestion=$cc)…"

    backup_file "$KERNEL_SYSCTL_FILE"
    cat > "$KERNEL_SYSCTL_FILE" <<EOF
# /etc/sysctl.d/99-noder-net.conf — managed by noder
# by popokole

# TCP congestion + qdisc
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $cc

# TCP Fast Open (server + client)
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 0

# Path-MTU probing — survives PMTUD blackholes (common on RU mobile)
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# Low latency for small writes
net.ipv4.tcp_notsent_lowat = 16384

# Auto-tuning for high-BDP RU links
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864

# SYN-flood defences (also see nft @flood set)
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 16384

# Conntrack — tier-aware timeouts
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 15
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 15
net.netfilter.nf_conntrack_generic_timeout = 60

# Ephemeral port range — wide for outbound conns from Xray
net.ipv4.ip_local_port_range = 10000 65000

# TIME-WAIT recycling (reuse is safe; recycle removed in 4.12+)
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Anti-spoof
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# IPv6 hardening (keep IPv6 working, just disable router-advertised ll-routes)
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# File handles
fs.file-max = 2097152
EOF

    # nf_conntrack hash bucket — set at module load time
    backup_file "$KERNEL_MODPROBE_FILE"
    cat > "$KERNEL_MODPROBE_FILE" <<EOF
# /etc/modprobe.d/noder-conntrack.conf — managed by noder
# by popokole
options nf_conntrack hashsize=131072
EOF

    # Apply now (silently skip keys that aren't supported on this kernel).
    sysctl --system >/dev/null 2>&1 || log_warn "часть sysctl-параметров отвергнута ядром (это нормально на старых ядрах)"
    log_ok "sysctl применён"

    # Reload conntrack hashsize via sysctl if module supports it on the fly.
    if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
        echo 131072 > /sys/module/nf_conntrack/parameters/hashsize || true
    fi
}

# ---------------------------------------------------------------------------
# XanMod installation
# ---------------------------------------------------------------------------

kernel::__probe_xanmod_repo() {
    # Verify the repo actually serves a Release file. As of mid-2026 the
    # deb.xanmod.org CDN intermittently returns 404 on everything; if so,
    # we skip XanMod entirely instead of half-adding a broken apt source.
    local url="http://deb.xanmod.org/dists/releases/Release"
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" || echo 0)"
    if [ "$code" = "200" ]; then
        return 0
    fi
    log_warn "XanMod репозиторий недоступен ($url → HTTP $code)"
    return 1
}

kernel::__add_xanmod_repo() {
    if [ -f /etc/apt/sources.list.d/xanmod-release.list ]; then
        return 0
    fi
    install -m 0755 -d /etc/apt/keyrings
    if ! curl -fsSL --max-time 15 https://dl.xanmod.org/archive.key \
            | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg.tmp 2>/dev/null; then
        rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg.tmp
        log_warn "Не удалось скачать XanMod ключ — пропускаю репозиторий"
        return 1
    fi
    mv /etc/apt/keyrings/xanmod-archive-keyring.gpg.tmp \
       /etc/apt/keyrings/xanmod-archive-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main" \
        > /etc/apt/sources.list.d/xanmod-release.list
    # apt-get update -qq может вернуть 100 если репо отдаёт 404 на Release.
    # Не валим установку — снимаем файл и сообщаем.
    if ! apt-get update -qq -o Dir::Etc::sourcelist=sources.list.d/xanmod-release.list \
            -o Dir::Etc::sourceparts=/dev/null -o APT::Get::List-Cleanup=0 2>/dev/null; then
        log_warn "apt-get update для XanMod вернул ошибку — удаляю репозиторий"
        rm -f /etc/apt/sources.list.d/xanmod-release.list
        return 1
    fi
    # Полный update тоже на случай если первый refresh не подхватил
    apt-get update -qq 2>/dev/null || true
    return 0
}

kernel::__pick_xanmod_pkg() {
    # Returns the package name appropriate for this CPU.
    local lvl
    lvl="$(kernel::current_cpu_level)"
    case "$lvl" in
        x64v4) echo "linux-xanmod-x64v4" ;;
        x64v3) echo "linux-xanmod-x64v3" ;;
        x64v2) echo "linux-xanmod-x64v2" ;;
        *)     echo "linux-xanmod-x64v1" ;;
    esac
}

kernel::__current_kernel_version() {
    uname -r
}

kernel::__is_xanmod_running() {
    uname -r | grep -qi xanmod
}

kernel::__newest_installed_xanmod() {
    # Returns "vmlinuz path" of the newest installed xanmod kernel, or "".
    ls -1 /boot/vmlinuz-*xanmod* 2>/dev/null | sort -V | tail -1
}

kernel::__find_grub_entry() {
    # $1 = pattern (e.g. "xanmod" or current uname -r)
    # Echo the GRUB entry id-path suitable for grub-reboot/grub-set-default.
    # Format: "Advanced options for Ubuntu>Ubuntu, with Linux <version>"
    local pattern="$1"
    [ -r /boot/grub/grub.cfg ] || { echo ""; return 0; }
    # Find advanced submenu id
    local sub
    sub="$(awk -F"['\"]" '/^submenu / {print $2; exit}' /boot/grub/grub.cfg)"
    if [ -z "$sub" ]; then
        # Single menu — find first matching menuentry
        awk -F"['\"]" -v pat="$pattern" '/^menuentry / && $2 ~ pat {print $2; exit}' /boot/grub/grub.cfg
        return 0
    fi
    local entry
    entry="$(awk -F"['\"]" -v pat="$pattern" '/^[[:space:]]*menuentry / && $2 ~ pat {print $2; exit}' /boot/grub/grub.cfg)"
    if [ -n "$entry" ]; then
        echo "${sub}>${entry}"
    fi
}

kernel::__save_state() {
    install -d -m 0700 "$(dirname "$KERNEL_STATE_FILE")"
    python3 -c "
import json, sys, pathlib
p = pathlib.Path('$KERNEL_STATE_FILE')
data = {}
if p.exists():
    try: data = json.loads(p.read_text())
    except Exception: data = {}
import os
for k, v in os.environ.items():
    if k.startswith('NODER_KS_'):
        data[k[9:].lower()] = v
p.write_text(json.dumps(data, indent=2))
p.chmod(0o600)
"
}

kernel::install_xanmod() {
    require_root
    local can_install reason
    can_install="$(kernel::can_install_xanmod)"
    case "$can_install" in
        yes) ;;
        no:arch:*)
            log_warn "XanMod пропускается: архитектура $(echo "$can_install" | cut -d: -f3) не поддерживается. Применяю только sysctl + BBR(v1)."
            kernel::apply_sysctl
            return 0
            ;;
        no:virt:*)
            local virt; virt="$(echo "$can_install" | cut -d: -f3)"
            log_warn "Виртуализация $virt не позволяет менять ядро. XanMod пропускается, применяю sysctl + BBR(v1)."
            kernel::apply_sysctl
            return 0
            ;;
        no:os:*)
            log_warn "Ваш дистрибутив не Ubuntu/Debian — XanMod пропускается."
            kernel::apply_sysctl
            return 0
            ;;
    esac

    if kernel::__is_xanmod_running; then
        log_ok "XanMod уже работает: $(kernel::__current_kernel_version)"
        kernel::apply_sysctl
        return 0
    fi

    if [ -n "$(kernel::__newest_installed_xanmod)" ]; then
        log_info "XanMod уже установлен ($(kernel::__newest_installed_xanmod | xargs basename)), но не активен. Готовлю boot-fallback…"
        kernel::__schedule_xanmod_boot
        return 0
    fi

    if ! kernel::__probe_xanmod_repo; then
        log_warn "Пропускаю XanMod (репо недоступен), применяю sysctl + BBR(v1)"
        kernel::apply_sysctl
        return 0
    fi

    local pkg
    pkg="$(kernel::__pick_xanmod_pkg)"
    log_info "Устанавливаю $pkg (микро-уровень CPU $(kernel::current_cpu_level))…"

    if ! kernel::__add_xanmod_repo; then
        log_warn "XanMod репо не добавлен, применяю только sysctl + BBR(v1)"
        kernel::apply_sysctl
        return 0
    fi
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y -qq --no-install-recommends "$pkg" 2>/dev/null; then
        log_warn "Не удалось установить $pkg, применяю только sysctl + BBR(v1)"
        # Repo больше не нужен (был добавлен временно)
        rm -f /etc/apt/sources.list.d/xanmod-release.list
        apt-get update -qq 2>/dev/null || true
        kernel::apply_sysctl
        return 0
    fi

    log_ok "Установлено: $(kernel::__newest_installed_xanmod | xargs basename 2>/dev/null || echo "$pkg")"
    update-grub >/dev/null 2>&1 || true

    kernel::__schedule_xanmod_boot
    kernel::apply_sysctl
}

kernel::__schedule_xanmod_boot() {
    # Wire up a one-shot boot-watchdog:
    #   1. Set permanent GRUB default = current (stable) entry.
    #   2. Set next boot = XanMod entry via grub-reboot.
    #   3. After successful XanMod boot, noder-boot-ok.service waits
    #      KERNEL_PROMOTE_DELAY seconds, then promotes XanMod to default.
    local stable_entry xanmod_entry
    stable_entry="$(kernel::__find_grub_entry "$(kernel::__current_kernel_version)")"
    xanmod_entry="$(kernel::__find_grub_entry xanmod)"

    if [ -z "$xanmod_entry" ]; then
        log_warn "Не нашёл XanMod в /boot/grub/grub.cfg — пропускаю grub-reboot. Загрузите вручную."
        return 0
    fi
    if [ -z "$stable_entry" ]; then
        log_warn "Не нашёл текущее (стабильное) ядро в grub.cfg — fallback может не сработать."
    fi

    # Persist state for noder-boot-ok.service
    install -d -m 0700 "$(dirname "$KERNEL_STATE_FILE")"
    python3 - <<PY
import json, pathlib
p = pathlib.Path("$KERNEL_STATE_FILE")
data = {
    "stable_entry": "$stable_entry",
    "candidate_entry": "$xanmod_entry",
    "candidate_promoted": False,
    "promote_delay_sec": int("$KERNEL_PROMOTE_DELAY"),
}
p.write_text(json.dumps(data, indent=2))
p.chmod(0o600)
PY

    # Configure GRUB
    if [ -n "$stable_entry" ]; then
        grub-set-default "$stable_entry"
        log_ok "GRUB default → стабильное ядро (fallback)"
    fi
    grub-reboot "$xanmod_entry"
    log_ok "GRUB next-boot → XanMod (одноразово; не взлетит — откатимся на default)"

    kernel::__install_boot_watchdog
    log_info "Перезагрузите систему: noder перейдёт на XanMod при следующем boot."
}

kernel::__install_boot_watchdog() {
    cat > "$KERNEL_BOOT_OK_UNIT" <<'EOF'
[Unit]
Description=noder boot-watchdog (promote candidate kernel if it boots OK)
After=multi-user.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/noder/scripts/boot-ok.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    install -d -m 0755 "$NODER_HOME/scripts"
    cat > "$NODER_HOME/scripts/boot-ok.sh" <<'EOF'
#!/usr/bin/env bash
# Promote the candidate kernel to default once it has booted cleanly.
# by popokole
set -euo pipefail

STATE=/var/lib/noder/kernel-state.json
[ -r "$STATE" ] || exit 0

candidate="$(python3 -c "import json,sys; print(json.load(open('$STATE')).get('candidate_entry',''))")"
promoted="$(python3 -c "import json,sys; print(json.load(open('$STATE')).get('candidate_promoted',False))")"
delay="$(python3 -c "import json,sys; print(int(json.load(open('$STATE')).get('promote_delay_sec',600)))")"

[ -z "$candidate" ] && exit 0
[ "$promoted" = "True" ] && exit 0

current="$(uname -r)"
case "$candidate" in
    *xanmod*) is_xanmod_candidate=1 ;;
    *)        is_xanmod_candidate=0 ;;
esac

# Only promote if we actually booted into the candidate kernel.
if [ "$is_xanmod_candidate" = "1" ] && ! echo "$current" | grep -qi xanmod; then
    logger -t noder "boot-watchdog: candidate XanMod did not boot (running $current); keeping stable default"
    exit 0
fi

logger -t noder "boot-watchdog: candidate kernel booted as $current; waiting ${delay}s before promoting"
sleep "$delay"

# Final health-check: is xray-node container up?
if command -v docker >/dev/null 2>&1; then
    if ! docker ps --filter "name=remnanode" --format '{{.Status}}' | grep -qi 'up'; then
        logger -t noder "boot-watchdog: remnanode container not healthy; refusing to promote candidate"
        exit 0
    fi
fi

grub-set-default "$candidate"
python3 - <<PY
import json, pathlib
p = pathlib.Path("$STATE")
data = json.loads(p.read_text())
data["candidate_promoted"] = True
p.write_text(json.dumps(data, indent=2))
PY
logger -t noder "boot-watchdog: promoted '$candidate' as permanent GRUB default"
EOF
    chmod 0755 "$NODER_HOME/scripts/boot-ok.sh"

    systemctl daemon-reload
    systemctl enable --now noder-boot-ok.service >/dev/null 2>&1 || true
    log_ok "boot-watchdog установлен (промоут через ${KERNEL_PROMOTE_DELAY}s после успешной загрузки)"
}

# ---------------------------------------------------------------------------
# Status / report
# ---------------------------------------------------------------------------

kernel::status() {
    local virt arch cc available tfo qdisc bbr_runtime
    virt="$(kernel::detect_virt)"
    arch="${NODER_ARCH:-$(uname -m)}"
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")"
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "?")"
    tfo="$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "?")"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")"
    bbr_runtime="$(grep -c bbr /proc/net/netstat 2>/dev/null || echo 0)"

    printf '%s Ядро:                %s\n' "  " "$(uname -r)"
    printf '%s Виртуализация:       %s\n' "  " "$virt"
    printf '%s Архитектура:         %s\n' "  " "$arch"
    printf '%s CPU уровень:         %s\n' "  " "$(kernel::current_cpu_level)"
    printf '%s XanMod:              %s\n' "  " "$(kernel::__is_xanmod_running && echo "активен" || echo "не активен")"
    printf '%s Congestion control:  %s  (доступно: %s)\n' "  " "$cc" "$available"
    printf '%s Default qdisc:       %s\n' "  " "$qdisc"
    printf '%s TCP Fast Open:       %s  (3 = client+server)\n' "  " "$tfo"
    printf '%s Conntrack max:       %s\n' "  " "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "?")"
    printf '%s Conntrack текущие:   %s\n' "  " "$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo "?")"
}

# ---------------------------------------------------------------------------
# Menu entry-points
# ---------------------------------------------------------------------------

kernel::menu() {
    while true; do
        ui::clear
        ui::header "Ядро и BBRv3"
        kernel::status
        echo
        printf '  [1] Установить XanMod + применить sysctl\n'
        printf '  [2] Применить только sysctl + BBR(v1) (без замены ядра)\n'
        printf '  [3] Проверить congestion control / TFO / conntrack\n'
        printf '  [4] Подготовить reboot на XanMod (если уже установлен)\n'
        printf '  [5] Откатить sysctl к дефолтам ОС\n'
        printf '  [0] Назад\n'
        ui::footer
        local c; ui::prompt c "$(t ui.choose_option)"
        case "$c" in
            1) kernel::install_xanmod; ui::pause ;;
            2) kernel::apply_sysctl; ui::pause ;;
            3) kernel::status; ui::pause ;;
            4) kernel::__schedule_xanmod_boot; ui::pause ;;
            5) kernel::revert_sysctl; ui::pause ;;
            0) return ;;
            *) log_warn "$(t ui.invalid_choice)"; ui::pause ;;
        esac
    done
}

kernel::revert_sysctl() {
    require_root
    if [ -f "$KERNEL_SYSCTL_FILE" ]; then
        backup_file "$KERNEL_SYSCTL_FILE"
        rm -f "$KERNEL_SYSCTL_FILE"
        log_ok "Удалён $KERNEL_SYSCTL_FILE"
    fi
    if [ -f "$KERNEL_MODPROBE_FILE" ]; then
        backup_file "$KERNEL_MODPROBE_FILE"
        rm -f "$KERNEL_MODPROBE_FILE"
        log_ok "Удалён $KERNEL_MODPROBE_FILE"
    fi
    sysctl --system >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Combined entry — install flow calls this
# ---------------------------------------------------------------------------

kernel::run() {
    # Used by install wizard. Idempotent.
    kernel::install_xanmod
}
