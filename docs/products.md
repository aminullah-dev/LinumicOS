# Products (محصولات)

Phase 7 of [the company OS roadmap](company-os-roadmap.md). The owner, 2026-10-20: "Linumic OS must be everything of
the company" and "nothing may be left behind; every platform must move equally". That day KhayatYar's builds all said
1.9.0 but each was made on a different day (Mac 10-15, Android 10-13, iPhone 10-09) and the newest GitHub release was
still v1.8.0. This page shows, for every product and each of its platforms, what is live, what was built, what is on
the default branch and how far behind it each build is, and says when a product's platforms are **not level**.

Read-only. No new key: it uses what the Platforms hub, the Release Center, the licence ledger and the Monitor already
read, and two GitHub GETs of its own with the existing token. Code: `Packages/LinumicCore/Sources/LinumicCore/Products/`,
`App/ProductsModel.swift`, `App/Views/ProductBoardViews.swift`.

## The page

One card per product, in this order: WorkTrack, SafeBeauty, VELRO, Talar, KhayatYar, MediFlow, NerkhTimes, Namazia,
DukanPro, Linumic OS. A card shows:

- the **level badge**: Platforms level, Platforms not level, Level unknown, or Nothing shipped yet (with an icon, so
  colour is never the only sign);
- the findings when it is not level, the first unread part when it is unknown;
- one row per **compared platform** (the apps people install): Store, Build, Main. On the Mac each value shows its
  source and read time on hover; a dash is "none" (the reason on hover), "Unknown" says why;
- pills for open pull requests (and how many are agents'), CI on the default branch, licences (MediFlow, KhayatYar)
  and Monitor health;
- the newest read time of anything on the card.

A product's page lists every value with its source and read time underneath, or what was found (none) or why it is
unknown, then the level rule and every part not read, pull requests with links, CI per repository, licences, health
and the repositories. Filters: All, Not level, Level unknown. "Read now" queues the Platforms, Release Center and
Products jobs (the automation queue runs one job at a time).

## Where each value comes from

| Value | Source | Read time |
|---|---|---|
| Live in the store (App Store) | Release Center: App Store Connect `/v1/apps/{id}/appStoreVersions`, the live version of that platform (IOS or MAC_OS) | the app's `fetchedAt` |
| Live in the store (Google Play) | Release Center: the production track's newest release (version name from Play's "code (name)" release name, the highest version code) | the app's `fetchedAt` |
| Live, when the console was not read | the inventory's store listing (`productionVersion`), with the listing's own source and day. **Shown, never compared** (a record can lag behind the store) | the listing's verified day |
| Newest build (store apps) | App Store Connect's newest build of that platform (`/v1/builds`, and builds attached to versions) with its upload time; Google Play: the highest version code on any track (Play gives no date) | `fetchedAt` |
| Newest build (sideloaded) | the newest of the repository's last 10 GitHub releases with an asset for that platform (`.apk`, `.dmg`, `.msi`/`.exe`, MediFlow's `-windows.zip`), its tag as the version | the Platforms hub's reading |
| Newest build (Linumic OS) | this app's own Info.plist, for the platform it runs on | now |
| On main | the version file on the default branch (`PlatformCatalog`), with file:line @ branch | the Platforms hub's reading |
| Behind main | `GET /repos/{r}/commits?sha=<default branch>&per_page=100`: commits dated after the build (committer date), "at least" when all 100 are; days from the build to the newest commit | that read |
| Pull requests, CI | Release Center (`/pulls`, Actions runs on the default branch), else the Platforms hub's count and workflows | each repository's `fetchedAt` (the oldest is shown) |
| Licences | the licence ledger (active, ending within 30 days, expired) | its last sync; never synced and empty is Unknown |
| Health | the Monitor's latest result per production address of the product or part | the oldest check |

## The catalogue

`ProductsCatalog` lists each product's **tracks** (an app's platforms that should move together: VELRO Ride on Android
and iOS) and each platform's slot. It reuses the inventory: every slot names an inventory platform record, store ids are
the inventory's store listings, version files are `PlatformCatalog`'s; a test checks every slot against the seed
inventory and every version file id against the catalogue. What it adds, with its source:

- **Linumic OS** (not an inventory product): macOS and iOS, version from this repository's `project.yml:15-16`
  (project-wide MARKETING_VERSION and CURRENT_PROJECT_VERSION; `supportedDestinations: [macOS, iOS]`, line 24), read
  through the same GitHub reading as the hub (`releaseTracking`) because the hub has no row for it.
- **Namazia's** two version files (`app/build.gradle:25-26`, `ios/project.yml:23-24,53`), added to `PlatformCatalog`:
  on 2026-10-09 main held only README.md; on 2026-10-20 it holds both apps (GitHub tree of main).
