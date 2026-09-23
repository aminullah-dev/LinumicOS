# Command Center Roadmap

This is the roadmap for the Command Center itself. Product roadmaps live inside
the app.

## Phase 1: MVP foundation (in progress)

- [x] Independent repo, docs, security architecture
- [x] `LinumicCore` domain model + tests
- [x] Local JSON persistence behind `InventoryStore`
- [x] Seed inventory with verified facts only
- [ ] macOS app: sidebar navigation, dashboard, product list/detail/edit
- [ ] Manual version, release, repository and roadmap records
- [x] Keychain `SecretStore`, `RepositoryHostClient` interface
- [ ] Fill in the product facts marked UNKNOWN (owner: Linumic)

## Phase 2: GitHub (read-only)

- [ ] GitHub token in Keychain via Settings → Integrations
- [ ] Read-only sync: default branch, last commit, open PRs/issues, latest release, CI status
- [ ] Local working-copy status (branch, uncommitted changes), reading only

## Phase 3: Backend

- [ ] Choose a backend (see ARCHITECTURE.md), authentication, roles, audit log
- [ ] `RemoteInventoryStore`, migrating local data up
- [ ] Integration credentials move server-side

## Phase 4: Stores

- [ ] App Store Connect API (read-only status)
- [ ] Google Play Developer API (read-only status)

## Phase 5: Marketing

- [ ] Content calendar, drafts, approval workflow
- [ ] Publishing to social networks, gated by per-post approval

## Phase 6: Intelligence

- [ ] Market intelligence source registry (see docs/market-intelligence.md)
- [ ] AI assistant with verified/derived/unknown labelling

## Later clients

- [ ] iOS/iPadOS client reusing LinumicCore
- [ ] Web client on the backend API
