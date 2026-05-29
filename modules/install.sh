#!/usr/bin/env bash
# install.sh — мастер установки ноды Remnawave
# by popokole
#
# Главные особенности:
#  • Идемпотентность: каждый шаг проверяет своё состояние ДО действия.
#  • Rollback: trap ERR + накопительный список «сделанного» (INSTALL_DONE).
#    При фатальной ошибке откатывается в обратном порядке.
#  • --random: всё, что не задано флагом, генерируется автоматически.
#  • Парсер docker-compose из панели: вставил снипет — забрал NODE_PORT +
#    SSL_CERT.
#  • Поддерживает шесть базовых режимов вызова из ТЗ 4 (флаги CLI).

[ -n "${__NODER_INSTALL_LOADED:-}" ] && return 0
__NODER_INSTALL_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

# Pre-load всех зависимых модулей (lazy в run-time).
install::__load_modules() {
    source "$NODER_HOME/modules/01_preflight.sh"
    source "$NODER_HOME/modules/02_docker.sh"
    source "$NODER_HOME/modules/07_node.sh"
    source "$NODER_HOME/modules/08_firewall.sh"
    source "$NODER_HOME/modules/14_kernel.sh"
}

# ---------------------------------------------------------------------------
# Shared install context (filled by CLI args + wizard)
# ---------------------------------------------------------------------------
declare -A INSTALL_CTX=()
INSTALL_DONE=()

install::__set()  { INSTALL_CTX["$1"]="$2"; }
install::__get()  { printf '%s' "${INSTALL_CTX[$1]:-}"; }
install::__has()  { [ -n "${INSTALL_CTX[$1]:-}" ]; }

# Push a rollback step onto the stack.
install::__commit() { INSTALL_DONE+=("$1"); }

install::__rollback() {
    log_warn "Откатываю установку…"
    local i
    for ((i=${#INSTALL_DONE[@]}-1; i>=0; i--)); do
        local action="${INSTALL_DONE[$i]}"
        log_info "  rollback: $action"
        case "$action" in
            state_init)    rm -f "$NODER_STATE_FILE" 2>/dev/null || true ;;
            compose_write) rm -f /opt/remnanode/docker-compose.yml /opt/remnanode/.env 2>/dev/null || true ;;
            container_up)  (cd /opt/remnanode && docker compose down) 2>/dev/null || true ;;
            firewall_apply)
                # Restore the most recent backup of nftables.conf
                local last
                last="$(ls -t "$NODER_BACKUP_DIR/files/"*/nftables.conf 2>/dev/null | head -1)"
                if [ -n "$last" ]; then
                    cp "$last" /etc/nftables.conf && systemctl reload nftables 2>/dev/null || true
                fi
                ;;
        esac
    done
    log_warn "Откат завершён."
}

# ---------------------------------------------------------------------------
# CLI parser
# ---------------------------------------------------------------------------

install::__parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --random)       install::__set random 1 ;;
            --name)         install::__set name "$2"; shift ;;
            --mode)         install::__set mode "$2"; shift ;;
            --port)         install::__set port "$2"; shift ;;
            --dest)         install::__set dest "$2"; shift ;;
            --domain)       install::__set domain "$2"; shift ;;
            --panel-ip)     install::__set panel_ip "$2"; shift ;;
            --panel-host)   install::__set panel_host "$2"; shift ;;
            --node-port)    install::__set node_port "$2"; shift ;;
            --secret)       install::__set ssl_cert "$2"; shift ;;
            --compose)      install::__set compose_snippet "$2"; shift ;;
            --tg-token)     install::__set tg_token "$2"; shift ;;
            --tg-chat)      install::__set tg_chat "$2"; shift ;;
            --panel-url)    install::__set api_url "$2"; shift ;;
            --panel-token)  install::__set api_token "$2"; shift ;;
            --auto-register) install::__set auto_register 1 ;;
            --no-tg)        install::__set no_tg 1 ;;
            --no-kernel)    install::__set no_kernel 1 ;;
            --yes|-y)       install::__set yes 1 ;;
            *) log_warn "Неизвестный флаг: $1" ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# Wizard steps (each step short-circuits if value already set)
# ---------------------------------------------------------------------------

