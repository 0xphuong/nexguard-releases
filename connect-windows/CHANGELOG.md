# Changelog

All notable changes to NexGuard Connect (Windows client) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

---

## [0.1.7] - 2026-07-03

Add Organization + Remove Organization polish + hide the portal URL
from the tray UI.

### Added

- Optional **Label** field on Add Organization (macOS parity). When
  set, the label replaces the URL in the tray header and the sign-in
  screen so the portal address never appears on-screen.
- **Remove current organization** action in the ⋯ menu (destructive
  red foreground). Revokes tokens, drops the server from the
  registry, then switches to the next saved org or Onboarding.
- `windows/CLAUDE.md` — dev working notes (test-box, release
  pipeline, gotchas) mirrored in the source repo.

### Changed

- Tray header subtitle now shows the **label only** — empty label
  collapses the whole line instead of falling back to the URL host.
- Sign-in screen's "to <server>" subtitle hides similarly when no
  label is set.

---

## [0.1.6] - 2026-07-03

First public release of the Windows client. Feature parity with
macOS client v0.0.10 plus Windows-specific hardening: in-app OAuth
via `WebView2` (no leftover browser tabs), MSI installer with the
WebView2 Runtime bootstrapper embedded (so Windows Server / older
Windows 10 hosts don't need to install runtime dependencies by
hand), a full auto-update pipeline with progress modal + auto-
restart, and a brand refresh (shield icon everywhere, phase-color
state dot in the tray, Segoe Fluent iconography).

For the full source-side changelog see the [nexguard-connect
Windows changelog](https://github.com/0xphuong/nexguard-connect/blob/main/windows/CHANGELOG.md#016---2026-07-03).

### Server pairing

Requires NexGuard server v2.1.0+ (needs loopback `redirect_uri`
support in `/auth/native/begin`).

---

## [0.1.5] - 2026-07-03

Fix: auto-restart after update actually restarts.

### Fixed

- **Auto-restart helper hung until timeout**. The 0.1.4 helper polled
  for any `msiexec.exe` process to exit before launching the new
  build, but Windows always keeps a persistent `msiexec.exe` Windows
  Installer service running -- so the poll never emptied. The helper
  now watches the *specific PID* of the elevated msiexec we spawned,
  which exits cleanly once the package finishes installing.
- Helper falls back to a fixed 45 s wait if the msiexec PID couldn't
  be captured (rare).
- Helper writes a small progress log to `%TEMP%\nexguard-restart.log`
  so future update-flow issues are diagnosable.

---

## [0.1.4] - 2026-07-03

Auto-restart after in-app update.

### Added

- **Auto-restart helper** — after the user clicks Update and the MSI
  finishes installing, the freshly-installed exe launches
  automatically. Chrome/Slack/Discord parity: no more manual Start-
  menu round trip. Implementation: the old exe writes a tiny
  PowerShell script to `%TEMP%`, spawns it detached at normal
  integrity right before `Shutdown()`, and the helper polls until
  both the old process AND msiexec are gone before launching the
  new install. Self-deletes when done.

### Changed

- **Launching-state copy** in the update modal now tells the user
  the app will "close and reopen automatically when the new version
  is ready" -- previously said "will close in a moment" which sent
  the wrong expectation.

---

## [0.1.3] - 2026-07-03

Brand refresh + polished upgrade flow.

### Added

- **Full-brand app icon** (multi-res `.ico` bundling 16/24/32/48/64/128/256
  from the same shield mark macOS ships) embedded into the .exe and
  the MSI's Add/Remove Programs entry.
- **Branded tray icon** — the shield replaces the placeholder disc,
  with a small phase-color dot in the bottom-right corner (Docker /
  Cloudflare WARP convention) so the tray still telegraphs Connected
  / Reconnecting / Revoked / Idle at a glance.
- **State-driven update modal** — click Update in the tray chip and
  the modal opens straight into the Downloading state with a live
  progress bar; no intermediate "Details / Confirm" screen. Panels
  swap through Downloading → Preparing → Launching → (shutdown) or
  Failed with a Try again path.
- **Force update check on startup** — every launch fetches the
  latest manifest even inside the 24 h throttle window, so a user
  who re-opens the app sees updates published since the last run.
- **Dismiss X on the update chip** — session-scoped hide for the
  advertised version. Reappears when the manifest advances to a
  newer version or the user manually re-checks.

### Changed

- **About window** trimmed to macOS `orderFrontStandardAboutPanel`
  parity: icon, product name, version, copyright. No more Server /
  User rows (that data belongs in Copy Diagnostic Log).
- **In-app logo** replaces the "NG" text monogram in the tray popup
  header, About window, and WebView2 loading overlay.
- **Friendly upgrade errors** — 403 / 404 / 5xx / timeout / UAC deny
  each map to a distinct human-readable message inside the modal
  (was: raw HTTP status).

### Fixed

- Clicking Install / Update no longer closed the modal and hid the
  tray, leaving the user unable to see download progress or a 404
  error. The modal now stays open for the full pipeline.

---

## [0.1.1] - 2026-07-02

First auto-update path exercised end-to-end. The v0.1.0 client would
never see updates because nothing polled the manifest; this release
wires the manifest poll to bootstrap + a 1 h timer with a 24 h throttle,
so the client is now self-updating without any admin push.

### Added

- **Auto update check on bootstrap + hourly** — `UpdateChecker` polls
  `versions.json` at
  `raw.githubusercontent.com/0xphuong/nexguard-releases/main/versions.json`
  (same URL macOS uses) with a 24 h throttle persisted to
  `HKCU\Software\NexGuard\Connect\UpdateCheckLastAt`. Steady-state
  cost: at most one small JSON fetch per day per client.
- **Manual "Check for updates"** — kebab menu entry that bypasses the
  throttle. `Info` banner on `.upToDate` / `.unknown` results so a
  manual click never reads as "nothing happened".
- **`UpdateWindow`** — modal shown when the tray "Update available"
  chip is clicked. Shows current → latest side by side, release date,
  clickable changelog link, primary `Install now` + secondary `Later`.
- **Mandatory-update block** — if the running version is below the
  manifest's declared `minimum`, `ConnectAsync` early-returns with
  "Install the required update before connecting.". The
  `UpdateWindow` in required mode hides `Later` so the only path
  forward is the install.

### Changed

- **Product identity in the tray popup**: NG monogram + subtle server
  subtitle + compact `● Connected` status pill in the header.
  Replaces the previous plain-text `NexGuard` title.
- **Persistent status stripe** — 3 px full-width phase-colored bar
  at the very top of the popup, colorblind-safe backup to the pill.
- **Segoe Fluent Icons + Segoe UI Variable** everywhere — no more
  ambiguous emoji fallbacks (⏳ ⚠ ⋯).
- **About dialog**, **kebab menu**, and **diagnostic notifications**
  now render in the app's design system instead of the OS-default
  `MessageBox` chrome.

### Fixed

- **In-app OAuth** — sign-in now happens inside an embedded
  `WebView2` window that closes programmatically on callback, so
  the user no longer has to manually close a leftover browser tab.
  Bundles the WebView2 Evergreen bootstrapper in the MSI so Windows
  Server / older Windows 10 hosts pick up the runtime on install.
