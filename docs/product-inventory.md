# Product Inventory

The inventory lives in the app, seeded from
`Packages/LinumicCore/Sources/LinumicCore/Resources/seed-inventory.json`. That file is
**generated** by `tools/inventory/build_seed.py` from evidence gathered read-only on 2026-09-23.
Every fact records its sources (kind, exact reference, observed date) and one of four
states: VERIFIED, PARTIALLY VERIFIED, UNKNOWN, CONFLICTING.

For the full findings, open questions and classification of every repository, see
[product-discovery-report.md](product-discovery-report.md).

## Summary

| Product | Repositories | Current version | Status | Website |
|---|---|---|---|---|
| Safe Beauty | stealth-service-vault-, safebeauty-privacy, Marketing/pipeline | per platform (iOS 1.0.1 / Android 2.1.5) | active (partial) | linumic.com/what-we-do/safebeauty |
| Velro | velro | 1.0.0 (iOS, partial) | active (partial) | linumic.com/what-we-do/velro |
| WorkTrack | WorkTrack | per platform (iOS 1.0 / Android 1.2.0) | active (partial) | linumic.com/what-we-do/worktrack |
| DukanPro | DukanPro | UNKNOWN — TO BE VERIFIED | development (partial) | UNKNOWN — TO BE VERIFIED |
| Talar | talar, talar-releases | 1.0.0 | active (partial) | linumic.com/what-we-do/talar |
| NerkhTimes | NerkhTimes, nerkhtimes.github.io | per platform (iOS 1.0 / Android 1.0.11) | active (partial) | aminullah-dev.github.io/nerkhtimes.github.io |
| Namazia | -Namazia | per platform (iOS 1.0 / Android 1.1.0) | active (partial) | UNKNOWN — TO BE VERIFIED |
| AfghanJama (KhayatYar) | AfghanJama | 1.8.0 | active (partial) | linumic.com/what-we-do/tailor-erp |
| SODER-HAKEM | SODER-HAKEM | 1.0 (partial) | UNKNOWN — TO BE VERIFIED | UNKNOWN — TO BE VERIFIED |
| MediFlow | MediFlow, Marketing/marketing | 0.2.0 | development (partial) | linumic.com/what-we-do/mediflow |
| Tailoring Workshop ERP (Darzi) | Tailoring-Workshop-ERP | UNKNOWN — TO BE VERIFIED | development (partial) | none (owner: the linumic.com Tailor ERP page is AfghanJama) |
| The Digital Infrastructure of the Pashto Language | The-Digital-Infrastructure-of-the-Pashto-Language | 0.1.0 (partial) | UNKNOWN — TO BE VERIFIED | UNKNOWN — TO BE VERIFIED |

"(partial)" means PARTIALLY VERIFIED: supported by indirect evidence, awaiting owner confirmation.

## Verification by area (seed revision 5)

Derived, never stored: each product's state rolls up the areas below (the app's Verification
tab shows the same breakdown with every source). Counts: V verified, P partially verified,
U unknown, C conflicting; — means nothing recorded. The facts are the nine key fields;
next version, priority and other names don't count.

| Product | Overall | Facts | Repositories | Platforms | Stores |
|---|---|---|---|---|---|
| Safe Beauty | PARTIALLY VERIFIED | 7V 1P 1U | 2V 1P | 6V | 2V |
| Velro | PARTIALLY VERIFIED | 7V 2P | 1V | 9V | 5V |
| WorkTrack | PARTIALLY VERIFIED | 7V 1P 1U | 1V | 4V 1P | 2V |
| DukanPro | PARTIALLY VERIFIED | 5V 2P 2U | 1V | 4V 1U | — |
| Talar | PARTIALLY VERIFIED | 7V 2P | 2V | 3V 1P | — |
| NerkhTimes | PARTIALLY VERIFIED | 7V 1P 1U | 2V | 3V | 2V |
| Namazia | PARTIALLY VERIFIED | 4V 1P 4U | 1V | 2V | 2V |
| AfghanJama | PARTIALLY VERIFIED | 8V 1P | 1V | 3V 1P | — |
| SODER-HAKEM | PARTIALLY VERIFIED | 6V 1P 2U | 1V | 1V | — |
| MediFlow | PARTIALLY VERIFIED | 8V 1P | 2V | 1V 1P | — |
| Tailoring Workshop ERP | PARTIALLY VERIFIED | 5V 2P 2U | 1V | 2V | — |
| The Digital Infrastructure of the Pashto Language | PARTIALLY VERIFIED | 4V 3P 2U | 1V | 1V | — |

No product is fully VERIFIED yet: each one still has at least one partially verified or
unknown key fact. The open items are listed per product under "Needs confirmation".

Evidence kinds in the seed: local files are classified by what was read (Gradle
configuration, Xcode project, package manifest, project configuration, Git repository, or
another local file such as a README), next to GitHub, website, App Store, Google Play and owner
statements.

## Updating the inventory

- **In the app:** each fact has an Edit… action that records a new value and its source.
  Choosing "Record my confirmation as a source" stores an owner confirmation with today's date.
- **Rebuilding the seed:** edit `tools/inventory/build_seed.py` (every value there cites its evidence),
  then run `python3 tools/inventory/build_seed.py`. Bump `seedRevision` when the evidence
  changes: an inventory without edits made in the app is upgraded to the new seed on launch, and one
  with edits is never overwritten.
