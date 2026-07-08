#!/usr/bin/env bash
#
# NexGuard Connect — universal installer (macOS + Linux)
# ─────────────────────────────────────────────────────────────
#
# One-liner install (latest, auto-detects OS):
#   curl -fsSL https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.sh | bash
#
# Linux needs root — pipe to sudo bash:
#   curl -fsSL https://... | sudo bash
#
# Pin a specific version:
#   curl -fsSL https://... | INSTALL_VERSION=0.3.1 bash
#
# Uninstall:
#   curl -fsSL https://... | bash -s -- --uninstall            # macOS
#   curl -fsSL https://... | sudo bash -s -- --uninstall       # Linux
#
# Local:
#   bash install.sh [--uninstall] [--force] [--version] [--help]
#
# Flow:
#   1. Detect OS + arch (Darwin/x86_64+arm64, Linux/x86_64)
#   2. Fetch release manifest (versions.json)
#   3. Download artifact (DMG on macOS, .deb on Linux)
#   4. Verify SHA-256 against manifest
#   5. Install:
#        macOS: mount DMG → copy to /Applications → strip Gatekeeper quarantine
#        Linux: dpkg -i (+ apt install -f) → verify nexguard-tunneld
#   6. Cleanup temp files (trap on any exit)

set -euo pipefail

# ── Config ───────────────────────────────────────────────────
readonly MANIFEST_URL="https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/versions.json"

# ── Colors (TTY-aware, honors NO_COLOR) ─────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; RED=""; YELLOW=""; BLUE=""; CYAN=""
fi

step()    { echo "${BLUE}▶${RESET} ${BOLD}$*${RESET}"; }
info()    { echo "  ${DIM}$*${RESET}"; }
success() { echo "${GREEN}✓${RESET} $*"; }
warn()    { echo "${YELLOW}⚠${RESET} $*"; }
error()   { echo "${RED}✗${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Cleanup on exit ─────────────────────────────────────────
TMP_DIR=""
MOUNT_POINT=""
cleanup() {
    local rc=$?
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    fi
    [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    return $rc
}
trap cleanup EXIT INT TERM

# ── OS detection ────────────────────────────────────────────
detect_os() {
    local kernel; kernel="$(uname -s)"
    case "$kernel" in
        Darwin) OS=macos ;;
        Linux)  OS=linux ;;
        *)      die "Unsupported OS: $kernel. Only macOS + Linux supported." ;;
    esac
    ARCH="$(uname -m)"
}

# ── Help ────────────────────────────────────────────────────
print_help() {
    cat <<HELP
${BOLD}NexGuard Connect — universal installer${RESET}

${BOLD}Usage:${RESET}
    curl -fsSL <URL> | bash              ${DIM}# macOS${RESET}
    curl -fsSL <URL> | sudo bash         ${DIM}# Linux (needs root)${RESET}
    bash install.sh [options]

${BOLD}Options:${RESET}
    ${CYAN}--uninstall${RESET}      Remove NexGuard Connect from this machine
    ${CYAN}--force${RESET}          Force reinstall even if version already matches
    ${CYAN}--version${RESET}        Print installed version + exit
    ${CYAN}--help${RESET}           Print this help + exit

${BOLD}Environment:${RESET}
    ${CYAN}INSTALL_VERSION${RESET}     Pin specific version (default: latest from manifest)
    ${CYAN}INSTALL_PREFIX${RESET}      Install dir (macOS only, default: /Applications)
    ${CYAN}NO_COLOR${RESET}            Disable ANSI colors

${BOLD}Examples:${RESET}
    # Install latest
    curl -fsSL <URL> | bash

    # Specific version
    curl -fsSL <URL> | INSTALL_VERSION=0.3.1 bash

    # Uninstall (macOS)
    curl -fsSL <URL> | bash -s -- --uninstall

    # Uninstall (Linux)
    curl -fsSL <URL> | sudo bash -s -- --uninstall

${BOLD}Supported platforms:${RESET}
    macOS      — Apple Silicon (arm64) + Intel (x86_64), macOS 13+
    Linux      — Ubuntu 20.04+ / Debian, x86_64
HELP
}

# ══════════════════════════════════════════════════════════════
#  macOS branch
# ══════════════════════════════════════════════════════════════
readonly MACOS_PRODUCT_ID="nexguard-connect-macos"
readonly MACOS_APP_NAME="NexGuardConnect.app"

