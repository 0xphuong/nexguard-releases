# Changelog

All notable changes to NexGuard Connect (Windows client) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

---

## [0.5.1] - 2026-07-16

Internal DNS through the tunnel now survives Disconnect + Reconnect.
Zero UX change from 0.5.0 -- same tray icon flow, same 0 UAC prompts
on Connect/Disconnect.

### Fixed

- **Internal DNS breaks on the 2nd (and every subsequent) Connect.**
  Symptom: after the very first Connect on a fresh 0.5.0 install
  internal names (e.g. an org-internal DNS zone) resolve fine. After
  a Disconnect + Connect cycle, they stop resolving, while public
  names (`google.com`) keep working. Only Windows was affected;
  macOS + Linux clients on the same server were fine.

  Root cause layered:

    1. The v0.5.0 no-UAC-per-Connect fast path (`ServiceController
       .Start` from the medium-integrity tray app) skipped the
       elevated `tunnel-up.ps1` script that used to set the tunnel
       adapter's `InterfaceMetric = 1`. Every Connect after the
       very first hit fast path -> metric stayed at auto (~5),
       tying with the Ethernet adapter -> Ethernet's public DNS
       won ties -> CoreDNS on the tunnel was never queried.
    2. Even the pre-fast-path script set metric WITHOUT
       `-AutomaticMetric Disabled`. The TCP/IP stack recomputes
       metric on the next routing change and reverts to auto
       unless the flag says "don't".
    3. `wireguard.exe /tunnelservice` worker calls
       `SetIpInterfaceEntry` with `UseAutomaticMetric=TRUE` ~2 s
       after the SCM Event 7036 fires (post-adapter-Up route
       configuration in the WG worker), so a single
       `Set-NetIPInterface` call gets overwritten.

  Fix (matches the "no-UAC-per-Connect" design goal):

    - **New Scheduled Task** `\NexGuardConnect\SetTunnelMetric`
      registered by the MSI installer. Runs as `NT AUTHORITY\
      SYSTEM`. Triggered by SCM Event 7036 filtered to
      `param1='NexGuard Manager'` -- fires on every service state
      transition. The action polls the `nexguard` adapter to reach
      Up, then runs `Set-NetIPInterface -InterfaceMetric 1
      -AutomaticMetric Disabled` for IPv4 + IPv6 in an 8-attempt
      retry loop (~8 s window) to survive wireguard.exe's post-Up
      overwrite, then `Clear-DnsClientCache`.
    - **No UAC bleed-through.** Task installs at MSI install-time
      inside the already-elevated msiexec transaction; runtime
      invocations run as SYSTEM via Task Scheduler, invisible to
      the tray app. Connect/Disconnect UX unchanged from 0.5.0.
    - **`-AutomaticMetric Disabled`** added to the elevated
      slow-path `tunnel-up.ps1` too, defense-in-depth for
      first-Connect on fresh installs.
    - **Uninstall CustomAction** removes the task + its action
      script cleanly.

  Rollback safe: reverting to 0.5.0 leaves the task orphaned but
  its action is exactly what 0.5.0 wants on its metric step
  (harmless). To fully remove after rollback:
  `Unregister-ScheduledTask -TaskPath '\NexGuardConnect\' -TaskName
  SetTunnelMetric -Confirm:$false` from an elevated PS.

### Notes for enterprise / hardened environments

- **Task Scheduler service must be enabled.** Some STIG / CIS L2
  images disable it; in that case the task never fires and this
  fix is a no-op (falls back to whatever metric wintun picked).
- **Enterprise GPO pinning `AutomaticMetric = Enabled`** on all
  interfaces overrides this fix the same way it would override a
  manual `Set-NetIPInterface`. Doc-only issue.

---

## [0.5.0] - 2026-07-15

Ownership + branding release. Tunnel service registered as our own
**`NexGuardManager`** instead of the upstream-derived
`WireGuardTunnel$nexguard`. Standalone WireGuard for Windows can
now be installed side-by-side without collision. UAC prompt drops
to once at install/first-connect. "Launch at login" toggle finally
works + shows a visible checkmark.

### Changed

- **Windows Service renamed** `WireGuardTunnel$nexguard` →
  **`NexGuardManager`**. Upstream `wireguard.exe /installtunnelservice`
  hardcodes the prefix `WireGuardTunnel$` and we can't override it;
  v0.5.0 bypasses that command and registers the service directly
  via `sc.exe create` pointing at `wireguard.exe /tunnelservice`
  (worker mode, no name hardcoding). Practical wins:
    * NexGuard Connect + standalone WireGuard for Windows coexist.
    * services.msc + Task Manager + Event Viewer show
      "NexGuardManager" / "NexGuard Manager".
    * Migration cleanup in `tunnel-up.ps1` — the first run after
      upgrade stops + deletes any leftover `WireGuardTunnel$nexguard`
      service before creating `NexGuardManager`. No manual steps
      required.

