#!/usr/bin/env bash
# uninstall.sh — удаление ноды с двойным подтверждением
# by popokole

[ -n "${__NODER_UNINSTALL_LOADED:-}" ] && return 0
__NODER_UNINSTALL_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

uninstall::__pre_backup() {
    local stamp dst
    stamp="$(date +%Y-%m-%d_%H-%M-%S)"
    dst="$NODER_BACKUP_DIR/uninstall_${stamp}.tar.gz"
    install -d -m 0700 "$NODER_BACKUP_DIR"
    tar -czf "$dst" \
        --ignore-failed-read \
        "$NODER_STATE_DIR" \
        /opt/remnanode \
        /etc/nftables.conf \
        /etc/fail2ban/jail.d/noder-ssh.conf \
        /etc/sysctl.d/99-noder-net.conf \
        /etc/systemd/system/noder-*.service \
        2>/dev/null || true
    chmod 0600 "$dst"
    log_ok "$(t uninstall.backup_saved): $dst"
}

uninstall::run() {
    require_root

    ui::clear
    ui::header "Удаление ноды"
    if ! state::exists; then
        log_warn "Нода не установлена"
        return 0
    fi

    local name; name="$(state::get node_name)"
    echo "$(t uninstall.warn)"
    echo
    printf '  Нода: %s%s%s\n\n' "$C_BOLD" "$name" "$C_RESET"

    # First confirm
    if [ "${1:-}" != "--yes" ]; then
        if ! ui::confirm "Действительно удалить ноду $name?"; then
            log_info "Отменено"
            return 0
        fi
        # Second confirm: typed name
        local typed
        ui::prompt typed "$(t uninstall.confirm_name)"
        if [ "$typed" != "$name" ]; then
            die "$(t uninstall.name_mismatch)"
        fi
    fi

    # Backup BEFORE we tear anything down.
    uninstall::__pre_backup

    # Stop + remove container
    if [ -d /opt/remnanode ]; then
        (cd /opt/remnanode && docker compose down --rmi local 2>/dev/null || true)
    fi
    docker rm -f remnanode 2>/dev/null || true

    # Disable + remove systemd units
    for unit in noder-tg noder-boot-ok noder-blocklists noder-updates noder-health; do
        systemctl disable --now "${unit}.service" 2>/dev/null || true
        systemctl disable --now "${unit}.timer"   2>/dev/null || true
        rm -f "/etc/systemd/system/${unit}.service" "/etc/systemd/system/${unit}.timer"
    done
    systemctl daemon-reload

    # Restore vanilla nftables: flush our table only.
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet noder 2>/dev/null || true
    fi
    rm -f /etc/nftables.conf /etc/sysctl.d/99-noder-net.conf /etc/modprobe.d/noder-conntrack.conf
    sysctl --system >/dev/null 2>&1 || true

    # fail2ban jail
    rm -f /etc/fail2ban/jail.d/noder-ssh.conf /etc/fail2ban/action.d/noder-telegram.conf
    systemctl restart fail2ban 2>/dev/null || true

    # logrotate
    rm -f /etc/logrotate.d/noder

    # Remove main directories (keep backups!)
    rm -rf /opt/remnanode "$NODER_STATE_DIR" "$NODER_LOG_DIR" /var/lib/noder

    # Unregister CLI
    rm -f /usr/local/bin/noder

    # NB: we deliberately do NOT delete $NODER_HOME (/opt/noder) here when
    # uninstall is invoked from that very script — it would yank the rug.
    # The user can `rm -rf /opt/noder` separately if they want.

    log_ok "$(t uninstall.done)"
}
