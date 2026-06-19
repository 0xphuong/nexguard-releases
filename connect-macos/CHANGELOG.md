# Changelog

All notable changes to NexGuard Connect (macOS client) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

---

## [0.0.7] - 2026-06-18

Menu layout cleanup + diagnostics. UX-only release; no behavior changes
to auth, tunnel, or network recovery.

### Added

- **Open Web Portal** menu item (⌘P) — opens the active server URL in
  the user's default browser. One-click access to portal-side actions
  (view device, audit log, manage devices) that the client itself
  doesn't expose (`App/Views/ContentView.swift`).
- **Advanced ▸ submenu** groups rare + destructive actions:
  - Remove Current Organization (with `trash` icon)
  - Uninstall Privileged Helper (with `minus.circle` icon)
  - Copy Diagnostic Log (with `doc.on.clipboard` icon)

  Icons substitute for the red-text destructive styling that macOS
  Menus don't render — SwiftUI's `role: .destructive` only colors text
  on iOS context menus and alerts. Role kept for semantic clarity.
- **Copy Diagnostic Log** — copies a compact state snapshot to the
  clipboard (version, build, macOS, state, tunnel health, server, user,
  device, helper status, last handshake, last error). Intended for
  paste-into-support-ticket workflows.
- **Inline app version in About menu** — "About NexGuard Connect (0.0.7)"
  so the build is visible without opening the About panel.
- **Quit menu hint** — when the tunnel is connected, the Quit item
  reads "Quit (VPN stays connected)" instead of "Quit NexGuard
  Connect", clarifying that the tunnel survives app quit (matches
  WireGuard.app / Tailscale / Mullvad behaviour, and our existing
  leftover-tunnel adoption logic).

### Changed

- **Menu structure regrouped** for clearer visual hierarchy: Organizations
  → Account (Open Portal, Sign Out) → Preferences (Launch at Login) →
  Advanced (destructive) → System (About, Quit). Reduced from 5 dividers
  to 4 by consolidating account-related items.
- **Remove Current Organization** moved from top-level menu to the
  Advanced submenu — was sitting next to "Add Organization" with
  identical styling, prone to misclick.

---

## [0.0.6] - 2026-06-18

Robust auto-reconnect on network change + launch at login. Major rewrite of
the WiFi-roam / network-flap handling after observing repeated
disconnect-to-Ready bugs. New design follows the WireGuard.app / Mullvad
pattern: probe before tearing the tunnel down, restart only if probing
fails. Research and code-review behind the rewrite saved to
`docs/network-recovery-research.md`.

### Added

- **Launch at Login** (`App/State/AutoLaunch.swift`, menu item in
  `ContentView`). Uses `SMAppService.mainApp` — no paid Apple Developer
  Program required. Enabled by default on first install (one-time
  `launchAtLogin.defaultApplied` flag); subsequent runs respect the user's
  choice. Refreshed on every menu open in case the user toggled it
  externally via System Settings → Login Items.
- **`TunnelManager.adoptLeftover()`** — sets `startedAt = Date()` when the
  app inherits a tunnel it didn't start. Without this, `stats()` returned
  nil indefinitely and the UI was permanently stuck on "Last handshake: —".
  Called from `bootstrap()` leftover adoption, `connectForce()` catch
  branch, and `hardReconnect()` catch branch.
- **`docs/network-recovery-research.md`** — synthesis + raw output of the
  deep-research workflow (8 confirmed claims with citations to WireGuard,
  Mullvad, Tailscale, Apple DTS) and the code-review workflow (15
  high-severity bugs found across 10 finder angles). Documents why we
  switched from stop-then-start to probe-first.

### Changed

- **Auto-reconnect: probe-first instead of stop-then-start.** Old design
  tore down the tunnel on every NWPath event and tried `wg-quick up`
  before DHCP/DNS/default-route stabilized — both attempts often failed,
  leaving state stuck in `.enrolled` with the 30 s backoff blocking
  recovery. New design:
  1. Mark `tunnelHealth = .degraded` (UI signal only — tunnel kept up)
  2. Debounce 1 s (Mullvad-style)
  3. Poll `wg show` every 2 s for up to 10 s. Fresh handshake newer than
     2× `PersistentKeepalive` = wireguard-go's UDP socket already
     rebound → mark healthy, no restart.
  4. Only if probing fails: hard restart, with backoff stamped on success
     only so a transient failure doesn't lock out recovery.
