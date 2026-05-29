#!/usr/bin/env bash
# 13_menu.sh — интерактивное меню по цифрам
# by popokole

[ -n "${__NODER_MENU_LOADED:-}" ] && return 0
__NODER_MENU_LOADED=1

# shellcheck source=00_common.sh
source "$NODER_HOME/modules/00_common.sh"

# Lazy-load module on demand; show TODO placeholder if file missing.
menu::__load_or_stub() {
    local file="$1" fn_check="$2"
    if [ -r "$NODER_HOME/modules/$file" ]; then
        # shellcheck disable=SC1090
        source "$NODER_HOME/modules/$file"
        if [ -n "$fn_check" ] && ! declare -F "$fn_check" >/dev/null; then
            log_warn "модуль $file загружен, но функция $fn_check отсутствует"
            return 1
        fi
        return 0
    fi
    log_warn "модуль $file ещё не реализован"
    ui::pause
    return 1
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------

menu::main() {
    while true; do
        ui::clear
        ui::header "$(t menu.main_title)"
        local installed=""
        if state::exists; then
            local name
            name="$(state::get node_name)"
            installed="${C_GREEN}● установлена${C_RESET} ${C_DIM}(${name})${C_RESET}"
        else
            installed="${C_YELLOW}○ не установлена${C_RESET}"
        fi
        printf '  Статус: %s\n\n' "$installed"

        printf '  [%2d] %s\n' 1 "$(t menu.items.1)"
        printf '  [%2d] %s\n' 2 "$(t menu.items.2)"
        printf '  [%2d] %s\n' 3 "$(t menu.items.3)"
        printf '  [%2d] %s\n' 4 "$(t menu.items.4)"
        printf '  [%2d] %s\n' 5 "$(t menu.items.5)"
        printf '  [%2d] %s\n' 6 "$(t menu.items.6)"
        printf '  [%2d] %s\n' 7 "$(t menu.items.7)"
        printf '  [%2d] %s\n' 8 "$(t menu.items.8)"
        printf '  [%2d] %s\n' 9 "$(t menu.items.9)"
        printf '  [%2d] %s\n' 10 "$(t menu.items.10)"
        printf '  [%2d] %s\n' 11 "$(t menu.items.11)"
        printf '  [%2d] %s\n' 12 "$(t menu.items.12)"
        printf '  [%2d] %s\n' 13 "$(t menu.items.13)"
        printf '  [%2d] %s\n' 14 "$(t menu.items.14)"
        printf '  [%2d] %s\n' 15 "$(t menu.items.15)"
        printf '  [%2d] %s\n' 0 "$(t menu.items.0)"

        ui::footer
        local choice
        ui::prompt choice "$(t ui.choose_option)"

        case "$choice" in
            1)  menu::install ;;
            2)  menu::control ;;
            3)  menu::health ;;
            4)  menu::logs ;;
            5)  menu::updates ;;
            6)  menu::regen ;;
            7)  menu::show_config ;;
            8)  menu::change_panel ;;
            9)  menu::blocklists ;;
            10) menu::backup ;;
            11) menu::telegram ;;
            12) menu::ssh ;;
            13) menu::api ;;
            14) menu::uninstall ;;
            15) menu::hardening ;;
            0|q|Q|exit|quit) echo; echo "$(t ui.exit)"; exit 0 ;;
            *)  log_warn "$(t ui.invalid_choice): $choice"; ui::pause ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Sub-menus (each one is a self-contained loop; 0 returns to caller)
# ---------------------------------------------------------------------------

menu::install() {
    if menu::__load_or_stub install.sh install::run; then
        install::run
        ui::pause
    fi
}

