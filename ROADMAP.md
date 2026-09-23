# Command Center Roadmap

This is the roadmap for the Command Center itself. Product roadmaps live inside
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
- [ ] Owner answers the questions in docs/product-discovery-report.md

## Phase 2: GitHub (read-only) (done except local status)

- [x] GitHub token in Keychain via Settings → Integrations
- [x] Read-only sync: default branch, last commit, open PRs/issues, latest release, CI status
- [ ] Local working-copy status (branch, uncommitted changes), reading only. Needs a security-scoped folder bookmark in the sandbox.

## Phase 3: Backend

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
- [ ] AI assistant with verified/derived/unknown labelling

## Later clients

- [ ] iOS/iPadOS client reusing LinumicCore
- [ ] Web client on the backend API