- **`handlePathUpdate` reacts from `.connected` AND `.reconnecting`** so a
  follow-up path callback (e.g., DHCP just finalized the real lease after
  a link-local intermediate) can refresh recovery in flight.
- **`hardReconnect` on terminal failure stays `.reconnecting`** (not
  `.enrolled`) and schedules a 5 s retry — keeps `handlePathUpdate` armed
  so the next network event can trigger recovery, instead of permanently
  dropping the user to "Ready".
- **`reconnectTask` is now a stored, cancellable handle.** `disconnect()`,
  `signOut()`, `switchTo()`, and `forceReSignIn()` cancel it before
  proceeding. Previously a user clicking Disconnect mid-reconnect would
  see the tunnel resurrect itself a few seconds later.
- **`bootstrap()` adopts leftover tunnel BEFORE spawning the background
  refresh Task** — fixes a race where the background Task could clobber
  the just-adopted `.connected` state with `.enrolled` or
  `.pendingApproval`. The background Task now also respects
  `state == .connected` and skips `enrollDevice()` over an adopted tunnel.

### Fixed

- **WiFi off → on no longer drops the client to "Ready"** when DHCP/DNS
  hasn't fully stabilized. New probe-first design keeps the tunnel
  through the transition; wireguard-go rebinds its UDP socket
  automatically on most network changes.
- **WiFi A → WiFi B roaming (same `en0`) no longer false-positive
  reconnects.** `interfaceIPv4(_:)` now skips link-local (169.254/16) and
  loopback (127/8). `getifaddrs(3)` returns interfaces in unspecified
  order — without filtering, two callbacks on the SAME network could
  return different IPs (DHCP lease vs link-local) and trip a spurious
  "network changed" reconnect.
- **"Last handshake: —" sticking after auto-reconnect adopted a tunnel.**
  Catch-branch adoption paths now call `TunnelManager.adoptLeftover()` to
  sync `startedAt`, so `stats()` works.
- **`infoBanner` re-rendering on every menu open.** Two remaining direct
  `infoBanner = ...` writes (`cleanupOrphanTunnel`, "Device approved" in
  `refreshDeviceStatus`) now route through `showInfoBanner(...)` with
  auto-clear (5 s and 10 s respectively).
- **30-second backoff burning on a failed auto-reconnect.**
  `lastReconnectAt` is stamped ONLY when a hard restart succeeds — a
  failed attempt no longer locks out the next NWPath-driven recovery.

### Technical notes

