#!/usr/bin/env bash
#
# NexGuard Connect — Linux install / update / uninstall
# ─────────────────────────────────────────────────────────────
#
# One-liner install (latest):
#   curl -fsSL https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install-linux.sh | sudo bash
#
# Pin a specific version:
#   curl -fsSL https://... | sudo INSTALL_VERSION=0.2.1 bash
#
# Uninstall:
#   curl -fsSL https://... | sudo bash -s -- --uninstall
#
# Local (after download):
#   sudo bash install-linux.sh [--uninstall] [--force] [--help]
#
# What it does:
#   1. Preflight (Ubuntu 20.04+, x86_64, dpkg, curl, sha256sum)
#   2. Fetch release manifest (versions.json)
#   3. Download nexguard-connect_<ver>_amd64.deb from S3
#   4. Verify SHA-256 against manifest
#   5. dpkg -i (auto-installs systemd unit, adds user to nexguard group)
#   6. Verify daemon nexguard-tunneld is running
#   7. Cleanup temp files
#
# Requires: Ubuntu 20.04+, curl, sha256sum, dpkg, systemd, root.

set -euo pipefail

# ── Config ───────────────────────────────────────────────────
readonly MANIFEST_URL="https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/versions.json"
readonly PRODUCT_ID="nexguard-connect-linux-cli"
readonly PKG_NAME="nexguard-connect"
readonly SERVICE="nexguard-tunneld"

# ── Colors ───────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; RED=""; YELLOW=""; BLUE=""; CYAN=""
fi

# ── Logging ─────────────────────────────────────────────────
step()    { echo "${BLUE}▶${RESET} ${BOLD}$*${RESET}"; }
info()    { echo "  ${DIM}$*${RESET}"; }
success() { echo "${GREEN}✓${RESET} $*"; }
warn()    { echo "${YELLOW}⚠${RESET} $*"; }
error()   { echo "${RED}✗${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Cleanup on exit ─────────────────────────────────────────
TMP_DIR=""
cleanup() {
    local rc=$?
    [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    return $rc
}
trap cleanup EXIT INT TERM

# ── Help ────────────────────────────────────────────────────
print_help() {
    cat <<HELP
${BOLD}NexGuard Connect — Linux installer${RESET}

${BOLD}Usage:${RESET}
    curl -fsSL <URL> | sudo bash
    sudo bash install-linux.sh [options]

${BOLD}Options:${RESET}
    ${CYAN}--uninstall${RESET}     Purge NexGuard Connect (apt remove --purge)
    ${CYAN}--force${RESET}         Force reinstall even if version matches
    ${CYAN}--version${RESET}       Print installed version + exit
    ${CYAN}--help${RESET}          Print this help + exit

${BOLD}Environment:${RESET}
    ${CYAN}INSTALL_VERSION${RESET}    Pin specific version (default: latest)
    ${CYAN}NO_COLOR${RESET}           Disable ANSI colors

${BOLD}Examples:${RESET}
    # Latest
    curl -fsSL https://... | sudo bash

    # Specific version
    curl -fsSL https://... | sudo INSTALL_VERSION=0.2.1 bash

    # Uninstall
    curl -fsSL https://... | sudo bash -s -- --uninstall

${BOLD}Post-install:${RESET}
    Add your user to the ${CYAN}nexguard${RESET} group nếu chưa được auto-add:
        sudo usermod -aG nexguard \$USER
        newgrp nexguard    # hoặc log out + log in lại
    Then:
        nexguard             # launch TUI dashboard
HELP
}

# ── Root check ──────────────────────────────────────────────
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Cần chạy với sudo: ${CYAN}curl -fsSL <URL> | sudo bash${RESET}"
    fi
}

# ── Uninstall ────────────────────────────────────────────────
do_uninstall() {
    require_root
    step "Uninstalling NexGuard Connect"

    # Stop tunnel + service
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        info "Stopping $SERVICE"
        systemctl stop "$SERVICE" || true
    fi

    # apt purge (removes package + config)
    if dpkg -l | grep -q "^ii  $PKG_NAME "; then
        info "Purging $PKG_NAME"
        apt-get purge -y "$PKG_NAME"
    else
        info "$PKG_NAME chưa install — bỏ qua purge"
    fi

    # Cleanup runtime state
    if [ -d "/run/nexguard" ]; then
        info "Removing /run/nexguard state"
        rm -rf /run/nexguard
    fi

    # Ask about config + tokens
    if [ -d "/etc/nexguard" ] || [ -d "$HOME/.config/nexguard-connect" ]; then
        echo ""
        read -p "$(echo "${YELLOW}?${RESET} Xoá luôn config + saved orgs + tokens? (y/N) ")" -n 1 -r ans
        echo ""
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            rm -rf /etc/nexguard
            rm -rf "$HOME/.config/nexguard-connect"
            success "Config removed"
        else
            info "Config kept (re-install sẽ dùng lại)"
        fi
    fi

    echo ""
    success "${BOLD}Uninstalled.${RESET}"
}

# ── Parse args ───────────────────────────────────────────────
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) do_uninstall; exit 0 ;;
        --force) FORCE=1 ;;
        --version)
            dpkg -s "$PKG_NAME" 2>/dev/null | grep '^Version:' | awk '{print $2}' || echo "not installed"
            exit 0 ;;
        --help|-h) print_help; exit 0 ;;
        *) die "Unknown argument: $1. Try --help." ;;
    esac
    shift
