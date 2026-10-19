# Linumic OS Roadmap

This is the roadmap for Linumic OS itself. Product roadmaps live inside
the app.

## Phase 1: MVP foundation (in progress)

- [x] Independent repo, docs, security architecture
- [x] `LinumicCore` domain model + tests
- [x] Local JSON persistence behind `InventoryStore`
- [x] Seed inventory with verified facts only
- [x] macOS app: sidebar navigation, dashboard, product list/detail/edit
- [x] Manual version, release, repository and roadmap records
- [x] Keychain `SecretStore`, `RepositoryHostClient` interface
- [x] Verified product inventory: evidence model, discovery report, verification UI
- [x] Owner answered the main questions (2026-09-23); a few remain in docs/product-discovery-report.md

## Phase 2: GitHub (read-only) (done except local status)

- [x] GitHub token in Keychain via Settings → Integrations
- [x] Read-only sync: default branch, last commit, open PRs/issues, latest release, CI status
- [x] Local working-copy status (branch, uncommitted changes), reading only, via a security-scoped folder bookmark. Done in Oversight Increment 2.

## Phase 2.5: Project oversight ("from 0 to 100")

- [x] Oversight screen + live dashboard card over every repository, not just linked products
- [x] Discovery of all owned repositories from GitHub (`OversightSync`), read-only
- [x] Per-repo security posture: Dependabot / secret-scanning / code-scanning alerts + default-branch protection, each best-effort (Unknown when unreadable, never a false zero)
- [x] 0–100 fleet-health score and per-repo health roll-up (`OversightSummary`)
- [x] Local `.git` scan via a security-scoped bookmark: current branch, tip-vs-remote divergence, and exact uncommitted-tracked-file count by blob SHA (Increment 2; the app is sandboxed so it parses `.git` directly rather than running git)
- [x] Periodic oversight sweep (launch + every 30 min while open) and change alerts with local notifications (Increment 3)
- [x] Background sweep while the window is closed: the automation engine keeps every job running behind the menu bar, opens at login, and uses iOS background refresh (PR #13, merged 2026-10-19; docs/automation.md)

## Platform control (manage every Linumic platform from Linumic OS)

- [x] Phase 1: licence centre for MediFlow and KhayatYar: issue, renew, void, ledger on Supabase, signing keys in the Mac Keychain, expiry reminders (2026-10-09, PR "Platform control, phase 1")
- [x] Phase 2: platforms hub: version on main, latest release and downloads, CI per workflow, open PRs, store versions, drift flags, business model and links for 9 products (2026-10-09, PR "Platform control, phase 2")
- [x] Phase 3: WorkTrack customers and renewals: vendor sign-in, companies, detail, orders, revenue, audit, licence renewal with diff and confirmation, reminders (2026-10-09, PR "Platform control, phase 3"; tested on the local emulator only)
- [x] Phase 4: Operations: Talar, SafeBeauty and VELRO admin overview (queues, details, settlements/payouts, trips, network, commissions read only), Talar hall approve/reject (audited by Talar), "Waiting for you" dashboard card, queue notifications (2026-10-09, PR "Platform control, phase 4"; tested on local emulators and a local VELRO backend only)
- [ ] Operations writes, after the product fixes: SafeBeauty audited callables for provider approval and platform config; Talar idempotent settlements; VELRO staging (research/platform-admin-apis.md §7)
- [ ] WorkTrack: sync the local action log to Supabase; TEST / DUPLICATE marks from the app

## Phase 3: Backend (Supabase; see docs/backend-plan.md)

- [x] Backend chosen (Supabase, 2026-09-23), Sign in with Apple, admins (`app_admins`) and an append-only audit log
- [x] `RemoteInventoryStore` behind `HybridInventoryStore` (2026-09-23; the first sync uploads the local data), the licence
  ledger (2026-10-09) and the oversight register (2026-10-09) in the cloud
- [x] Server-side checks while the Mac is off: the Sentinel (deployed 2026-10-19; docs/sentinel.md)
- [ ] Integration credentials move server-side (they are still in this device's Keychain)

## Phase 4: Stores

- [x] Store listings screens and the public App Store lookup refresh (no credentials)
- [x] App Store Connect API (read-only status): the owner's key connected 2026-09-23; versions, builds and review
  state in the Release Center (2026-10-09)
- [x] Google Play Developer API (read-only status): the owner's service account connected 2026-09-23; tracks and
  rollouts in the Release Center through an edit that is never committed (2026-10-09)

## Phase 5: Marketing

- [x] Content calendar, drafts, approval workflow (idea → draft → review → approved → scheduled → published, recorded by hand)
- [ ] Publishing to social networks, gated by per-post approval

## Phase 6: Intelligence

- [x] Market intelligence source → evidence → finding register with enforced citation rules
- [ ] Collectors for specific sources (after the terms of use are checked)
- [x] AI assistant with verified/derived/unknown labelling (local engine, no language model)
- [ ] Optional language model for phrasing, restating grounded statements only (needs a provider key)

## Company OS (docs/company-os-roadmap.md)

- [x] Phase 1: the Desk and the ledgers (PR #21, merged 2026-10-19)
- [ ] Phase 2: obligations and accounts, the encrypted continuity export, the daily backup counted from `Backups/`
  (built; the owner's steps are in the pull request)
- [ ] Phases 3 to 6: sync and reminders with the Mac off, money, sales, legal and marketing

## Clients

- [x] iOS/iPadOS from the same target (builds for the Simulator; device install needs a provisioning run in Xcode)
- [x] Notarised macOS release (tools/release/build-release.sh; first build accepted 2026-09-23)
- Web client: not planned for now (owner: Mac + iOS)