install::__step_name() {
    install::__has name && { log_debug "name=$(install::__get name)"; return 0; }
    if install::__has random; then
        local suffix
        suffix="$(python3 "$NODER_HOME/modules/04_random.py" node-suffix)"
        install::__set name "NODE-$suffix"
        log_info "Имя сгенерировано: $(install::__get name)"
        return 0
    fi
    local input
    while true; do
        ui::prompt input "$(t install.step_name)"
        if [ ${#input} -lt 2 ]; then
            log_warn "$(t install.name_too_short)"
            continue
        fi
        if [[ ! "$input" =~ ^[A-Za-z0-9_-]+$ ]]; then
            log_warn "$(t install.name_invalid)"
            continue
        fi
        install::__set name "$input"
        break
    done
}

install::__step_mode() {
    install::__has mode && return 0
    if install::__has random; then
        install::__set mode "reality"
        log_info "Режим (random): reality"
        return 0
    fi
    ui::clear
    ui::header "$(t install.step_mode)"
    printf '  [1] %s\n' "$(t install.mode_reality)"
    printf '  [2] %s\n' "$(t install.mode_selfsteal)"
    ui::footer
    local c; ui::prompt c "$(t ui.choose_option)"
    case "$c" in
        1|"") install::__set mode reality ;;
        2)    install::__set mode selfsteal ;;
        *)    install::__set mode reality ;;
    esac
}

install::__step_dest() {
    [ "$(install::__get mode)" = "reality" ] || return 0
    install::__has dest && return 0

    if install::__has random; then
        local mask
        mask="$(NODER_HOME="$NODER_HOME" python3 "$NODER_HOME/modules/04_random.py" mask)"
        install::__set dest "$(echo "$mask" | python3 -c 'import json,sys; m=json.load(sys.stdin); print(m["domain"]+":443")')"
        install::__set server_names "$(echo "$mask" | python3 -c 'import json,sys; m=json.load(sys.stdin); print(",".join(m["server_names"]))')"
        log_info "Маска (random): $(install::__get dest)"
        return 0
    fi

    ui::clear
    ui::header "$(t install.step_dest)"
    echo "  $(t install.dest_help)"
    echo
    printf '  [1] %s\n' "$(t install.dest_random)"
    printf '  [2] %s\n' "$(t install.dest_pick)"
    printf '  [3] %s\n' "$(t install.dest_custom)"
    ui::footer
    local c; ui::prompt c "$(t ui.choose_option)"
    case "$c" in
        1|"") install::__pick_random_mask ;;
        2)    install::__pick_mask_from_list ;;
        3)    install::__pick_custom_dest ;;
        *)    install::__pick_random_mask ;;
    esac
}

install::__pick_random_mask() {
    local mask
    mask="$(NODER_HOME="$NODER_HOME" python3 "$NODER_HOME/modules/04_random.py" mask)"
    install::__set dest "$(echo "$mask" | python3 -c 'import json,sys; m=json.load(sys.stdin); print(m["domain"]+":443")')"
    install::__set server_names "$(echo "$mask" | python3 -c 'import json,sys; m=json.load(sys.stdin); print(",".join(m["server_names"]))')"
    log_ok "Маска: $(install::__get dest)"
}

install::__pick_mask_from_list() {
    local masks_json i
    masks_json="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["masks"]))' "$NODER_HOME/data/reality_masks.json")"
    local n
    n="$(echo "$masks_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
    for i in $(seq 0 $((n-1))); do
        local domain region notes
        domain="$(echo "$masks_json" | python3 -c "import json,sys; print(json.load(sys.stdin)[$i]['domain'])")"
        region="$(echo "$masks_json" | python3 -c "import json,sys; print(json.load(sys.stdin)[$i].get('region','?'))")"
        notes="$(echo "$masks_json" | python3 -c "import json,sys; print(json.load(sys.stdin)[$i].get('notes',''))")"
        printf '  [%2d] %-32s %-8s %s\n' "$((i+1))" "$domain" "$region" "$notes"
    done
    local c; ui::prompt c "$(t ui.choose_option)"
    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "$n" ]; then
        local mask
        mask="$(echo "$masks_json" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)[$((c-1))]))")"
        install::__set dest "$(echo "$mask" | python3 -c 'import json,sys; m=json.load(sys.stdin); print(m["domain"]+":443")')"
        install::__set server_names "$(echo "$mask" | python3 -c 'import json,sys; m=json.load(sys.stdin); print(",".join(m["server_names"]))')"
    else
        install::__pick_random_mask
    fi
}