done

# ── Preflight ────────────────────────────────────────────────
echo ""
echo "${BOLD}${CYAN}NexGuard Connect${RESET} · Linux installer"
echo "${DIM}────────────────────────────────────────────${RESET}"
echo ""

require_root

# OS check
if [ ! -f /etc/os-release ]; then
    die "Cannot detect distro (missing /etc/os-release)"
fi
. /etc/os-release

if [ "${ID:-}" != "ubuntu" ] && [ "${ID_LIKE:-}" != "debian" ]; then
    warn "Distro detected: ${ID:-unknown} (${PRETTY_NAME:-?})"
    warn "Script mặc định build cho Ubuntu 20.04+. Non-Debian derivatives có thể fail."
fi
info "System: ${PRETTY_NAME:-unknown} · $(uname -m)"

# Arch check
if [ "$(uname -m)" != "x86_64" ]; then
    die "Only x86_64 supported (arm64 build chưa có)."
fi

# Tools check
for tool in curl sha256sum dpkg systemctl; do
    command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
done

# ── Fetch manifest ──────────────────────────────────────────
step "Fetch release manifest"
MANIFEST=$(curl -fsSL "$MANIFEST_URL") || die "Không tải được manifest từ $MANIFEST_URL"

# Parse (uses python3 for robust JSON)
if ! command -v python3 >/dev/null 2>&1; then
    die "python3 required to parse JSON manifest. apt install python3"
fi

LATEST=$(echo "$MANIFEST" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['products']['$PRODUCT_ID']['latest'])")
LATEST_SHA=$(echo "$MANIFEST" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['products']['$PRODUCT_ID']['sha256'])")
LATEST_URL=$(echo "$MANIFEST" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['products']['$PRODUCT_ID']['download_url'])")
MINIMUM=$(echo "$MANIFEST" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['products']['$PRODUCT_ID'].get('minimum','0.0.0'))")

VERSION="${INSTALL_VERSION:-$LATEST}"

if [ "$VERSION" = "$LATEST" ]; then
    DOWNLOAD_URL="$LATEST_URL"
    EXPECTED_SHA="$LATEST_SHA"
    info "Target: ${BOLD}$VERSION${RESET} (latest)"
else
    BASE_URL="${LATEST_URL%/*}"
    DOWNLOAD_URL="$BASE_URL/${PKG_NAME}_${VERSION}_amd64.deb"
    EXPECTED_SHA=""
    warn "Target: $VERSION (pinned) — SHA-256 verify sẽ skip (manifest chỉ có SHA cho $LATEST)"
