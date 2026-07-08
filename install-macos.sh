#!/usr/bin/env bash
#
# NexGuard Connect — macOS install / update / uninstall
# ─────────────────────────────────────────────────────────────
#
# One-liner install (latest):
#   curl -fsSL https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install-macos.sh | bash
#
# Pin a specific version:
#   curl -fsSL https://... | INSTALL_VERSION=0.3.1 bash
#
# Uninstall:
#   curl -fsSL https://... | bash -s -- --uninstall
#
# Local (after download):
#   bash install-macos.sh [--uninstall] [--force] [--help]
#
# What it does:
#   1. Fetch release manifest (versions.json)
#   2. Download NexGuard-Connect-<ver>.dmg from S3 (with progress)
#   3. Verify SHA-256 against manifest
#   4. Mount DMG, copy NexGuardConnect.app → /Applications
#   5. Unmount DMG
#   6. xattr -dr com.apple.quarantine  →  bypass Gatekeeper warning
#   7. Cleanup temp files
#
# Requires: macOS 12+, curl, hdiutil, shasum, python3 (all built-in).

set -euo pipefail

# ── Config ───────────────────────────────────────────────────
readonly MANIFEST_URL="https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/versions.json"
readonly PRODUCT_ID="nexguard-connect-macos"
readonly APP_NAME="NexGuardConnect.app"
readonly INSTALL_PREFIX="${INSTALL_PREFIX:-/Applications}"

# ── Colors (TTY-aware, honors NO_COLOR) ──────────────────────
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
MOUNTED=""
cleanup() {
    local rc=$?
    if [ -n "$MOUNTED" ] && [ -d "$MOUNTED" ]; then
        hdiutil detach "$MOUNTED" -force >/dev/null 2>&1 || true
    fi
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    return $rc
}
trap cleanup EXIT INT TERM

# ── Help ────────────────────────────────────────────────────
print_help() {
    cat <<HELP
${BOLD}NexGuard Connect — macOS installer${RESET}

${BOLD}Usage:${RESET}
    curl -fsSL <URL> | bash
    bash install-macos.sh [options]

${BOLD}Options:${RESET}
    ${CYAN}--uninstall${RESET}     Remove installed app + helper + sudoers rule
    ${CYAN}--force${RESET}         Force reinstall even if version matches
    ${CYAN}--version${RESET}       Print installed version + exit
    ${CYAN}--help${RESET}          Print this help + exit

${BOLD}Environment:${RESET}
    ${CYAN}INSTALL_VERSION${RESET}    Pin specific version (default: latest from manifest)
    ${CYAN}INSTALL_PREFIX${RESET}     Install directory (default: /Applications)
    ${CYAN}NO_COLOR${RESET}           Disable ANSI colors

${BOLD}Examples:${RESET}
    # Install latest
    curl -fsSL https://... | bash

    # Install specific version
    curl -fsSL https://... | INSTALL_VERSION=0.3.1 bash

    # Uninstall
    curl -fsSL https://... | bash -s -- --uninstall

    # Force reinstall + skip version check
    bash install-macos.sh --force
HELP
}