macos_uninstall() {
    local prefix="${INSTALL_PREFIX:-/Applications}"
    step "Uninstalling NexGuard Connect (macOS)"

    osascript -e 'tell application "NexGuardConnect" to quit' 2>/dev/null || true
    sleep 1

    if [ -d "$prefix/$MACOS_APP_NAME" ]; then
        info "Removing $prefix/$MACOS_APP_NAME"
        rm -rf "$prefix/$MACOS_APP_NAME"
    fi

    if [ -f /usr/local/libexec/nexguard-wg-helper ]; then
        info "Removing helper"
        sudo rm -f /usr/local/libexec/nexguard-wg-helper
    fi

    if [ -f /etc/sudoers.d/nexguard-connect ]; then
        info "Removing sudoers rule"
        sudo rm -f /etc/sudoers.d/nexguard-connect
    fi

    if [ -d /var/run/wireguard ]; then
        info "Cleaning tunnel state"
        sudo rm -rf /var/run/wireguard/*.conf 2>/dev/null || true
    fi

    if [ -d "$HOME/Library/Preferences" ]; then
        echo ""
        read -p "$(echo "${YELLOW}?${RESET} Xoá luôn user preferences (saved orgs + tokens)? (y/N) ")" -n 1 -r ans
        echo ""
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            rm -f "$HOME/Library/Preferences/com.nexguard.connect.plist"
            rm -rf "$HOME/Library/Application Support/NexGuardConnect"
            success "Preferences removed"
        else
            info "Preferences kept (re-install sẽ dùng lại)"
        fi
    fi
    echo ""
    success "${BOLD}Uninstalled.${RESET}"
}

macos_install() {
    # Preflight
    if ! command -v hdiutil >/dev/null 2>&1; then
        die "hdiutil not found — not a real macOS system?"
    fi
    for tool in curl shasum; do
        command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
    done

    local prefix="${INSTALL_PREFIX:-/Applications}"
    [ -w "$prefix" ] || die "$prefix không writeable. Chạy với sudo hoặc INSTALL_PREFIX=~/Applications."

    # Fetch manifest
    step "Fetch release manifest"
    local manifest; manifest=$(curl -fsSL "$MANIFEST_URL") || die "Không tải được manifest"

    command -v python3 >/dev/null 2>&1 || die "python3 required to parse manifest"

    local latest latest_sha latest_url minimum
    latest=$(echo "$manifest" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['products']['$MACOS_PRODUCT_ID']['latest'])")
    latest_sha=$(echo "$manifest" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['products']['$MACOS_PRODUCT_ID']['sha256'])")
    latest_url=$(echo "$manifest" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['products']['$MACOS_PRODUCT_ID']['download_url'])")
    minimum=$(echo "$manifest" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['products']['$MACOS_PRODUCT_ID'].get('minimum','0.0.0'))")

    local version="${INSTALL_VERSION:-$latest}"
    local download_url expected_sha
    if [ "$version" = "$latest" ]; then
        download_url="$latest_url"
        expected_sha="$latest_sha"
        info "Target: ${BOLD}$version${RESET} (latest)"
    else
        download_url="${latest_url%/*}/NexGuard-Connect-${version}.dmg"
        expected_sha=""
        warn "Target: $version (pinned) — SHA-256 verify sẽ skip"
    fi
    info "URL:    $download_url"
    info "Minimum supported: $minimum"

    # Check existing install
    local installed_ver=""
    if [ -d "$prefix/$MACOS_APP_NAME" ]; then
        installed_ver=$(defaults read "$prefix/$MACOS_APP_NAME/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
        if [ "$installed_ver" = "$version" ] && [ "$FORCE" -eq 0 ]; then
            success "Version $version đã cài — nothing to do (use --force để reinstall)"
            return 0
        fi
        info "Current: $installed_ver · Target: $version"
    fi

    # Download DMG
    step "Download .dmg"
    TMP_DIR=$(mktemp -d -t nexguard-install)
    local dmg="$TMP_DIR/NexGuardConnect.dmg"
    curl -# -fL -o "$dmg" "$download_url" || die "Download failed"
    info "Downloaded: $(du -h "$dmg" | cut -f1)"

    # SHA-256 verify
    if [ -n "$expected_sha" ]; then
        step "Verify SHA-256"
        local actual; actual=$(shasum -a 256 "$dmg" | awk '{print $1}')
        if [ "$actual" != "$expected_sha" ]; then
            error "SHA-256 mismatch!"
            error "  Expected: $expected_sha"
            error "  Got:      $actual"
            die "File corruption hoặc MITM. Aborting."
        fi
        success "SHA-256 verified"
    fi

    # Mount DMG
    step "Mount DMG"
    MOUNT_POINT=$(mktemp -d -t nexguard-mount)
    hdiutil attach "$dmg" -mountpoint "$MOUNT_POINT" -nobrowse -quiet
    info "Mounted at $MOUNT_POINT"

    local app_src="$MOUNT_POINT/$MACOS_APP_NAME"
    [ -d "$app_src" ] || die "$MACOS_APP_NAME not found in DMG"

    # Install
    step "Install to $prefix"
    if [ -d "$prefix/$MACOS_APP_NAME" ]; then
        info "Removing existing install"
        rm -rf "$prefix/$MACOS_APP_NAME"
    fi
    cp -R "$app_src" "$prefix/"
    success "Copied to $prefix/$MACOS_APP_NAME"

    # Unmount
    hdiutil detach "$MOUNT_POINT" -quiet
    MOUNT_POINT=""

    # Strip Gatekeeper quarantine (the whole point of this script)
    step "Strip Gatekeeper quarantine"
    xattr -dr com.apple.quarantine "$prefix/$MACOS_APP_NAME" 2>/dev/null || true
    success "Quarantine attribute removed"

    # Post-install
    echo ""
    echo "${GREEN}${BOLD}✅ NexGuard Connect $version installed${RESET}"
    echo "${DIM}────────────────────────────────────────────${RESET}"
    echo ""
    echo "  ${BOLD}Launch:${RESET}"
    echo "    open '$prefix/$MACOS_APP_NAME'"
    echo "    ${DIM}(or from Launchpad / Spotlight)${RESET}"
    echo ""
}

# ══════════════════════════════════════════════════════════════
#  Linux branch
# ══════════════════════════════════════════════════════════════
readonly LINUX_PRODUCT_ID="nexguard-connect-linux-cli"
readonly LINUX_PKG_NAME="nexguard-connect"
readonly LINUX_SERVICE="nexguard-tunneld"

linux_require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Cần chạy với sudo: ${CYAN}curl -fsSL <URL> | sudo bash${RESET}"
    fi
}

linux_uninstall() {
    linux_require_root
    step "Uninstalling NexGuard Connect (Linux)"

    if systemctl is-active --quiet "$LINUX_SERVICE" 2>/dev/null; then
        info "Stopping $LINUX_SERVICE"
        systemctl stop "$LINUX_SERVICE" || true
    fi

    if dpkg -l | grep -q "^ii  $LINUX_PKG_NAME "; then
        info "Purging $LINUX_PKG_NAME"
        apt-get purge -y "$LINUX_PKG_NAME"
    else
        info "$LINUX_PKG_NAME chưa install — bỏ qua purge"
    fi

    if [ -d /run/nexguard ]; then
        info "Removing /run/nexguard state"
        rm -rf /run/nexguard
    fi

    if [ -d /etc/nexguard ] || [ -d "$HOME/.config/nexguard-connect" ]; then
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

linux_install() {
    linux_require_root

    # OS check
    [ -f /etc/os-release ] || die "Cannot detect distro (missing /etc/os-release)"
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ] && [ "${ID_LIKE:-}" != "debian" ]; then
        warn "Distro: ${ID:-unknown} (${PRETTY_NAME:-?})"
        warn "Non-Debian derivatives có thể fail — proceed at your own risk."
    fi
    info "System: ${PRETTY_NAME:-unknown} · $ARCH"

    [ "$ARCH" = "x86_64" ] || die "Only x86_64 supported on Linux (arm64 build chưa có)."

    for tool in curl sha256sum dpkg systemctl; do
        command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
    done

    # Fetch manifest
    step "Fetch release manifest"
    local manifest; manifest=$(curl -fsSL "$MANIFEST_URL") || die "Không tải được manifest"

    command -v python3 >/dev/null 2>&1 || die "python3 required to parse manifest. apt install python3"

    local latest latest_sha latest_url minimum
    latest=$(echo "$manifest" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['products']['$LINUX_PRODUCT_ID']['latest'])")
    latest_sha=$(echo "$manifest" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['products']['$LINUX_PRODUCT_ID']['sha256'])")
    latest_url=$(echo "$manifest" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['products']['$LINUX_PRODUCT_ID']['download_url'])")
    minimum=$(echo "$manifest" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['products']['$LINUX_PRODUCT_ID'].get('minimum','0.0.0'))")

    local version="${INSTALL_VERSION:-$latest}"
    local download_url expected_sha
    if [ "$version" = "$latest" ]; then
        download_url="$latest_url"
        expected_sha="$latest_sha"
        info "Target: ${BOLD}$version${RESET} (latest)"
    else
        download_url="${latest_url%/*}/${LINUX_PKG_NAME}_${version}_amd64.deb"
        expected_sha=""
        warn "Target: $version (pinned) — SHA-256 verify sẽ skip"
    fi
    info "URL:    $download_url"
    info "Minimum supported: $minimum"

    # Check existing install
    local current=""
    if dpkg -s "$LINUX_PKG_NAME" >/dev/null 2>&1; then
        current=$(dpkg -s "$LINUX_PKG_NAME" | grep '^Version:' | awk '{print $2}' | cut -d- -f1)
        if [ "$current" = "$version" ] && [ "$FORCE" -eq 0 ]; then
            success "Version $version đã cài — nothing to do (use --force để reinstall)"
            return 0
        fi
        info "Current: $current · Target: $version"
    fi

    # Download
    step "Download .deb"
    TMP_DIR=$(mktemp -d -t nexguard-install.XXXXXX)
    local deb="$TMP_DIR/nexguard-connect.deb"
    curl -# -fL -o "$deb" "$download_url" || die "Download failed"
    info "Downloaded: $(du -h "$deb" | cut -f1)"

    # SHA-256 verify
    if [ -n "$expected_sha" ]; then
        step "Verify SHA-256"
        local actual; actual=$(sha256sum "$deb" | awk '{print $1}')
        if [ "$actual" != "$expected_sha" ]; then
            error "SHA-256 mismatch!"
            error "  Expected: $expected_sha"
            error "  Got:      $actual"
            die "File corruption hoặc MITM. Aborting."
        fi
        success "SHA-256 verified"
    fi

    # Install
    step "Install package"
    if dpkg -i "$deb"; then
        info "dpkg -i OK"
    else
        warn "dpkg -i had issues — trying apt-get install -f"
        apt-get install -f -y
    fi

    # Verify daemon
    step "Verify daemon"
    sleep 1
    if ! systemctl is-active --quiet "$LINUX_SERVICE"; then
        warn "$LINUX_SERVICE chưa chạy — thử start manual"
        systemctl start "$LINUX_SERVICE" || die "Failed to start $LINUX_SERVICE. Check: journalctl -u $LINUX_SERVICE"
        sleep 1
        systemctl is-active --quiet "$LINUX_SERVICE" || die "$LINUX_SERVICE vẫn không start được"
    fi
    success "$LINUX_SERVICE is active"

    # Post-install
    echo ""
    echo "${GREEN}${BOLD}✅ NexGuard Connect $version installed${RESET}"
    echo "${DIM}────────────────────────────────────────────${RESET}"
    echo ""

    local install_user="${SUDO_USER:-$(whoami)}"
    if id -nG "$install_user" 2>/dev/null | grep -qw nexguard; then
        info "User ${BOLD}$install_user${RESET} đã trong group ${CYAN}nexguard${RESET}"
        echo ""
        echo "  ${BOLD}Launch TUI:${RESET}"
        echo "    ${CYAN}nexguard${RESET}"
    else
        warn "User ${BOLD}$install_user${RESET} chưa trong group ${CYAN}nexguard${RESET}"
        echo ""
        echo "  Chạy 2 lệnh sau:"
        echo "    ${CYAN}sudo usermod -aG nexguard $install_user${RESET}"
        echo "    ${CYAN}newgrp nexguard${RESET}    ${DIM}# hoặc log out + log in lại${RESET}"
        echo ""
        echo "  Sau đó:"
        echo "    ${CYAN}nexguard${RESET}"
    fi
    echo ""
}

# ══════════════════════════════════════════════════════════════
#  Main dispatcher
# ══════════════════════════════════════════════════════════════

# Print version + exit
print_installed_version() {
    detect_os
    case "$OS" in
        macos)
            local app="${INSTALL_PREFIX:-/Applications}/$MACOS_APP_NAME"
            if [ -d "$app" ]; then
                defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown"
            else
                echo "not installed"
            fi ;;
        linux)
            dpkg -s "$LINUX_PKG_NAME" 2>/dev/null | grep '^Version:' | awk '{print $2}' || echo "not installed" ;;
    esac
}

# Parse args
ACTION=install
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) ACTION=uninstall ;;
        --force)     FORCE=1 ;;
        --version)   print_installed_version; exit 0 ;;
        --help|-h)   print_help; exit 0 ;;
        *)           die "Unknown argument: $1. Try --help." ;;
    esac
    shift
done

# Banner
echo ""
echo "${BOLD}${CYAN}NexGuard Connect${RESET} · universal installer"
echo "${DIM}────────────────────────────────────────────${RESET}"

detect_os
info "Detected OS: ${BOLD}$OS${RESET} · arch ${BOLD}$ARCH${RESET}"
echo ""

case "$OS" in
    macos)
        case "$ACTION" in
            install)   macos_install ;;
            uninstall) macos_uninstall ;;
        esac ;;
    linux)
        case "$ACTION" in
            install)   linux_install ;;
            uninstall) linux_uninstall ;;
        esac ;;
esac