The rewrite was driven by two background workflows: a deep-research pass
that surfaced the WireGuard.app `wgBumpSockets()` pattern, Mullvad's 1 s
synthetic-offline debounce, Apple DTS guidance ("reachability is not
ground truth"), and Tailscale's `net/netmon` + HTTP captive-portal probe;
and a high-effort code review (10 finder angles, 1-vote verify, sweep)
that confirmed 15 distinct bugs in the previous auto-reconnect
implementation. Full output of both saved to
`docs/network-recovery-research.md` (Appendices A & B).

---

## [0.0.5] - 2026-06-14

Self-healing tunnel: detect stale handshakes and recover automatically on
network changes.

### Added

- **`TunnelHealth` enum** (`.healthy` / `.degraded`) published in AppState.
  Computed each polling tick from handshake age. Drives menu bar icon color
  and in-app status copy (`App/State/AppState.swift`).
- **Network change detection** via `NWPathMonitor` (Apple's `Network`
  framework). Watches WiFi ↔ Ethernet ↔ Cellular transitions and captive
  portal events. When the path becomes satisfied again while the tunnel is
  up, the client auto-reconnects to force a fresh WireGuard handshake
  against the new local IP / interface — fixes the "Connected but no
  traffic" stale state that appears after laptop sleep/wake or roaming.
  30-second backoff prevents reconnect loops on flappy networks
  (`AppState.startNetworkMonitoring()`, `handlePathUpdate(_:)`,
  `autoReconnectIfStale(reason:)`).
- **Dynamic stale threshold** based on the peer's `PersistentKeepalive`:
  with NexGuard's typical KP=25, a handshake older than ~75 s is flagged
  degraded (3 missed keepalives, min 60 s floor). When KP is disabled, the
  threshold falls back to WireGuard's own `REJECT_AFTER_TIME` of 180 s —
  treats only true session death as degraded, avoiding false positives on
  legitimately-idle tunnels.
- **Health-aware menu bar icon**: 🟢 green when connected + healthy,
  🟠 orange when connected + degraded, distinguishing "we think we're
  connected" from "we are actively talking to the peer"
  (`App/NexGuardConnectApp.swift`).
- **Health-aware ConnectedView**: status text shows "Connection Unstable"
  with warning-colored orb + exclamation icon when degraded — matches the
  menu bar signal so the user sees the same story whether they glance at
  the icon or open the menu (`App/Views/ConnectedView.swift`).

### Changed

- **Stats polling interval**: 2 s → 5 s. 60 % less CPU/battery for the same
  perceived freshness of the Last Handshake row (`startStatsPolling()`).
- **Tear-down hooks**: `disconnect()`, `signOut()`, `forceReSignIn()`, and
  `switchTo()` now all call `stopNetworkMonitoring()` and reset
  `tunnelHealth` so a stale monitor never lingers after the tunnel goes
  away.

### Notes

- No server-side changes. Pairs with NexGuard server 2.1.0+.

[0.0.5]: https://github.com/0xphuong/nexguard-connect/releases/tag/macos-v0.0.5

---

## [0.0.4] - 2026-06-14

Client-side support for the device-approval workflow introduced in NexGuard
server 2.1.0.

### Added

- **`.pendingApproval` state**. After enrollment, when the server returns
  `status="pending"`, the client transitions to the new `.pendingApproval`
  state instead of `.enrolled`. The Connect button is unavailable until
  approval lands (`App/State/AppState.swift`).
- **PendingApprovalView**. Hourglass orb with warning tint, "Pending Approval"
  hero copy, explanatory subtext, and a "Check Status" button that polls the
  server on demand. The user's email + device name display below as context
  (`App/Views/PendingApprovalView.swift`).
- **Automatic status polling**. `verifySession()` (called on every menu open)
  also calls `refreshDeviceStatus()` to catch admin approve / revoke between
  menu opens. When an approval lands:
  - `.pendingApproval` → `.enrolled`
  - Banner: "Device approved. You can now connect."
  When admin revokes an active session:
  - `.enrolled` / `.connected` → `.pendingApproval`
  - Tunnel stops immediately.
- **`NativeEnrollResponse.status`** field — `"pending"` | `"approved"`. Used
  by `enrollDevice()` and `refreshDeviceStatus()` to drive state transitions
  (`App/API/NexGuardAPI.swift`).

### Notes

- Pairs with NexGuard server 2.1.0. Older server versions will return no
  `status` field; the client defaults to `.enrolled` in that case (graceful
  fallback for mixed-version rollout).

[0.0.4]: https://github.com/0xphuong/nexguard-connect/releases/tag/macos-v0.0.4

---

## [0.0.2] - 2026-06-14

First fully-functional release: sign in → auto-enroll → connect, multi-tenant,
MFA-compatible. Pairs with NexGuard server 2.0.1.

### Added

- **Sign in with NexGuard** via `ASWebAuthenticationSession` + PKCE. Opens
  Safari, completes auth at the portal (whatever provider the admin enables —
  Google OIDC, local, magic link, SAML), redirects back to the app via the
  `nexguard-connect://` URL scheme. No native MFA UI required: when the user
  has MFA registered, the existing portal MFA challenge runs in Safari and the
  client receives the code only after MFA verifies (`App/Auth/OAuthClient.swift`, `App/State/AppState.swift`).
- **Auto device enrollment** after sign-in. Client generates a WireGuard
  keypair locally (private key never leaves the device), names the device
  `{hostname} ({hwUUID-prefix})` so the same Mac always maps to one server-side
  device row, then POSTs to `/api/v1/devices/enroll`. The returned `wg-quick`
  config is parsed, the private key is injected over the server's
  `PrivateKey = REPLACE_ME` placeholder, and the result is cached for instant
  reconnect (`App/State/AppState.swift`).
- **One-click Connect / Disconnect**. Tunnel comes up through the bundled
  `wg-quick` CLI (works without paid Apple Developer; will move to NetworkExtension
  when that's available). Pre-flight token refresh on connect catches a stale
  24-hour VPN session before the user stares at a tunnel that has no peer on
  the server.
- **Auto refresh with single-flight lock**. Access JWT (1 h TTL) refreshes
  silently ~5 min before expiry. Concurrent calls share the same in-flight
  task. On `session_expired` (server's 24 h policy), `forceReSignIn(reason:)`
  clears local state and prompts the user to sign in again.
- **Sign Out** revokes the refresh token server-side via
  `POST /api/v1/native/revoke` before wiping local store, so a stolen
  `store.json` can't extend its life.
- **Multi-tenant: per-organization isolation**.
  - `ServerConfig` registry tracks all servers the user has signed into,
    plus which one is currently active.
  - `Keychain` storage is namespaced by server URL — tokens, device ID, WG
    private key, and cached config never leak across organizations.
  - **Onboarding screen** on first launch (or when the user adds another org):
    URL + optional label input, HEAD-ping validation, then auto sign-in.
  - **Organization switcher** in the menu bar ellipsis menu lists every saved
    server with a checkmark on the active one. Switching is instant — local
    state is reloaded, no re-Google-login required.
  - **Deep-link** `nexguard-connect://configure?server=https://...&label=...`
    pre-fills the onboarding view from an emailed onboarding link.
- **Session-expired UX** that respects the server's "Require Auth for VPN
  Sessions" policy. When the server returns `401 session_expired`, the app
  clears state with a clear "Session expired — please sign in again." banner
  and the right action button.
- **Helper install banner** — single inline row when the privileged helper is
  missing. The helper supports `up`, `down`, and `show` subcommands; the last
  one lets the app read real WireGuard handshake state without prompting for
  admin every poll (`App/Helper/HelperInstaller.swift`, `App/Vendor/bin/nexguard-wg-helper`).

### Changed

- **UI redesigned** around a calm utilitarian language:
  - Design tokens (`Palette`, `Typo`, `Space`, `Radius`) replace ad-hoc
    fonts/colors/spacings (`Shared/DesignTokens.swift`).
  - Status orb (64 pt with radial gradient + state-colored glow) is the
    centerpiece. Pulsing ring while `.connecting`/`.reconnecting`, success
    halo when `.connected`, accent-colored shield when `.enrolled`.
  - All states share a `minHeight: 340` so the popover does not jitter when
    transitioning Enrolled → Connecting → Connected.
  - Header strip (logo + ellipsis menu) and content area separated by a
    subtle 0.5-opacity divider; items anchor to corners.
  - About panel is forced to the front via temporary `.regular` activation
    policy + `NSApp.activate()` + close-observer that demotes back to
    `.accessory` (LSUIElement apps default to opening windows behind the
    focused app) (`App/Views/WindowActivator.swift`).
- **Sign out moved into the ellipsis menu** (Tailscale-style). The footer
  strip was removed so the popover stays a stable height as state changes.

### Removed

- Pre-T6 manual workflows that are obsolete now that enrollment is automatic:
  - `Import Config` view + URL scheme handler.
  - `Generate Keypair` view (the app generates one automatically during enroll).
  - `Export .conf` button.
  - `setImportedConfig` flow + the corresponding bootstrap branch.
- RX/TX traffic display in the stats strip — without root, the app could only
  ever show `0 KB` (`wg show` needs root on macOS userspace WG), which was
  misleading. The Last Handshake row remains.
- Dev-mode "real tunnel via wg-quick CLI" banner.

### Fixed

- **Last handshake reset to "now" on every menu open** — every popover open
  was running `bootstrap()` which called `TunnelManager.loadFromPreferences()`,
  which overwrote `startedAt = Date()` when it detected the leftover tunnel.
  Guarded with `startedAt == nil` so the field is set exactly once
  (`App/Tunnel/TunnelManager.swift`).
- **Onboarding view had no Cancel button** when triggered from the menu —
  user had to quit and relaunch to back out. Cancel is now shown when at
  least one server is already configured (first-launch users still must
  complete onboarding to enter the app). ESC also dismisses.
- **Apple's `.relative(presentation: .numeric)` could render small elapsed
  durations as "0 sec." for too long**. Replaced with a deterministic
  formatter (`now` < 2 s, `Xs ago`, `Xm ago`, `Xh Ym ago`, `Xd ago`).

[0.0.2]: https://github.com/0xphuong/nexguard-connect/releases/tag/v0.0.2
