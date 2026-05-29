#!/usr/bin/env bash
# 00_common.sh — общие функции, логирование, цвета, watermark
# by popokole
#
# Подключается из noder.sh и каждого модуля. Идемпотентна — повторный source безопасен.

# Guard against double-source
[ -n "${__NODER_COMMON_LOADED:-}" ] && return 0
__NODER_COMMON_LOADED=1

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------

readonly NODER_WATERMARK="by popokole"
readonly NODER_HEADER_TITLE="N O D E R  ·  Remnawave Node Manager"

# ----------------------------------------------------------------------------
# TTY / color detection
# ----------------------------------------------------------------------------

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
    readonly C_MAGENTA=$'\033[35m'
    readonly C_CYAN=$'\033[36m'
    readonly C_GRAY=$'\033[90m'
else
    readonly C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN=""
    readonly C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN="" C_GRAY=""
fi

# ----------------------------------------------------------------------------
# Initialization (ensure dirs, log file)
# ----------------------------------------------------------------------------

common::init() {
    # Only mutate filesystem when running as root (interactive previews may not be root).
    if [ "$(id -u)" -eq 0 ]; then
        install -d -m 0750 "$NODER_STATE_DIR" "$NODER_LOG_DIR" "$NODER_BACKUP_DIR" 2>/dev/null || true
        : >> "$NODER_LOG_FILE" 2>/dev/null || true
        chmod 0640 "$NODER_LOG_FILE" 2>/dev/null || true
    fi
}

# ----------------------------------------------------------------------------
# Logging — JSONL to file, colored to stdout when interactive
# ----------------------------------------------------------------------------

__log_json_escape() {
    # Minimal JSON string escaper for the log writer.
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

__log_write() {
    local level="$1" msg="$2" module="${3:-${FUNCNAME[2]:-main}}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ -w "$NODER_LOG_FILE" ] 2>/dev/null || { [ "$(id -u)" -eq 0 ] && [ -d "$NODER_LOG_DIR" ]; }; then
        printf '{"ts":"%s","level":"%s","module":"%s","msg":"%s"}\n' \
            "$ts" "$level" "$(__log_json_escape "$module")" "$(__log_json_escape "$msg")" \
            >> "$NODER_LOG_FILE" 2>/dev/null || true
    fi
}

log_debug() { [ "${NODER_DEBUG:-0}" = "1" ] || return 0; __log_write DEBUG "$*"; echo "${C_GRAY}[debug]${C_RESET} $*" >&2; }
log_info()  { __log_write INFO  "$*"; echo "${C_CYAN}[info]${C_RESET} $*"; }
log_ok()    { __log_write INFO  "$*"; echo "${C_GREEN}[ok]${C_RESET} $*"; }
log_warn()  { __log_write WARN  "$*"; echo "${C_YELLOW}[warn]${C_RESET} $*" >&2; }
log_error() { __log_write ERROR "$*"; echo "${C_RED}[error]${C_RESET} $*" >&2; }
log_crit()  { __log_write CRITICAL "$*"; echo "${C_RED}${C_BOLD}[CRIT]${C_RESET} $*" >&2; }

die() {
    log_error "$*"
    exit 1
}

# ----------------------------------------------------------------------------
# Secret masking — for logs, dumps, UI
# ----------------------------------------------------------------------------

mask_secret() {
    # Show first 4 and last 4 chars only. Short secrets become "***".
    local s="$1"
    local n=${#s}
    if [ "$n" -le 8 ]; then
        printf '***'
    else
        printf '%s***%s' "${s:0:4}" "${s: -4}"
    fi
}

# ----------------------------------------------------------------------------
# i18n — locale file lookup with fallback to key
# ----------------------------------------------------------------------------

__LOCALE_FILE="${NODER_HOME}/locales/${NODER_LOCALE}.json"

t() {
    local key="$1"
    if [ ! -r "$__LOCALE_FILE" ] || ! command -v jq >/dev/null 2>&1; then
        printf '%s' "$key"
        return 0
    fi
    local v
    v="$(jq -r --arg k "$key" '
        def get($k):
            ($k | split(".")) as $p
            | reduce $p[] as $x (.; if type == "object" and has($x) then .[$x] else null end);
        get($k) // empty
    ' "$__LOCALE_FILE" 2>/dev/null)"
    if [ -z "$v" ] || [ "$v" = "null" ]; then
        printf '%s' "$key"
    else
        printf '%s' "$v"
    fi
}

# ----------------------------------------------------------------------------
# UI helpers — header, footer, prompts, pauses
# ----------------------------------------------------------------------------

ui::clear() {
    [ "${NODER_NO_CLEAR:-0}" = "1" ] && return 0
    [ -t 1 ] && command -v clear >/dev/null 2>&1 && clear || true
}

ui::header() {
    local title="${1:-$NODER_HEADER_TITLE}"
    local line="═══════════════════════════════════════════════"
    printf '%s%s%s\n' "$C_BOLD$C_CYAN" "$line" "$C_RESET"
    printf '%s   %s%s\n' "$C_BOLD" "$title" "$C_RESET"
    printf '%s%53s%s\n' "$C_DIM" "$NODER_WATERMARK" "$C_RESET"
    printf '%s%s%s\n\n' "$C_BOLD$C_CYAN" "$line" "$C_RESET"
}

ui::footer() {
    printf '\n%s%53s%s\n' "$C_DIM" "$NODER_WATERMARK" "$C_RESET"
}

ui::pause() {
    printf '\n%s%s%s ' "$C_DIM" "$(t ui.press_enter)" "$C_RESET"
    read -r _ || true
}

ui::prompt() {
    # ui::prompt <var> <text> [default]
    local __var="$1" __text="$2" __default="${3:-}" __input
    if [ -n "$__default" ]; then
        printf '%s%s%s [%s]: ' "$C_BOLD" "$__text" "$C_RESET" "$__default"
    else
        printf '%s%s%s: ' "$C_BOLD" "$__text" "$C_RESET"
    fi
    read -r __input || __input=""
    # Strip CR (Windows-paste \r) and surrounding whitespace.
    __input="${__input//$'\r'/}"
    __input="${__input#"${__input%%[![:space:]]*}"}"
    __input="${__input%"${__input##*[![:space:]]}"}"
    [ -z "$__input" ] && __input="$__default"
    printf -v "$__var" '%s' "$__input"
}

ui::prompt_secret() {
    # ui::prompt_secret <var> <text>
    local __var="$1" __text="$2" __input
    printf '%s%s%s: ' "$C_BOLD" "$__text" "$C_RESET"
    read -rs __input || __input=""
    echo
    __input="${__input//$'\r'/}"
    printf -v "$__var" '%s' "$__input"
}

ui::confirm() {
    # Returns 0 for yes, 1 for no. Default no.
    local prompt="${1:-$(t ui.confirm)}" ans
    printf '%s%s%s [y/N]: ' "$C_BOLD$C_YELLOW" "$prompt" "$C_RESET"
    read -r ans || ans=""
    case "${ans,,}" in y|yes|д|да) return 0 ;; *) return 1 ;; esac
}

# ----------------------------------------------------------------------------
# Privilege / environment checks
# ----------------------------------------------------------------------------

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "$(t common.need_root)"
    fi
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "$(t common.missing_command): $1"
}

