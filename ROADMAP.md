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
- [ ] Background sweep while the app is closed (needs BGTaskScheduler / a login item)

## Phase 3: Backend (deferred at the owner's instruction; see docs/backend-plan.md)

- [ ] Choose a backend (see ARCHITECTURE.md), authentication, roles, audit log
- [ ] `RemoteInventoryStore`, migrating local data up
- [ ] Integration credentials move server-side

## Phase 4: Stores

- [x] Store listings screens and the public App Store lookup refresh (no credentials)
- [ ] App Store Connect API (read-only status). Needs an API key (.p8) from the owner.
- [ ] Google Play Developer API (read-only status). Needs a service account from the owner.

## Phase 5: Marketing

- [x] Content calendar, drafts, approval workflow (idea → draft → review → approved → scheduled → published, recorded by hand)
- [ ] Publishing to social networks, gated by per-post approval

## Phase 6: Intelligence

- [x] Market intelligence source → evidence → finding register with enforced citation rules
- [ ] Collectors for specific sources (after the terms of use are checked)
- [x] AI assistant with verified/derived/unknown labelling (local engine, no language model)
- [ ] Optional language model for phrasing, restating grounded statements only (needs a provider key)

## Clients

- [x] iOS/iPadOS from the same target (builds for the Simulator; device install needs a provisioning run in Xcode)
- [x] Notarised macOS release (tools/release/build-release.sh; first build accepted 2026-09-23)
- Web client: not planned for now (owner: Mac + iOS)
