#!/usr/bin/env bash
# 06_selfsteal.sh — Caddy + Let's Encrypt + сайт-заглушка
# by popokole
#
# Selfsteal-режим: на стандартный 443 поднимается обычный HTTPS-сайт
# (нейтральный лендинг) с автоматическим Let's Encrypt от Caddy.
# Reality fallback внутри Xray смотрит на 127.0.0.1:<caddy_port>.

[ -n "${__NODER_SSTL_LOADED:-}" ] && return 0
__NODER_SSTL_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

readonly CADDY_CONF=/etc/caddy/Caddyfile
readonly STUB_ROOT=/var/www/selfsteal
readonly STUB_TEMPLATES=("$NODER_HOME/data/stubs"/*)

selfsteal::__install_caddy() {
    if command -v caddy >/dev/null 2>&1; then
        log_debug "Caddy уже установлен"
        return 0
    fi
    require_root
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/caddy-stable-archive-keyring.gpg ]; then
        curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /etc/apt/keyrings/caddy-stable-archive-keyring.gpg
        curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends caddy
}

selfsteal::__validate_domain() {
    local domain="$1" expected_ip="$2"
    [ -z "$domain" ] && return 1
    # Резолв
    local got
    got="$(getent ahostsv4 "$domain" | awk '{print $1; exit}')"
    if [ -z "$got" ]; then
        log_warn "DNS не резолвится: $domain"
        return 1
    fi
    if [ -n "$expected_ip" ] && [ "$got" != "$expected_ip" ]; then
        log_warn "A-запись $domain указывает на $got, ожидался $expected_ip"
        return 1
    fi
    # 80/tcp доступен снаружи для HTTP-01 challenge
    if ! timeout 5 bash -c "</dev/tcp/$domain/80" 2>/dev/null; then
        log_warn "Порт 80 на $domain не отвечает"
        return 1
    fi
    return 0
}

selfsteal::__render_stub() {
    install -d -m 0755 "$STUB_ROOT"
    # Выбираем случайный шаблон из data/stubs, если есть; иначе генерируем
    # минималистичный «coming soon».
    local pick
    if compgen -G "$NODER_HOME/data/stubs/*.html" >/dev/null; then
        pick="$(ls "$NODER_HOME/data/stubs/"*.html | shuf -n 1)"
        install -m 0644 "$pick" "$STUB_ROOT/index.html"
    else
        cat > "$STUB_ROOT/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Welcome</title>
<style>
body{font-family:system-ui,-apple-system,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#0c0c10;color:#aaa}
h1{font-weight:300;letter-spacing:.2em}
</style>
</head>
<body><h1>WELCOME</h1></body>
</html>
EOF
    fi
}

selfsteal::__render_caddyfile() {
    local domain="$1"
    cat <<EOF
# /etc/caddy/Caddyfile — managed by noder
# by popokole

{
    admin off
}

$domain {
    root * $STUB_ROOT
    file_server
    encode gzip
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer-when-downgrade"
    }
    log {
        output file /var/log/caddy/access.log
        format json
    }
}
EOF
}

selfsteal::run() {
    # Аргументы из install-мастера приходят через state.json.
    require_root
    local domain panel_ip
    domain="$(state::get selfsteal.domain)"
    panel_ip="$(state::get panel.ip)"
    [ -z "$domain" ] && die "selfsteal.domain не задан в state.json"

    selfsteal::__install_caddy
    if ! selfsteal::__validate_domain "$domain" ""; then
        die "Домен $domain не прошёл проверку (DNS/порт 80). Settings → DNS → запустите ещё раз."
    fi
    selfsteal::__render_stub
    backup_file "$CADDY_CONF"
    selfsteal::__render_caddyfile "$domain" > "$CADDY_CONF"

    install -d -m 0750 /var/log/caddy
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl restart caddy
    log_ok "Caddy запущен на $domain (Let's Encrypt в фоне)"

    # Сохраняем cert_dir для backup'ов
    python3 "$NODER_HOME/modules/03_state.py" set selfsteal.cert_dir \
        "\"/var/lib/caddy/.local/share/caddy\"" >/dev/null
}
