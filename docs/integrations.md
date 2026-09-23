# Integrations

**Connected:** GitHub (read-only). **Not connected:** everything else. Each one is added
only when explicit credentials and authorization are provided.

## Principles

- **Read-only first.** Every integration starts by reading data only. Writes
  (creating issues, submitting builds, publishing posts) come later, each one
  confirmed by a person.
- **Snapshots with provenance.** Integration data is stored as snapshots with
  `source` and `fetchedAt`, kept separate from manually entered facts.
- **Credentials** are held in the Keychain (MVP) or on the backend (later). They
  are never in source code or Git. See [security.md](security.md).
- **Failure is visible.** A failed sync shows an error state and never keeps
  showing stale data as if it were current.

## GitHub (implemented, read-only)

- **Code:** `GitHubClient` (`Packages/LinumicCore/Sources/LinumicCore/Integrations/GitHubClient.swift`)
  implements `RepositoryHostClient`. It sends GET requests only, and a test asserts that every
  request is a body-less GET to api.github.com.
- **What it reads:** repository metadata (visibility, description, homepage, default branch),
  the latest commit on the default branch, published releases (drafts excluded), open PRs,
  open issues (PRs excluded), languages, and the latest GitHub Actions run on the default
  branch. Lists read one page of 100 items.
- **Sync:** `RepositorySync.refresh` replaces only each repository's `gitHub` snapshot, stamped
  with `fetchedAt`. It never changes repository links, types or verification. Failures are
  reported per repository, and the toolbar shows how many failed and why.
- **In the app:** Development → Repositories → **Refresh from GitHub** (⌘R), or Settings →
  Integrations. Without a token only public repositories can be read (60 requests/hour).
- **Token:** Settings → Integrations → GitHub. Use a **fine-grained** personal access token
  limited to the Linumic repositories with read-only *Metadata, Contents, Issues, Pull
  requests, Actions*. It's stored in the Keychain as `github.token` (service
  `com.linumic.commandcenter`) and never written to disk, logs or the inventory.
  Don't reuse a GitHub CLI token: those carry write scopes.
- **Verified live on 2026-09-23:** an opt-in test (`GITHUB_TOKEN=… swift test --filter
  liveReadOnlySnapshot`) read the private MediFlow and public DukanPro repositories. The
  sandboxed app refreshed the public repositories without a token.
- **Not yet:** local working-copy status (branch, uncommitted changes). The sandboxed app needs
  a user-granted, security-scoped folder bookmark before it can run `git` read-only against
  `~/Projects`.
- **Forbidden without explicit per-action approval:** push, merge, delete branch, close issue,
  edit settings. None of these exist in the code.

## Apple App Store Connect (Phase 4)

- App Store Connect API with an API key (`.p8`). The key is never committed
  (`*.p8` is in `.gitignore`). It is stored in the Keychain, later on the backend.
- Role: the least-privileged role that can read app status.
- Data: production version, latest submitted build, review state, TestFlight
  build state.

## Google Play Console (Phase 4)

- Google Play Developer API through a service account with read-only access
  to the listed apps. The JSON key is never committed.
- Data: track versions (internal/closed/open/production), release status,
  review status.

## Social media (Phase 5)

LinkedIn, Facebook, Instagram, X and YouTube. OAuth per network, tokens stored
on the backend. Publishing always goes through a draft → approve → publish
workflow.

## AI providers (Phase 6)

Model API keys are stored on the backend. Requests contain only the data
needed for the question. See [market-intelligence.md](market-intelligence.md)
and the AI assistant section of ARCHITECTURE.md.
