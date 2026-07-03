# Changelog

All notable changes to NexGuard Connect (Windows client) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