- A GitHub release asset per sideloaded platform (KhayatYar's `.apk`/`.dmg`/`.msi`, Talar's APK in talar-releases,
  MediFlow's `-windows.zip`, SafeBeauty's salon desktop `.dmg`/`.exe`), from the GitHub releases read on 2026-10-20.
- KhayatYar iOS has no version file: `iosApp/project.yml` on main sets no MARKETING_VERSION (GitHub contents API,
  2026-10-20). It has no App Store listing in the inventory, so its builds are Unknown, not "none".

**Compared** are the apps people install: WorkTrack, SafeBeauty, NerkhTimes and Namazia on Android and iOS; VELRO Ride
and Driver on Android and iOS, VELRO Ops on iOS and macOS; Talar's Android app; KhayatYar on Android, macOS, Windows and
iOS; MediFlow on Windows and macOS; DukanPro on Android, iOS and macOS; Linumic OS on macOS and iOS. Web consoles,
servers, Electron shells and SafeBeauty's salon desktop app are listed with their health but **not compared**: their
deployed version is not published and no version file of theirs is catalogued (each says so).

## Platforms level or not

Within each track, over the compared platforms (`ProductLevelRule`):

1. **Built versions differ:** the newest builds are different version numbers. "Built versions differ: Android 1.4.0
   (11), iOS 1.3.0 (9) (2026-10-17)".
2. **Live versions differ:** the versions live in the stores (read from the consoles) are different version numbers.
3. **A platform has no build while another has one:** "macOS has no build (None of the last 1 GitHub releases of
   aminullah-dev/MediFlow has a mac .dmg / .pkg / .zip file.), while Windows 0.2.0 (2026-08-27)".
4. **Behind main:** the newest build (or, without one, the live version read from the console) is a lower version than
   the version file on main, or main has commits dated after the build and its newest commit is at least
   `behindDays` (7) days later. "Android 1.9.0 (2026-10-13) behind main 1.9.1"; "iOS 1.9.0 (12) (2026-10-09) behind
   main by 14 commits, 11 days". A build made today is not behind because a pull request was merged an hour later.

Only real version numbers are compared (`SemanticVersion`): a tag like `android-app` or `salon-desktop` never is, and
build numbers are per platform (WorkTrack 1.3.0 is build 6 on Android and 4 on iOS: level).

**Level** means every compared platform was read and no rule found anything. A value that was not read (no key, a
repository not read yet, a store record instead of a console reading) makes the product **Level unknown**, with every
reason listed, unless a rule already found it not level: Unknown is never "level" and never zero. **Nothing shipped
yet**: no compared platform has a build or a store version (DukanPro today).

## Daily Brief, Desk and Command Palette

- **Brief section "Products"** (after Releases): one line per product not level, "KhayatYar: platforms not level",
  every finding in its detail, filed under the product, so the **Desk shows one item per product not level** (normal
  severity: This week, or Today for WorkTrack and SafeBeauty). Its fact is the findings without what moves every day
  (commit counts, days), so a dismissal holds until a version changes. A product whose level is unknown is a gap of the
  section, so an item of its own ("unknown, not zero"). Line ids carry the catalogue's product id only.
- **Command Palette:** "<product>: platforms not level" for each, every product's page, "Read products and agents now".

## Reading, schedule and what is kept

The automation job **Products and agents** (every 30 minutes, after the Platforms hub and the Release Center, GitHub
token required) reads, read-only:

- `GET /repos/{r}` and `GET /repos/{r}/commits?sha=<branch>&per_page=100` for every compared platform's version-file
  repository and every product's code repository (10 repositories today);
- Linumic OS's repository through the hub's `releaseTracking` (repository, latest release, releases, open pull request
  count, workflows and their latest runs, `project.yml`);
- the agents' pull requests ([docs/agents.md](agents.md)).

A repository that fails keeps its previous reading with the error; a rate limit stops the round. Kept on this device in
`products-agents.json` (next to `inventory.json`): commit dates and the newest sha (no message, author or e-mail), the
Linumic OS reading, the agents' pull request numbers, titles, branches, states, dates and links. No response body (the
ETags live in memory for the session only) and no credential. The rest of the page is derived each time and stored
nowhere.

## Seen on the Simulator

With `-LCCProductsSample 1` (Debug builds only; add `-LCCScreen productBoard` and `-LCCProductCard <id>`, or
`-LCCScreen agents` and `-LCCAgent <slug>`) both pages show made-up readings and the app starts no job. Checked on an
iPhone 17 Pro Simulator in English and Dari (right to left) on 2026-10-20. A read-only run of the real reads against
GitHub the same day (the owner's GitHub token, no store keys, nothing kept) ran without errors; its findings stay in
the app, not in this public repository. The store parts are not verified against App Store Connect and Google Play here: they run on
the owner's Mac with his keys.
