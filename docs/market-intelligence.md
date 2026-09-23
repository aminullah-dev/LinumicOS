# Market Intelligence (design)

**Status:** the source → evidence → finding register is implemented (Intelligence → Market
Intelligence). It's empty until a person records sources. Nothing is collected
automatically and no conclusions about the Afghan market are made here.

## Purpose

To help Linumic decide what to build for Afghanistan by tracking evidence about
market needs, employment trends, business needs, software demand, industry
opportunities, customer feedback, product requests and regional language
requirements (Dari, Pashto and others).

## Non-negotiable rules

1. **Every item has a source and a timestamp**: where it came from (URL,
   dataset, interview, support ticket) and when it was published and collected.
2. **No unsupported claims.** Statements without a source are not stored as
   findings.
3. **Evidence and interpretation are kept separate.** Raw evidence is stored as
   it came in, and AI summaries are stored as *derived analysis* that links to
   the evidence behind it.
4. **Unknowns stay unknown.** If data is missing, the system says so.
5. **Personal data:** customer feedback is minimized and anonymized before
   analysis.

## Data model (planned)

```text
Source          id, kind (dataset | publication | news | survey | interview |
                customer_feedback | product_request), publisher, url, language,
                reliability note
Evidence        id, sourceId, publishedAt, collectedAt, region?, sector?,
                language, excerpt/value, tags
Finding         id, statement, kind (verified | derived), evidenceIds[],
                method, createdAt, createdBy (person | assistant), confidence note
ProductSignal   id, productId?, findingIds[], suggestion, status
```

## Implemented (2026-09-23)

- `MarketSource`, `MarketEvidence` and `MarketFinding` in `Models/Intelligence.swift`, stored in the
  inventory under `market`.
- Enforced rules (`MarketIntelligence.issues`, applied before every save): evidence must reference
  an existing source and can't be empty; a finding must cite at least one existing evidence item;
  a derived finding must state its method. A source or evidence item still referenced can't be deleted.
- Findings have a review state (draft/reviewed) and can be linked to products.

## Pipeline (planned)

```text
Source registry → collectors (manual entry first) → Evidence store
        → AI-assisted tagging & summarization (derived, human-reviewable)
        → Findings → linked to products / roadmap items
```

Collectors will be added one at a time, only for sources whose terms of use
allow it.

## UNKNOWN — TO BE VERIFIED

- Which sources are reliable and legally usable
- Which regions and sectors to prioritise
- Who reviews derived findings
