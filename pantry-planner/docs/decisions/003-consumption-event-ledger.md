# 003. Food leaves via an append-only event ledger

**Status:** accepted
**Date:** 2026-08-13

## Context

Food has to leave the system, and the obvious implementation — decrement a
quantity column, delete the row at zero — destroys information at the moment
of writing. Cooking with 340 g of tomato paste and binning 340 g of furry
tomato paste are byte-identical writes to a mutable column.

That matters here more than in a general inventory system, because the app
exists to reduce waste. "Am I wasting less than in July, and why" is the
question that decides whether the project worked. A design that cannot answer
it fails at its own purpose while looking perfectly correct.

Three concrete cases force the decision:

- Seed row 1, "half a bag of rice" — an estimate, not a measurement. Cooking
  subtracts recipe amounts nobody actually weighs, so inventory drifts from
  reality by construction.
- Cooking half a recipe, eating straight from the bag, and throwing food away
  are three different events that a single `qty = qty - n` cannot distinguish.
- Two devices editing the same item offline (question 6).

## Options considered

### Option A — Mutable quantity column
One row per item, `UPDATE items SET qty_g = qty_g - 360`. Delete at zero.

Tempting, and worth being honest about why: it is the smallest possible
schema, reads are a single column fetch with no aggregation, and it is what
almost everyone builds first. For a pantry app it looks entirely adequate.

Rejected because the loss is silent and permanent. Reason for the decrement is
gone the instant it is written, so waste analysis is impossible retroactively —
not "hard later", *impossible*, since the data was never recorded. It also
merges badly offline: two concurrent absolute values mean last-write-wins and
one edit vanishes without trace.

### Option B — Full event sourcing (CQRS, event store, replay, projections)
Rejected as over-engineering for a solo project. Event schema versioning,
projection rebuilds and eventual-consistency debugging cost more than this
problem is worth.

### Option C — Append-only movement ledger, derived quantity (chosen)
The middle ground, and the industry norm for inventory: SAP material
documents, Odoo `stock.move`, NetSuite and Shopify inventory transactions all
work this way, as does double-entry bookkeeping generally. A bank does not
overwrite a balance; it appends a transaction and derives one.

Mechanically it is an ordinary table that we agree never to `UPDATE`. It costs
discipline, not infrastructure.

## Decision

Every movement is an appended, immutable row carrying a signed delta and a
reason. Quantity on hand is derived by summing the ledger.

```
pantry_event
  id
  product_id         what
  lot_id             which physical package (expiry lives here, not on product)
  delta_base_unit    signed: +2270, -360
  reason             CAPTURE | COOK | CONSUME | WASTE | ADJUSTMENT
  waste_reason       expired | spoiled | freezer_burn | disliked | accident
                     (NULL unless reason = WASTE)
  precision          measured | derived | estimated
  recipe_id          (NULL unless reason = COOK)
  observed_qty       (NULL unless reason = ADJUSTMENT — what the recount saw)
  occurred_at
  device_id          (offline merge — question 6)
```

One mechanism, several meanings: the reason code carries the semantic
difference rather than a table per event type.

**`WASTE` sub-reasons are required in v1**, because they partition into
different failures with different fixes: `expired` indicts the app itself
(the forecasting v1 exists to do), `spoiled` and `freezer_burn` indict storage
or an optimistic shelf life, `disliked` indicts purchasing rather than pantry
management, and `accident` is noise that must not be allowed to pollute the
other four.

**`precision`** records how well the number is known — `measured` (a scale),
`derived` (the recipe said 360 g), `estimated` (eyeballed). This is the seed
data's `confidence` column applied at consumption time. Flattening the three
is how an inventory quietly becomes fiction.

Supporting rules:

- **Drift is accepted, not denied.** Countables decrement exactly. Measurables
  pre-fill the recipe amount as an editable default — accepted as `derived`,
  overridden as `measured`. Never decrement silently.
- **Recount is first-class.** An `ADJUSTMENT` stores the observed amount and
  the delta needed to reconcile. The gap between computed and observed is
  itself data: it measures how wrong the estimates run.
- **Nothing is deleted.** Zero quantity means inactive. Rebuying creates a new
  lot rather than resurrecting the old one.
- **Expiry belongs to the lot, not the product.** Cooking draws from the lot
  expiring soonest — FEFO, first expired first out.

## Consequences

- Easy: waste analysis by cause; "what did I throw away in July" is a `WHERE`
  clause. Full history of every item. Offline merge becomes near-trivial —
  appended events from two devices merge by summing, with no conflict
  resolution (question 6 inherits this for free).
- Harder: current quantity is a `SUM`, not a column read. Mitigation is the
  standard one — a cached `qty_on_hand` written in the same transaction as the
  event, with the ledger as truth, the cache as convenience, and a periodic
  reconcile job that raises an alarm when they disagree.
- Discipline required: ledger rows are never edited or deleted. Corrections
  are compensating entries, in the same spirit as ADR records being immutable.
- Interacts with ADR 002: a `NULL` delta (unknown quantity consumed) is
  legal, and any total summing the ledger must report it via `excluded`
  (modelling rule 4).
- New work: lot table and lot-selection logic (FEFO); cached quantity plus
  reconcile job; the recount UI; `device_id` on every event.
- Revisit if: the ledger grows large enough that even cached reads hurt —
  the standard answer is periodic snapshot rows, not abandoning the pattern.