fi
info "URL:    $DOWNLOAD_URL"
info "Minimum supported: $MINIMUM"

# ── Check existing install ──────────────────────────────────
CURRENT=""
if dpkg -s "$PKG_NAME" >/dev/null 2>&1; then
    CURRENT=$(dpkg -s "$PKG_NAME" | grep '^Version:' | awk '{print $2}' | cut -d- -f1)
    if [ "$CURRENT" = "$VERSION" ] && [ "$FORCE" -eq 0 ]; then
        success "Version $VERSION đã cài — nothing to do (use --force để reinstall)"
        exit 0
    fi
    info "Current: $CURRENT · Target: $VERSION"
fi

# ── Download ────────────────────────────────────────────────
step "Download .deb"
TMP_DIR=$(mktemp -d -t nexguard-install.XXXXXX)
DEB="$TMP_DIR/nexguard-connect.deb"

curl -# -fL -o "$DEB" "$DOWNLOAD_URL" || die "Download failed từ $DOWNLOAD_URL"

DEB_SIZE=$(du -h "$DEB" | cut -f1)
info "Downloaded: $DEB_SIZE"

# ── SHA-256 verify ─────────────────────────────────────────
if [ -n "$EXPECTED_SHA" ]; then
    step "Verify SHA-256"
    ACTUAL=$(sha256sum "$DEB" | awk '{print $1}')
    if [ "$ACTUAL" != "$EXPECTED_SHA" ]; then
        error "SHA-256 mismatch!"
        error "  Expected: $EXPECTED_SHA"
        error "  Got:      $ACTUAL"
        die "File corruption hoặc man-in-the-middle. Aborting."
    fi
    success "SHA-256 verified"
fi

# ── Install ─────────────────────────────────────────────────
step "Install package"
if dpkg -i "$DEB" 2>&1 | tee "$TMP_DIR/dpkg.log"; then
    info "dpkg -i OK"
else
    # Try to fix missing deps
    warn "dpkg -i had issues — trying apt-get install -f"
    apt-get install -f -y
fi

# ── Verify daemon ───────────────────────────────────────────
step "Verify daemon"
sleep 1
if systemctl is-active --quiet "$SERVICE"; then
    success "$SERVICE is active"
else
    warn "$SERVICE chưa chạy — thử start manual"
    systemctl start "$SERVICE" || die "Failed to start $SERVICE. Check: journalctl -u $SERVICE"
    sleep 1
    systemctl is-active --quiet "$SERVICE" || die "$SERVICE vẫn không start được"
    success "$SERVICE started"
fi

# ── Post-install hint ──────────────────────────────────────
echo ""
echo "${GREEN}${BOLD}✅ NexGuard Connect $VERSION installed${RESET}"
echo "${DIM}────────────────────────────────────────────${RESET}"
echo ""

# Check user in nexguard group
INSTALL_USER="${SUDO_USER:-$(whoami)}"
if id -nG "$INSTALL_USER" 2>/dev/null | grep -qw nexguard; then
    info "User ${BOLD}$INSTALL_USER${RESET} đã trong group ${CYAN}nexguard${RESET}"
    echo ""
    echo "  ${BOLD}Launch TUI:${RESET}"
    echo "    ${CYAN}nexguard${RESET}"
else
    warn "User ${BOLD}$INSTALL_USER${RESET} chưa trong group ${CYAN}nexguard${RESET}"
    echo ""
    echo "  Chạy 2 lệnh sau để add + activate:"
    echo "    ${CYAN}sudo usermod -aG nexguard $INSTALL_USER${RESET}"
    echo "    ${CYAN}newgrp nexguard${RESET}    # hoặc log out + log in lại"
    echo ""
    echo "  Sau đó:"
    echo "    ${CYAN}nexguard${RESET}    # launch TUI"
fi
echo ""
