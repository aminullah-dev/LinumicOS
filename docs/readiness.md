# Operational readiness (آمادگی عملیاتی)

The owner's P1 item: "an operational checklist for every product, as Facts with a date and a source: is CI green, the
date of the last restore test, is the signing key backed up, is monitoring on". One fixed list of checks is asked of
every project, and each answer comes only from what Linumic OS already reads or records. It joins what the Projects
page, the Release Center, the Monitor, Keys & Backups, Continuity, Obligations and the Desk each hold, per project.

Read-only and derived each time: no request of its own, no file, no key, no Supabase table. Code:
`Packages/LinumicCore/Sources/LinumicCore/Readiness/Readiness.swift`, `App/ReadinessCollect.swift`,
`App/Views/ReadinessViews.swift`.

## Where it is

- **A project's page, Overview tab:** the panel "Operational readiness", after "Level across platforms". One row per
  check: its name with its state beside it as one pill (icon, word and colour together), the evidence in one sentence,
  its source and its date. The rows are **weakest first** (`ProductReadiness.weakestFirst`: failed, needing attention,
  unknown, passed; inside one state, the order of the table below), so the row under the verdict is the one the verdict
  is about. Checks that do not apply are folded under "N checks do not apply to this project".
- **Projects page, "Readiness":** the fourth segment beside All, Not level and Level unknown. Every project with its
  counts and the first thing to look at, **weakest first**; archived projects are in their own group below, in grey,
  and never push an active project down. A row opens the project's page.
- **The counts** beside a verdict (`ReadinessTally`) are an icon and a number per state, weakest first, then "6 of 8
  known". They stand for the headline sentence, which is what VoiceOver reads and what the pointer shows.

Nothing here creates a Desk item, a Brief line, a notification or a "Waiting on you" entry (see "Not on the Desk").

## The states

| State | Means | Colour |
|---|---|---|
| Passed | Read, and as it should be | green |
| Needs attention | Read, and worth a look (old, differing, due soon); nothing is broken | amber |
| Failed | Read, and wrong or missing | red |
| **Unknown** | **Not read, or no evidence.** The sentence says which reading is missing | grey |
| Not applicable | The check has nothing to ask of this project (no repository, no server, no Mac app) | grey, folded |

**Unknown is never passed.** It is not counted as passed, it is never green, and:

- a reading that passed but is **older than its window** is Unknown ("That was read more than 3 hours ago, so it is not
  counted as passed until it is read again"). The windows are the automation's own (`DataFreshness.staleWindow`): 90
  minutes for CI and pull requests (the Release Center job), 60 minutes for the Monitor. A reading that found something
  **wrong stays** as it is however old: old bad news holds until a new reading clears it;
- a registry, register or log that could not be read is Unknown, not empty;
- "nothing recorded" is not proof of "nothing wrong": no obligation on record is Not applicable, not Passed.

## The checks

The same checks for every project, built in this order (a panel then lists them weakest first, see above). "Source" is
where the result's own source line points.

| # | Check | Reads (already in the app) | Passed | Needs attention | Failed | Unknown | Not applicable |
|---|---|---|---|---|---|---|---|
| 1 | CI on the default branch | The project card's CI (`ProductCard.ci`): the Release Center's Actions runs on the default branch of each code repository, else the Platforms hub's workflows | every repository with runs is green (one with no runs is named) | no repository has any CI run | a run is failing | not read yet, the Release Center does not watch the repository, a run is still in progress, or the green reading is older than 90 minutes | no code repository is recorded (Kabul Signal) |
| 2 | Pull requests waiting | `ProductCard.pulls`: the Release Center's open pull requests with their opening day | none open, only drafts, or none opened more than **14 days** ago | a pull request that is not a draft was opened more than 14 days ago (how many, the oldest, since when) | never | not read, only a count was read (no dates), GitHub gave no opening day, or the reading is older than 90 minutes | no code repository |
| 3 | Platforms level | `ProductCard.level` (`ProductLevelRule`, docs/products.md) | Platforms level | Platforms not level (the first finding, "and N more") | never | Level unknown (the first part not read); **No platform compared** when the project lists an app platform (nothing of it is read) | Nothing shipped yet; No platform compared when the Projects page lists no app platform for the project |
| 4 | Monitoring | `ProductCard.health`: the Monitor's latest result per production address of the project | every check up, read within 60 minutes | a check slow; or the Projects page lists a web or server part for the project and **no** address of it is monitored | a check down | the Monitor has not run, an address was not checked, or the healthy reading is older than 60 minutes | nothing is monitored and no web or server part is listed |
| 5 | Signing key in a backup | The Keys & Backups registry: the keys recorded for the project that need a backup (`TrackedKey.product`), `KeysRules.backupState`, the restore tests of their backups, and on the Mac the key files' dates | every key is in a backup, and the weakest of those backups was restore-tested within **90 days** (`KeysRules.restoreTestMaxDays`) | a key changed after its newest backup, a key file is missing on this Mac, or the backup's restore test is older than 90 days or not recorded | a key is in no backup | the registry could not be read, or **it records no key for the project** | never |
| 6 | Restore test | For Linumic OS: `continuity.json`, the newest "Opened outside this Mac" record. For every other project: **nothing**, see below | an export was opened outside this Mac within 90 days | the last one is older than 90 days | no export was ever opened outside this Mac | `continuity.json` not read (iPhone, iPad, unreadable file); **every other project**: Linumic OS holds no record of a restore test of its data | never |
| 7 | Ledger reviewed | The Desk's reading of the project's PRIORITIES.md (`DeskSourceStatus`): its review day («آخرین بازبینی») and open items | reviewed within **7 days** (`CenterBuilder.reviewAfterDays`) | reviewed more than 7 days ago | never | the Desk reads no PRIORITIES.md for the project, the file was not read (not granted, not found, unreadable, this device), or it has no review day line | never |
| 8 | Obligations and deadlines | The obligations register: the open rows whose product is this project, nearest first, **except marketing rows** (a post queue ending, a clock change), which are the Marketing page's only (2026-11-13) | open rows, the nearest more than **14 days** away | the nearest is due within 14 days, or a row has no date recorded | the nearest is overdue | `obligations.json` could not be read, or a live source that feeds this project was not read (the licence ledger for MediFlow and KhayatYar, the continuity log for Linumic OS) and no row says more | the register holds no open row for the project |
| 9 | Installed on this Mac | `InstalledAppCheck` (docs/products.md): the project's Mac app in /Applications against its newest release | Current | Behind, Test build, or a build newer than every release | never | Same version (how it was built is not recorded), an unreadable Info.plist, or a device with no /Applications | no Mac app of the project is compared with a tag; not installed; the repository has no release yet (Linumic OS today) |

Notes on what a check does **not** say:

- **5** is about the key files the registry tracks. It says nothing about an Apple signing identity in the Keychain, and a
  project whose key is recorded only as a gap (NerkhTimes, DukanPro) is Unknown, with the gap still on Keys & Backups.
- **6** is the owner's rule "one real restore test per product, with a date". Linumic OS has no place to record a
  restore test of another product's database yet, so the check is Unknown for them rather than borrowed from the key
  backups (check 5 carries those). Recording one per product is the next step, not made here.
- **8** counts a licence that has ended as an overdue obligation of its product, as the register does. It leaves out the
  area Marketing (`MarketingScope`): until 2026-11-13 an overdue post made WorkTrack and SafeBeauty read Failed here.
  Marketing is on the Marketing page, and the Center says in one line when some of it is overdue.
- **3** has no age rule of its own: the level rule already says what it could not read.
- **4** uses this device's Monitor. The Sentinel checks the same addresses from the server; its reading is not joined
  here yet.

## The summary

`ReadinessSummary` counts the states. There is **no score**. The headline is "5 of 8 known · 4 passed · 1 failed ·
3 unknown": the denominator is the checks that apply, and unknown is always said on its own.

| Standing | When | Colour |
|---|---|---|
| Failing | a check failed | red |
| Needs attention | nothing failed, a check needs attention | amber |
| Not known | nothing known to be wrong, and more checks are unknown than known (or none is known) | grey |
| Partly known | nothing known to be wrong, most known, some unknown | grey |
| Ready | **every** applicable check was read and passed | green |

One unknown check keeps a project from "Ready".

## The portfolio order

`ReadinessBuilder.portfolio`: active projects (In focus and Maintenance, the owner's tiers) first, sorted by standing in
the order above, then by more failures, more checks needing attention, more unknowns, focus before maintenance, and the
Projects page's own order. Archived projects are sorted the same way in their own list. The four pills above the list
count the active projects only.

## Not on the Desk

The scorecard is a page to look at, not a source of tasks: most of what it finds is already on the Desk from its own
source (failing CI and pull requests ready to merge from Releases, "platforms not level" from Products, overdue
obligations, restore tests due, ledgers due for review), and nine checks for every project would flood it.

To switch it on later, without a second copy of those items: add a Daily Brief section built from
`ReadinessBuilder.build` (as `ProductsBrief.section` does for the level), with one line per project and only for a
check no other section reports (a signing key in no backup, a pull request waiting more than 14 days, a served project
with no monitored address), `factKey` = the check and its state so a dismissal holds until the state changes, Unknown
as a `BriefGap` with `isDeskItem == false`. `DeskBuilder` then files it under the product by itself.

## Seen and not seen

Compiled for macOS and the iOS Simulator; the panel and the list were **not run and not looked at** when this was
written (2026-11-12). To look at them with made-up readings, a Debug build takes `-LCCProductsSample 1 -LCCScreen
productBoard -LCCProjectsView readiness`, and `-LCCProductCard <id>` for one project's page.

Tests: `ReadinessTests.swift` (every check's states from fixtures, the seed registry, "nothing read means nothing
passed" over the real catalogue, the stale-reading rule, the summary, the order and the archived group).
