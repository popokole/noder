#!/usr/bin/env bash
# 10_updates.sh — проверка и установка обновлений Xray и образа ноды
# by popokole
#
# Каналы:
#   • Xray-core   — GitHub release API (XTLS/Xray-core)
#   • Образ ноды  — digest remnawave/node:latest на Docker Hub
# Логика по ТЗ 5.9:
#   — раз в неделю systemd-таймер шлёт алерт в Telegram при появлении новой
#     версии с inline-кнопкой «Обновить сейчас» / «Отложить» / «Игнорировать»;
#   — нажатие на кнопку запускает 10_updates.sh (через 09_telegram.py
#     callback). До нажатия — ничего не обновляется автоматически.

[ -n "${__NODER_UPDATES_LOADED:-}" ] && return 0
__NODER_UPDATES_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

readonly UPDATES_CACHE=/var/lib/noder/updates.json
readonly XRAY_REPO=XTLS/Xray-core
readonly NODE_IMAGE=remnawave/node

updates::__github_latest() {
    # GET https://api.github.com/repos/$1/releases/latest -> tag_name
    local repo="$1"
    curl -fsSL --connect-timeout 8 --max-time 20 \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${repo}/releases/latest" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tag_name","").lstrip("v"))' 2>/dev/null
}

updates::__current_xray_version() {
    # Read from the running container.
    docker exec remnanode xray version 2>/dev/null \
        | awk '/Xray/ {print $2; exit}' \
        | sed 's/^v//'
}

updates::__image_digest() {
    # docker.io v2 manifest digest for $image:$tag
    local image="$1" tag="${2:-latest}"
    local token
    token="$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${image}:pull" \
        2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
    [ -z "$token" ] && return 1
    curl -fsSI \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        "https://registry-1.docker.io/v2/${image}/manifests/${tag}" 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1} /^docker-content-digest:/ {print $2; exit}' \
        | tr -d '\r\n'
}

updates::__current_image_digest() {
    docker inspect --format '{{index .RepoDigests 0}}' "${NODE_IMAGE}:latest" 2>/dev/null \
        | awk -F'@' '{print $2}'
}

# ---------------------------------------------------------------------------
# Public actions
# ---------------------------------------------------------------------------

updates::check() {
    log_info "Проверяю обновления…"
    install -d -m 0700 "$(dirname "$UPDATES_CACHE")"

    local cur_xray new_xray cur_img new_img
    cur_xray="$(updates::__current_xray_version)"
    new_xray="$(updates::__github_latest "$XRAY_REPO")"
    cur_img="$(updates::__current_image_digest)"
    new_img="$(updates::__image_digest "$NODE_IMAGE" latest)"

    printf '  Xray: текущий %-12s доступен %s\n' "${cur_xray:-?}" "${new_xray:-?}"
    printf '  Image digest:\n'
    printf '    current: %s\n' "${cur_img:-?}"
    printf '    latest : %s\n' "${new_img:-?}"

    local xray_changed=0 image_changed=0
    [ -n "$cur_xray" ] && [ -n "$new_xray" ] && [ "$cur_xray" != "$new_xray" ] && xray_changed=1
    [ -n "$cur_img" ] && [ -n "$new_img" ] && [ "$cur_img" != "$new_img" ] && image_changed=1

    python3 - <<PY
import json, pathlib, datetime
p = pathlib.Path("$UPDATES_CACHE")
p.write_text(json.dumps({
    "checked_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "xray": {"current": "$cur_xray", "latest": "$new_xray", "changed": $xray_changed == 1},
    "image": {"current": "$cur_img", "latest": "$new_img", "changed": $image_changed == 1},
}, indent=2))
p.chmod(0o600)
PY

    if [ "$xray_changed" -eq 1 ] || [ "$image_changed" -eq 1 ]; then
        log_warn "Доступно обновление"
        updates::__notify_tg "$cur_xray" "$new_xray" "$image_changed"
        return 2
    fi
    log_ok "Всё актуально"
}

updates::__notify_tg() {
    [ -x "$NODER_HOME/modules/09_telegram.py" ] || return 0
    python3 "$NODER_HOME/modules/09_telegram.py" notify \
        --event update_available \
        --xray-old "$1" --xray-new "$2" \
        --image-changed "$3" 2>/dev/null || true
}

updates::xray() {
    # Xray-core живёт ВНУТРИ образа remnawave/node. Обновить «только Xray»
    # без замены образа невозможно — образ привязан к версии Xray. Поэтому
    # обновление Xray = pull нового образа.
    log_info "Xray встроен в образ ноды — обновление = pull нового образа"
    updates::image
}

updates::image() {
    require_root
    log_info "Pull нового образа $NODE_IMAGE:latest…"
    docker pull "$NODE_IMAGE:latest"
    log_info "Пересоздание контейнера…"
    source "$NODER_HOME/modules/07_node.sh"
    node::recreate
    log_ok "Контейнер запущен на новом образе"
    if [ -x "$NODER_HOME/modules/09_telegram.py" ]; then
        python3 "$NODER_HOME/modules/09_telegram.py" notify --event update_done 2>/dev/null || true
    fi
}

updates::rollback() {
    require_root
    log_info "Откат к предыдущему образу из локального кэша…"
    local prev
    prev="$(docker images "$NODE_IMAGE" --format '{{.ID}} {{.CreatedAt}}' | sort -k2,3 | head -2 | tail -1 | awk '{print $1}')"
    if [ -z "$prev" ]; then
        die "В кэше нет предыдущего образа $NODE_IMAGE"
    fi
    docker tag "$prev" "$NODE_IMAGE:rollback"
    source "$NODER_HOME/modules/07_node.sh"
    sed -i "s|image: $NODE_IMAGE:latest|image: $NODE_IMAGE:rollback|" /opt/remnanode/docker-compose.yml
    node::recreate
    log_ok "Откат выполнен; чтобы вернуться обратно — noder update --confirm"
}

# ---------------------------------------------------------------------------
# systemd-таймер — проверять раз в неделю
# ---------------------------------------------------------------------------

updates::install_timer() {
    require_root
    cat > /etc/systemd/system/noder-updates.service <<EOF
[Unit]
Description=noder updates check
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$NODER_HOME/noder.sh update check
EOF

    cat > /etc/systemd/system/noder-updates.timer <<'EOF'
[Unit]
Description=noder weekly updates check

[Timer]
OnCalendar=Sun 04:00 Europe/Moscow
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now noder-updates.timer
    log_ok "noder-updates.timer установлен (воскресенье 04:00 МСК)"
}

# ---------------------------------------------------------------------------
# Sub-commands dispatch (called from noder.sh)
# ---------------------------------------------------------------------------

updates::run() {
    case "${1:-}" in
        check|"")           updates::check ;;
        xray)               updates::xray ;;
        image|--confirm)    updates::image ;;
        rollback|--rollback) updates::rollback ;;
        schedule|--schedule) updates::install_timer ;;
        *)                  die "noder update: неизвестная команда: ${1:-}" ;;
    esac
}

# Aliases for menu entries
updates::schedule() { updates::install_timer; }
