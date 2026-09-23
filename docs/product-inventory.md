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
| Tailoring Workshop ERP (Darzi) | Tailoring-Workshop-ERP | UNKNOWN — TO BE VERIFIED | development (partial) | **CONFLICTING** |
| The Digital Infrastructure of the Pashto Language | The-Digital-Infrastructure-of-the-Pashto-Language | 0.1.0 (partial) | UNKNOWN — TO BE VERIFIED | UNKNOWN — TO BE VERIFIED |

"(partial)" means PARTIALLY VERIFIED: supported by indirect evidence, awaiting owner confirmation.

## Updating the inventory

- **In the app:** each fact has an Edit… action that records a new value and its source.
  Choosing "Record my confirmation as a source" stores an owner confirmation with today's date.
- **Rebuilding the seed:** edit `tools/inventory/build_seed.py` (every value there cites its evidence),
  then run `python3 tools/inventory/build_seed.py`. The seed is used only on first launch or
  after a schema upgrade, so rebuilding it never overwrites edits made in the app.
