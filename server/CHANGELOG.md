# Changelog

All notable changes to NexGuard will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

---

## [4.0.2] - 2026-07-27

### Added

- **`policy_rules.comment` column** (nullable, ≤200 chars).
  Admin-facing memo -- what a rule is for ("Grafana at
  10.99.0.5", "block old wiki backend"). Rendered as a
  regular column in the /policies/:id/rules table and echoed
  in the Remove-rule confirmation modal so a delete decision
  has the business context inline.
- New Ecto migration
  `20260727000004_add_comment_to_policy_rules.exs` adds the
  column non-null-safely -- existing rules default to
  `NULL` and render as `—` in the table until edited.

### Changed

- **Add-rule form on `/policies/:id/rules` collapsed to a
  single row** (was four full-width stacked field boxes).
  New CSS grid `.ng-rule-add-form` -- six columns:
  destination / action / protocol / port(s) / comment /
  submit. Column ratios weight the two free-text inputs
  (destination + comment) heaviest via
  `minmax(160-180px, 1.4-1.6fr)` so shorter selects don't
  starve them; the small selects use `minmax(90-110px,
  0.7-0.9fr)`. Below 900px viewport the grid wraps to
  two columns so nothing clips inside a sidebar-open
  laptop admin console. Four per-input hint blocks were
  fused into one `.ng-rule-add-form-hint` line below the
  grid.

### Notes

- No fz_wall change -- `comment` is a UI-only column and is
  not projected into `Policies.as_effective_rules/0`.
- No client change.

---

## [4.0.1] - 2026-07-27

### Fixed

- **L7 apps unreachable after any policy CRUD** (regression
  since v3.3.0). `FzWall.Server.handle_call({:set_rules, ...})`
  runs `cli().setup_firewall()` before `restore/1` to prevent
  duplicate jump-rule accumulation -- but `setup_firewall/0`'s
  `teardown_table` wipes the **whole** `inet nexguard` table,
  including the `l7_prerouting` chain installed at boot. The
  restore path only re-adds users/devices/filter rules, so
  the TPROXY hook was silently missing until the next
  container restart. Effect: traffic to any L7 VIP in
  `10.99.0.0/16` fell through to the forward chain and hit
  the `Default deny` policy (or fz_wall global default),
  making every L7-managed app unreachable to VPN clients as
  soon as an admin edited a policy.

  Fix: after `restore/1`, re-run `try_l7(install_l7)` if
  `l7_enabled?() == true`. The `fwmark route` lives in the
  kernel routing table (not nftables) so it survives the
  teardown and doesn't need a rerun. Mirrors the boot flow
  in `FzWall.Server.init/1`.

  No client change; deploy the image + no manual step needed.
  L7 access recovers as soon as the container running v4.0.1
  is up (next boot re-installs the TPROXY chain fresh, and
  subsequent policy CRUDs no longer wipe it).

---

## [4.0.0] - 2026-07-27

**Breaking**: retires the legacy `FzHttp.Rules` subsystem in
its entirety. Policies (v3.3.0) are now the sole L3/L4 egress
rule surface. Admins were expected to recreate any remaining
legacy rules as policies BEFORE upgrading (see v3.3.0
"Removal plan"). The Ecto migration guards against silent
data loss -- see "Migration" below.

### Removed

- **`FzHttp.Rules` context** + `Rules.Rule` schema +
  `Rules.Authorizer` (dropped from `FzHttp.Auth.Roles`) +
  the `Rules.Rule.Changeset` + `Rules.Rule.Query` modules.
- **`FzHttpWeb.RuleLive.Index`** LiveView + `rule_list_component`
  + `/rules` route + `/rules/deny` route. Sidebar "Firewall
  Rules" link is gone; Access Control section now leads with
  Policies.
- **`FzHttpWeb.API.V0.RuleController`** + `/api/v0/rules` REST
  routes. External clients that scripted against `/api/v0/rules`
  must migrate to policies (a REST surface for policies is
  future work; see task.md if needed).
- **`Events.add("rules", ...)`** + **`Events.delete("rules", ...)`**
  handlers. Policy CRUD invokes `Events.set_rules/0`
  directly.
- **Legacy Postgres `rules` table** -- see Migration.
- **`manage_rules_permission/0`** authorizer permission and the
  `L3/L4 rules` count on the user Show page + `Firewall
  Rules` row on the settings/account profile card (there is
  no per-user rules concept any more; policies scope by
  assignment or `applies_to_all_users`).

### Changed

- **`FzHttp.Events.set_rules/0`** + **`FzHttp.Server.load_settings/0`**
  drop the `MapSet.union(Rules.as_settings(), ...)` step
  introduced in v3.3.0 for coexistence; only
  `Policies.as_effective_rules/0` runs now. One less table
  hit per boot and per CRUD.
- **`FzHttp.Policies.port_rules_supported?/0`** absorbs the
  identical helper that used to live in `FzHttp.Rules`. Same
  underlying config key (`:fz_wall, :port_based_rules_supported`);
  moved home only.

### Migration (`20260727000003_drop_legacy_rules_table.exs`)

- Pre-flight `SELECT count(*) FROM rules` runs before the
  drop. If the table is non-empty, the migration **refuses**
  with a loud error explaining the required manual conversion
  path. Prevents accidental egress-reopen on a live gateway
  where the admin forgot to migrate remaining legacy rows.
- **Escape hatch**: set
  `NEXGUARD_ALLOW_LEGACY_RULES_LOSS=true` on the container
  to force the drop even with non-zero rows. Intended for
  fresh dev / staging boxes where losing legacy fixtures is
  fine.
- Postgres types `action_enum` + `port_type_enum` are NOT
  dropped -- `policies` + `policy_rules` still reference
  them.
- `down/0` recreates the `rules` table shell (empty).
  Rollback for the SCHEMA; the actual dropped rows are gone,
  intentionally.

### Compatibility

- **No client change**. Clients see the same WG peer + config;
  rules apply server-side.
- **REST API v0**: `/api/v0/rules` is gone. Programmatic rule
  management is not supported in v4.0.0 -- managed via
  `/policies` admin UI.
- **Rollback**: `git checkout v3.3.0` + `docker compose up -d`.
  The Ecto `down/0` recreates the empty rules table; if you
  need the legacy rows back, restore from a v3.3.x DB
  snapshot.

---

## [3.3.0] - 2026-07-27

Additive: introduces the **policy-based egress model** as a
successor to the per-user `rules` table. Named policies group
`(destination, port, action)` rules; users are added to policies
via a many-to-many join. The nftables backend (fz_wall) is
unchanged -- it already organises rules per-user internally, so
policy-derived rules just union with the legacy rule stream and
land in the exact same per-user chains.

Coexists with the legacy `/rules` UI during the v3.3.x
transition. `/rules` is scheduled for removal in v4.0.0 (see
`task.md`). Admins can migrate at their pace; no forced move.

### Added

- **New tables**: `policies`, `policy_rules`, `users_policies`
  (composite PK on the join). Ecto schemas +
  `FzHttp.Policies.{Policy, PolicyRule}` + `FzHttp.Policies`
  context with the standard `create / update / delete / list`
  surface + `add_user_to_policy / remove_user_from_policy /
  list_users_in_policy / list_policies_for_user` for M2M
  operations. Idempotent add (composite PK + `ON CONFLICT DO
  NOTHING`) so a UI double-click no-ops instead of raising.
- **Postgres constraints**: reused `action_enum` and
  `port_type_enum` types so the wire shape stays identical to
  legacy rules. Two GiST exclusion constraints prevent
  duplicate `(policy_id, destination, action)` with overlapping
  port ranges inside the same policy (port-less vs port-typed
  predicates split so `10.0/8 accept` doesn't collide with
  `10.0/8 accept :443`).
- **`FzHttp.Policies.as_effective_rules/0`** flattens every
  (user, policy_rule) pair into rule projections whose shape
  matches `FzHttp.Rules.setting_projection/1` -- fz_wall sees
  one flat `MapSet` regardless of source.
- **`FzHttp.Events.set_rules/0` unions** the legacy per-user
  rules and the policy-derived rules so both surfaces stay
  live during the transition.
- **Admin UI `/policies`**: index + show (Overview / Rules /
  Users / Danger tabs) + New Policy modal + inline add-rule +
  user assignment `<select>` + confirm modals for
  delete/remove. Sidebar link "Policies" under Access Control,
  next to Firewall Rules.
- **Audit log events**: `policy.create`, `policy.update`,
  `policy.delete`, `policy_rule.{create,update,delete}`,
  `policy.user_added`, `policy.user_removed`,
  `policy.users_bulk_added`.
- **Bulk assign**: `[Assign all (N)]` button on the policy's
  Users tab -- inserts every remaining user via a single
  `INSERT ... ON CONFLICT DO NOTHING` and fires
  `Events.set_rules/0` exactly once (loop-calling the
  per-user path would trigger N nftables teardown+rebuild
  cycles, which is unnecessary for a single bulk action).
- **Global policies** (`applies_to_all_users` flag). When
  enabled, the policy's rules materialise ONCE with
  `user_id=nil` (fz_wall's global `forward` chain + global
  `ip_accept`/`ip_drop` sets) instead of the per-user
  cross product. New users automatically inherit these
  rules -- no per-user assignment step. Example: "allow
  `10.0.100.10:443` for everyone" is now one nftables
  element regardless of user count, matching what the
  legacy `/rules` UI did with `user_id=nil`. UI hides the
  Users tab for global policies and shows a `global`
  badge in the list + header.
- **nftables overlap-tolerance**: `add_element` calls now
  swallow `interval overlaps with an existing one` and
  `File exists` errors (both idempotent no-ops -- the
  narrower interval is already covered by the wider one).
  Prevents a hard boot-time crash of `fz_wall.Server.init/1`
  when a user has both a legacy rule and a policy rule
  whose destinations overlap during the v3.3.x transition.
- **/policies UI alignment**: Replaced OS-native
  `data-confirm` browser prompts on the list-page delete
  button and the "Assign all users" button with the styled
  in-app modal used by Applications / Users / Access Groups.
  Switched `ng-card` / `ng-card-header` / `ng-card--danger`
  (undefined in main.scss -- rendered unstyled) to the
  peer-page `ng-detail-card` + `ng-section-header` shell,
  and moved the Danger tab to the shared `ng-danger-zone`
  layout. No functional change; visual/typography
  consistency with the rest of the admin only.

### Behaviour notes

- **Effective rule for a user** = union of the user's legacy
  rows in `rules` (if any) plus every `policy_rule` in every
  policy the user is in. `FzWall.Server` doesn't care where
  each rule came from -- the merge happens above it.
- **Conflict semantics** carry over unchanged from the legacy
  model: nftables first-match wins inside each per-user chain.
  Ordering is by insertion order (same as `rules`).
- **Default action** on a policy is currently informational --
  the global fz_wall default (`drop`) still gates anything not
  matched by an explicit rule. Persisted so a future release
  can key per-user default off the policy without a schema
  change.

### Compatibility

- **No client change** -- clients see the same WG peer + config;
  rules apply server-side.
- **Legacy `rules` table untouched.** Migration is additive.
  Rows created in the admin UI's `/rules` page keep working.
- **Removal plan**: v4.0.0 auto-migrates remaining `rules`
  rows into a "legacy" policy, hides `/rules`, and drops the
  table after a release cycle. See `task.md` for the ordered
  removal steps.

---

## [3.2.3] - 2026-07-21

Fixes the "Windows A + Windows B collision" bug: two devices
enrolled by the same user used to fight over the tunnel because
`GET /api/v1/devices/me/config` always returned the
most-recently-enrolled row, ignoring which client was actually
asking. Whichever device signed in most recently hijacked the
other's config; the older device then couldn't reconnect
without pulling the newer's IP down (breaking WG routing for
both).