# ── Uninstall ────────────────────────────────────────────────
do_uninstall() {
    step "Uninstalling NexGuard Connect"

    # Stop running app
    osascript -e 'tell application "NexGuardConnect" to quit' 2>/dev/null || true
    sleep 1

    # Force-kill leftover helper processes
    pkill -f "NexGuardConnect" 2>/dev/null || true

    # Remove app
    if [ -d "$INSTALL_PREFIX/$APP_NAME" ]; then
        info "Removing $INSTALL_PREFIX/$APP_NAME"
        rm -rf "$INSTALL_PREFIX/$APP_NAME" 2>/dev/null || sudo rm -rf "$INSTALL_PREFIX/$APP_NAME"
    fi

    # Remove privileged helper + sudoers (needs sudo)
    if [ -f "/usr/local/libexec/nexguard-wg-helper" ] || [ -f "/etc/sudoers.d/nexguard-connect" ]; then
        info "Removing privileged helper + sudoers rule (needs sudo)"
        sudo rm -f /usr/local/libexec/nexguard-wg-helper /etc/sudoers.d/nexguard-connect
    fi

    # Cleanup any stale tunnel state
    if [ -d "/var/run/wireguard" ]; then
        info "Cleaning stale tunnel state"
        sudo rm -rf /var/run/wireguard 2>/dev/null || true
    fi

    # Ask about user data
    if [ -f "$HOME/Library/Preferences/vn.binhphuong.nexguard.connect.plist" ] || \
       [ -d "$HOME/Library/Application Support/NexGuardConnect" ]; then
        echo ""
        read -p "$(echo "${YELLOW}?${RESET} Xoá luôn preferences + saved orgs + tokens? (y/N) ")" -n 1 -r ans
        echo ""
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            rm -f "$HOME/Library/Preferences/vn.binhphuong.nexguard.connect.plist"
            rm -rf "$HOME/Library/Application Support/NexGuardConnect"
            defaults delete vn.binhphuong.nexguard.connect 2>/dev/null || true
            success "User data removed"
        else
            info "User data kept (re-install sẽ dùng lại)"
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
            if [ -d "$INSTALL_PREFIX/$APP_NAME" ]; then
                plutil -extract CFBundleShortVersionString raw \
                    "$INSTALL_PREFIX/$APP_NAME/Contents/Info.plist" 2>/dev/null || echo "unknown"
            else
                echo "not installed"
            fi
            exit 0 ;;
        --help|-h) print_help; exit 0 ;;
        *) die "Unknown argument: $1. Try --help." ;;
    esac
    shift
done

# ── Preflight ────────────────────────────────────────────────
echo ""
echo "${BOLD}${CYAN}NexGuard Connect${RESET} · macOS installer"
echo "${DIM}────────────────────────────────────────────${RESET}"
echo ""

# macOS check
if [ "$(uname)" != "Darwin" ]; then
    die "Script chỉ chạy trên macOS. Cho Linux: install-linux.sh"
fi
MACOS_VER=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
info "System: macOS $MACOS_VER · $(uname -m)"

# Tools check
for tool in curl hdiutil shasum python3 plutil; do
    command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
done

# ── Fetch manifest ──────────────────────────────────────────
step "Fetch release manifest"
MANIFEST=$(curl -fsSL "$MANIFEST_URL") || die "Không tải được manifest từ $MANIFEST_URL"

# Parse latest info
LATEST=$(echo "$MANIFEST" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['products']['$PRODUCT_ID']['latest'])")
LATEST_SHA=$(echo "$MANIFEST" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['products']['$PRODUCT_ID']['sha256'])")
LATEST_URL=$(echo "$MANIFEST" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['products']['$PRODUCT_ID']['download_url'])")

# Determine target version
VERSION="${INSTALL_VERSION:-$LATEST}"

if [ "$VERSION" = "$LATEST" ]; then
    DOWNLOAD_URL="$LATEST_URL"
    EXPECTED_SHA="$LATEST_SHA"
    info "Target: ${BOLD}$VERSION${RESET} (latest)"
else
    # Substitute version in URL (assumes standard naming pattern)
    BASE_URL="${LATEST_URL%/*}"
    DOWNLOAD_URL="$BASE_URL/NexGuard-Connect-${VERSION}.dmg"
    EXPECTED_SHA=""
    warn "Target: $VERSION (pinned) — SHA-256 verify sẽ skip (manifest chỉ có SHA cho $LATEST)"
fi
info "URL:    $DOWNLOAD_URL"

# ── Check existing install ──────────────────────────────────
CURRENT=""
if [ -d "$INSTALL_PREFIX/$APP_NAME" ]; then
    CURRENT=$(plutil -extract CFBundleShortVersionString raw \
        "$INSTALL_PREFIX/$APP_NAME/Contents/Info.plist" 2>/dev/null || echo "?")
    if [ "$CURRENT" = "$VERSION" ] && [ "$FORCE" -eq 0 ]; then
        success "Version $VERSION đã cài — nothing to do (use --force để reinstall)"
        exit 0
    fi
    info "Current: $CURRENT · Target: $VERSION"