menu::control() {
    while true; do
        ui::clear
        ui::header "$(t menu.control.title)"
        printf '  [1] %s\n' "$(t menu.control.start)"
        printf '  [2] %s\n' "$(t menu.control.stop)"
        printf '  [3] %s\n' "$(t menu.control.restart)"
        printf '  [4] %s\n' "$(t menu.control.recreate)"
        printf '  [0] %s\n' "$(t ui.back)"
        ui::footer
        local c; ui::prompt c "$(t ui.choose_option)"
        case "$c" in
            1) menu::__load_or_stub 07_node.sh node::start && node::start && ui::pause ;;
            2) menu::__load_or_stub 07_node.sh node::stop && node::stop && ui::pause ;;
            3) menu::__load_or_stub 07_node.sh node::restart && node::restart && ui::pause ;;
            4) menu::__load_or_stub 07_node.sh node::recreate && node::recreate && ui::pause ;;
            0) return ;;
            *) log_warn "$(t ui.invalid_choice)"; ui::pause ;;
        esac
    done
}

menu::health() {
    if menu::__load_or_stub 12_health.sh health::report; then
        health::report
        ui::pause
    fi
}

menu::logs() {
    while true; do
        ui::clear
        ui::header "$(t menu.logs.title)"
        printf '  [1] %s\n' "$(t menu.logs.xray_tail)"
        printf '  [2] %s\n' "$(t menu.logs.xray_follow)"
        printf '  [3] %s\n' "$(t menu.logs.container)"
        printf '  [4] %s\n' "$(t menu.logs.noder)"
        printf '  [5] %s\n' "$(t menu.logs.fail2ban)"
        printf '  [6] %s\n' "$(t menu.logs.tg)"
        printf '  [0] %s\n' "$(t ui.back)"
        ui::footer
        local c; ui::prompt c "$(t ui.choose_option)"
        case "$c" in
            1) menu::__load_or_stub 07_node.sh node::logs_xray_tail && node::logs_xray_tail && ui::pause ;;
            2) menu::__load_or_stub 07_node.sh node::logs_xray_follow && node::logs_xray_follow ;;
            3) menu::__load_or_stub 07_node.sh node::logs_container && node::logs_container && ui::pause ;;
            4) tail -n 200 "$NODER_LOG_FILE" 2>/dev/null || echo "(пусто)"; ui::pause ;;
            5) journalctl -u fail2ban --no-pager -n 200 2>/dev/null || echo "(fail2ban не активен)"; ui::pause ;;
            6) journalctl -u noder-tg --no-pager -n 200 2>/dev/null || echo "(noder-tg не активен)"; ui::pause ;;
            0) return ;;
            *) log_warn "$(t ui.invalid_choice)"; ui::pause ;;
        esac
    done
}

menu::updates() {
    while true; do
        ui::clear
        ui::header "$(t menu.updates.title)"
        printf '  [1] %s\n' "$(t menu.updates.check)"
        printf '  [2] %s\n' "$(t menu.updates.xray)"
        printf '  [3] %s\n' "$(t menu.updates.image)"
        printf '  [4] %s\n' "$(t menu.updates.rollback)"
        printf '  [5] %s\n' "$(t menu.updates.schedule)"
        printf '  [0] %s\n' "$(t ui.back)"
        ui::footer
        local c; ui::prompt c "$(t ui.choose_option)"
        case "$c" in
            1) menu::__load_or_stub 10_updates.sh updates::check && updates::check && ui::pause ;;
            2) menu::__load_or_stub 10_updates.sh updates::xray && updates::xray && ui::pause ;;
            3) menu::__load_or_stub 10_updates.sh updates::image && updates::image && ui::pause ;;
            4) menu::__load_or_stub 10_updates.sh updates::rollback && updates::rollback && ui::pause ;;
            5) menu::__load_or_stub 10_updates.sh updates::schedule && updates::schedule && ui::pause ;;
            0) return ;;
            *) log_warn "$(t ui.invalid_choice)"; ui::pause ;;
        esac
    done
}

