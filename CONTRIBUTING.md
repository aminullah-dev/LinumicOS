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

## Code layout

- Domain logic belongs in `LinumicCore` and must not import SwiftUI or AppKit.
- `App/` contains views and the thin `InventoryModel` observable wrapper.