# ----------------------------------------------------------------------------
# Error trap — wired by callers that opt in
# ----------------------------------------------------------------------------

common::on_error() {
    local exit_code=$?
    local line="${1:-?}"
    log_error "$(t common.unexpected_error) (line $line, exit $exit_code)"
    if declare -F rollback >/dev/null 2>&1; then
        log_warn "$(t common.running_rollback)"
        rollback || log_error "$(t common.rollback_failed)"
    fi
    exit "$exit_code"
}

common::enable_err_trap() {
    trap 'common::on_error $LINENO' ERR
    trap 'log_warn "$(t common.interrupted)"; common::on_error $LINENO' INT TERM
}

# ----------------------------------------------------------------------------
# Backup of a single file before mutation
# ----------------------------------------------------------------------------

backup_file() {
    local path="$1"
    [ -f "$path" ] || return 0
    local stamp
    stamp="$(date +%Y-%m-%d_%H-%M-%S)"
    local dst="$NODER_BACKUP_DIR/files/$stamp"
    install -d -m 0700 "$dst"
    cp -a "$path" "$dst/" || true
    log_debug "backup: $path -> $dst/"
}

# ----------------------------------------------------------------------------
# State helpers (thin wrappers around 03_state.py)
# ----------------------------------------------------------------------------

state::get() {
    # state::get <jsonpath>  (e.g. state::get node_name)
    [ -r "$NODER_STATE_FILE" ] || { echo ""; return 0; }
    python3 "$NODER_HOME/modules/03_state.py" get "$1" 2>/dev/null || echo ""
}

state::set() {
    # state::set <jsonpath> <value>
    python3 "$NODER_HOME/modules/03_state.py" set "$1" "$2"
}

state::exists() {
    [ -r "$NODER_STATE_FILE" ]
}
