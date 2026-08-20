# Schema

The logical model. DDL lives in [`schema/001_canonical_mysql.sql`](../schema/001_canonical_mysql.sql);
this file explains the parts that are not obvious from reading it.

## Shape

```
raw_capture  ──(normalisation)──>  product ──< product_barcode
(untrusted, append-only)              │
                                      ├──< lot ──< pantry_event >── recipe
                                      │                                │
                                      ├──< piece_weight_curated        └──< recipe_ingredient
                                      ├──< density
                                      └──< shelf_life_by_product

shelf_life_by_class   (keyed by class, not product)
```

**product** is the identity of a food, independent of packaging — "Jasmine
rice", "Clover honey". **lot** is a set of physically interchangeable units of
that food sharing an expiry date and an open state (ADR 007). **pantry_event**
is the append-only ledger; everything else is reference data.

## The four load-bearing ideas

**Quantity is not stored.** There is no `qty` column on `lot`. On-hand
quantity is `SUM(pantry_event.delta_base_unit)` for that lot (ADR 003).
`lot.qty_on_hand_cached` exists purely as a cache, written in the same
transaction as the event, with a reconcile job to catch drift. If the cache
and the ledger ever disagree, the ledger is right.

**NULL means unknown, and nothing else does.** No sentinel strings, no zeros
standing in for missing data (ADR 002). The corollary is a discipline the
schema cannot enforce on its own: any aggregate over a nullable column must
report how many rows it skipped (modelling rule 4).

**Not applicable is not unknown.** `shelf_life_by_class.days IS NULL` means
expiry does not apply to that class in that state — honey, rice, sealed cans.
That is a completely different fact from "we don't know when this expires",
and conflating them is what leaves a needs-attention list stuck at ten items
forever (ADR 001).

**Estimates are never written down.** `lot.expires_on` holds only dates a
human actually read off a label. Everything else is derived at read time
through the resolution chain and rendered with its provenance. A stored
estimate is indistinguishable from a real date on the next read, and a user
who trusts an invented date throws away good food — which would make the app
a cause of the waste it exists to prevent.

## Four choices worth explaining

**`DECIMAL`, never `FLOAT`.** Binary floating point cannot represent 0.1
exactly. A ledger that accumulates rounding error in a project whose premise
is refusing to lie with numbers would be self-defeating.

**Client-generated event IDs.** `pantry_event.id` is a UUIDv7 minted on the
phone, not an auto-increment. This is what makes sync retries idempotent: when
a response is lost the client retries, and the server upserts by an ID it did
not invent. Auto-increment keys structurally cannot do this (ADR 005). UUIDv7
also sorts by time, which suits a log.

**A composite foreign key on `(lot_id, product_id)`.** `pantry_event`
duplicates `product_id`, which the lot already knows. That denormalisation is
made safe rather than merely documented: `lot` carries a redundant-looking
`UNIQUE KEY (id, product_id)` so the event's foreign key can reference both
columns at once. A row whose product disagrees with its lot cannot be
inserted.

**"If and only if" constraints.** `CHECK ((reason = 'WASTE') = (waste_reason
IS NOT NULL))` compares two booleans, so it enforces both directions at once:
waste events must carry a reason, and nothing else may. The same shape governs
`observed_qty` on adjustments.

## Derived, not stored

- **On-hand quantity** — `SUM(delta_base_unit)` per lot, subject to the
  checkpoint rule below.
- **Balance after a recount** — an `ADJUSTMENT` is a checkpoint, so the
  balance is the observed value plus only the deltas that occurred after it.
  Late-arriving earlier events stay in the ledger and are excluded from the
  balance (ADR 005).
- **Effective expiry** — resolution chain: label date, else open date plus
  opened shelf life, else acquisition date plus sealed shelf life, else not
  applicable, else unknown (ADR 001).
- **Piece weight** — resolution chain: `lot.measured_piece_weight_g`, else the
  median of this user's past measured events, else `piece_weight_curated`,
  else a vendored reference table (not in v1), else unknown (ADR 004).
