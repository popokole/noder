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
        ui::banner
        ui::status_line
        echo

        ui::section "Установка и управление"
        ui::menu_item  1 "$(t menu.items.1)"  ok
        ui::menu_item  2 "$(t menu.items.2)"
        ui::menu_item  6 "$(t menu.items.6)"
        ui::menu_item  8 "$(t menu.items.8)"
        ui::menu_item 14 "$(t menu.items.14)" danger

        ui::section "Мониторинг и диагностика"
        ui::menu_item  3 "$(t menu.items.3)"
        ui::menu_item  4 "$(t menu.items.4)"
        ui::menu_item  7 "$(t menu.items.7)"

        ui::section "Автоматизация"
        ui::menu_item  5 "$(t menu.items.5)"
        ui::menu_item  9 "$(t menu.items.9)"
        ui::menu_item 10 "$(t menu.items.10)"

        ui::section "Безопасность · ядро · бот"
        ui::menu_item 11 "$(t menu.items.11)" accent
        ui::menu_item 12 "$(t menu.items.12)"
        ui::menu_item 13 "$(t menu.items.13)" accent
        ui::menu_item 15 "$(t menu.items.15)" accent

        echo
        ui::menu_item  0 "$(t menu.items.0)" back

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
        ui::banner
        ui::section "$(t menu.control.title)"
        ui::menu_item 1 "$(t menu.control.start)"    ok
        ui::menu_item 2 "$(t menu.control.stop)"     warn
        ui::menu_item 3 "$(t menu.control.restart)"
        ui::menu_item 4 "$(t menu.control.recreate)" accent
        echo
        ui::menu_item 0 "$(t ui.back)" back
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
        ui::banner
        ui::section "$(t menu.logs.title)"
        ui::menu_item 1 "$(t menu.logs.xray_tail)"
        ui::menu_item 2 "$(t menu.logs.xray_follow)" accent
        ui::menu_item 3 "$(t menu.logs.container)"
        ui::menu_item 4 "$(t menu.logs.noder)"
        ui::menu_item 5 "$(t menu.logs.fail2ban)"
        ui::menu_item 6 "$(t menu.logs.tg)"
        echo
        ui::menu_item 0 "$(t ui.back)" back
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
        ui::banner
        ui::section "$(t menu.updates.title)"
        ui::menu_item 1 "$(t menu.updates.check)"    ok
        ui::menu_item 2 "$(t menu.updates.xray)"     accent
        ui::menu_item 3 "$(t menu.updates.image)"    accent
        ui::menu_item 4 "$(t menu.updates.rollback)" warn
        ui::menu_item 5 "$(t menu.updates.schedule)"
        echo
        ui::menu_item 0 "$(t ui.back)" back
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
        ui::banner
        ui::section "$(t menu.regen.title)"
        ui::menu_item 1 "$(t menu.regen.short_id)" ok
        ui::menu_item 2 "$(t menu.regen.dest)"
        ui::menu_item 3 "$(t menu.regen.port)"     warn
        ui::menu_item 4 "$(t menu.regen.full)"     accent
        ui::menu_item 5 "$(t menu.regen.rollback)" warn
        echo
        ui::menu_item 0 "$(t ui.back)" back
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
    ui::banner
    ui::section "$(t menu.items.7)"
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
        ui::banner
        ui::section "$(t menu.geo.title)"
        ui::menu_item 1 "$(t menu.geo.both)"          ok
        ui::menu_item 2 "$(t menu.geo.routing)"
        ui::menu_item 3 "$(t menu.geo.firewall)"
        ui::menu_item 4 "$(t menu.geo.sources_show)"
        ui::menu_item 5 "$(t menu.geo.sources_edit)"  warn
        ui::menu_item 6 "$(t menu.geo.rollback)"      warn
        echo
        ui::menu_item 0 "$(t ui.back)" back
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
        ui::banner
        ui::section "$(t menu.backup.title)"
        ui::menu_item 1 "$(t menu.backup.create)"          ok
        ui::menu_item 2 "$(t menu.backup.restore_last)"    warn
        ui::menu_item 3 "$(t menu.backup.restore_choose)"  warn
        ui::menu_item 4 "$(t menu.backup.download)"
        ui::menu_item 5 "$(t menu.backup.schedule)"        accent
        echo
        ui::menu_item 0 "$(t ui.back)" back
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
        ui::banner
        ui::section "$(t menu.tg.title)"
        ui::menu_item 1 "$(t menu.tg.enable)"        ok
        ui::menu_item 2 "$(t menu.tg.disable)"       warn
        ui::menu_item 3 "$(t menu.tg.change_token)"
        ui::menu_item 4 "$(t menu.tg.change_chat)"
        ui::menu_item 5 "$(t menu.tg.trusted)"       accent
        ui::menu_item 6 "$(t menu.tg.test)"          ok
        ui::menu_item 7 "$(t menu.tg.show)"
        echo
        ui::menu_item 0 "$(t ui.back)" back
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
        ui::banner
        ui::section "$(t menu.ssh.title)"
        ui::menu_item 1 "$(t menu.ssh.f2b)"          ok
        ui::menu_item 2 "$(t menu.ssh.port)"         warn
        ui::menu_item 3 "$(t menu.ssh.no_password)"  danger
        ui::menu_item 4 "$(t menu.ssh.show)"
        echo
        ui::menu_item 0 "$(t ui.back)" back
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
        ui::banner
        ui::section "$(t menu.api.title)"
        ui::menu_item 1 "$(t menu.api.enable)"  warn
        ui::menu_item 2 "$(t menu.api.disable)"
        ui::menu_item 3 "$(t menu.api.change)"
        ui::menu_item 4 "$(t menu.api.test)"    ok
        ui::menu_item 5 "$(t menu.api.auto)"    accent
        ui::menu_item 6 "$(t menu.api.show)"
        ui::menu_item 7 "$(t menu.api.wipe)"    danger
        echo
        ui::menu_item 0 "$(t ui.back)" back
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
        ui::banner
        if menu::__load_or_stub 14_kernel.sh kernel::status; then
            kernel::status
        fi

        ui::section "Ядро · сетевой стек"
        ui::menu_item 1 "$(t menu.kernel.install_xanmod)" accent
        ui::menu_item 2 "$(t menu.kernel.apply_sysctl)"   ok
        ui::menu_item 3 "$(t menu.kernel.status)"
        ui::menu_item 4 "$(t menu.kernel.schedule_boot)"  warn
        ui::menu_item 5 "$(t menu.kernel.revert)"         warn

        ui::section "Firewall · DDoS"
        ui::menu_item 6  "$(t menu.kernel.fw_apply)"      ok
        ui::menu_item 7  "$(t menu.kernel.fw_strict_on)"  warn
        ui::menu_item 8  "$(t menu.kernel.fw_strict_off)"
        ui::menu_item 9  "$(t menu.kernel.fw_status)"
        ui::menu_item 10 "$(t menu.kernel.fw_clear)"      warn
        ui::menu_item 11 "$(t menu.kernel.fw_f2b)"        ok
        echo
        ui::menu_item 0 "$(t ui.back)" back
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