install::__pick_custom_dest() {
    local input
    ui::prompt input "Введите свой dest (формат host:port)"
    local rep
    rep="$(NODER_HOME="$NODER_HOME" python3 "$NODER_HOME/modules/05_reality.py" validate "$input" 2>/dev/null || true)"
    if [ -z "$rep" ]; then
        log_warn "Не удалось проверить dest. Использую как есть."
    else
        local ok
        ok="$(echo "$rep" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))')"
        if [ "$ok" != "True" ]; then
            log_warn "Dest не прошёл проверку:"
            echo "$rep" | python3 -m json.tool | sed 's/^/    /'
            if ! ui::confirm "Использовать всё равно?"; then
                install::__pick_custom_dest
                return
            fi
        fi
    fi
    install::__set dest "$input"
    install::__set server_names "$(echo "$input" | cut -d: -f1)"
}

install::__step_domain() {
    [ "$(install::__get mode)" = "selfsteal" ] || return 0
    install::__has domain && return 0
    ui::prompt INPUT "$(t install.step_domain)"
    install::__set domain "$INPUT"
}

install::__step_port() {
    install::__has port && return 0
    if install::__has random; then
        # Try 443 first; if busy, ask random.py
        if ss -tlnp 2>/dev/null | grep -q ':443 '; then
            install::__set port "$(python3 "$NODER_HOME/modules/04_random.py" port)"
        else
            install::__set port 443
        fi
        log_info "Порт (random): $(install::__get port)"
        return 0
    fi
    ui::clear
    ui::header "$(t install.step_port)"
    printf '  [1] %s\n' "$(t install.port_443)"
    printf '  [2] %s\n' "$(t install.port_random)"
    printf '  [3] %s\n' "$(t install.port_manual)"
    ui::footer
    local c; ui::prompt c "$(t ui.choose_option)"
    case "$c" in
        1|"") install::__set port 443 ;;
        2)    install::__set port "$(python3 "$NODER_HOME/modules/04_random.py" port)" ;;
        3)    local p; ui::prompt p "Порт"; install::__set port "$p" ;;
    esac
}

install::__step_panel() {
    install::__has panel_host || {
        if install::__has random; then
            log_warn "panel-host обязателен — передайте --panel-host или --panel-ip"
            return 1
        fi
        local p; ui::prompt p "$(t install.step_panel_host)"
        install::__set panel_host "$p"
    }
    # Резолвим в IP если домен
    if ! install::__has panel_ip; then
        local h
        h="$(install::__get panel_host)"
        if [[ "$h" =~ ^[0-9.]+$ ]]; then
            install::__set panel_ip "$h"
        else
            local resolved
            resolved="$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1; exit}')"
            install::__set panel_ip "${resolved:-$h}"
        fi
    fi
}

install::__step_compose() {
    install::__has node_port && install::__has ssl_cert && return 0

    if install::__has compose_snippet; then
        local parsed
        parsed="$(printf '%s' "$(install::__get compose_snippet)" | node::parse_compose_snippet)"
        local np sc
        np="$(echo "$parsed" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("node_port") or "")')"
        sc="$(echo "$parsed" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ssl_cert") or "")')"
        [ -n "$np" ] && install::__set node_port "$np"
        [ -n "$sc" ] && install::__set ssl_cert "$sc"
        if [ -z "$np" ] || [ -z "$sc" ]; then
            log_warn "Не удалось извлечь NODE_PORT/SSL_CERT из --compose. Введу вручную."
        else
            log_ok "Из compose: NODE_PORT=$np, SSL_CERT=$(mask_secret "$sc")"
            return 0
        fi
    fi

    install::__has yes && return 0

    ui::clear
    ui::header "Связь ноды с панелью"
    echo "$(t install.step_panel_compose)"
    echo "  (можно либо вставить compose из панели целиком, либо просто Enter)"
    echo
    local first_line snippet=""
    read -r first_line || true
    if [ -n "$first_line" ]; then
        snippet="$first_line"$'\n'
        while IFS= read -r line; do snippet+="$line"$'\n'; done
    fi
    if [ -n "$snippet" ]; then
        local parsed
        parsed="$(printf '%s' "$snippet" | node::parse_compose_snippet)"
        local np sc
        np="$(echo "$parsed" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("node_port") or "")')"
        sc="$(echo "$parsed" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ssl_cert") or "")')"
        [ -n "$np" ] && install::__set node_port "$np"
        [ -n "$sc" ] && install::__set ssl_cert "$sc"
    fi

    if ! install::__has node_port; then
        local p; ui::prompt p "$(t install.step_node_port)"
        install::__set node_port "$p"
    fi
    if ! install::__has ssl_cert; then
        local s; ui::prompt_secret s "$(t install.step_secret)"
        install::__set ssl_cert "$s"
    fi
}

