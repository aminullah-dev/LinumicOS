# Contributing

## Rules

1. **No invented data.** Unknown facts stay unknown (`nil` / `.unknown`, shown
   as "Unknown — to be verified"). Sample data for UI work must be labelled
   `SAMPLE` and must never go into `seed-inventory.json`.
2. **No fake integrations.** An integration either calls the real API or does
   not exist yet. Don't simulate a response and present it as live.
3. **No secrets in Git.** Credentials go in the Keychain (see docs/security.md).
   Check `git diff --cached` before every commit.
4. **No side effects on other repositories or stores** without explicit,
   per-action user confirmation.
5. **This repository is independent.** Don't copy files from other Linumic
   projects into it.

## Workflow

Small, verifiable steps:

1. Describe the change.
2. Implement it.
3. `swift test --package-path Packages/LinumicCore`
4. `xcodegen generate && xcodebuild -project LinumicOS.xcodeproj -scheme LinumicOS build`
5. Update docs and `CHANGELOG.md`.
6. Commit with a meaningful message.

## Supabase migrations

- A migration that creates a table, a view or a sequence in `public` grants it to the API roles that need it, and
  revokes what they must not have, in the same file and in plain SQL. Since 2026-10-30 Supabase grants a new table
  nothing on its own. If no API role may reach it, revoke it from `anon` and `authenticated` and add
  `-- data-api: revoke-only public.<name>: <why>`. Details: docs/security.md, "Data API grants are explicit".
- `python3 tools/supabase/check_migration_grants.py` checks this (CI runs it). Add the table to the expected matrix in
  `supabase/tests/grants/matrix.sql`, and run `supabase/tests/grants/run.sh` (a throwaway local Postgres, never the
  live project).

## Localization (English + Dari)

- Literal strings in SwiftUI views (`Text("…")`, `Button("…")`, `.help("…")`) are localizable
  automatically.
- A string that reaches the UI through a plain `String` must be localized explicitly:
  - in the app, `String(localized: "…")` for messages, and `LocalizedStringKey(title)` inside
    components that take a `String` title;
  - in LinumicCore, `L("…")` for fixed text and `LF("… %@ …", arg)` for templates. These read
    the app's catalog at runtime.
- Record data and evidence are never translated.
- Every new string needs a Dari translation in `App/Resources/Localizable.xcstrings`. Check with
  `python3 tools/l10n/check_catalog.py`, which also checks that format specifiers match. Use
  positional specifiers (`%1$@`) when Dari word order differs.
- Afghan Dari terminology: معلومات (not اطلاعات), کمپاین, مخزن for repository, انتشار for release.

## Colours and shapes

- Use the tokens in `App/Views/Theme.swift`, not raw system colours: `.statusGood`, `.statusWarn`, `.statusBad`,
  `.statusInfo`, `.statusUnknown` (neutral grey: unknown, not read or not checked is never shown green), `.brandAccent`,
  and `SidebarItem.tint` / `AreaTint` for an area's tiles and header. Radii and spacing: `Theme.Radius`, `Theme.Spacing`.
- Shared pieces: `PageHeader` at the top of a main page, `.cardSurface()` / `.frostedCard()` for cards, `PillLabel` for
  status pills, `KPITile` for number cards, `.hoverHighlight()` for rows that act. They handle dark mode, Increase
  Contrast, Reduce Transparency and Reduce Motion.
- The values live in `App/Resources/Assets.xcassets` (`AccentColor`, `Theme/`), each with light, dark and Increase
  Contrast variants, written by `python3 tools/design/make_colors.py`. Change a colour there, never in the asset files;
  `make_colors.py --check` (CI runs it) fails when a file differs from the table or a pair misses its contrast rule.

## Code layout

- Domain logic belongs in `LinumicCore` and must not import SwiftUI or AppKit.
- `App/` contains views and the thin `InventoryModel` observable wrapper.
