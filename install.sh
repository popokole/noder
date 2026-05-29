#!/usr/bin/env bash
# install.sh — bootstrap для установки noder на чистом Ubuntu
# Использование:
#   bash <(curl -sL https://raw.githubusercontent.com/popokole/noder/main/install.sh)
#   bash <(curl -sL ...) -- install --random --name FI-1 --panel-ip ...
#
# by popokole

set -Eeuo pipefail

readonly REPO="${NODER_REPO:-popokole/noder}"
readonly BRANCH="${NODER_BRANCH:-main}"
readonly DEST="${NODER_HOME:-/opt/noder}"
readonly BIN_LINK=/usr/local/bin/noder
readonly TARBALL_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_reset=$'\033[0m'

log() { printf '%s[noder-install]%s %s\n' "$c_dim" "$c_reset" "$*"; }
err() { printf '%s[noder-install] ERROR%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
ok()  { printf '%s[noder-install] OK%s %s\n' "$c_green" "$c_reset" "$*"; }

trap 'err "Установка прервана на строке $LINENO"' ERR

if [ "$(id -u)" -ne 0 ]; then
    err "Требуются права root. Запустите через sudo."
    exit 1
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
cat <<EOF
${c_bold}
═══════════════════════════════════════════════
   N O D E R   ·   Remnawave Node Manager
                                     by popokole
═══════════════════════════════════════════════
${c_reset}
EOF

# ---------------------------------------------------------------------------
# OS check
# ---------------------------------------------------------------------------
if [ ! -r /etc/os-release ]; then
    err "Не найден /etc/os-release — поддерживается только Ubuntu/Debian."
    exit 1
fi
. /etc/os-release
case "${ID:-}" in
    ubuntu|debian) ;;
    *) err "Поддерживается только Ubuntu/Debian. У вас: ${ID:-unknown}"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Minimal deps to bootstrap (full deps installed by 01_preflight.sh later)
# ---------------------------------------------------------------------------
log "Устанавливаю минимальные зависимости (curl, ca-certificates, tar)…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl tar gnupg

# ---------------------------------------------------------------------------
# Fetch tarball / clone repo
# ---------------------------------------------------------------------------
if [ -d "$DEST" ] && [ -f "$DEST/noder.sh" ]; then
    log "Найдена существующая установка в $DEST — обновляю…"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log "Скачиваю $TARBALL_URL …"
if ! curl -fsSL "$TARBALL_URL" | tar -xz -C "$tmp"; then
    err "Не удалось скачать tarball. Проверьте сеть и доступность $REPO."
    exit 1
fi

src="$(find "$tmp" -maxdepth 2 -type d -name 'noder-*' | head -1)"
if [ -z "$src" ] || [ ! -f "$src/noder.sh" ]; then
    err "Распакованный архив не содержит noder.sh — возможно, репозиторий не публичен."
    exit 1
fi

mkdir -p "$DEST"
# Rsync if available (preserves attrs); else cp -a
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude=state.json --exclude=.env "$src/" "$DEST/"
else
    # Be careful not to wipe runtime data — only sync code/data/locales/modules
    for d in modules locales data scripts; do
        rm -rf "$DEST/$d"
        cp -a "$src/$d" "$DEST/$d" 2>/dev/null || true
    done
    cp -a "$src/noder.sh" "$DEST/noder.sh"
    cp -a "$src/install.sh" "$DEST/install.sh" 2>/dev/null || true
    cp -a "$src/README.md" "$DEST/README.md"  2>/dev/null || true
    cp -a "$src/LICENSE"   "$DEST/LICENSE"    2>/dev/null || true
fi

chmod +x "$DEST/noder.sh"
chmod +x "$DEST/modules/"*.py 2>/dev/null || true

# ---------------------------------------------------------------------------
# Register /usr/local/bin/noder
# ---------------------------------------------------------------------------
ln -sf "$DEST/noder.sh" "$BIN_LINK"
ok "Установлено в $DEST"
ok "Команда: ${c_bold}noder${c_reset}"

# ---------------------------------------------------------------------------
# Forward extra arguments to `noder install` if given:
#   bash <(curl ...) -- install --random --name FI-1 ...
# ---------------------------------------------------------------------------
if [ $# -gt 0 ]; then
    log "Запускаю: noder $*"
    exec "$BIN_LINK" "$@"
fi

cat <<EOF

Готово. Дальше:
  • ${c_bold}noder${c_reset}                          — открыть главное меню
  • ${c_bold}noder install --random${c_reset}         — установка в один заход (с флагами)
  • ${c_bold}noder help${c_reset}                     — все команды

                                     by popokole
EOF
