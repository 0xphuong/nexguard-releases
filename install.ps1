<#
.SYNOPSIS
    NexGuard Connect — Windows installer / updater / uninstaller.

.DESCRIPTION
    One-liner install (latest):
        irm https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.ps1 | iex

    Pin a specific version:
        $env:INSTALL_VERSION = "0.3.1"
        irm https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.ps1 | iex

    Uninstall (or any flag) — use the scriptblock form so args can pass through:
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.ps1))) -Uninstall

    Local:
        powershell -ExecutionPolicy Bypass -File .\install.ps1 [-Uninstall] [-Force] [-Version] [-Help]

    What it does:
        1. Preflight (Windows 10+, x64, admin rights)
        2. Fetch release manifest (versions.json)
        3. Download NexGuardConnect-<ver>.msi
        4. Verify SHA-256 against manifest
        5. msiexec /i /passive /norestart with per-machine install
        6. Verify install (Uninstall registry key)
        7. Cleanup temp files

.PARAMETER Uninstall
    Remove NexGuard Connect (msiexec /x, silent).

.PARAMETER Force
    Force reinstall even if version already matches.

.PARAMETER Version
    Print installed version and exit.

.PARAMETER Help
    Print help and exit.

.EXAMPLE
    irm https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.ps1))) -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Force,
    [switch]$Version,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Config ───────────────────────────────────────────────────
$ManifestUrl = 'https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/versions.json'
$ProductId   = 'nexguard-connect-windows'
$ProductName = 'NexGuard Connect'

# ── Colors (ANSI VT — Win10+; use [char]27 so PS 5.1 works too) ─
# PowerShell 5.1 (default trên Windows Server 2022) không hiểu `"``e"`
# escape, nó output literal 'e'. [char]27 chạy được cả 5.1 lẫn 7+.
$ESC = [char]27
$SupportsColor = -not $env:NO_COLOR -and $Host.UI.SupportsVirtualTerminal
if ($SupportsColor) {
    $Bold = "$ESC[1m"; $Dim = "$ESC[2m"; $Reset = "$ESC[0m"
    $Green = "$ESC[32m"; $Red = "$ESC[31m"; $Yellow = "$ESC[33m"
    $Blue = "$ESC[34m"; $Cyan = "$ESC[36m"
} else {
    $Bold = ''; $Dim = ''; $Reset = ''
    $Green = ''; $Red = ''; $Yellow = ''; $Blue = ''; $Cyan = ''
}

function Write-Step    { param($m) Write-Host "$Blue▶$Reset $Bold$m$Reset" }
function Write-Info    { param($m) Write-Host "  $Dim$m$Reset" }
function Write-OK      { param($m) Write-Host "$Green✓$Reset $m" }
function Write-Warn    { param($m) Write-Host "$Yellow⚠$Reset $m" }
function Write-Err     { param($m) Write-Host "$Red✗$Reset $m" -ForegroundColor Red }
function Die           { param($m) Write-Err $m; exit 1 }

# ── Cleanup on exit ─────────────────────────────────────────
$script:TmpDir = $null
function Invoke-Cleanup {
    if ($script:TmpDir -and (Test-Path $script:TmpDir)) {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $script:TmpDir
    }
}

