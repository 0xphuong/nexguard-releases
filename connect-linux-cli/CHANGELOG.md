# Changelog — NexGuard Connect (Linux CLI + TUI)

Mirrors the source repo's `nexguard-connect/linux-cli/CHANGELOG.md`.
Tag prefix: `linux-cli-vX.Y.Z`. Manifest product id:
`nexguard-connect-linux-cli`.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
SemVer: features = MINOR, bug fixes = PATCH.

## [0.1.0] - 2026-07-06

First public release. Rust + ratatui client with the same feature
set as the macOS + Windows clients, packaged as a single `.deb`
shipping bundled WireGuard tooling (renamed `ng`/`ng-quick`) so
apt doesn't pull `wireguard-tools` or `openresolv` at install
time.

### Architecture

- **`nexguard`** — user-space CLI with a fullscreen ratatui
  dashboard when launched without args. Speaks a JSON-newline
  protocol to the daemon over `/run/nexguard/tunneld.sock`.
- **`nexguard-tunneld`** — systemd system service (root). Owns
  the WireGuard interface (`ng-nexguard`), config file at
  `/etc/nexguard/`, and DNS integration with systemd-resolved via
  `resolvectl dns <iface>` / `resolvectl domain <iface> ~.`.
- **Group-gated socket** — `nexguard` posix group; postinst
  creates it and adds `$SUDO_USER`. Mode 0660 root:nexguard.
- **Tailscale/Mullvad pattern** — no wg-quick reliance for DNS,
  no external `wireguard-tools` dep at runtime.

### Added

- **Sign-in / sign-out** — OAuth 2.0 PKCE with RFC 8252 loopback
  redirect (`http://127.0.0.1:51820/callback`). `xdg-open`
  launches the browser on desktops; headless servers see a
  copy-pasteable URL + SSH port-forward instructions.
- **Multi-organisation** — `nexguard org add/list/remove/switch`
  and an interactive ratatui overlay (press `O`) with arrow
  navigation + confirmation-guarded delete.
- **Connect / Disconnect** via daemon IPC. Interface named
  `ng-nexguard` (parity with a distinct rebranded namespace so
  the client coexists cleanly with a stock WireGuard install).
- **Bandwidth stats** refreshed every 5s from `ng show <iface>
  transfer`. TUI Connected view + `nexguard stats` show live
  rx/tx.
- **Update pipeline** — `nexguard update check|install` fetches
  `raw.githubusercontent.com/0xphuong/nexguard-releases/main/versions.json`,
  verifies the .deb SHA-256 strictly (no fallback on missing
  hash), then invokes `pkexec dpkg -i`.
- **Client identity headers** — `X-NexGuard-Client-Platform: linux-cli`
  + `X-NexGuard-Client-Version` on every server request (parity
  with macOS + Windows, feeds the server-side devices table).
- **Diagnostic bundle** — `nexguard log --export <path>` (or press
  `E` in the TUI) writes a `.tar.gz` with `report.txt`
  (OS + config redacted + daemon snapshot + `ip link` + `resolvectl`
  + `systemctl status`) and `journal.txt`. Tokens + the WireGuard
  private key are never included.
- **Conflict detection** — reads `/sys/class/net/*/wireguard` and
  surfaces a warning strip in the TUI if another non-ours WG
  interface is up alongside the tunnel.
- **Deep-link handler** — `.desktop` file with
  `MimeType=x-scheme-handler/nexguard-connect;` registered via
  `xdg-mime` in postinst. `nexguard-connect://configure?server=<url>&label=<label>`
  URLs adds the org idempotently.
- **Autostart on login** — `nexguard autostart enable/disable`
  (systemd user unit).
- **TUI overlays** — `?` shows full keybinds; `O` opens the org
  picker; sign-in / add-org / update-install / log-tail all
  suspend the alt-screen and resume on Enter so cooked-terminal
  interactions (OAuth callback, URL prompt, pkexec password,
  `journalctl -f`) work naturally.

### Security notes

- **Endpoint IP:port hidden** from TUI Connected view + `nexguard
  status` output. Same rationale as macOS + Windows: defence
  against shoulder-surfing, screenshots in support tickets, and
  Zoom screen-shares. Value stays in the daemon snapshot for
  diagnostic export.
- **Tokens** live in `~/.local/share/nexguard-connect/tokens.json`
  mode 0600 (matches `tailscaled.state` model). WireGuard
  private key stored the same way at `wg-private-key.txt`.

### Distro targets

Ubuntu 20.04 / 22.04 / 24.04 / 26.04 LTS. No GUI toolkit deps —
runs identically on server (SSH) and desktop (RDP/VNC + TUI).

### Runtime dependencies

`libmnl0`, `iproute2`, `policykit-1 | polkit`, `systemd` — all
core-priority or ubiquitous on target LTS.

Pair with the macOS + Windows clients at `macos-v0.3.0+` and
`windows-v0.3.1+` -- all three now stamp
`X-NexGuard-Client-Platform` + `X-NexGuard-Client-Version` on
every server request.