fi

# ── Download ────────────────────────────────────────────────
step "Download DMG"
TMP_DIR=$(mktemp -d -t nexguard-install.XXXXXX)
DMG="$TMP_DIR/NexGuard-Connect-$VERSION.dmg"

curl -# -fL -o "$DMG" "$DOWNLOAD_URL" || die "Download failed từ $DOWNLOAD_URL"

DMG_SIZE=$(du -h "$DMG" | cut -f1)
info "Downloaded: $DMG_SIZE"

# ── SHA-256 verify ─────────────────────────────────────────
if [ -n "$EXPECTED_SHA" ]; then
    step "Verify SHA-256"
    ACTUAL=$(shasum -a 256 "$DMG" | awk '{print $1}')
    if [ "$ACTUAL" != "$EXPECTED_SHA" ]; then
        error "SHA-256 mismatch!"
        error "  Expected: $EXPECTED_SHA"
        error "  Got:      $ACTUAL"
        die "File corruption hoặc man-in-the-middle. Aborting."
    fi
    success "SHA-256 verified"
fi

# ── Mount ──────────────────────────────────────────────────
step "Mount DMG"
MOUNTED=$(hdiutil attach "$DMG" -nobrowse -plist 2>/dev/null | \
    python3 -c "import sys,plistlib; d=plistlib.loads(sys.stdin.buffer.read()); [print(e['mount-point']) for e in d.get('system-entities',[]) if 'mount-point' in e]" | tail -1)
[ -n "$MOUNTED" ] && [ -d "$MOUNTED" ] || die "Failed to mount DMG"
[ -d "$MOUNTED/$APP_NAME" ] || die "$APP_NAME không có trong DMG"
info "Mounted at $MOUNTED"

# ── Stop running instance ──────────────────────────────────
if pgrep -f "NexGuardConnect" >/dev/null 2>&1; then
    step "Stop running instance"
    osascript -e 'tell application "NexGuardConnect" to quit' 2>/dev/null || true
    sleep 2
    pkill -9 -f "NexGuardConnect" 2>/dev/null || true
fi

# ── Copy to /Applications ──────────────────────────────────
step "Install → $INSTALL_PREFIX"

# Remove old
if [ -d "$INSTALL_PREFIX/$APP_NAME" ]; then
    info "Removing existing install"
    rm -rf "$INSTALL_PREFIX/$APP_NAME" 2>/dev/null || sudo rm -rf "$INSTALL_PREFIX/$APP_NAME"
fi

# Copy new (try without sudo first — user often owns /Applications)
if cp -R "$MOUNTED/$APP_NAME" "$INSTALL_PREFIX/" 2>/dev/null; then
    info "Copied without sudo"
else
    info "Needs sudo for $INSTALL_PREFIX (bạn có thể cần nhập password)"
    sudo cp -R "$MOUNTED/$APP_NAME" "$INSTALL_PREFIX/"
fi

# ── Strip quarantine attribute ──────────────────────────────
step "Bypass Gatekeeper (xattr -dr com.apple.quarantine)"

# Note: DMG này chưa notarize (cần Apple Developer Program $99/y),
# nên macOS Gatekeeper mặc định block. Xoá quarantine attr an toàn
# vì user đã explicit run install script này — không phải drive-by.
if xattr -dr com.apple.quarantine "$INSTALL_PREFIX/$APP_NAME" 2>/dev/null; then
    info "Quarantine removed"
else
    info "Needs sudo for quarantine removal"
    sudo xattr -dr com.apple.quarantine "$INSTALL_PREFIX/$APP_NAME"
fi

# ── Done ───────────────────────────────────────────────────
echo ""
echo "${GREEN}${BOLD}✅ NexGuard Connect $VERSION installed${RESET}"
echo "${DIM}────────────────────────────────────────────${RESET}"
echo ""
echo "  ${BOLD}Launch:${RESET}"
echo "    open $INSTALL_PREFIX/$APP_NAME"
echo ""
echo "  Hoặc tìm ${CYAN}NexGuard Connect${RESET} trong Launchpad / Spotlight."
echo ""
