#!/usr/bin/env bash
# backup.sh — backup / restore (п.10 ТЗ)
# by popokole
#
# Что: state.json, docker-compose, .env, nftables ruleset, fail2ban,
#      Caddy (selfsteal), последние гео-списки.
# Куда: /var/backups/noder/auto/YYYY-MM-DD_HH-MM-SS.tar.gz (auto), manual/.
# Ротация: 30 авто-копий.

[ -n "${__NODER_BACKUP_LOADED:-}" ] && return 0
__NODER_BACKUP_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

readonly BACKUP_AUTO_DIR="$NODER_BACKUP_DIR/auto"
readonly BACKUP_MANUAL_DIR="$NODER_BACKUP_DIR/manual"
readonly BACKUP_RETAIN_AUTO=30

backup::__items() {
    local list=(
        "$NODER_STATE_DIR"
        /opt/remnanode/docker-compose.yml
        /opt/remnanode/.env
        /etc/nftables.conf
        /etc/sysctl.d/99-noder-net.conf
        /etc/modprobe.d/noder-conntrack.conf
        /etc/fail2ban/jail.d/noder-ssh.conf
        /etc/fail2ban/action.d/noder-telegram.conf
        /etc/caddy/Caddyfile
        /etc/systemd/system/noder-tg.service
        /etc/systemd/system/noder-blocklists.service
        /etc/systemd/system/noder-blocklists.timer
        /etc/systemd/system/noder-updates.service
        /etc/systemd/system/noder-updates.timer
        /etc/systemd/system/noder-boot-ok.service
        /usr/local/share/xray/geosite.dat
        /usr/local/share/xray/geoip.dat
    )
    printf '%s\n' "${list[@]}"
}

backup::create() {
    # backup::create [auto|manual]
    require_root
    local kind="${1:-manual}"
    local dst_dir
    case "$kind" in
        auto)   dst_dir="$BACKUP_AUTO_DIR" ;;
        manual|*) dst_dir="$BACKUP_MANUAL_DIR" ;;
    esac
    install -d -m 0700 "$dst_dir"

    local stamp; stamp="$(date +%Y-%m-%d_%H-%M-%S)"
    local dst="$dst_dir/noder-${stamp}.tar.gz"

    local tmp; tmp="$(mktemp)"
    backup::__items | grep -v '^$' > "$tmp"
    # filter to existing paths only
    : >| "${tmp}.exists"
    while IFS= read -r p; do
        [ -e "$p" ] && echo "$p" >> "${tmp}.exists"
    done < "$tmp"

    tar -czf "$dst" --files-from="${tmp}.exists" 2>/dev/null || true
    chmod 0600 "$dst"
    rm -f "$tmp" "${tmp}.exists"
    log_ok "Backup: $dst ($(du -h "$dst" | awk '{print $1}'))"

    # Ротация auto-бэкапов
    if [ "$kind" = "auto" ]; then
        local extra
        extra="$(ls -1t "$BACKUP_AUTO_DIR"/noder-*.tar.gz 2>/dev/null | tail -n +$((BACKUP_RETAIN_AUTO + 1)))"
        if [ -n "$extra" ]; then
            echo "$extra" | xargs -r rm -f
            log_debug "Старые auto-бэкапы удалены"
        fi
    fi

    echo "$dst"
}

backup::list() {
    echo "── auto ──"
    ls -lh "$BACKUP_AUTO_DIR"/*.tar.gz 2>/dev/null | awk '{print "  ", $9, "("$5")"}' || echo "  (пусто)"
    echo "── manual ──"
    ls -lh "$BACKUP_MANUAL_DIR"/*.tar.gz 2>/dev/null | awk '{print "  ", $9, "("$5")"}' || echo "  (пусто)"
}

backup::restore_last() {
    require_root
    local last
    last="$(ls -1t "$BACKUP_AUTO_DIR"/noder-*.tar.gz "$BACKUP_MANUAL_DIR"/noder-*.tar.gz 2>/dev/null | head -1)"
    [ -z "$last" ] && die "Нет ни одного бэкапа"
    backup::__restore_from "$last"
}

backup::restore_choose() {
    require_root
    mapfile -t backups < <(ls -1t "$BACKUP_AUTO_DIR"/noder-*.tar.gz "$BACKUP_MANUAL_DIR"/noder-*.tar.gz 2>/dev/null)
    if [ "${#backups[@]}" -eq 0 ]; then
        die "Нет ни одного бэкапа"
    fi
    local i
    for i in "${!backups[@]}"; do
        printf '  [%2d] %s\n' "$((i+1))" "${backups[$i]}"
    done
    local c; ui::prompt c "Выберите номер"
    if [[ ! "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "${#backups[@]}" ]; then
        die "Некорректный выбор"
    fi
    backup::__restore_from "${backups[$((c-1))]}"
}

backup::__restore_from() {
    local src="$1"
    log_info "Восстанавливаю из $src…"
    if ! ui::confirm "Это перепишет state.json, compose, firewall. Продолжить?"; then
        return 0
    fi
    # Pre-restore safety copy
    backup::create manual >/dev/null || true
    tar -xzf "$src" -C / 2>/dev/null || die "tar упал"

    sysctl --system >/dev/null 2>&1 || true
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart nftables 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    source "$NODER_HOME/modules/07_node.sh" 2>/dev/null && node::restart 2>/dev/null || true
    log_ok "Восстановлено из $src"
}

backup::install_timer() {
    require_root
    cat > /etc/systemd/system/noder-backup.service <<EOF
[Unit]
Description=noder auto-backup
After=docker.service

[Service]
Type=oneshot
ExecStart=$NODER_HOME/noder.sh backup auto
EOF

    cat > /etc/systemd/system/noder-backup.timer <<'EOF'
[Unit]
Description=noder daily auto-backup

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now noder-backup.timer
    log_ok "noder-backup.timer установлен (03:30 ежедневно, ротация 30 копий)"
}

backup::schedule() { backup::install_timer; }

# CLI dispatcher
backup::run() {
    case "${1:-create}" in
        create|"")        backup::create "${2:-manual}" ;;
        auto)             backup::create auto ;;
        list)             backup::list ;;
        restore-last)     backup::restore_last ;;
        restore-choose)   backup::restore_choose ;;
        schedule)         backup::install_timer ;;
        *) die "noder backup: неизвестная команда: $1" ;;
    esac
}