menu::regen() {
    while true; do
        ui::clear
        ui::header "$(t menu.regen.title)"
        printf '  [1] %s\n' "$(t menu.regen.short_id)"
        printf '  [2] %s\n' "$(t menu.regen.dest)"
        printf '  [3] %s\n' "$(t menu.regen.port)"
        printf '  [4] %s\n' "$(t menu.regen.full)"
        printf '  [5] %s\n' "$(t menu.regen.rollback)"
        printf '  [0] %s\n' "$(t ui.back)"
        ui::footer
        local c; ui::prompt c "$(t ui.choose_option)"
        case "$c" in
            1) menu::__load_or_stub 06_regen.sh regen::short_id && regen::short_id && ui::pause ;;
            2) menu::__load_or_stub 06_regen.sh regen::dest && regen::dest && ui::pause ;;
            3) menu::__load_or_stub 06_regen.sh regen::port && regen::port && ui::pause ;;
            4) menu::__load_or_stub 06_regen.sh regen::full && regen::full && ui::pause ;;
            5) menu::__load_or_stub 06_regen.sh regen::rollback && regen::rollback && ui::pause ;;
            0) return ;;
            *) log_warn "$(t ui.invalid_choice)"; ui::pause ;;
        esac
    done
}

menu::show_config() {
    ui::clear
    ui::header "$(t menu.items.7)"
    if ! state::exists; then
        log_warn "$(t menu.not_installed_hint)"
        ui::pause
        return
    fi
    python3 "$NODER_HOME/modules/03_state.py" dump --mask
    ui::footer
    ui::pause
}

menu::change_panel() {
    if menu::__load_or_stub install.sh install::change_panel; then
        install::change_panel
        ui::pause
    fi
}

menu::blocklists() {
    while true; do
        ui::clear
        ui::header "$(t menu.geo.title)"
        printf '  [1] %s\n' "$(t menu.geo.both)"
        printf '  [2] %s\n' "$(t menu.geo.routing)"
        printf '  [3] %s\n' "$(t menu.geo.firewall)"
        printf '  [4] %s\n' "$(t menu.geo.sources_show)"
        printf '  [5] %s\n' "$(t menu.geo.sources_edit)"
        printf '  [6] %s\n' "$(t menu.geo.rollback)"
        printf '  [0] %s\n' "$(t ui.back)"
        ui::footer
        local c; ui::prompt c "$(t ui.choose_option)"
        case "$c" in
            1) menu::__load_or_stub 11_blocklists.sh blocklists::update_all && blocklists::update_all && ui::pause ;;
            2) menu::__load_or_stub 11_blocklists.sh blocklists::update_routing && blocklists::update_routing && ui::pause ;;
            3) menu::__load_or_stub 11_blocklists.sh blocklists::update_firewall && blocklists::update_firewall && ui::pause ;;
            4) menu::__load_or_stub 11_blocklists.sh blocklists::show_sources && blocklists::show_sources && ui::pause ;;
            5) menu::__load_or_stub 11_blocklists.sh blocklists::edit_sources && blocklists::edit_sources && ui::pause ;;
            6) menu::__load_or_stub 11_blocklists.sh blocklists::rollback && blocklists::rollback && ui::pause ;;
            0) return ;;
            *) log_warn "$(t ui.invalid_choice)"; ui::pause ;;
        esac
    done
}

menu::backup() {
    while true; do
        ui::clear
        ui::header "$(t menu.backup.title)"
        printf '  [1] %s\n' "$(t menu.backup.create)"
        printf '  [2] %s\n' "$(t menu.backup.restore_last)"
        printf '  [3] %s\n' "$(t menu.backup.restore_choose)"
        printf '  [4] %s\n' "$(t menu.backup.download)"
        printf '  [5] %s\n' "$(t menu.backup.schedule)"
        printf '  [0] %s\n' "$(t ui.back)"
        ui::footer
        local c; ui::prompt c "$(t ui.choose_option)"
        case "$c" in
            1) menu::__load_or_stub backup.sh backup::create && backup::create && ui::pause ;;
            2) menu::__load_or_stub backup.sh backup::restore_last && backup::restore_last && ui::pause ;;
            3) menu::__load_or_stub backup.sh backup::restore_choose && backup::restore_choose && ui::pause ;;
            4) menu::__load_or_stub backup.sh backup::list && backup::list && ui::pause ;;
            5) menu::__load_or_stub backup.sh backup::schedule && backup::schedule && ui::pause ;;
            0) return ;;
            *) log_warn "$(t ui.invalid_choice)"; ui::pause ;;
        esac
    done
}