install::__step_tg() {
    install::__has no_tg && return 0
    install::__has tg_token && return 0
    install::__has yes && return 0
    if ui::confirm "$(t install.step_tg)"; then
        local tok chat
        ui::prompt_secret tok "Токен Telegram-бота"
        ui::prompt chat "chat_id для уведомлений"
        install::__set tg_token "$tok"
        install::__set tg_chat "$chat"
    fi
}

install::__step_kernel() {
    install::__has no_kernel && return 0
    install::__has yes && { install::__set apply_kernel 1; return 0; }
    if ui::confirm "Применить kernel-тюнинг + XanMod BBRv3? (рекомендуется)"; then
        install::__set apply_kernel 1
    fi
}

# ---------------------------------------------------------------------------
# Summary + confirm
# ---------------------------------------------------------------------------

install::__summary() {
    ui::clear
    ui::header "$(t install.summary)"
    printf '  %-22s %s\n' "Имя ноды:"      "$(install::__get name)"
    printf '  %-22s %s\n' "Режим:"         "$(install::__get mode)"
    if [ "$(install::__get mode)" = "reality" ]; then
        printf '  %-22s %s\n' "Dest-маска:"    "$(install::__get dest)"
        printf '  %-22s %s\n' "Server names:"  "$(install::__get server_names)"
        printf '  %-22s %s\n' "Reality-порт:"  "$(install::__get port)"
    else
        printf '  %-22s %s\n' "Домен (selfsteal):" "$(install::__get domain)"
    fi
    printf '  %-22s %s\n' "Панель:"        "$(install::__get panel_host) ($(install::__get panel_ip))"
    printf '  %-22s %s\n' "NODE_PORT:"     "$(install::__get node_port)"
    printf '  %-22s %s\n' "SSL_CERT:"      "$(mask_secret "$(install::__get ssl_cert)")"
    printf '  %-22s %s\n' "Telegram:"      "$( install::__has tg_token && echo "настроен ($(mask_secret "$(install::__get tg_token)"))" || echo "пропущен" )"
    printf '  %-22s %s\n' "Kernel/BBRv3:"  "$( install::__has apply_kernel && echo "да" || echo "нет" )"
    ui::footer
    if install::__has yes; then return 0; fi
    if ! ui::confirm "$(t install.confirm)?"; then
        die "$(t install.cancel)"
    fi
}

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------

