#!/usr/bin/env bash
# ssh_harden.sh — SSH hardening с защитой от самоблокировки
# by popokole
#
# Защита от lockout (ТЗ 5.11):
#   • перед сменой порта/отключением паролей проверяем наличие ключа в
#     authorized_keys; нет ключей → отказ;
#   • новый порт открывается в nft ДО изменения sshd_config;
#   • после применения — таймер на 5 минут; если пользователь не ввёл
#     `noder ssh confirm` в течение этого окна, конфиг откатывается.

[ -n "${__NODER_SSHH_LOADED:-}" ] && return 0
__NODER_SSHH_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

readonly SSHD_CONFIG=/etc/ssh/sshd_config
readonly SSH_ROLLBACK_FILE=/var/lib/noder/ssh-rollback.json
readonly SSH_CONFIRM_FLAG=/var/lib/noder/ssh-confirmed
readonly SSH_ROLLBACK_TIMER=/etc/systemd/system/noder-ssh-rollback.timer
readonly SSH_ROLLBACK_SERVICE=/etc/systemd/system/noder-ssh-rollback.service
readonly SSH_CONFIRM_WINDOW_SEC=300

ssh::__current_port() {
    awk '/^Port[[:space:]]+[0-9]+/ {print $2; exit}' "$SSHD_CONFIG" 2>/dev/null
    echo 22
}

ssh::__has_authorized_keys() {
    # Любой root/sudo-пользователь с ключом — считаем безопасным.
    local found=0
    for home in /root /home/*; do
        [ -d "$home" ] || continue
        if [ -s "$home/.ssh/authorized_keys" ]; then
            local lines; lines="$(grep -cv '^[[:space:]]*\(#\|$\)' "$home/.ssh/authorized_keys" 2>/dev/null || echo 0)"
            [ "$lines" -gt 0 ] && found=1
        fi
    done
    [ "$found" -eq 1 ]
}

ssh::show() {
    require_root
    echo "── /etc/ssh/sshd_config (выжимка) ──"
    grep -E '^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|ChallengeResponseAuthentication|UsePAM)' \
        "$SSHD_CONFIG" 2>/dev/null \
        | sed 's/^/  /'
    echo
    echo "── ключи в authorized_keys ──"
    for home in /root /home/*; do
        [ -d "$home" ] || continue
        if [ -s "$home/.ssh/authorized_keys" ]; then
            local n; n="$(grep -cv '^[[:space:]]*\(#\|$\)' "$home/.ssh/authorized_keys" 2>/dev/null || echo 0)"
            printf '  %-30s %s ключей\n' "${home%/}" "$n"
        fi
    done
}

ssh::install_f2b() {
    require_root
    source "$NODER_HOME/modules/08_firewall.sh"
    firewall::install_fail2ban
}

ssh::change_port() {
    require_root
    if ! ssh::__has_authorized_keys; then
        die "В authorized_keys нет ни одного ключа. Смена порта рискованна — отказываюсь."
    fi
    local new
    ui::prompt new "Новый SSH-порт"
    [[ "$new" =~ ^[0-9]+$ ]] || die "Не порт: $new"
    [ "$new" -ge 1 ] && [ "$new" -le 65535 ] || die "Порт вне диапазона"

    local old; old="$(ssh::__current_port)"
    if [ "$new" = "$old" ]; then
        log_info "Порт уже $new — ничего не делаю"
        return 0
    fi

    log_info "Открываю новый порт $new в nft до изменения sshd…"
    nft add rule inet noder input tcp dport "$new" counter accept 2>/dev/null || true

    # Сохраняем rollback
    install -d -m 0700 "$(dirname "$SSH_ROLLBACK_FILE")"
    cp -a "$SSHD_CONFIG" "${SSHD_CONFIG}.noder-backup"
    python3 - <<PY
import json, pathlib
pathlib.Path("$SSH_ROLLBACK_FILE").write_text(json.dumps({
    "kind": "port",
    "old_port": int("$old"),
    "new_port": int("$new"),
    "sshd_backup": "$SSHD_CONFIG.noder-backup",
}))
PY

    # Меняем порт в sshd_config
    if grep -qE '^[[:space:]]*Port[[:space:]]' "$SSHD_CONFIG"; then
        sed -i "s/^[[:space:]]*Port[[:space:]].*/Port $new/" "$SSHD_CONFIG"
    else
        echo "Port $new" >> "$SSHD_CONFIG"
    fi

    sshd -t || { log_error "sshd config invalid — откатываюсь"; mv "${SSHD_CONFIG}.noder-backup" "$SSHD_CONFIG"; return 1; }
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
    log_ok "SSH слушает порт $new"

    ssh::__arm_rollback_timer
    state::set ssh_hardening true >/dev/null 2>&1 || true
    cat <<EOF

  ⚠ Сейчас открыто окно ${SSH_CONFIRM_WINDOW_SEC}с на подтверждение.
  Откройте НОВУЮ ssh-сессию на порту $new и выполните:
       noder ssh confirm

  Если за ${SSH_CONFIRM_WINDOW_SEC} секунд noder не получит подтверждения —
  sshd вернётся на порт $old и nft-правило для $new будет удалено.
EOF
}