# ── Help ────────────────────────────────────────────────────
function Show-Help {
    @"
$Bold${ProductName} — Windows installer$Reset

${Bold}Usage:${Reset}
    # One-liner (no args)
    irm <URL> | iex

    # With args (scriptblock form so args pass through)
    & ([scriptblock]::Create((irm <URL>))) -Uninstall

    # Local
    powershell -ExecutionPolicy Bypass -File install.ps1 [options]

${Bold}Options:${Reset}
    $Cyan-Uninstall$Reset      Remove NexGuard Connect (silent msiexec /x)
    $Cyan-Force$Reset          Force reinstall even if version matches
    $Cyan-Version$Reset        Print installed version + exit
    $Cyan-Help$Reset           Print this help + exit

${Bold}Environment:${Reset}
    $Cyan`$env:INSTALL_VERSION$Reset   Pin specific version (default: latest from manifest)
    $Cyan`$env:NO_COLOR$Reset          Disable ANSI colors

${Bold}Examples:${Reset}
    # Latest
    irm https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.ps1 | iex

    # Specific version
    `$env:INSTALL_VERSION = '0.3.1'
    irm https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.ps1 | iex

    # Uninstall
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.ps1))) -Uninstall

${Bold}Requirements:${Reset}
    Windows 10 build 1809+ / Windows 11 · x64 · Administrator rights
"@ | Write-Host
}

# ── Root check ──────────────────────────────────────────────
function Test-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-Admin)) {
        Write-Err "Cần chạy với quyền Administrator."
        Write-Host ""
        Write-Host "  Mở PowerShell as Admin (Win+X → Terminal (Admin)) rồi chạy lại:"
        Write-Host "    ${Cyan}irm https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.ps1 | iex${Reset}"
        Write-Host ""
        exit 1
    }
}

# ── Find installed product ──────────────────────────────────
function Get-InstalledProduct {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in Get-ChildItem $root -ErrorAction SilentlyContinue) {
            $item = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            if (-not $item) { continue }
            # Strict mode throws on missing properties, phải check tồn tại trước.
            $displayName = if ($item.PSObject.Properties['DisplayName']) { $item.DisplayName } else { $null }
            if ($displayName -and $displayName -like '*NexGuard*Connect*') {
                return [PSCustomObject]@{
                    DisplayName     = $displayName
                    DisplayVersion  = if ($item.PSObject.Properties['DisplayVersion'])  { $item.DisplayVersion }  else { '' }
                    UninstallString = if ($item.PSObject.Properties['UninstallString']) { $item.UninstallString } else { '' }
                    ProductCode     = $key.PSChildName
                }
            }
        }
    }
    return $null
}

# ── Print installed version ─────────────────────────────────
function Show-Version {
    $p = Get-InstalledProduct
    if ($p) { $p.DisplayVersion } else { 'not installed' }
}

# ── Uninstall ───────────────────────────────────────────────
function Invoke-Uninstall {
    Assert-Admin
    Write-Step "Uninstalling $ProductName"

    $p = Get-InstalledProduct
    if (-not $p) {
        Write-Info "$ProductName chưa install — nothing to do"
        return
    }

    Write-Info "Found: $($p.DisplayName) v$($p.DisplayVersion)"
    Write-Info "Product code: $($p.ProductCode)"

    $logFile = Join-Path $env:TEMP "nexguard-uninstall.log"
    $args = @('/x', $p.ProductCode, '/passive', '/norestart', '/L*V', "`"$logFile`"")

    Write-Info "Running: msiexec.exe $($args -join ' ')"
    $proc = Start-Process msiexec.exe -ArgumentList $args -Wait -PassThru
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Die "msiexec exited with code $($proc.ExitCode). See log: $logFile"
    }

    Write-OK "$ProductName uninstalled"
    if ($proc.ExitCode -eq 3010) {
        Write-Warn "Reboot required to fully complete uninstall."
    }
}

