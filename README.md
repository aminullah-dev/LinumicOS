# Linumic Command Center

Private management system for the Linumic software ecosystem: products,
repositories, platforms, versions, releases, roadmap, issues, deployments,
store status, social media and (later) AI-assisted market intelligence for
Afghanistan.

**Status:** MVP foundation. No external integrations are connected yet.

## Layout

```text
LinumicCommandCenter/
├── project.yml                 XcodeGen spec for the macOS app (the .xcodeproj is generated)
├── App/                        SwiftUI macOS client (UI only, no business logic)
├── Packages/LinumicCore/       Platform-neutral domain models, persistence, services, tests
│   └── Sources/LinumicCore/Resources/seed-inventory.json
└── docs/                       Product inventory, integrations, security, market intelligence
```

## Requirements

- macOS 27 SDK / Xcode 27 or newer (Swift 6.4)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Development

```bash
# Run the core test suite
swift test --package-path Packages/LinumicCore

# Generate the Xcode project and open it
xcodegen generate && open LinumicCommandCenter.xcodeproj

# Or build from the command line
xcodegen generate && xcodebuild -project LinumicCommandCenter.xcodeproj \
  -scheme LinumicCommandCenter -configuration Debug build
```

The app stores its data at
`~/Library/Containers/com.linumic.commandcenter/Data/Library/Application Support/LinumicCommandCenter/inventory.json`.
On first launch it is seeded from `seed-inventory.json`, which holds only
verified facts (product names and GitHub repositories). Everything else shows
as **Unknown — to be verified** until someone enters it.

## Documents

- [ARCHITECTURE.md](ARCHITECTURE.md): system design and module boundaries
- [PRODUCTS.md](PRODUCTS.md): product data model
- [ROADMAP.md](ROADMAP.md): Command Center roadmap
- [CHANGELOG.md](CHANGELOG.md)
- [CONTRIBUTING.md](CONTRIBUTING.md): working rules
- [docs/product-inventory.md](docs/product-inventory.md): current inventory with sources
- [docs/integrations.md](docs/integrations.md)
- [docs/security.md](docs/security.md)
- [docs/market-intelligence.md](docs/market-intelligence.md)
