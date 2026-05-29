#!/usr/bin/env bash
# NODER — Remnawave Node Manager
# by popokole

set -Eeuo pipefail

# Resolve real path (follow symlinks from /usr/local/bin/noder)
__src="${BASH_SOURCE[0]}"
while [ -L "$__src" ]; do
    __dir="$(cd -P "$(dirname "$__src")" && pwd)"
    __src="$(readlink "$__src")"
    [[ "$__src" != /* ]] && __src="$__dir/$__src"
done
__dir="$(cd -P "$(dirname "$__src")" && pwd)"

export NODER_HOME="${NODER_HOME:-$__dir}"
export NODER_VERSION="1.0.0"
export NODER_STATE_DIR="${NODER_STATE_DIR:-/etc/noder}"
export NODER_STATE_FILE="${NODER_STATE_FILE:-$NODER_STATE_DIR/state.json}"
export NODER_LOG_DIR="${NODER_LOG_DIR:-/var/log/noder}"
export NODER_LOG_FILE="${NODER_LOG_FILE:-$NODER_LOG_DIR/noder.log}"
export NODER_BACKUP_DIR="${NODER_BACKUP_DIR:-/var/backups/noder}"
export NODER_LOCALE="${NODER_LOCALE:-ru}"

# Load common module (logging, colors, watermark, helpers)
# shellcheck source=modules/00_common.sh
source "$NODER_HOME/modules/00_common.sh"

# ----------------------------------------------------------------------------
# Dispatch: CLI flags vs interactive menu
# ----------------------------------------------------------------------------

usage() {
    cat <<EOF
$(t cli.usage_title)

  noder                     — $(t cli.usage_menu)
  noder install [flags]     — $(t cli.usage_install)
  noder regen [flags]       — $(t cli.usage_regen)
  noder status              — $(t cli.usage_status)
  noder update [--confirm]  — $(t cli.usage_update)
  noder uninstall [--yes]   — $(t cli.usage_uninstall)
  noder version             — $(t cli.usage_version)
  noder help                — $(t cli.usage_help)

$(t cli.usage_install_flags)
  --random                            $(t cli.flag_random)
  --name <name>                       $(t cli.flag_name)
  --mode <reality|selfsteal>          $(t cli.flag_mode)
  --port <port>                       $(t cli.flag_port)
  --dest <host:port>                  $(t cli.flag_dest)
  --domain <fqdn>                     $(t cli.flag_domain)
  --panel-ip <ip>                     $(t cli.flag_panel_ip)
  --panel-host <host>                 $(t cli.flag_panel_host)
  --node-port <port>                  $(t cli.flag_node_port)
  --secret <key>                      $(t cli.flag_secret)
  --compose <docker-compose snippet>  $(t cli.flag_compose)
  --tg-token <token>                  $(t cli.flag_tg_token)
  --tg-chat <id>                      $(t cli.flag_tg_chat)
  --panel-url <url>                   $(t cli.flag_panel_url)
  --panel-token <token>               $(t cli.flag_panel_token)
  --auto-register                     $(t cli.flag_auto_register)
  --no-tg                             $(t cli.flag_no_tg)
  --yes                               $(t cli.flag_yes)

                                     by popokole
EOF
}

main() {
    common::init

    local cmd="${1:-menu}"
    [ $# -gt 0 ] && shift || true

    case "$cmd" in
        menu|"")
            # shellcheck source=modules/13_menu.sh
            source "$NODER_HOME/modules/13_menu.sh"
            menu::main
            ;;
        install)
            # shellcheck source=modules/install.sh
            source "$NODER_HOME/modules/install.sh"
            install::run "$@"
            ;;
        regen)
            source "$NODER_HOME/modules/06_regen.sh"
            regen::run "$@"
            ;;
        regen-all)
            source "$NODER_HOME/modules/06_regen.sh"
            regen::run_all "$@"
            ;;
        status)
            source "$NODER_HOME/modules/12_health.sh"
            health::report
            ;;
        update)
            source "$NODER_HOME/modules/10_updates.sh"
            updates::run "$@"
            ;;
        blocklists)
            source "$NODER_HOME/modules/11_blocklists.sh"
            case "${1:-update}" in
                update|"")        blocklists::update_all ;;
                routing)          blocklists::update_routing ;;
                firewall)         blocklists::update_firewall ;;
                schedule)         blocklists::install_timer ;;
                rollback)         blocklists::rollback ;;
                show|sources)     blocklists::show_sources ;;
                *) die "$(t cli.unknown_cmd): blocklists $1" ;;
            esac
            ;;
        kernel)
            source "$NODER_HOME/modules/14_kernel.sh"
            case "${1:-status}" in
                install|xanmod)   kernel::install_xanmod ;;
                sysctl)           kernel::apply_sysctl ;;
                status|"")        kernel::status ;;
                revert)           kernel::revert_sysctl ;;
                *) die "$(t cli.unknown_cmd): kernel $1" ;;
            esac
            ;;
        firewall|fw)
            source "$NODER_HOME/modules/08_firewall.sh"
            case "${1:-apply}" in
                apply|"")         firewall::apply ;;
                status)           firewall::status ;;
                strict)           firewall::set_strict_mode "${2:-on}" ;;
                fail2ban|f2b)     firewall::install_fail2ban ;;
                *) die "$(t cli.unknown_cmd): firewall $1" ;;
            esac
            ;;
        health)
            source "$NODER_HOME/modules/12_health.sh"
            health::report
            ;;
        uninstall)
            source "$NODER_HOME/modules/uninstall.sh"
            uninstall::run "$@"
            ;;
        backup)
            source "$NODER_HOME/modules/backup.sh"
            backup::run "$@"
            ;;
        ssh)
            source "$NODER_HOME/modules/ssh_harden.sh"
            ssh::run "$@"
            ;;
        tg|telegram)
            python3 "$NODER_HOME/modules/09_telegram.py" "$@"
            ;;
        api|panel-api)
            python3 "$NODER_HOME/modules/panel_api.py" "$@"
            ;;
        version|--version|-v)
            echo "noder $NODER_VERSION — by popokole"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            log_error "$(t cli.unknown_cmd): $cmd"
            usage
            exit 2
            ;;
    esac
}

main "$@"