menu::telegram() {
    while true; do
        ui::clear
        ui::header "$(t menu.tg.title)"
        printf '  [1] %s\n' "$(t menu.tg.enable)"
        printf '  [2] %s\n' "$(t menu.tg.disable)"
        printf '  [3] %s\n' "$(t menu.tg.change_token)"
        printf '  [4] %s\n' "$(t menu.tg.change_chat)"
        printf '  [5] %s\n' "$(t menu.tg.trusted)"
        printf '  [6] %s\n' "$(t menu.tg.test)"
        printf '  [7] %s\n' "$(t menu.tg.show)"
        printf '  [0] %s\n' "$(t ui.back)"
        ui::footer
        local c; ui::prompt c "$(t ui.choose_option)"
        case "$c" in
            1) menu::__load_or_stub 09_telegram.sh tg::enable && tg::enable && ui::pause ;;
            2) menu::__load_or_stub 09_telegram.sh tg::disable && tg::disable && ui::pause ;;
            3) menu::__load_or_stub 09_telegram.sh tg::change_token && tg::change_token && ui::pause ;;
            4) menu::__load_or_stub 09_telegram.sh tg::change_chat && tg::change_chat && ui::pause ;;
            5) menu::__load_or_stub 09_telegram.sh tg::trusted && tg::trusted && ui::pause ;;
            6) menu::__load_or_stub 09_telegram.sh tg::test && tg::test && ui::pause ;;
            7) menu::__load_or_stub 09_telegram.sh tg::show && tg::show && ui::pause ;;
            0) return ;;
            *) log_warn "$(t ui.invalid_choice)"; ui::pause ;;
        esac
    done
}

menu::ssh() {
    while true; do
        ui::clear
        ui::header "$(t menu.ssh.title)"
        printf '  [1] %s\n' "$(t menu.ssh.f2b)"
        printf '  [2] %s\n' "$(t menu.ssh.port)"
        printf '  [3] %s\n' "$(t menu.ssh.no_password)"
        printf '  [4] %s\n' "$(t menu.ssh.show)"
        printf '  [0] %s\n' "$(t ui.back)"
        ui::footer
        local c; ui::prompt c "$(t ui.choose_option)"
        case "$c" in
            1) menu::__load_or_stub ssh_harden.sh ssh::install_f2b && ssh::install_f2b && ui::pause ;;
            2) menu::__load_or_stub ssh_harden.sh ssh::change_port && ssh::change_port && ui::pause ;;
            3) menu::__load_or_stub ssh_harden.sh ssh::disable_password && ssh::disable_password && ui::pause ;;
            4) menu::__load_or_stub ssh_harden.sh ssh::show && ssh::show && ui::pause ;;
            0) return ;;
            *) log_warn "$(t ui.invalid_choice)"; ui::pause ;;
        esac
    done
}

menu::api() {
    while true; do
        ui::clear
        ui::header "$(t menu.api.title)"
        printf '  [1] %s\n' "$(t menu.api.enable)"
        printf '  [2] %s\n' "$(t menu.api.disable)"
        printf '  [3] %s\n' "$(t menu.api.change)"
        printf '  [4] %s\n' "$(t menu.api.test)"
        printf '  [5] %s\n' "$(t menu.api.auto)"
        printf '  [6] %s\n' "$(t menu.api.show)"
        printf '  [7] %s\n' "$(t menu.api.wipe)"
        printf '  [0] %s\n' "$(t ui.back)"
        ui::footer
        local c; ui::prompt c "$(t ui.choose_option)"
        case "$c" in
            1) menu::__load_or_stub panel_api.sh api::enable && api::enable && ui::pause ;;
            2) menu::__load_or_stub panel_api.sh api::disable && api::disable && ui::pause ;;
            3) menu::__load_or_stub panel_api.sh api::change && api::change && ui::pause ;;
            4) menu::__load_or_stub panel_api.sh api::test && api::test && ui::pause ;;
            5) menu::__load_or_stub panel_api.sh api::auto && api::auto && ui::pause ;;
            6) menu::__load_or_stub panel_api.sh api::show && api::show && ui::pause ;;
            7) menu::__load_or_stub panel_api.sh api::wipe && api::wipe && ui::pause ;;
            0) return ;;
            *) log_warn "$(t ui.invalid_choice)"; ui::pause ;;
        esac
    done
}

