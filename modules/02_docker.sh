#!/usr/bin/env bash
# 02_docker.sh — установка Docker Engine + compose plugin (idempotent)
# by popokole

[ -n "${__NODER_DOCKER_LOADED:-}" ] && return 0
__NODER_DOCKER_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

docker::is_installed() {
    command -v docker >/dev/null 2>&1
}

docker::has_compose_plugin() {
    docker compose version >/dev/null 2>&1
}

docker::install() {
    if docker::is_installed && docker::has_compose_plugin; then
        log_ok "Docker уже установлен ($(docker --version | head -1))"
        return 0
    fi

    require_root
    log_info "Устанавливаю Docker Engine…"

    install -m 0755 -d /etc/apt/keyrings

    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi

    local arch codename
    arch="${NODER_ARCH:-$(dpkg --print-architecture)}"
    # shellcheck disable=SC1091
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-jammy}")"

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable
EOF

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker
    log_ok "Docker установлен: $(docker --version)"
    log_ok "Compose:         $(docker compose version | head -1)"
}

docker::ensure() {
    docker::install
    # Sanity check — daemon responding.
    if ! docker info >/dev/null 2>&1; then
        die "Docker daemon не отвечает после установки"
    fi
}