install::__execute() {
    require_root
    log_info "$(t install.starting)"

    # 1. Pre-flight
    log_info "$(t install.preflight)"
    preflight::run

    # 2. Docker
    log_info "$(t install.docker_install)"
    docker::ensure

    # 3. Reality keypair
    if [ "$(install::__get mode)" = "reality" ]; then
        log_info "$(t install.gen_keys)"
        local keys priv pub
        keys="$(python3 "$NODER_HOME/modules/05_reality.py" keygen)"
        priv="$(echo "$keys" | python3 -c 'import json,sys; print(json.load(sys.stdin)["private_key"])')"
        pub="$(echo "$keys" | python3 -c 'import json,sys; print(json.load(sys.stdin)["public_key"])')"
        install::__set priv "$priv"
        install::__set pub "$pub"
        install::__set short_id "$(python3 "$NODER_HOME/modules/04_random.py" short-id)"
    fi

    # 4. State
    log_info "$(t install.state_write)"
    python3 "$NODER_HOME/modules/03_state.py" init --node-name "$(install::__get name)" --force >/dev/null
    install::__commit state_init

    python3 "$NODER_HOME/modules/03_state.py" set mode "$(install::__get mode)" >/dev/null
    python3 "$NODER_HOME/modules/03_state.py" set panel.host  "$(install::__get panel_host)" >/dev/null
    python3 "$NODER_HOME/modules/03_state.py" set panel.ip    "$(install::__get panel_ip)" >/dev/null
    python3 "$NODER_HOME/modules/03_state.py" set panel.node_port "$(install::__get node_port)" >/dev/null
    python3 "$NODER_HOME/modules/03_state.py" set panel.secret_key "$(install::__get ssl_cert)" >/dev/null

    if [ "$(install::__get mode)" = "reality" ]; then
        python3 "$NODER_HOME/modules/03_state.py" set reality.port "$(install::__get port)" >/dev/null
        python3 "$NODER_HOME/modules/03_state.py" set reality.dest "$(install::__get dest)" >/dev/null
        python3 "$NODER_HOME/modules/03_state.py" set reality.server_names \
            "[$(install::__get server_names | awk -F, '{for(i=1;i<=NF;i++)printf "%s\"%s\"", (i==1?"":","), $i}')]" >/dev/null
        python3 "$NODER_HOME/modules/03_state.py" set reality.private_key "$(install::__get priv)" >/dev/null
        python3 "$NODER_HOME/modules/03_state.py" set reality.public_key  "$(install::__get pub)" >/dev/null
        python3 "$NODER_HOME/modules/03_state.py" set reality.short_ids "[\"$(install::__get short_id)\"]" >/dev/null
    fi
    if install::__has tg_token; then
        python3 "$NODER_HOME/modules/03_state.py" set telegram.enabled true >/dev/null
        python3 "$NODER_HOME/modules/03_state.py" set telegram.tg_token "$(install::__get tg_token)" >/dev/null
        python3 "$NODER_HOME/modules/03_state.py" set telegram.chat_id "$(install::__get tg_chat)" >/dev/null
    fi

    # 5. Compose + .env
    log_info "$(t install.compose_create)"
    node::write_files "$(install::__get node_port)" "$(install::__get ssl_cert)"
    install::__commit compose_write

    # 6. Kernel (optional)
    if install::__has apply_kernel; then
        log_info "Применяю kernel-тюнинг + XanMod (если совместимо)"
        kernel::run
    fi

    # 7. Firewall
    log_info "$(t install.fw_apply)"
    firewall::run
    install::__commit firewall_apply

    # 8. Start container
    log_info "$(t install.node_start)"
    node::pull
    node::start
    install::__commit container_up

    # 9. Print params
    install::__print_params
}

# ---------------------------------------------------------------------------
# Final output for panel
# ---------------------------------------------------------------------------

install::__print_params() {
    local name port dest sn pub short_id ip
    name="$(install::__get name)"
    port="$(install::__get port)"
    dest="$(install::__get dest)"
    sn="$(install::__get server_names)"
    pub="$(install::__get pub)"
    short_id="$(install::__get short_id)"
    # Лучшее приближение «нашего» внешнего IP
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

    ui::clear
    ui::header "$(t install.params_for_panel)"
    cat <<EOF

  Нода:           $name
  Адрес ноды:     ${ip}:$(install::__get node_port)
  SECRET_KEY:     (уже введён вами)

  Inbound VLESS-Reality:
    Порт:          $port
    Dest:          $dest
    Server names:  $sn
    Private key:   $(install::__get priv)
    Public key:    $pub
    Short ID:      $short_id
    Flow:          xtls-rprx-vision

  $(t install.copy_to_profile)

EOF
    ui::footer

    # Дублируем в Telegram (если настроен) — через 09_telegram, когда модуль готов
    if install::__has tg_token && [ -x "$NODER_HOME/modules/09_telegram.py" ]; then
        python3 "$NODER_HOME/modules/09_telegram.py" notify --event install_done 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------

install::run() {
    install::__load_modules
    install::__parse_args "$@"
    trap 'common::on_error $LINENO' ERR
    trap 'install::__rollback; exit 130' INT TERM

    install::__step_name
    install::__step_mode
    install::__step_dest
    install::__step_domain
    install::__step_port
    install::__step_panel
    install::__step_compose
    install::__step_tg
    install::__step_kernel
    install::__summary
    install::__execute

    log_ok "$(t install.success)"
}

install::change_panel() {
    # п.5.12 — смена IP/домена панели
    require_root
    state::exists || die "$(t menu.not_installed_hint)"
    local h ip
    ui::prompt h "Новый IP или домен панели" "$(state::get panel.host)"
    [ -z "$h" ] && return 0
    if [[ "$h" =~ ^[0-9.]+$ ]]; then
        ip="$h"
    else
        ip="$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1; exit}')"
    fi
    python3 "$NODER_HOME/modules/03_state.py" set panel.host "$h"
    python3 "$NODER_HOME/modules/03_state.py" set panel.ip "$ip"
    log_ok "panel.host=$h, panel.ip=$ip"
    install::__load_modules
    firewall::apply
    if ui::confirm "Перезапустить ноду сейчас?"; then
        node::restart
    fi
}