menu::uninstall() {
    if menu::__load_or_stub uninstall.sh uninstall::run; then
        uninstall::run
        ui::pause
    fi
}

menu::hardening() {
    # Объединённое меню «Ядро · BBRv3 · DDoS» — пункт 15.
    while true; do
        ui::clear
        ui::header "$(t menu.kernel.title)"
        if menu::__load_or_stub 14_kernel.sh kernel::status; then
            kernel::status
        fi
        echo
        printf '  ── Ядро ──\n'
        printf '  [1] %s\n' "$(t menu.kernel.install_xanmod)"
        printf '  [2] %s\n' "$(t menu.kernel.apply_sysctl)"
        printf '  [3] %s\n' "$(t menu.kernel.status)"
        printf '  [4] %s\n' "$(t menu.kernel.schedule_boot)"
        printf '  [5] %s\n' "$(t menu.kernel.revert)"
        printf '  ── Firewall · DDoS ──\n'
        printf '  [6] %s\n' "$(t menu.kernel.fw_apply)"
        printf '  [7] %s\n' "$(t menu.kernel.fw_strict_on)"
        printf '  [8] %s\n' "$(t menu.kernel.fw_strict_off)"
        printf '  [9] %s\n' "$(t menu.kernel.fw_status)"
        printf ' [10] %s\n' "$(t menu.kernel.fw_clear)"
        printf ' [11] %s\n' "$(t menu.kernel.fw_f2b)"
        printf '  [ 0] %s\n' "$(t ui.back)"
        ui::footer
        local c; ui::prompt c "$(t ui.choose_option)"
        case "$c" in
            1)  menu::__load_or_stub 14_kernel.sh kernel::install_xanmod && kernel::install_xanmod && ui::pause ;;
            2)  menu::__load_or_stub 14_kernel.sh kernel::apply_sysctl && kernel::apply_sysctl && ui::pause ;;
            3)  menu::__load_or_stub 14_kernel.sh kernel::status && kernel::status && ui::pause ;;
            4)  menu::__load_or_stub 14_kernel.sh kernel::install_xanmod && kernel::__schedule_xanmod_boot && ui::pause ;;
            5)  menu::__load_or_stub 14_kernel.sh kernel::revert_sysctl && kernel::revert_sysctl && ui::pause ;;
            6)  menu::__load_or_stub 08_firewall.sh firewall::apply && firewall::apply && ui::pause ;;
            7)  menu::__load_or_stub 08_firewall.sh firewall::set_strict_mode && firewall::set_strict_mode on && ui::pause ;;
            8)  menu::__load_or_stub 08_firewall.sh firewall::set_strict_mode && firewall::set_strict_mode off && ui::pause ;;
            9)  menu::__load_or_stub 08_firewall.sh firewall::status && firewall::status && ui::pause ;;
            10) menu::__load_or_stub 08_firewall.sh firewall::apply && require_root && nft flush set inet noder scanners4 2>/dev/null; nft flush set inet noder scanners6 2>/dev/null; log_ok "Очищено"; ui::pause ;;
            11) menu::__load_or_stub 08_firewall.sh firewall::install_fail2ban && firewall::install_fail2ban && ui::pause ;;
            0)  return ;;
            *)  log_warn "$(t ui.invalid_choice)"; ui::pause ;;
        esac
    done
}