# ── Install ─────────────────────────────────────────────────
function Invoke-Install {
    Assert-Admin

    # Preflight
    $osArch = (Get-CimInstance Win32_OperatingSystem).OSArchitecture
    if ($osArch -notlike '*64*') {
        Die "Only 64-bit Windows supported. Detected: $osArch"
    }
    $osBuild = [Environment]::OSVersion.Version.Build
    Write-Info "System: Windows build $osBuild · $osArch"
    if ($osBuild -lt 17763) {
        Write-Warn "Windows 10 build 1809+ recommended (detected $osBuild). Older builds may miss WireGuard driver support."
    }

    # Fetch manifest
    Write-Step "Fetch release manifest"
    try {
        $manifest = Invoke-RestMethod -Uri $ManifestUrl -UseBasicParsing -ErrorAction Stop
    } catch {
        Die "Không tải được manifest từ ${ManifestUrl}: $($_.Exception.Message)"
    }

    $product = $manifest.products.$ProductId
    if (-not $product) { Die "Manifest không có product '$ProductId'" }

    $latest      = $product.latest
    $latestSha   = $product.sha256
    $latestUrl   = $product.download_url
    $minimum     = if ($product.PSObject.Properties['minimum']) { $product.minimum } else { '0.0.0' }

    $targetVersion = if ($env:INSTALL_VERSION) { $env:INSTALL_VERSION } else { $latest }
    if ($targetVersion -eq $latest) {
        $downloadUrl = $latestUrl
        $expectedSha = $latestSha
        Write-Info "Target: $Bold$targetVersion$Reset (latest)"
    } else {
        $baseUrl = $latestUrl -replace '/[^/]+$', ''
        $downloadUrl = "$baseUrl/NexGuardConnect-$targetVersion.msi"
        $expectedSha = ''
        Write-Warn "Target: $targetVersion (pinned) — SHA-256 verify sẽ skip"
    }
    Write-Info "URL:    $downloadUrl"
    Write-Info "Minimum supported: $minimum"

    # Check existing install
    $installed = Get-InstalledProduct
    if ($installed) {
        if ($installed.DisplayVersion -eq $targetVersion -and -not $Force) {
            Write-OK "Version $targetVersion đã cài — nothing to do (use -Force để reinstall)"
            return
        }
        Write-Info "Current: $($installed.DisplayVersion) · Target: $targetVersion"
    }

    # Download
    Write-Step "Download .msi"
    $script:TmpDir = Join-Path $env:TEMP ("nexguard-install-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $script:TmpDir | Out-Null
    $msi = Join-Path $script:TmpDir 'NexGuardConnect.msi'

    $oldProgress = $ProgressPreference
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $msi -UseBasicParsing -ErrorAction Stop
    } catch {
        Die "Download failed từ ${downloadUrl}: $($_.Exception.Message)"
    } finally {
        $ProgressPreference = $oldProgress
    }
    $sizeMB = [math]::Round((Get-Item $msi).Length / 1MB, 2)
    Write-Info "Downloaded: $sizeMB MB"

    # SHA-256 verify
    if ($expectedSha) {
        Write-Step "Verify SHA-256"
        $actual = (Get-FileHash -Path $msi -Algorithm SHA256).Hash.ToLower()
        $expected = $expectedSha.ToLower()
        if ($actual -ne $expected) {
            Write-Err "SHA-256 mismatch!"
            Write-Err "  Expected: $expected"
            Write-Err "  Got:      $actual"
            Die "File corruption hoặc man-in-the-middle. Aborting."
        }
        Write-OK "SHA-256 verified"
    }

    # Install
    Write-Step "Install MSI"
    $logFile = Join-Path $env:TEMP "nexguard-install.log"
    $msiArgs = @('/i', "`"$msi`"", '/passive', '/norestart', '/L*V', "`"$logFile`"", 'ALLUSERS=1')
    Write-Info "Running: msiexec.exe $($msiArgs -join ' ')"

    $proc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
    switch ($proc.ExitCode) {
        0    { Write-OK "MSI install completed" }
        3010 { Write-OK "MSI install completed (reboot required)" }
        1602 { Die "User cancelled install (exit 1602)" }
        1603 { Die "Fatal MSI error (exit 1603). See log: $logFile" }
        default { Die "msiexec exited with code $($proc.ExitCode). See log: $logFile" }
    }

    # Verify
    Write-Step "Verify install"
    $verify = Get-InstalledProduct
    if (-not $verify) { Die "Install verify failed — product not in registry" }
    Write-OK "Registered: $($verify.DisplayName) v$($verify.DisplayVersion)"

    # Post-install
    Write-Host ""
    Write-Host "$Green$Bold✅ $ProductName $targetVersion installed$Reset"
    Write-Host "$Dim────────────────────────────────────────────$Reset"
    Write-Host ""
    Write-Host "  ${Bold}Launch:${Reset}"
    Write-Host "    Start Menu → ${Cyan}NexGuard Connect${Reset}"
    Write-Host "    ${Dim}(or run: `"C:\Program Files\NexGuard Connect\NexGuardConnect.exe`")${Reset}"
    Write-Host ""
    if ($proc.ExitCode -eq 3010) {
        Write-Warn "Reboot recommended để WireGuard driver load đầy đủ."
        Write-Host ""
    }
}

# ══════════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════════
try {
    if ($Help)    { Show-Help; exit 0 }
    if ($Version) { Show-Version; exit 0 }

    Write-Host ""
    Write-Host "$Bold$Cyan${ProductName}$Reset · Windows installer"
    Write-Host "$Dim────────────────────────────────────────────$Reset"
    Write-Host ""

    if ($Uninstall) {
        Invoke-Uninstall
    } else {
        Invoke-Install
    }
} finally {
    Invoke-Cleanup
}
