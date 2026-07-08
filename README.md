# NexGuard Releases

Public manifest + changelogs for the NexGuard product family. The
[NexGuard Connect](https://github.com/0xphuong/nexguard-connect) macOS
and Windows clients poll this repo to surface "Update available" /
"Update required" prompts.

## What's here

| File | Purpose |
|---|---|
| [`versions.json`](versions.json) | Machine-readable: latest + minimum version per product, download links, changelog deep-links. The client fetches this file. |
| [`install.sh`](install.sh) | Universal installer for NexGuard Connect — auto-detects macOS vs Linux, downloads matching artifact, verifies SHA-256, installs. |
| [`connect-macos/CHANGELOG.md`](connect-macos/CHANGELOG.md) | Mirror of the [NexGuard Connect](https://github.com/0xphuong/nexguard-connect) macOS client changelog. |
| [`connect-windows/CHANGELOG.md`](connect-windows/CHANGELOG.md) | Mirror of the [NexGuard Connect](https://github.com/0xphuong/nexguard-connect) Windows client changelog. |
| [`connect-linux-cli/CHANGELOG.md`](connect-linux-cli/CHANGELOG.md) | Mirror of the [NexGuard Connect](https://github.com/0xphuong/nexguard-connect) Linux CLI/TUI changelog. |
| [`server/CHANGELOG.md`](server/CHANGELOG.md) | Mirror of the [NexGuard server](https://github.com/0xphuong/nexguard) changelog. |

## Quick install

One command, auto-detects your OS:

```bash
# macOS
curl -fsSL https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.sh | bash

# Linux (needs root)
curl -fsSL https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.sh | sudo bash
```

Uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.sh | bash -s -- --uninstall        # macOS
curl -fsSL https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.sh | sudo bash -s -- --uninstall   # Linux
```

Pin a specific version: `INSTALL_VERSION=0.3.1 curl ... | bash`.

Flags: `--help`, `--force`, `--uninstall`, `--version`. Env vars: `INSTALL_VERSION`, `INSTALL_PREFIX` (macOS), `NO_COLOR`.

What the script does per OS:

- **macOS** — mounts the DMG, copies `NexGuardConnect.app` to `/Applications`, then runs `xattr -dr com.apple.quarantine` so the Gatekeeper "Apple could not verify" prompt doesn't fire on first launch.
- **Linux** (Ubuntu 20.04+ / Debian, x86_64) — installs the `.deb` via `dpkg -i` (with `apt-get install -f` fallback for deps), then verifies `nexguard-tunneld` is active. Reminds you to run `usermod -aG nexguard $USER` if not already.

## Products

| Product | Latest | Minimum | Source repo |
|---|---|---|---|
| NexGuard Connect (macOS) | `0.3.0` | `0.0.5` | [nexguard-connect](https://github.com/0xphuong/nexguard-connect) |
| NexGuard Connect (Windows) | `0.3.1` | `0.1.0` | [nexguard-connect](https://github.com/0xphuong/nexguard-connect) |
| NexGuard Connect (Linux CLI) | `0.1.8` | `0.1.7` | [nexguard-connect](https://github.com/0xphuong/nexguard-connect) |
| NexGuard Server | `3.1.0` | `3.0.0` | [nexguard](https://github.com/0xphuong/nexguard) |

## How the client uses this

`NexGuard Connect` fetches `versions.json` on launch and every ~24 h:

```
GET https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/versions.json
```

It then compares the running app version against `products.nexguard-connect-macos`:

- `local >= latest` → no banner.
- `minimum <= local < latest` → dismissible "Update available" banner with a link to `download_url`.
- `local < minimum` → blocking "Update required" modal. Connect button disabled until the user updates.

`raw.githubusercontent.com` is CDN-cached and has **no API rate limit**, so this scales to thousands of clients without infra on our side.

## Schema (`versions.json`)

```jsonc
{
  "schema_version": 1,              // bump on breaking changes
  "products": {
    "<product-id>": {
      "latest":        "X.Y.Z",     // current stable
      "minimum":       "X.Y.Z",     // clients below this must update
      "released_at":   "YYYY-MM-DD",
      "download_url":  "https://...",
      "sha256":        "hex...",    // hex SHA-256 of the artifact at download_url
                                    //   optional in the schema, but the macOS
                                    //   client (>= 0.3.0) and the Windows
                                    //   client (>= 0.3.0) both refuse to
                                    //   install any update whose entry is
                                    //   missing this field or whose hash
                                    //   doesn't match.
                                    //   Emit with:  shasum -a 256 <artifact>
                                    //   (or Get-FileHash -Algorithm SHA256)
      "changelog_url": "https://..."
    }
  }
}
```

Product ids in use:
- `nexguard-connect-macos`
- `nexguard-connect-windows`
- `nexguard-connect-linux-cli`
- `nexguard-server`

Future: `nexguard-connect-ios`, `nexguard-connect-android`, etc.

## Release process

Each release (in the corresponding source repo):

1. Tag + push in the source repo (`nexguard-connect` or `nexguard`).
2. Update `versions.json` in this repo — bump `latest` (and `minimum` if old versions should be force-deprecated).
3. Append the new changelog entry under `connect-macos/CHANGELOG.md` or `server/CHANGELOG.md` (copy from the source repo's `CHANGELOG.md`).
4. Commit + push.

`minimum` should only be bumped for:
- Security fixes the older client cannot handle safely.
- Server-side API breaks the older client can no longer talk to.
- Critical bugs that make the older client misbehave at runtime.

Avoid bumping `minimum` on every release — users dislike forced updates.

## Verifying `versions.json`

```bash
# Quick local check the JSON parses + schema is consistent
jq '.' versions.json
```

A `.github/workflows/validate.yml` action validates `versions.json` on every PR (JSON syntax + required fields).