- **`lot.shelf_life_state`** — a generated column. Frozen outranks opened,
  because freezing suspends spoilage: an opened bag in the freezer behaves
  frozen, not opened.

## The raw layer

Untrusted input lands in `raw_capture` unmodified. Normalisation reads from it
and writes the canonical tables; nothing downstream reads it directly.

In v1 this is a table in the same SQLite file, with the untrusted blob in a
JSON `payload` column (ADR 008). In phase 2 the role moves to MongoDB, which is
why the canonical MySQL schema has no equivalent — a planned asymmetry, not
drift. The principle was never "use a document store"; it is that untrusted
data lands raw and is normalised at exactly one boundary.

Three things make it more than a log table:

**Content and metadata are separated.** `payload` and `verbatim` hold what was
captured. Every other column is metadata *about* the capture — when, from which
device, whether the barcode has been looked up, whether normalisation has run.

**"Never edited" is enforced, not just documented.** A `BEFORE UPDATE` trigger
aborts any attempt to change `payload`, `verbatim`, `barcode`, `source`,
`captured_at` or `device_id`. Resolution and normalisation columns stay
mutable, because those record what the system has *done* with a capture rather
than what was captured.

**The backlogs are queries, not guesses.** Two partial indexes cover the only
two work queues that exist: scans awaiting a barcode lookup
(`lookup_status = 'pending'` — what an offline scan produces, per ADR 005) and
captures awaiting normalisation (`normalised_at IS NULL`).

The seed loads all 11 verbatim notebook lines, each linked to the product and
lot it became. Row 6 is the one to look at: *"One Lipton box"* is a complete
and faithful capture of an ambiguous reality, and the canonical row derived
from it is honest about how little it knows.

There is no separate sync queue. Unacknowledged ledger events are the outbox.

## What seeding real data changed

Applying the 11 real items broke the draft schema in four places. Every one was
the schema quietly asserting something nobody had observed:

1. **`is_opened` had to be split from `opened_on`.** The jasmine rice is open,
   but nobody wrote down when. One column could not hold that.
2. **`is_frozen` had to become nullable.** Defaulting it to 0 would have
   asserted "fresh" about the chicken wings when the truth was unknown — and
   that single fact swings their shelf life from 3 days to 270.
3. **`base_unit` and `shelf_life_class` had to become nullable.** ADR 002 makes
   identity the only hard requirement, and the Lipton box has neither.
4. **`qty_precision` had to become nullable**, tracking the delta. Precision
   describes a number, and the Lipton box has no number to describe.

A fifth arrived with the expiry capture: **`expires_on_precision`**, because
three dates were printed year-and-month only, and a `DATE` column would have
invented a day nobody saw.

## Still open

- **Chicken wing piece weight.** A *natural* countable, so no printed weight
  exists to look up — ADR 004 tier 1 applies: weigh the bag once and divide by
  10. This is now the only missing bridge, and the only thing blocking the
  "Noodle bowl" recipe.
- `opened_on` for the jasmine rice — known open, date unrecorded.
- The chicken wings carry sell-by dates on the packaging that were not
  transcribed. Low priority: a sell-by is the retailer's date and would not
  drive alerts anyway (ADR 001).
- Seed row 6 ("a Lipton box") stays unresolved **by design**. It is the
  worst-case row the schema exists to represent, not a defect to clean up —
  and it now demonstrates something useful: it carries a valid expiry date
  while its product, unit and quantity all remain unknown.

Resolved since the first draft: the tomato paste size (12 oz = 340 g, verified
against the can, so the 170 g suspicion was wrong and there is no 1700 g
error), the chicken wings being frozen, and both manufactured piece weights —
Indomie packs at 85 g and granola pouches at 42 g, printed and verified.
Both are recorded with `min_g = max_g = typical_g`, which is how an exact
manufactured weight is distinguished from a natural distribution.
