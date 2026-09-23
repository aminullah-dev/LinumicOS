# Product Data Model

The current inventory and its evidence are in [docs/product-inventory.md](docs/product-inventory.md)
and [docs/product-discovery-report.md](docs/product-discovery-report.md). This file describes the
**shape** of the records, defined in `Packages/LinumicCore/Sources/LinumicCore/Models/`.
Schema version: **2**.

The product list isn't assumed to be complete. Products are added in the app or in
`tools/inventory/build_seed.py`, never hard-coded in Swift.

## Evidence: `Fact`, `Verification`, `Source`

Every important field is a `Fact<Value>`:

```text
Fact<Value>
├── value          Value?        nil = unknown (never a guess)
└── verification   Verification
    ├── status     verified | partiallyVerified | unknown | conflicting
    ├── sources    [Source]      kind + exact reference + observedAt + detail
    ├── verifiedAt Date?
    └── notes      String
```

`Source.kind` says what the evidence is. It is exposed to the registry as `sourceType`,
`sourceReference`, `observedValue` (the `detail`) and `verifiedAt` (the `observedAt`):

| Kind | Meaning |
|---|---|
| `ownerStatement` | The owner said so, or confirmed it in the app |
| `gitRepository` | Git metadata of a local working copy |
| `projectConfiguration` | firebase.json, .firebaserc, deploy settings |
| `xcodeProject` | An Xcode project or its XcodeGen `project.yml` |
| `packageManifest` | package.json, pyproject.toml, pubspec.yaml, melos.yaml, Package.swift… |
| `gradleConfiguration` | Android Gradle build files |
| `localRepository` | Any other local file (README, docs). The raw value is kept for stored inventories. |
| `gitHub` | GitHub REST API, read-only |
| `website` | A public web page |
| `appStore`, `googlePlay` | Public store listings, or the owner's Play Console (view only) |
| `other` | Anything else. Unrecognised kinds also decode as `other`. |

Integrity rules, enforced by `integrityIssues`, the tests and the editors:
- VERIFIED or PARTIALLY VERIFIED requires at least one source and a verification date.
- VERIFIED or PARTIALLY VERIFIED requires a value, and an UNKNOWN fact must not carry one.
- CONFLICTING requires at least two sources, or a note explaining the conflict.

A product's overall status rolls up its key fields, platforms, repository links and store
listings: any CONFLICTING makes it conflicting, all VERIFIED makes it verified, nothing
verified makes it unknown, and anything else is partially verified.

`verificationState` (the roll-up), `verificationBreakdown` (per area: product facts,
repositories, platforms, store listings), `lastVerifiedAt` and `sources` (every distinct source,
newest first) are **derived** on each read and never stored, so they can't drift from the
evidence. The product table, dashboard tiles and Verification tab all read them.

## Product

| Field | Type |
|---|---|
| `id`, `name` | String (`officialName` is `name`; `lifecycleStatus` is `status`) |
| `isLinumicProduct` | Fact<Bool> |
| `alsoKnownAs` | Fact<[String]>: store names, app titles, working names |
| `summary`, `category`, `projectType`, `backend` | Fact<String> |
| `status` | Fact<ProductStatus>: idea, development, active, maintenance, completed (finished, e.g. a book), paused, retired |
| `currentVersion`, `nextVersion` | Fact<String> |
| `website` | Fact<URL> |
| `repositories` | [RepositoryRecord]: **many per product** |
| `platforms` | [PlatformRecord]: each with its own evidence |
| `storeListings` | [StoreListing]: many per store (e.g. separate passenger and driver apps) |
| `releases`, `roadmap`, `issues`, `deployments` | manual records |
| `documentation`, `analytics`, `socialAccounts` | links |
| `notes`, `provenance` | who created the record and when |

## RepositoryRecord

`name`, `owner`, `url`, `host` (github/other), **`type`**, **`link`** (a `Verification` that this
repository belongs to the product), `gitHub` (read-only `RepositorySnapshot`: visibility,
description, homepage, default branch, latest commit, release count and latest release,
open PRs and issues, languages, `fetchedAt`), `localCheckouts` (path, branch, last commit,
observed date) and `notes`.

Derived registry accessors: `localPath` (first working copy), `visibility`, `defaultBranch`,
`repositoryDescription`, `latestCommit` / `latestCommitDate` (newest of GitHub and local),
`verificationState` and `lastVerifiedAt` (from `link`) and `source` (newest link evidence).
`Product.platforms(for:)` returns the platforms whose evidence is a file in that repository or
its GitHub slug. A repository's platform comes from evidence, never from its name.

`RepositoryType`: `monorepo`, `application`, `backend`, `website`, `releases`, `documentation`,
`research`, `infrastructure`, `marketing` or `unknown`. Unrecognised values decode as `unknown`.

## PlatformRecord

`platform` (`android`, `iOS`, `macOS`, `windows`, `web`, `backend`, `desktop`, `watchOS`,
`research`, `unknown`), `component`, `identifier` (bundle or application ID), `sourceVersion`
(from the build config) and `verification`. Evidence must be a build file, a store listing or
a release asset. A folder name doesn't count.

## StoreListing

`store` (appStore or googlePlay), `appName`, `appIdentifier`, `url`, `storefront`, `seller`,
`productionVersion`, `latestSubmittedVersion`, `reviewStatus` and `verification`.

## UnresolvedItem

Projects found during discovery that aren't confirmed products: `kind` (possibleProduct or
unresolvedRepository), `location`, `findings`, `question` and `verification`.

## Release, RoadmapItem, IssueRecord, Deployment

Unchanged from schema 1. See `Records.swift`.