- **Config path moves** from `%LOCALAPPDATA%\NexGuardConnect\nexguard.conf`
  (per-user, wiped on profile delete) to
  **`%ProgramData%\NexGuardConnect\nexguard.conf`** (machine-scoped,
  always readable by the LocalSystem-run tunnel worker). File ACL:
  SYSTEM + Administrators + current user, inheritance off.

- **Standalone WireGuard for Windows detection** — `ConflictDetector`
  reads the WireGuardManager service ImagePath from the registry.
  Since v0.5.0 the two installs don't share a service name, so the
  presence of a standalone install is now just an INFO log line
  (no blocking dialog, no ErrorMessage banner). Kept because the
  older WireGuard install ships a vintage WinTUN driver that CAN
  fight ours on adapter creation on Win11 24H2 -- worth having in
  the support triage record.

### Fixed

- **Windows 11 24H2 "handshake stale" forever.** Root cause was
  the WireGuardManager singleton service being claimed by a
  standalone WireGuard for Windows install (2021 vintage) that
  couldn't talk to the modern proxy handshake protocol. Service
  rename above removes the contention -- NexGuard's own service
  pipeline handles the tunnel end-to-end.

- **Tunnel service shut down immediately with "Firewall error at
  helpers.go:100: The specified group does not exist"** (exit
  code 1319). `sc.exe create` doesn't set `SidType` on the new
  service, so the tunnel worker has no per-service SID to identify
  itself to WFP when it tries to register firewall filter rules.
  Fix: after `sc create`, run `sc sidtype NexGuardManager unrestricted`
  and `sc privs NexGuardManager` with the minimum privilege list
  (SeChangeNotifyPrivilege / SeImpersonatePrivilege /
  SeCreateGlobalPrivilege / SeAssignPrimaryTokenPrivilege /
  SeLoadDriverPrivilege). Worker completes "Enabling firewall
  rules" and adapter reaches Up within ~2s.

- **PowerShell console flashed briefly on every Connect + Disconnect.**
  `Process.Start` with `Verb="runas"` routes through `ShellExecute`
  which ignores `CreateNoWindow` and `WindowStyle=Hidden`. Fix:
  call `ShellExecuteExW` directly via P/Invoke with `nShow = SW_HIDE`
  + `-WindowStyle Hidden` on the PowerShell command line as
  belt-and-braces. UAC prompt still shows, but no console flash
  and no taskbar entry.

- **UAC prompt on every Connect + Disconnect.** Users were seeing
  an elevation prompt every single toggle. Fix in two parts:
    1. When creating `NexGuardManager` we now also run
       `sc sdset` granting the built-in `Users` group
       `SERVICE_START | SERVICE_STOP | SERVICE_QUERY_STATUS`
       (SDDL fragment `(A;;LCRPWPRC;;;BU)`) -- Users can toggle
       the service without elevation, but still can't change
       config, delete, or write to its ACL.
    2. `BringUpAsync` / `BringDownAsync` have a fast path that
       calls `ServiceController.Start()` / `.Stop()` directly.
       On the second and every subsequent Connect after install,
       the fast path succeeds and NO UAC prompt appears. Elevated
       PowerShell fallback runs only when service doesn't exist
       yet (fresh install / first Connect) or SDDL is wrong
       (upgrade from pre-0.5.0-sdset build). In that fallback,
       the script re-applies sidtype + privs + sdset on the
       existing service instead of delete+recreate.

- **"Launch at login" toggle looked broken.** Two issues stacked:
    1. No visible state feedback — the WPF default `IsCheckable`
       glyph is a tiny tick that many users don't spot,
       especially on dark themes. Fix: reuse the same green
       Fluent-icon checkmark pattern the Organizations list
       uses (`CheckmarkIcon()` in TrayPopupWindow). Same green
       tint as the "Connected" status stripe.
    2. Registry write went to a bogus path under single-file
       publish. `AutoLaunch.Enable()` used
       `Assembly.GetEntryAssembly()?.Location` which returns
       empty or a .dll path under .NET 8 single-file, so
       Explorer had nothing runnable to launch at login. Fix:
       switch to `Environment.ProcessPath` (real .exe path).
       `Enable/Disable` now return bool and the UI surfaces
       actual failure via a MessageBox.

