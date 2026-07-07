# Changelog — NexGuard Connect (Linux CLI + TUI)

Mirrors the source repo's `nexguard-connect/linux-cli/CHANGELOG.md`.
Tag prefix: `linux-cli-vX.Y.Z`. Manifest product id:
`nexguard-connect-linux-cli`.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
SemVer: features = MINOR, bug fixes = PATCH.

## [0.2.0] - 2026-07-07

TUI redesign — the fullscreen dashboard reads like an operator
control panel now, not a splash screen. Same keybinds, same
daemon protocol shape (all new snapshot fields are optional
behind `#[serde(default)]`), so nothing else changes for users
who prefer the plain `nexguard status` / `connect` CLI paths.

### Added

- **Data-dense Connected view** — TRAFFIC (↑ Sent / ↓ Recv /
  live Rate) + SESSION (Uptime / Handshake age / DNS) side-by-
  side cards, plus meta rows (Org / User / Address).
- **Live bandwidth rate** computed client-side from the delta
  between successive daemon snapshots — no daemon-side rate
  field needed.
- **Handshake-age telemetry** from `ng show latest-handshakes`
  polled every 5s alongside transfer counters. Truest aliveness
  signal: interface can be UP with a 5-min-old handshake.
- **Client IPv4 + DNS resolvers** surfaced from the .conf so the
  TUI proves the tunnel actually swapped the host resolvers,
  not just brought a link up.
- **Phase glyph + org label inline in the header** (k9s pattern):
  `○` SignedOut, `◐` Disconnected, rotating `◐◓◑◒` Connecting
  spinner, `●` Connected.
- **Icon-prefixed toasts** on their own footer-adjacent row
  (Info/Success/Warning/Error variants, auto-clear ~4s).
- **Left-aligned STATUS card layout** across all four phases so
  pressing `[C]` is a swap-in-place, not a full reflow.
- **2-column Help overlay** with tinted section headers; `[A]`
  context split (autostart / add-org-in-picker) documented on
  one row.
- **Header ellipsises long org names** rather than overflowing.
- **Daemon-unreachable moved to a top banner** — matches
  conflict + update banner slot, footer stays the keybind hint.
- **Overlay backdrop dim** for Help + Org picker so modality
  reads at a glance.

### Compatibility

`StatusSnapshot` gained four optional fields (`latest_handshake`,
`client_ipv4`, `interface`, `dns`). A 0.2.0 CLI still talks to a
0.1.x daemon during the rollout — missing fields render as `-`.

Verified E2E on Ubuntu 22.04.5 (10.0.234.10) before ship.

---

## [0.1.8] - 2026-07-07

Security parity with macOS + Windows clients: enrolled device
names now carry a `/etc/machine-id[:8]` suffix so two Linux
boxes with the same hostname can't share an approved device row.

### Fixed

- **Device name at enroll time** built as `"{hostname}
  ({first-8-of-/etc/machine-id})"` -- parity with macOS
  `IOPlatformUUID` prefix + Windows `MachineGuid` prefix. Falls
  back to bare hostname if `/etc/machine-id` is missing.

### User-visible impact

Existing 0.1.0-0.1.7 Linux clients are enrolled server-side under
just the hostname. After upgrading to 0.1.8 they enrol under the
new suffixed name, so the server creates a **new device row that
needs admin approval**. The old row is orphaned and can be
deleted. This is the security fix paying its price -- prior
versions let a same-hostname client piggy-back onto an
already-approved row.

Verified E2E on Ubuntu 22.04.5 (10.0.234.10) before ship.

---

## [0.1.7] - 2026-07-07

**Bumped `minimum` to 0.1.7.** 0.1.0-0.1.6 had a routing bug that
silently dropped AllowedIPs routes, breaking DNS + LAN access
through the tunnel. Upgrade is mandatory.

Two real-user bugs surfaced on 10.0.234.9 and fixed in this
release:

### Fixed

