#!/usr/bin/env bash
# 01_preflight.sh — проверка root/ОС/архитектуры + установка системных зависимостей
# by popokole
#
# Идемпотентен: повторный запуск не делает лишних действий.

[ -n "${__NODER_PREFLIGHT_LOADED:-}" ] && return 0
__NODER_PREFLIGHT_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

readonly SUPPORTED_OS_VERSIONS=("22.04" "24.04")
readonly REQUIRED_PACKAGES=(
    curl
    ca-certificates
    gnupg
    jq
    python3
    python3-venv
    nftables
    fail2ban
    logrotate
    iproute2
    cron
    openssl
    tar
    coreutils
)

preflight::detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  echo "amd64"; return 0 ;;
        aarch64|arm64) echo "arm64"; return 0 ;;
        *)
            die "Unsupported architecture: $arch (поддерживаются x86_64 и arm64)"
            ;;
    esac
}

preflight::detect_os() {
    # Returns "<id> <version_id>"
    if [ ! -r /etc/os-release ]; then
        die "/etc/os-release не найден — поддерживается только Ubuntu"
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${ID:-unknown} ${VERSION_ID:-unknown}"
}

preflight::check_os() {
    read -r os_id os_ver <<<"$(preflight::detect_os)"
    if [ "$os_id" != "ubuntu" ]; then
        log_warn "ОС: $os_id $os_ver — поддерживается только Ubuntu. Скрипт может работать, но не тестировался."
        return 0
    fi
    local supported=0 v
    for v in "${SUPPORTED_OS_VERSIONS[@]}"; do
        [ "$os_ver" = "$v" ] && supported=1 && break
    done
    if [ "$supported" -eq 0 ]; then
        log_warn "Ubuntu $os_ver не входит в список рекомендованных (${SUPPORTED_OS_VERSIONS[*]}). Продолжаю на ваш страх и риск."
    else
        log_ok "ОС: ubuntu $os_ver"
    fi
}

preflight::check_systemd() {
    if [ ! -d /run/systemd/system ]; then
        die "systemd не обнаружен — noder требует systemd-based инициализации"
    fi
}

preflight::check_kernel() {
    # nftables требует ядро 4.x+ (любой современный Ubuntu есть).
    local kv
    kv="$(uname -r | cut -d. -f1)"
    if [ "$kv" -lt 4 ] 2>/dev/null; then
        die "Слишком старое ядро ($(uname -r)). nftables не сработает."
    fi
}

preflight::install_packages() {
    local missing=()
    local pkg
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        log_ok "Все зависимости установлены"
        return 0
    fi

    log_info "Устанавливаю пакеты: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}"
    log_ok "Пакеты установлены: ${missing[*]}"
}

preflight::ensure_runtime_dirs() {
    install -d -m 0750 "$NODER_STATE_DIR"
    install -d -m 0750 "$NODER_LOG_DIR"
    install -d -m 0700 "$NODER_BACKUP_DIR" "$NODER_BACKUP_DIR/auto" "$NODER_BACKUP_DIR/manual"
    install -d -m 0700 "$NODER_BACKUP_DIR/state" "$NODER_BACKUP_DIR/files"
    : >> "$NODER_LOG_FILE"
    chmod 0640 "$NODER_LOG_FILE"
}

preflight::install_logrotate() {
    local dst=/etc/logrotate.d/noder
    if [ -f "$dst" ]; then
        log_debug "logrotate уже настроен"
        return 0
    fi
    cat > "$dst" <<EOF
$NODER_LOG_DIR/*.log {
    weekly
    rotate 5
    maxsize 50M
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        systemctl kill -s HUP noder-tg.service 2>/dev/null || true
    endscript
}
EOF
    log_ok "logrotate: $dst"
}

preflight::register_cli() {
    # Register /usr/local/bin/noder symlink → $NODER_HOME/noder.sh
    local link=/usr/local/bin/noder
    local target="$NODER_HOME/noder.sh"
    if [ ! -x "$target" ]; then
        chmod +x "$target"
    fi
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
        log_debug "noder уже зарегистрирован"
        return 0
    fi
    ln -sf "$target" "$link"
    log_ok "Команда зарегистрирована: $link → $target"
}

preflight::run() {
    require_root
    log_info "Pre-flight проверки…"
    preflight::check_os
    preflight::check_systemd
    preflight::check_kernel
    local arch
    arch="$(preflight::detect_arch)"
    export NODER_ARCH="$arch"
    log_ok "Архитектура: $arch"
    preflight::install_packages
    preflight::ensure_runtime_dirs
    preflight::install_logrotate
    preflight::register_cli
    log_ok "Pre-flight завершён"
}
