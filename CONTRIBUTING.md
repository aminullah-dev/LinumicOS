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
4. `xcodegen generate && xcodebuild -project LinumicCommandCenter.xcodeproj -scheme LinumicCommandCenter build`
5. Update docs and `CHANGELOG.md`.
6. Commit with a meaningful message.

## Code layout

- Domain logic belongs in `LinumicCore` and must not import SwiftUI or AppKit.
- `App/` contains views and the thin `InventoryModel` observable wrapper.