---

## [0.4.0] - 2026-07-13

Additive telemetry release — pairs with NexGuard server 3.2.0.

### Added

- **Host OS + CPU architecture headers** on every request to the
  NexGuard server. `App.xaml.cs::ConfigureNexGuardHeaders` now stamps
  three new headers in addition to the existing Platform/Version pair:

      X-NexGuard-Client-OS-Name      Registry ProductName      ("Windows Server 2022 Datacenter")
      X-NexGuard-Client-OS-Version   Environment.OSVersion     ("10.0.20348")
      X-NexGuard-Client-Arch         RuntimeInformation.OSArch ("x86_64" | "arm64")

  Product name comes from `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProductName`
  (wrapped in try/catch so a locked-down registry never crashes an
  auth request). OS version is `Environment.OSVersion.Version.ToString(3)`
  ("10.0.20348" — 3 parts, revision omitted since it's almost always 0).
  Arch is normalized to match the macOS convention (`X64` → `x86_64`,
  `Arm64` → `arm64`) so fleet queries like "list all arm64 devices"
  work across platforms.

  Server (v3.2.0+) surfaces these in the admin UI (Devices index +
  Device Details card). Older servers ignore unknown headers — no
  coordinated release required.

  Passive telemetry, best-effort, no enforcement gate.

### Changed

- `<Version>` bumped `0.3.1` → `0.4.0` in `NexGuardConnect.csproj`
  (MINOR: new server-facing capability). MSI ProductVersion follows.

---

## [0.3.1] - 2026-07-04

Bug fix: tray popup footer version string is now dynamic.

The version text in the tray popup's bottom row was a hardcoded
XAML literal (`Text="v0.2.1"`) that never updated. Users who
upgraded would see the old version in the footer even though the
running app was on the new build. Pre-existing bug -- surfaced
during the 0.3.0 upgrade smoke test.

### Fixed

- **`Views/TrayPopupWindow.xaml`** — replaced the hardcoded
  literal with a named `VersionText` TextBlock.
- **`Views/TrayPopupWindow.xaml.cs`** — populate `VersionText`
  from `Assembly.GetEntryAssembly().GetName().Version` in the
  ctor, same pattern already used by `AboutWindow`.

---

## [0.3.0] - 2026-07-04

Verify update downloads with SHA-256. Manifest now carries a
`sha256` field alongside each product entry; the in-app installer
hashes the downloaded MSI (streaming, via
`System.Security.Cryptography.SHA256`) and refuses to run msiexec
if it doesn't match. Feature parity with macOS client v0.3.0.

Two failure surfaces added to the Failed panel:

- **Missing checksum** — manifest doesn't publish `sha256` for
  the Windows product. Strict: refuse (no fallback).
- **Hash mismatch** — file downloaded but hash differs. Refuse
  BEFORE stopping the tunnel or elevating msiexec.

Threat model this closes: an attacker who compromises the S3
bucket alone can no longer push a malicious MSI -- they'd also
need to compromise the GitHub-hosted manifest to publish a
matching hash. Separate channels, separate auth boundaries.

### Added

- **`App/Api/UpdateChecker.cs`** — `Product.Sha256` +
  `UpdateStatus.Sha256`.
- **`AppState._updateSha256`** — observable property, set from
  the manifest on every check.
- **`scripts/build-installer.ps1`** — prints the built MSI's
  SHA-256 for direct paste into `versions.json`.

### Changed

- **`AppState.InstallUpdateAsync`** — strict-mode preflight +
  post-download hash check before tunnel stop / msiexec launch.

---

## [0.2.1] - 2026-07-04

Tray menu reorg -- Advanced submenu (parity with macOS).

### Changed

- Kebab menu (⋯) gets an **Advanced** submenu containing `Remove
  current organization` (red / destructive, only when a server is
  bound), `Check for updates`, and `Copy diagnostic log`. Top
  level trims down to daily-driver actions: Organizations
  switcher, Add organization, Refresh status, Launch at login,
  Sign out, About, Quit. `About NexGuard Connect` stays at the
  top level -- users reflexively look for it there.

---

## [0.2.0] - 2026-07-03

Client identity telemetry -- every request to the NexGuard server
now carries `X-NexGuard-Client-Platform: windows` +
`X-NexGuard-Client-Version: 0.1.8`. Server stamps those into the
device row so admins can see which build each device is running
(passive; no enforcement).

### Added

- Client identifier headers on `HttpClient` factory defaults for
  the `"oauth"` + `"api"` named clients. The `"update"` client (hits
  GitHub raw for the manifest) intentionally stays header-less.

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
