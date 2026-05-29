#!/usr/bin/env bash
# 07_node.sh — docker-compose, .env, запуск контейнера ноды Remnawave
# by popokole

[ -n "${__NODER_NODE_LOADED:-}" ] && return 0
__NODER_NODE_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

readonly NODE_DIR=/opt/remnanode
readonly NODE_COMPOSE_FILE="$NODE_DIR/docker-compose.yml"
readonly NODE_ENV_FILE="$NODE_DIR/.env"
readonly NODE_CONTAINER_NAME=remnanode
readonly NODE_IMAGE_DEFAULT="remnawave/node:latest"

# ---------------------------------------------------------------------------
# Compose snippet parser
# ---------------------------------------------------------------------------
# Принимает на stdin docker-compose-сниппет из панели Remnawave
# (со строками APP_PORT=..., SSL_CERT=...). Выводит на stdout JSON:
#   {"node_port": 2222, "ssl_cert": "...", "image": "remnawave/node:latest"}
#
# Толерантен к разным форматам: с environment-списком, env_file, отступами.
node::parse_compose_snippet() {
    python3 - <<'PY'
import json, re, sys
text = sys.stdin.read()

def find_env(name):
    # environment: list-style "- NAME=VALUE" or mapping "NAME: VALUE"
    m = re.search(rf'-\s*{re.escape(name)}\s*[:=]\s*[\'"]?(.+?)[\'"]?\s*$', text, re.MULTILINE)
    if m:
        return m.group(1).strip()
    m = re.search(rf'^\s*{re.escape(name)}\s*[:=]\s*[\'"]?(.+?)[\'"]?\s*$', text, re.MULTILINE)
    if m:
        return m.group(1).strip()
    return None

out = {
    "node_port": find_env("APP_PORT") or find_env("NODE_PORT"),
    "ssl_cert":  find_env("SSL_CERT") or find_env("SECRET_KEY"),
}
m_img = re.search(r'image:\s*[\'"]?([^\s\'"]+)', text)
out["image"] = m_img.group(1) if m_img else None

# Coerce port to int when possible.
try: out["node_port"] = int(out["node_port"])
except Exception: pass

print(json.dumps(out, ensure_ascii=False))
PY
}

# ---------------------------------------------------------------------------
# Render compose + env
# ---------------------------------------------------------------------------

node::__render_env() {
    local node_port="$1" ssl_cert="$2"
    cat <<EOF
# /opt/remnanode/.env — managed by noder
# by popokole
APP_PORT=$node_port
SSL_CERT=$ssl_cert
EOF
}

node::__render_compose() {
    local image="${1:-$NODE_IMAGE_DEFAULT}"
    cat <<EOF
# /opt/remnanode/docker-compose.yml — managed by noder
# by popokole

services:
  $NODE_CONTAINER_NAME:
    container_name: $NODE_CONTAINER_NAME
    hostname: $(state::get node_name 2>/dev/null || echo node)
    image: $image
    restart: always
    network_mode: host
    env_file: .env
    volumes:
      - /usr/local/share/xray:/usr/local/share/xray:ro
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f xray || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
EOF
}

node::write_files() {
    # node::write_files <node_port> <ssl_cert> [image]
    require_root
    local node_port="$1" ssl_cert="$2" image="${3:-$NODE_IMAGE_DEFAULT}"
    [ -z "$node_port" ] || [ -z "$ssl_cert" ] && die "node::write_files требует node_port и ssl_cert"

    install -d -m 0750 "$NODE_DIR"
    install -d -m 0750 /usr/local/share/xray

    backup_file "$NODE_ENV_FILE"
    backup_file "$NODE_COMPOSE_FILE"

    node::__render_env "$node_port" "$ssl_cert" > "$NODE_ENV_FILE"
    chmod 0600 "$NODE_ENV_FILE"

    node::__render_compose "$image" > "$NODE_COMPOSE_FILE"
    chmod 0640 "$NODE_COMPOSE_FILE"

    log_ok "compose и .env записаны в $NODE_DIR"
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

node::__compose() {
    [ -f "$NODE_COMPOSE_FILE" ] || die "compose отсутствует: $NODE_COMPOSE_FILE"
    (cd "$NODE_DIR" && docker compose "$@")
}

node::pull() {
    require_root
    log_info "Скачиваю образ ноды…"
    node::__compose pull
}

node::start() {
    require_root
    log_info "$(t control.starting)"
    node::__compose up -d --remove-orphans
    node::wait_healthy
}

node::stop() {
    require_root
    log_info "$(t control.stopping)"
    node::__compose stop
}

node::restart() {
    require_root
    log_info "$(t control.restarting)"
    node::__compose restart
    node::wait_healthy
}

node::recreate() {
    require_root
    log_info "$(t control.recreating)"
    node::__compose down
    node::__compose up -d --force-recreate
    node::wait_healthy
}

node::wait_healthy() {
    # Wait up to 30 seconds for container to be up + healthcheck OK.
    local i status
    for i in $(seq 1 30); do
        status="$(docker inspect -f '{{.State.Status}}' $NODE_CONTAINER_NAME 2>/dev/null || echo "")"
        [ "$status" = "running" ] && {
            log_ok "Контейнер ${NODE_CONTAINER_NAME} запущен"
            return 0
        }
        sleep 1
    done
    log_warn "Контейнер ${NODE_CONTAINER_NAME} не вышел в running за 30 сек"
    return 1
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

node::logs_xray_tail() {
    docker exec "$NODE_CONTAINER_NAME" tail -n 200 /var/log/xray/access.log 2>/dev/null \
        || docker logs --tail 200 "$NODE_CONTAINER_NAME" 2>&1 || echo "(нет логов)"
}

node::logs_xray_follow() {
    docker exec "$NODE_CONTAINER_NAME" tail -f /var/log/xray/access.log 2>/dev/null \
        || docker logs -f --tail 200 "$NODE_CONTAINER_NAME"
}

node::logs_container() {
    docker logs --tail 200 "$NODE_CONTAINER_NAME" 2>&1 || echo "(контейнер не существует)"
}

# ---------------------------------------------------------------------------
# Status snapshot — used by 12_health.sh
# ---------------------------------------------------------------------------

node::status_json() {
    python3 - <<PY
import json, subprocess
def sh(*args):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""
ins = sh("docker", "inspect", "-f", "{{.State.Status}}|{{.State.Health.Status}}|{{.Image}}", "$NODE_CONTAINER_NAME")
status, health, image = (ins.split("|") + ["", "", ""])[:3]
print(json.dumps({
    "container": "$NODE_CONTAINER_NAME",
    "status": status or "absent",
    "health": health or "none",
    "image": image,
}, ensure_ascii=False))
PY
}