- **Bare `wg show …` calls in vendored `ng-quick` weren't
  renamed to `ng show`.** Only the helper-wrapped `cmd wg`
  calls got the sed patch when we bundled the WireGuard tools
  under `/usr/libexec/nexguard/ng`. Bare `$(wg show …)` and
  `<(wg show …)` in process substitution silently returned
  empty since `wg` isn't on the runtime PATH -- worst offender
  was the AllowedIPs route-add loop, which iterated over
  nothing and installed no routes to the tunnel subnets. DNS
  and LAN traffic then went out the physical NIC and timed out.
- **`bring_down` didn't guarantee interface removal.** ng-quick
  can exit 0 while leaving a partially-torn-down interface in
  the kernel; next connect hit `ng-nexguard already exists`.
  `bring_down` now runs `ip link del` as a safety net.
- **DNS handling for systemd-resolved.** Replace `/etc/resolv.conf`
  as a plain file (backing up the symlink for exact restore)
  AND push `resolvectl` per-link config -- belt-and-suspenders,
  because `resolvectl` alone on systemd 245 (Ubuntu 20.04)
  didn't route queries reliably even with `default-route yes` +
  `~.`.

### Skipped

0.1.4/5/6 shipped intermediate fixes that turned out
insufficient. Tags exist for bisection; changelog omits them
for readability.

---

## [0.1.4] - 2026-07-07

Bug fix — DNS stays reliable across connect/disconnect cycles.

### Fixed

- **ng-quick DNS handling** on systemd-resolved boxes:
    - `set_dns`: pin `resolvectl default-route <iface> yes` in
      addition to the `~.` routing domain, so resolved unambiguously
      prefers our link's DNS. Flush caches immediately after so any
      pre-existing negative-cache entries don't survive into the
      session.
    - `unset_dns`: flush caches after `resolvectl revert` so tunnel-
      routed answers don't linger after the tunnel is down --
      previously left users unable to resolve even the NexGuard
      server hostname after a disconnect.

Immediate workaround if upgrading via `nexguard update install`
fails because DNS is broken:

    sudo systemctl restart systemd-resolved
    nexguard update install

---

## [0.1.3] - 2026-07-07

Bug fix — `nexguard status` no longer masks the good error.

### Fixed

- **`nexguard status` pre-flight ping printed the wrong hint.**
  When the socket was reachable-but-permission-denied (fresh
  install, current SSH session missing the `nexguard` group), the
  old pre-flight sent users chasing `is nexguard-tunneld running`
  when the real fix is `newgrp nexguard`. Same fix pattern the
  TUI footer got in 0.1.1; the pre-flight is now gone and the
  real `daemon::call` error path drives the message.

---

## [0.1.2] - 2026-07-07

Bug fix — postinst reliably starts the daemon on fresh installs.

### Fixed

- **postinst** — the prior revision swallowed `systemctl start`
  failures with `|| true`. On some fresh installs there's a race
  between `daemon-reload` picking up the just-copied service
  file and the immediate `start` finding it, leaving the daemon
  inactive after apt install and users hitting the TUI's
  `Daemon unreachable — sudo systemctl start nexguard-tunneld`
  footer even though the sudo command they'd have to type is
  literally the fix. Postinst now retries the start up to 4
  times with 1s sleep between and prints an explicit WARNING
  with diagnose + retry commands if the service still can't
  come up.

---

## [0.1.1] - 2026-07-06

Bug fixes surfacing after the first day of real usage.

### Fixed

- **TUI footer misleading hint after fresh install.** When the daemon
  socket existed but the current SSH session hadn't inherited the
  new `nexguard` group yet, the footer said `sudo systemctl start
  nexguard-tunneld` — wrong action. Now checks whether the socket
  file exists and shows either `newgrp nexguard` (perm issue) or
  `sudo systemctl start` (service down) accordingly.

### Changed

- **postinst confirmation.** Prints
  `nexguard-tunneld service is running (enabled on boot).` after
  systemctl restart succeeds, so the user isn't left guessing
  whether the service actually came up.

---

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
