# Product Data Model

The current inventory (which products exist and what is known about them) is in
[docs/product-inventory.md](docs/product-inventory.md). This file describes the
**shape** of a product record, defined in
`Packages/LinumicCore/Sources/LinumicCore/Models/`.

The known product list is **not assumed to be complete**. Products are added
through the app or the seed file, never hard-coded in Swift.

## Product

| Field | Type | Notes |
|---|---|---|
| `id` | String (stable slug) | e.g. `safe-beauty` |
| `name` | String | |
| `summary` | String? | description, `nil` = unknown |
| `category` | String? | free text until a taxonomy is agreed |
| `status` | `ProductStatus` | `unknown`, `idea`, `development`, `active`, `maintenance`, `paused`, `retired` |
| `repositories` | [`RepositoryRecord`] | |
| `platforms` | [`Platform`] | `macOS`, `iOS`, `iPadOS`, `android`, `web`, `windows`, `linux`, `backend` |
| `currentVersion` | String? | latest version released to production |
| `nextVersion` | String? | |
| `backend` | String? | free text description of backend/hosting |
| `website` | URL? | |
| `appStore` | `StoreListing`? | |
| `googlePlay` | `StoreListing`? | |
| `roadmap` | [`RoadmapItem`] | |
| `issues` | [`IssueRecord`] | manual now, GitHub-synced later |
| `releases` | [`Release`] | |
| `deployments` | [`Deployment`] | |
| `documentation` | [`DocumentLink`] | |
| `socialAccounts` | [`SocialAccount`] | |
| `analytics` | [`DocumentLink`] | links to analytics dashboards; metrics ingestion is later |
| `notes` | String | |
| `provenance` | `Provenance` | source and timestamp of the record |

## Release

`version`, `buildNumber?`, `platform`, `environment` (`development`, `staging`,
`production`), `stage`, `isReleaseCandidate`, `releaseDate?`, `notes`.

`ReleaseStage`: `planning → development → internalTesting → beta → review →
released → deprecated`, plus `blocked` (a release that can't move forward).

## Other records

- **RepositoryRecord**: `name`, `url?`, `defaultBranch?`, `host` (`github`, `other`)
- **RoadmapItem**: `title`, `detail`, `status` (`idea`, `planned`, `inProgress`, `done`, `dropped`), `targetVersion?`, `targetDate?`
- **IssueRecord**: `title`, `severity` (`low`, `medium`, `high`, `critical`), `isOpen`, `url?`
- **Deployment**: `environment`, `target`, `status` (`unknown`, `healthy`, `degraded`, `failed`, `inProgress`), `version?`, `deployedAt?`
- **StoreListing**: `url?`, `productionVersion?`, `latestSubmittedVersion?`, `reviewStatus?`, `lastChecked?`
- **SocialAccount**: `network`, `handle`, `url?`
- **Provenance**: `source`, `recordedAt`