### Fixed

- **`GET /api/v1/devices/me/config` accepts optional
  `?device_id=<uuid>` query param.** Present: return that
  specific device, verify user ownership (403 `device_not_owned`
  if not). Absent: preserve pre-v3.2.3 "most-recent" behavior
  for backward compat with older clients.

- New `FzHttp.Devices.fetch_for_user_by_id/2` context helper
  with clean not-found / forbidden semantics.

### Client rollout required

Windows / macOS / Linux CLI clients each need a small matching
change to append `?device_id=<stored-uuid>` when calling
`me_config`. The `device_id` is already returned by
`/api/v1/devices/enroll` and persisted in every client's secure
store; just needs to be sent on the config fetch. Client
releases to follow.

### Compatibility

- Pre-v3.2.3 clients (don't send `device_id`): no behavior
  change.
- v3.2.3+ clients: send `device_id` and always get the right
  device, no more collisions between Windows A + B or Mac +
  Windows on the same user.

---

## [3.2.2] - 2026-07-20

Additive: native auth token responses now include
`session_expires_at` so native clients (macOS v0.5.7+) can detect
session expiry LOCALLY, without needing a live server call. Critical
when the tunnel is dead but the client still needs to sign the user
out cleanly (tunnel-DNS unreachable = any HTTP call to the server
URLErrors out, so the 401 that would normally trigger `forceReSignIn`
never surfaces).

Response JSON on `/api/v1/native/token` + `/api/v1/native/refresh`:

    "session_expires_at": "2026-07-21T05:00:16.497725Z"

ISO 8601 UTC timestamp = `user.last_signed_in_at + vpn_session_duration`.
Null when the org disabled session-based expiry, or when
`last_signed_in_at` is nil. Client's local expiry timer skips when
nil (fallback to existing paths: degraded-tunnel probe, refresh
timer 401, explicit user reconnect).

Zero DB migration; JSON-shape change only. Backward compatible --
older clients ignore the field.

---

## [3.2.1] - 2026-07-16

Silence `TLS handshake error from 127.0.0.1: EOF` log noise on
`nexguard-proxy`. Phoenix's HealthMonitor now probes the proxy's
plaintext observability port (`/readyz` on :9090) instead of the
TLS transparent listener (:8443). Improves signal quality --
`/readyz` returns 503 during bundle bootstrap + SIGTERM drain,
which the old TCP-connect probe missed.

Single-file change (`apps/fz_http/lib/fz_http/health_monitor.ex`).
No breaking changes.

---

## [3.2.0] - 2026-07-13

Additive telemetry release. One migration extends `devices` with
three nullable columns; no schema changes to existing columns, no
breaking API changes — older clients that don't send the new
headers keep working unchanged.

### Added

- **Host OS + CPU architecture telemetry on `devices`.** Three new
  nullable columns via migration `20260714000001_add_client_os_to_devices.exs`:

      client_os_name       ("macOS" | "Windows Server 2022 Datacenter" | "Ubuntu")
      client_os_version    ("14.3.1" | "10.0.20348" | "22.04")
      client_arch          ("arm64" | "x86_64" | "aarch64")

  Populated from new HTTP headers `X-NexGuard-Client-OS-Name` /
  `-OS-Version` / `-Arch` set by native clients on every authenticated
  request (macOS ≥ 0.4.0, Windows ≥ 0.4.0, Linux CLI ≥ 0.3.0).
  `Devices.record_client_info/2` now takes a map so the ingestion
  path handles all five telemetry fields uniformly.

  Admin UI:
  - Devices index — new secondary line under the Client column
    shows `<os_name> <os_version> · <arch>`. Primary line still
    reads `<platform> · <client_version>`.
  - Device details Client card — two new rows: **Operating System**
    (name + version) and **Architecture** (mono-formatted).

  Same best-effort ingestion policy as `client_version`: passive
  telemetry, DB failure is logged + swallowed so a telemetry write
  never breaks enroll / config flows.

### Docs

- README gains a **NexGuard Connect (VPN client)** section with the
  cross-platform one-liner installers (`install.sh` for macOS/Linux,
  `install.ps1` for Windows) hosted in the [`nexguard-releases`](https://github.com/0xphuong/nexguard-releases)
  repo. Scripts fetch `versions.json`, verify SHA-256, and (on
  macOS) strip the Gatekeeper `com.apple.quarantine` attribute
  automatically.

---

## [3.1.0] - 2026-07-03

Two feature adds serving the native clients. No breaking API
changes; older Windows / macOS clients continue to work unchanged.

### Added

- **Client identity telemetry on `devices`.** New nullable columns
  `client_platform`, `client_version`, `client_last_seen_at` on the
  `devices` table. Populated from the `X-NexGuard-Client-Platform`
  + `X-NexGuard-Client-Version` headers native clients now send on
  every `enroll` / `me_config` request. Admin device list gets a
  new **Client** column; device detail page gets a new **Client**
  section (Platform / Version / Last Reported). Passive telemetry
  only -- no enforcement.
- **RFC 8252 §7.3 loopback redirect_uri support** on
  `POST /auth/native/begin`. Accepts
  `http://127.0.0.1:*/callback`, `http://localhost:*/callback`,
  and `http://[::1]:*/callback` in addition to the custom
  `nexguard-connect://callback` scheme macOS uses. Unblocks
  Windows WebView2 OAuth without any custom URL scheme
  registration. External `http://` URLs are still rejected as a
  CSRF guard.

### Client pairing

  * Windows: 0.1.8+ (sends the identity headers, uses loopback OAuth)
  * macOS: 0.0.12+ (sends the identity headers)

---

## [3.0.0 - 3.0.9]

Multiple releases between 2.2.0 and 3.0.10 not mirrored here (portal
UX overhauls, dashboard refinements, WebSocket-based device status,
L7 proxy activation, mTLS internal CA, admin filter bars, etc.). See
the source-repo CHANGELOG in
[`0xphuong/nexguard`](https://github.com/0xphuong/nexguard/blob/main/CHANGELOG.md)
for the per-release breakdown.

---

## [2.2.0] - 2026-06-21

L7 ZTNA Phase 1 — admin data + UI surface for the upcoming layer-7
transparent proxy (see `docs/decisions.md` ADR-007 → ADR-014). The
proxy itself (CoreDNS + Go binary + smallstep) ships in L7-B → L7-F
across later releases; this release lands the database, contexts, and
admin tooling that those data-plane pieces will read from. **No
runtime behaviour change for end users on 2.2.0** — the L7 subsystem
ships dormant until the org-level toggle is flipped AND the proxy
binaries are deployed (planned for v3.0.0).

### Added

#### Data model (Phase 1 — DB schema)

Six additive migrations (`20260620000001` → `20260620000006`), safe
to apply on a running production. See
[`docs/migrations/v2.2.0.md`](docs/migrations/v2.2.0.md) for the
runbook.

- **`access_groups`** — manual / IdP-synced groups that gate L7-app
  reachability (ADR-014).
- **`user_group_memberships`** — composite-PK M:N join with provenance
  (`source: manual | idp_sync`) so a SCIM reconciliation job can leave
  manual memberships alone.
- **`applications`** — NEW table for L7-managed apps. Columns:
  `hostname` (unique, RFC 1035 validated), `virtual_ip` (`inet`,
  unique inside `10.99.0.0/16`), `backend`, `cert_source` enum
  (`upload | step_ca`), `cert_pem`, `key_pem` (Cloak-encrypted at
  rest), `tls_mode` (`terminate | passthrough`, passthrough deferred
  to v2), `l7_rules` (`jsonb`), `enabled`.
- **`application_allowed_groups`** — composite-PK M:N between apps
  and groups (ADR-014 group intersection check).
- **`users.access_scope`** — break-glass bypass marker
  (`limited | all`, default `limited` per ADR-008).
- **`org_settings`** — singleton row (CHECK constraint enforces
  `id = 1`), seeded with `l7_enabled = false`. Kill switch per
  ADR-014.

#### Elixir context layer (Phase 2)

- `FzHttp.AccessGroups` — CRUD + member add/remove + identity-API
  + bundle readers (`list_groups_for_user/1`,
  `list_groups_with_members/0`).
- `FzHttp.Applications` — CRUD with **in-transaction VIP allocation**
  so concurrent admin requests can't collide on the same VIP; M:N
  allowed-groups; per-mutation PubSub on `nexguard:l7:apps`.
- `FzHttp.OrgSettings` — singleton get/toggle + PubSub on
  `nexguard:l7:settings`. No-op detection skips audit + broadcast on
  identical writes.
- `FzHttp.L7.VipAllocator` — first-free scan over
  `10.99.0.1` → `10.99.255.254` with a Postgres advisory lock so two
  concurrent `create_application` requests serialise.
- New authorizers: `FzHttp.AccessGroups.Authorizer`,
  `FzHttp.Applications.Authorizer`, `FzHttp.OrgSettings.Authorizer` —
  admin-only; unprivileged subjects see nothing. All three registered
  in `FzHttp.Auth.Roles.list_authorizers/0`.

#### Admin UI (Phase 3)

- **`/access-groups`** — list (with stats strip), create-via-modal,
  detail page with inline edit, member roster, danger-zone delete.
- **`/users/:id`** — two new cards on the existing user detail page:
  - **Group Memberships** — add-to-group dropdown of unlinked groups,
    table of current memberships with link back to each group's
    detail page, styled-modal remove.
  - **L7 Access Scope** — `limited` / `all` badge in the header,
    single-button toggle with a styled break-glass confirmation modal
    showing before → after badge transition.
- **`/applications`** — list with stats strip + delete via styled
  modal.
- **`/applications/new`** + **`/applications/:id`** +
  **`/applications/:id/edit`** — full form: name, description,
  hostname (RFC 1035 live-validated), backend URL,
  card-style cert source picker, conditional cert + key PEM textareas
  with inline X.509 preview (Subject, SANs, expiry) when the PEM
  parses; Show page with hero, Routing card, L7 Rules row editor
  (action / methods as pill checkboxes / path_prefix / require_groups
  / require_mfa_age + up/down reorder + implicit-deny indicator
  pinned at the bottom), Allowed Groups picker, danger zone with
  Enable/Disable + Delete.
- **`/settings/l7`** — org kill switch. Status banner listing
  enabled-apps count + VIP subnet + TPROXY port when active.
  Confirmation modals with concrete bullet lists for both directions.
- All destructive actions (group delete, member remove, app delete,
  access-scope flip, L7 toggle) use the canonical
  `modal-card` + `ng-modal-*` Bulma pattern instead of browser
  `confirm()` dialogs.

#### Tests

- `test/fz_http/access_groups_test.exs`,
  `test/fz_http/applications_test.exs`,
  `test/fz_http/l7/vip_allocator_test.exs`,
  `test/fz_http/org_settings_test.exs` — context-layer coverage
  (~590 LOC).
- `test/fz_http_web/live/{access_groups_live,applications_live,setting_live,user_live}/...` —
  4 LiveView test files covering happy-path + critical validation +
  styled-modal flows.

### Dependencies

- `{:x509, "~> 0.8"}` — parses uploaded cert PEMs so the changeset can
  refuse a cert whose SAN/CN doesn't cover the declared hostname.

### Notes

- **L7 enforcement is dormant after this release.** The
  `org_settings.l7_enabled` toggle defaults to `false`; flipping it
  on doesn't break anything because the data plane (CoreDNS + L7
  proxy + step-ca) is not deployed yet — those land in L7-B → L7-F.
- The `key_pem` column stores Cloak-encrypted ciphertext; the
  `FzHttp.Vault` config must be set in your prod env if you intend to
  use the `upload` cert source. The `step_ca` path doesn't touch
  the column.

---

## [2.1.1] - 2026-06-19

Admin-facing notifications for the device approval workflow. The
in-portal notification system existed (badge + Notifications page) but
was only ever fired for VPN config-sync errors. Now it surfaces the
event admins actually need to act on: a self-enrolled device sitting
in `pending` state waiting for them.

### Added

- **Pending-device notification** fires from
  `Devices.find_or_create_for_user/3` when a new native enrollment
  lands in `pending`. The Notifications GenServer broadcasts via
  PubSub, so the navbar badge + Notifications page light up in real
  time — no refresh needed. Payload carries `device_id` so subsequent
  state changes can target it precisely
  (`apps/fz_http/lib/fz_http/devices.ex`,
  `apps/fz_http/lib/fz_http/notifications.ex`).
- **`Notifications.clear_for_device/1`** API + GenServer handler.
  Clears every notification whose payload has `device_id == id`.
- **`:warning` and `:info` icon variants** on the Notifications page
  (`apps/fz_http/lib/fz_http_web/live/notifications_live/index_live.ex`).
  CSS classes `ng-notif-icon--warning` / `--info` were already in
  `main.scss` from prior design work, so no styling change needed.

### Changed

- **`Devices.approve_device/3`** now calls
  `Notifications.clear_for_device/1` after the status transitions to
  approved — the pending banner disappears from the admin's list
  without a manual dismiss.
- **`Devices.revoke_approval/3`** fires a fresh pending-approval
  notification when an admin demotes an already-approved device. The
  text differs slightly ("was revoked and is back to pending
  approval") so the admin sees this is a re-arm, not a duplicate of
  the original enrollment.
- **`Devices.delete_device/3`** clears any pending notification for
  the deleted device — a stale "pending approval" banner for a row
  that no longer exists would be a UI bug.

### Notes

- Notifications are still in-memory only (GenServer state). They are
  wiped on app restart — consistent with the existing behavior of the
  notification subsystem. Persistence is a separate concern.
- Future polish (deferred): email / webhook out when a pending device
  appears, for teams where admins don't sit in the portal all day.

---

## [2.1.0] - 2026-06-14

Admin-facing controls for native devices: per-device IP override and explicit
approval workflow before a self-enrolled device can connect.

### Added

- **Admin IP override**. Admin can change a device's tunnel IPv4/IPv6 from the
  device detail page. New `Devices.admin_update_device/4` runs the existing
  CIDR / exclusion / uniqueness validation, calls `Events.set_config/0` to
  resync the running WG peer list immediately, and audits the change. UI shows
  a "Network Configuration" card on the device detail page (admin only) with
  inline edit form + post-save banner reminding the admin that the user must
  sign out and sign in on the NexGuard Connect client to pick up the new
  address locally (`apps/fz_http/lib/fz_http/devices.ex`,
  `apps/fz_http/lib/fz_http/devices/device/changeset.ex`,
  `apps/fz_http/lib/fz_http_web/templates/shared/show_device.html.heex`,
  `apps/fz_http/lib/fz_http_web/live/device_live/admin/show_live.ex`).
- **Device approval workflow**. New native-client enrollments arrive with
  `status="pending"` and are excluded from the WG peer list (`Device.Query.only_active/1`)
  until an admin clicks "Approve Device" in the portal. Pattern matches
  Tailscale's "approve new device" gate. Existing devices created before this
  feature default to `"approved"` (migration default), so no disruption to
  current users; admin-created devices via the portal also default to
  `"approved"` since the admin act IS the approval (only self-enrolled native
  clients start pending).
  - `POST /api/v1/devices/enroll` and `GET /api/v1/devices/me/config`
    responses now carry a `status` field so clients can show a "Pending
    Approval" screen instead of trying to connect.
  - `Devices.approve_device/3` and `Devices.revoke_approval/3` — admin-only,
    update status + stamp `approved_at` + `approved_by_id`, trigger
    `Events.set_config/0` to push the WG kernel update, and audit.
  - Portal UI: status badge per device on the index list, plus an "Approval"
    card on the device detail page with NexGuard-styled confirmation modals
    (no browser-native `window.confirm` — matches the existing delete-device
    modal pattern).
- **Audit log actions**: `device.ip.change`, `device.approve`,
  `device.revoke_approval`. The IP-change audit metadata carries `old_ipv4` /
  `new_ipv4` for forensic.

### Changed

- `Device.Query.only_active/1` now filters by `status == "approved"` in
  addition to user-session and MFA checks. Pending devices are silently
  excluded from the WG peer list — no special handling needed at the tunnel
  level (cryptokey routing rejects them automatically since the peer doesn't
  exist on the kernel interface).

[2.1.0]: https://github.com/0xphuong/NexGuard/compare/v2.0.1...v2.1.0

---

## [2.0.1] - 2026-06-14

MFA support for the native client auth flow introduced in 2.0.0.

### Added

- **MFA challenge for native sign-in**. When a user with at least one
  registered MFA method completes the OIDC step of the native flow,
  `do_sign_in/3` now redirects through the existing web MFA LiveView
  (`/mfa/auth/<last-used-method-id>`) instead of issuing the one-time code
  immediately. After the TOTP verifies, the LiveView redirects to a new
  `GET /auth/native/finalize` controller action which reads the deferred
  `:native_flow` session, creates the auth code, drops the browser session,
  and redirects to `nexguard-connect://callback`. Native clients reuse the
  portal's MFA UI — no native MFA UI required
  (`apps/fz_http/lib/fz_http_web/controllers/auth_controller.ex`,
  `apps/fz_http/lib/fz_http_web/live/mfa_live/auth_live.ex`,
  `apps/fz_http/lib/fz_http_web/router.ex`).
- **`FzHttp.Auth.MFA.has_methods?/1`** helper — quick existence check used by
  the native-flow MFA branch (`apps/fz_http/lib/fz_http/auth/mfa.ex`).

### Notes

- VPN session timer starts only after MFA passes (matches portal behavior):
  `Users.update_last_signed_in/2` is called in the MFA verify handler when
  `require_mfa` is enabled, so the 24-hour native-client refresh window is
  anchored on the MFA moment, not the OIDC moment.
- Native clients did not have to change — server still hands them a one-time
  code at the same `nexguard-connect://callback` URL after MFA.

[2.0.1]: https://github.com/0xphuong/NexGuard/compare/v2.0.0...v2.0.1

---

## [1.3.4] - 2026-06-10

### Fixed

- **Last Handshake shows "Thu, Jan 1, 1970, 8:00 AM" for devices that lost VPN auth** — root cause: WireGuard's `wg show dump` returns `latest_handshake = 0` for peers that have never completed a handshake (e.g. immediately after a peer is re-added when a user re-authenticates). `StatsUpdater.latest_handshake/1` converted the `"0"` string to `DateTime.from_unix!(0)` = `~U[1970-01-01T00:00:00Z]` and `StatsUpdater.update/1` wrote that value into `devices.latest_handshake`, overwriting any previously valid timestamp. If the user's session expired before the next real handshake, the 1970 value stuck in the DB and rendered in UI as "Thu, Jan 1, 1970, 8:00 AM" (UTC+8 / UTC+7 formatting of epoch 0). Four-part fix:
  - `StatsUpdater.latest_handshake("0")` now returns `nil` and the caller skips updating the field, preserving the previous good value (`apps/fz_http/lib/fz_http/devices/stats_updater.ex`).
  - Added `Devices.has_handshaken?/1` helper that treats both `nil` and pre-2000 timestamps as "never connected", so the "Connected / Never connected" badge on the device detail page renders correctly even for legacy rows (`apps/fz_http/lib/fz_http/devices.ex`, `apps/fz_http/lib/fz_http_web/templates/shared/show_device.html.heex`).
  - Defensive guard in `FormatTimestamp` JS helper: any timestamp before year 2000 renders as "Never" (`apps/fz_http/assets/js/util.js`).
  - Migration `20260610000001_clear_epoch_zero_handshakes` clears any existing pre-2000 `latest_handshake` values to `NULL` on deploy.

[1.3.4]: https://github.com/0xphuong/NexGuard/compare/v1.3.3...v1.3.4

---

## [1.3.3] - 2026-06-02

### Fixed

- **Periodic HTTP 431 "Request Header Fields Too Large" requiring browser cache clear** — root cause: OIDC redirect set two one-time cookies (`fz_oidc_state`, `fz_pkce_code_verifier`) but never deleted them after the callback consumed them, in `do_sign_in/3`, on error paths, or on `sign_out`. Combined with a large session cookie (`_fz_http_key` carries the Google `id_token` ~2 KB plus Guardian JWT, base64+encryption overhead → ~4–5 KB) and Cowboy's default `max_header_value_length: 4096`, browsers eventually built a Cookie header that exceeded the limit. Three-part fix:
  - Added `delete_cookie/1` to `FzHttpWeb.OIDC.State` and `FzHttpWeb.OAuth.PKCE`; called from every OIDC exit point — `oidc_callback` success (via `do_sign_in`), `oidc_callback` error branches, and `Authentication.sign_out`.
  - Raised the Cowboy header limit defaults via `:phoenix_http_protocol_options` — `max_header_value_length: 16384`, `max_header_name_length: 256`, `max_headers: 100` — buying ~4× headroom on top of the cleanup.
  - Added `FzHttpWeb.Plug.CookieHygiene` to the `:browser` pipeline. On every non-OIDC-callback request it sends `Set-Cookie: ...; Max-Age=0` for the two transient cookies, force-cleaning any orphans already sitting in user browsers from earlier releases. No re-login required.

[1.3.3]: https://github.com/0xphuong/NexGuard/compare/v1.3.2...v1.3.3

---

## [1.3.2] - 2026-05-29

### Fixed

- **HTTP 500 when admin views user detail page for users with an OIDC connection** — `OIDCLive.ConnectionsTableComponent` template had three top-level elements (modal conditional + page header `<div>` + table wrap `<div>`), violating Phoenix LiveView's "stateful components must have a single static HTML tag at the root" rule; component now wrapped in a single root `<div>`. Symptom appeared non-deterministic — admin could open their own user and a subset of others, but 500'd on the rest — because the parent template at `user_live/show.html.heex:157` skips the component when `@connections == []`, masking the bug for users without an `oidc_connections` row (i.e., users whose Google login never returned a `refresh_token`)

[1.3.2]: https://github.com/0xphuong/NexGuard/compare/v1.3.1...v1.3.2

---

## [1.3.1] - 2026-05-28

### Changed

- **Add Device modal redesigned** — wider layout (640px), advanced WireGuard settings collapsed behind "Advanced settings" toggle (hidden by default); Yes/No radio pairs replaced with `ng-toggle` switches; advanced section expands inline without page scroll
- **Device config result redesigned** — after generating a config: green success banner, amber one-time-view warning, QR code and Download button side-by-side, dark config block with Copy button, Done link to close without X button

### Fixed

- **QR code squished after Generate Configuration** — canvas element was being compressed horizontally inside flex container due to `height: auto` not maintaining aspect ratio on `<canvas>`; fixed with explicit `width: 140px; height: 140px; flex-shrink: 0`
- **"Save" text not centered in modal buttons** (Add Token, Add MFA Method, Add User) — `submit()` helper generated `<input type="submit">` which ignores `display: inline-flex; align-items: center` (no child nodes); replaced with `<button type="submit">` across all modals via shared `submit_button.html.heex`
- **Spinner icon** on config generation was using deprecated Font Awesome class (`fa fa-spinner fa-spin`); replaced with MDI (`mdi mdi-loading mdi-spin`) to match the rest of the design system

[Unreleased]: https://github.com/0xphuong/NexGuard/compare/v1.3.4...HEAD
[1.3.1]: https://github.com/0xphuong/NexGuard/compare/v1.3.0...v1.3.1

---

## [1.3.0] - 2026-05-27

### Added

- **Immutable Audit Log** — new `/settings/audit_log` page records every security-relevant event with actor, action, result, target, IP address, and timestamp; events are append-only (no edit or delete from UI/API)
- **Audit event coverage** — the following event types are captured:

  | Category | Events |
  |---|---|
  | Authentication | `auth.login`, `auth.logout`, `auth.login_failure`, `auth.mfa_success`, `auth.mfa_failure` |
  | Users | `user.create`, `user.update`, `user.delete`, `user.enable`, `user.disable` |
  | Devices | `device.create`, `device.delete` |
  | Rules | `rule.create`, `rule.update`, `rule.delete` |
  | Config | `config.change` |

- **Actor & IP tracking** — all events record the actor email and the originating IP address; events triggered via the REST API use the request IP; LiveView events use the WebSocket remote IP; system events (e.g. auto-expiry) log without actor
- **Target field** — events reference the affected object by type and label (e.g. `user: admin@corp.com`, `device: laptop`, `configuration: system`)
- **Configurable retention policy** — default 90 days; adjustable from 1 to 3650 days directly from the Audit Log settings page; backed by the `configurations` DB table (env var `AUDIT_LOG_RETENTION_DAYS` overrides and locks the UI field)
- **Daily purge** — `FzHttp.AuditLog.RetentionScheduler` GenServer runs once per day and deletes entries older than the configured retention window; reads the live DB value so changes take effect without a restart
- **Filterable log view** — filter by event category (Auth / Users / Config / Devices / Rules) and result (Success / Failure); shows "Showing N of M events" count when a filter is active
- **Paginated table** — 50 events per page with Prev / Next navigation; timestamps formatted client-side to local timezone via `FormatTimestamp` LiveView hook
- New `audit_logs` table (migration `20260527000001`) with `action`, `actor_id`, `actor_email`, `ip_address`, `result`, `target_type`, `target_id`, `target_label`, `metadata` (JSONB), `inserted_at`
- New `audit_log_retention_days` integer column in `configurations` table (migration `20260527000002`), default 90

### UI

- Audit Log page: dense log-console layout — color-coded action badges per category, success/failure icon-only result column, muted type prefix on target column, row hover highlight for cross-column scanning
- Retention Policy panel at bottom of page with explicit input + Save button (replaces previous hidden inline badge form)
- Page header shows read-only `N-day retention` and total event count badges
- Sidebar: **Audit Log** entry added under Settings

[1.3.0]: https://github.com/0xphuong/NexGuard/compare/v1.2.3...v1.3.0

---

## [1.2.3] - 2026-05-27

### Changed
- **Replaced all `data-confirm` (browser native dialogs) with styled LiveView modals** across the entire admin UI — all destructive and role-changing actions now use consistent `modal-card` modals matching the `ng-*` design system; each modal shows the target object (email, device name, provider label, token ID) in a monospace block, lists specific consequences, and supports Escape-to-close and backdrop-click-to-close
- **Refresh Tokens** (OIDC Connections table): removed `data-confirm` entirely — non-destructive action does not require confirmation

### Fixed
- **Delete Your Account** was submitting to `DELETE /sign_out` (session logout only) instead of `DELETE /user` (account deletion) — form action corrected; account is now actually deleted when confirmed

### UI — Modals added

| Action | Location | Pattern |
|---|---|---|
| Delete User | User Detail page | Parent LiveView modal |
| Promote / Demote User | User Detail page | Parent LiveView modal with role transition display (`current → new`) |
| Disable VPN Connection | User Detail page | `VPNConnectionComponent` internal modal — confirm only on disable, enable executes immediately |
| Delete Device | Device Detail page (admin + unprivileged) | Shared template modal, both LiveViews wired |
| Delete OIDC Provider | Security Settings | Single shared modal driven by `pending_delete` assign; title adapts to OIDC vs SAML |
| Delete SAML Provider | Security Settings | (same modal as above) |
| Delete Your Account | Account Settings | Modal gates the form submit to `DELETE /user` |
| Delete MFA Authenticator | Account Settings (admin + unprivileged) | Shared template button, modal in each parent template |
| Delete API Token | Account Settings | Parent LiveView modal showing full token UUID |
| Delete OIDC Connection | User Detail → OIDC Connections | `ConnectionsTableComponent` internal modal with provider-specific warning |

---

## [1.2.2] - 2026-05-27

### Added
- **Security Dashboard Panel** — new two-column layout on the main dashboard; left column displays a Security panel with six live-updated rows: MFA Coverage (percentage of users enrolled), Admin Accounts, Stale Devices (no handshake in 7+ days), VPN Session Duration, Authentication Methods (OIDC / SAML provider counts), and WAN Connectivity status

### Changed
- **VPN session timer starts from MFA completion** — when Force MFA (`require_mfa`) is enabled, `last_signed_in_at` is now set only after the user successfully completes MFA (not at password entry); when Force MFA is disabled the behaviour is unchanged (timer starts at password login)
- `Device.Query.only_active/1`: MFA-aware peer filtering — when `require_mfa` is on and `last_signed_in_at IS NULL` (user never completed MFA), the device is excluded from the WireGuard peer list regardless of `vpn_session_duration`; when `require_mfa` is on and sessions expire, a non-nil `last_signed_in_at` is required in addition to the expiry window check
- `Users.vpn_session_expired?/1`: returns `true` for users with `last_signed_in_at = nil` when `require_mfa` is on, so the VPN Status badge on the User Detail page correctly shows **Expired** instead of **Enabled** for users who have never completed MFA

### Fixed
- **WAN Connectivity badge** always showing "Disabled" when no checks were recorded — `list_connectivity_checks/0` returns a plain list (not `{:ok, list}`); corrected pattern match in dashboard assigns
- **MFA method ownership check** — `MFALive.Auth.handle_params/3` now validates that the requested MFA method belongs to the current user; previously any authenticated user could authenticate with another user's MFA method ID; mismatched ownership now redirects to `/` identical to a not-found result
- Admin-created devices for users who have never signed in no longer connect to VPN when Force MFA is enabled — the `only_active/1` fix above closes this gap

---

## [1.2.1] - 2026-05-26

### Added
- **Preserve Client IP / Internal Subnets UI** — `GATEWAY_NO_MASQUERADE_CIDRS` is now fully configurable from the **Network** settings page (new dedicated page separate from Client Defaults); toggle "Preserve Client IP" to enable no-NAT mode, with a textarea to customise the internal subnets (defaults: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`); changes hot-reload the nftables postrouting chain without restart
- New `gateway_no_masquerade_enabled` boolean column and `gateway_no_masquerade_cidrs` text column in the `configurations` table (migration `20260525000002`)
- When `GATEWAY_NO_MASQUERADE_ENABLED` or `GATEWAY_NO_MASQUERADE_CIDRS` env vars are set, the corresponding UI fields are locked with a clear "Locked by env var" badge and explanation
- `FzWall.Server.reload_masquerade/0` — GenServer call that flushes and rebuilds only the nftables `postrouting` chain from the current DB config value

### Changed
- Moved Preserve Client IP and Internal Subnets settings from Client Defaults to the new **Network** page (`/settings/network`) — these are server-side gateway/NAT settings, not WireGuard client defaults
- `fz_wall/nft.ex`: masquerade rules now read live from `FzHttp.Config.fetch_config!` at reload time instead of frozen boot-time Application env
- `runtime.exs`: removed `no_masquerade_cidrs` from `:fz_wall` app env (now read live from `FzHttp.Config`)

### UI
- Complete `ng-*` design system migration across all admin modal forms: OIDC, SAML, Add Device, Add API Token, MFA registration, Edit User, Show API Token
- New form component CSS: `ng-field`, `ng-label`, `ng-input`, `ng-textarea`, `ng-field-error`, `ng-field-hint`, `ng-input-group`, `ng-input-suffix`, `ng-toggle-row`, `ng-radio`, `ng-radio-group`
- Replaced all Bulma flash notifications with `ng-flash` / `ng-flash--info` / `ng-flash--error` components
- Replaced all `switch is-medium` toggles with `ng-toggle` across Security, OIDC, SAML, VPN connection components
- OIDC Connections table migrated to `ng-table` / `ng-secondary-btn` / `ng-danger-btn`
- `.is-main-section` given explicit `padding: 1.5rem` so page content is not Bulma-dependent

### Fixed
- `show_api_token_component`: removed Bulma `level`, `title is-6`, `button`, `block` — now uses `ng-label`, `ng-secondary-btn`, `ng-flash--info`, `ng-inline-link`
- Edit User modal form: replaced `field`/`control`/`label`/`help is-danger` with `ng-field`/`ng-label`/`ng-input`/`ng-field-error`

---

## [1.2.0] - 2026-05-25

### Added
- **No-NAT Subnets UI** — `GATEWAY_NO_MASQUERADE_CIDRS` is now configurable from the admin panel (Client Defaults → No-NAT Subnets) in addition to the environment variable; changes take effect immediately without a restart via a hot-reload that flushes and rebuilds only the nftables `postrouting` chain
- New `gateway_no_masquerade_cidrs` text column in the `configurations` table (migration `20260525000002`); env var continues to work as an override and locks the UI field when set
- `FzWall.Server.reload_masquerade/0` — new GenServer call that flushes the postrouting chain and re-applies RETURN + masquerade rules from the current database value

### Changed
- `fz_wall/nft.ex`: `setup_no_masquerade_rules/0` now reads `FzHttp.Config.fetch_config!(:gateway_no_masquerade_cidrs)` at runtime instead of the frozen `Application.fetch_env!` value set at boot; `reload_postrouting/0` added for hot-reload
- `runtime.exs`: removed `no_masquerade_cidrs` from the `:fz_wall` application env block (value is now read live from `FzHttp.Config`)

---

## [1.1.2] - 2026-05-25

### Added
- **Force MFA** global toggle in Security settings: when enabled, all users without an MFA method are redirected to the enrollment page on next sign-in and blocked from the REST API (`/v0`) until they enroll
- New `require_mfa` boolean column in the `configurations` table (migration `20260525000001`)
- New plug `FzHttpWeb.Plug.RequireMFA` added to the `:api` pipeline — returns `403` with a JSON error when Force MFA is on and the API user has no MFA method registered

### Changed
- `LiveMFA` hook: when Force MFA is enabled and a user has no MFA methods, redirects admin to `/settings/account/register_mfa` and unprivileged users to `/user_account/register_mfa` instead of continuing; MFA registration routes are excluded from enforcement to prevent redirect loops
- Redesigned MFA verification screen (`/mfa/auth/:id`): `auth-card` layout matching the login page, monospace OTP input with `one-time-code` autocomplete, "Use a different authenticator" back link
- Redesigned MFA method selector screen (`/mfa/types`): `auth-card` layout, each method displayed as an `auth-provider-btn` card consistent with the SSO provider buttons on the login page

---

## [1.1.1] - 2026-05-25

### Changed
- Redesigned User Detail page (`/users/:id`): page header with avatar, role badge, VPN status; profile and devices in card layout; danger zone with proper labels and descriptions
- Redesigned Device Detail page (`/devices/:id`, `/user_devices/:id`): page header with connection status badge; transfer stats (Received / Sent / Latest Handshake); details grouped into Network and WireGuard Configuration cards; danger zone
- Redesigned unprivileged Devices page (`/user_devices`): consistent page header with Add Device button; VPN Session card replacing the old inline level layout
- Breadcrumb on Device Detail is now context-aware: admin sees user email link, unprivileged user sees "My Devices" link
- `README.md`: updated Quick Start commands; added tip for resetting admin manually with `bin/create-or-reset-admin`
- `CHANGELOG.md`: added standard changelog following Keep a Changelog format

### Fixed
- `WIREGUARD_IPV4_ADDRESS` in `.env.example` documented as plain IP, not CIDR
- `PHOENIX_HTTP_PORT` corrected (was `PHOENIX_PORT`); `OUTBOUND_EMAIL_ADAPTER` corrected (was legacy `OUTBOUND_EMAIL_PROVIDER`)

---

## [1.1.0] - 2026-05-25

### Added
- Full NexGuard branding applied to admin UI, web manifest, and omnibus packages
- Proper `.env.example` with all supported environment variables documented

### Changed
- Admin UI redesigned: login page, main dashboard, navbar, sidebar menu
- Redesigned pages: Users, Devices, Rules, Settings (Security, Config, Account, Notifications, Customization)
- Omnibus cookbook and packaging migrated to `nexguard` namespace

---

## [1.0.2] - 2026-05-25

### Fixed
- Connectivity check configuration not applying correctly on fresh installs

---

## [1.0.1] - 2026-05-24

### Fixed
- Login page UI rendering incorrectly on certain screen sizes

---

## [1.0.0] - 2026-05-24

### Added
- Self-hosted VPN server built on WireGuard® and nftables (forked from Firezone 0.7)
- Web admin UI for managing users, devices, and egress firewall rules
- SSO support via OpenID Connect (OIDC) and SAML 2.0
- Per-user and global egress rules using Linux nftables
- Docker Compose and Omnibus package deployment methods
- REST API for programmatic management
- Multi-factor authentication support
- Connectivity checks and telemetry (opt-out supported)
- Automatic TLS via Caddy reverse proxy

[1.2.3]: https://github.com/0xphuong/NexGuard/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/0xphuong/NexGuard/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/0xphuong/NexGuard/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/0xphuong/NexGuard/compare/v1.1.2...v1.2.0
[1.1.2]: https://github.com/0xphuong/NexGuard/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/0xphuong/NexGuard/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/0xphuong/NexGuard/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/0xphuong/NexGuard/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/0xphuong/NexGuard/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/0xphuong/NexGuard/releases/tag/v1.0.0
