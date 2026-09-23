# Integrations

**No external integration is connected yet.** Each one below is implemented
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

## GitHub (Phase 2)

- Interface: `RepositoryHostClient` in LinumicCore (read-only methods only).
- Auth: fine-grained personal access token with **read-only** `Contents`,
  `Metadata`, `Pull requests`, `Issues`, `Actions` on selected repositories,
  stored in the Keychain as `github.token`. Later: a GitHub App on the backend.
- Data: default branch, latest commit, open PRs, open issues, latest release,
  latest workflow run conclusion.
- Local working copy status (branch, uncommitted changes) will come from
  running `git` read-only on paths the user chooses. The sandboxed app needs a
  user-granted security-scoped bookmark for this.
- Forbidden without explicit per-action approval: push, merge, delete branch,
  close issue, edit settings.

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