ssh::disable_password() {
    require_root
    if ! ssh::__has_authorized_keys; then
        die "В authorized_keys нет ни одного ключа. Отключать пароль нельзя — отказываюсь."
    fi
    cp -a "$SSHD_CONFIG" "${SSHD_CONFIG}.noder-backup"
    install -d -m 0700 "$(dirname "$SSH_ROLLBACK_FILE")"
    python3 - <<PY
import json, pathlib
pathlib.Path("$SSH_ROLLBACK_FILE").write_text(json.dumps({
    "kind": "password",
    "sshd_backup": "$SSHD_CONFIG.noder-backup",
}))
PY

    sed -i 's/^[[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication no/' "$SSHD_CONFIG"
    grep -q '^PasswordAuthentication ' "$SSHD_CONFIG" || echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
    sed -i 's/^[[:space:]]*ChallengeResponseAuthentication[[:space:]].*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
    grep -q '^ChallengeResponseAuthentication ' "$SSHD_CONFIG" || echo "ChallengeResponseAuthentication no" >> "$SSHD_CONFIG"

    sshd -t || { log_error "sshd config invalid — откатываюсь"; mv "${SSHD_CONFIG}.noder-backup" "$SSHD_CONFIG"; return 1; }
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
    log_ok "Парольная аутентификация выключена"

    ssh::__arm_rollback_timer
    state::set ssh_hardening true >/dev/null 2>&1 || true
    echo
    echo "  ⚠ Окно подтверждения ${SSH_CONFIRM_WINDOW_SEC}с. Войдите в НОВОЙ сессии"
    echo "    и выполните:  noder ssh confirm"
}

ssh::__arm_rollback_timer() {
    rm -f "$SSH_CONFIRM_FLAG"
    cat > "$SSH_ROLLBACK_SERVICE" <<EOF
[Unit]
Description=noder ssh-harden rollback

[Service]
Type=oneshot
ExecStart=$NODER_HOME/noder.sh ssh __rollback_if_unconfirmed
EOF
    cat > "$SSH_ROLLBACK_TIMER" <<EOF
[Unit]
Description=noder ssh-harden rollback after ${SSH_CONFIRM_WINDOW_SEC}s

[Timer]
OnActiveSec=${SSH_CONFIRM_WINDOW_SEC}sec
Unit=$(basename "$SSH_ROLLBACK_SERVICE")

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl start "$(basename "$SSH_ROLLBACK_TIMER")"
}

ssh::confirm() {
    require_root
    : > "$SSH_CONFIRM_FLAG"
    systemctl stop "$(basename "$SSH_ROLLBACK_TIMER")" 2>/dev/null || true
    rm -f "$SSH_ROLLBACK_TIMER" "$SSH_ROLLBACK_SERVICE" "$SSH_ROLLBACK_FILE" "${SSHD_CONFIG}.noder-backup"
    systemctl daemon-reload
    log_ok "Изменения SSH подтверждены. Rollback-таймер отменён."
}

ssh::__rollback_if_unconfirmed() {
    require_root
    if [ -f "$SSH_CONFIRM_FLAG" ]; then
        log_debug "ssh-harden подтверждён, откат не нужен"
        return 0
    fi
    [ -f "$SSH_ROLLBACK_FILE" ] || return 0
    log_warn "ssh-harden не был подтверждён за окно ${SSH_CONFIRM_WINDOW_SEC}с — откат…"
    local backup; backup="$(python3 -c "import json; print(json.load(open('$SSH_ROLLBACK_FILE')).get('sshd_backup',''))")"
    if [ -n "$backup" ] && [ -f "$backup" ]; then
        cp -a "$backup" "$SSHD_CONFIG"
        sshd -t && systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
    fi
    local old; old="$(python3 -c "import json; print(json.load(open('$SSH_ROLLBACK_FILE')).get('old_port',''))")"
    local new; new="$(python3 -c "import json; print(json.load(open('$SSH_ROLLBACK_FILE')).get('new_port',''))")"
    if [ -n "$new" ]; then
        nft delete rule inet noder input handle "$(nft -a list chain inet noder input | awk -v p="$new" '/tcp dport/ && $0 ~ p {print $NF; exit}')" 2>/dev/null || true
    fi
    rm -f "$SSH_ROLLBACK_FILE" "${SSHD_CONFIG}.noder-backup"
    rm -f "$SSH_ROLLBACK_TIMER" "$SSH_ROLLBACK_SERVICE"
    systemctl daemon-reload
    log_ok "SSH откатан. Старый порт: ${old:-?}"
    if [ -x "$NODER_HOME/modules/09_telegram.py" ]; then
        python3 "$NODER_HOME/modules/09_telegram.py" notify --event ssh_rolled_back 2>/dev/null || true
    fi
}

# CLI dispatcher
ssh::run() {
    case "${1:-show}" in
        show|"")                 ssh::show ;;
        f2b|fail2ban)            ssh::install_f2b ;;
        port)                    ssh::change_port ;;
        no-password)             ssh::disable_password ;;
        confirm)                 ssh::confirm ;;
        __rollback_if_unconfirmed) ssh::__rollback_if_unconfirmed ;;
        *) die "noder ssh: неизвестная команда: $1" ;;
    esac
}
