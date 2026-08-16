# 007. What a lot is, and when one splits

**Status:** accepted
**Date:** 2026-08-15

Extends ADR 003 by adding a sixth event reason, `TRANSFER`. It does not
supersede it.

## Context

ADR 003 put `lot_id` on every event and ADR 001 put expiry on the lot rather
than the product, but neither defined what a lot actually *is*. The schema
cannot be drawn until it is, because lot granularity decides how many rows a
shopping trip creates and how many expiry dates a person is asked to type.

The seed data has both shapes in it: 10 identical cans of tomato paste bought
together (row 5), and two rices bought at different times (rows 1 and 7).

## Options considered

### Option A — One lot per individual physical package
Ten cans become ten rows with ten identical expiry dates. Rejected: it
multiplies capture work with no gain, since the cans are indistinguishable and
nothing downstream needs to tell them apart.

### Option B — No lots; expiry lives on the product
Rejected by ADR 001 already. Two bags of rice bought a month apart have
different dates, and collapsing them means the app either warns too early or
too late for one of them.

### Option C — A lot is one acquisition of one product (chosen, refined)
Grouping by shopping trip is close, but it breaks the moment one package of
several is opened: the opened one has days left and the sealed ones have
years, and ADR 001's shelf life depends on exactly that difference.

## Decision

**A lot is a set of physically interchangeable units of one product that share
an expiry date and an open state.**

The consequences fall out of that sentence:

- Buying the same product on different days produces different lots, because
  the dates differ.
- Buying ten identical cans at once produces **one** lot with a quantity of
  ten. One expiry date is typed, not ten.
- Two rices are always different lots because they are different products.

**Opening one unit of a multi-unit lot splits it.** The opened unit moves to a
new lot with `opened_on` set; the remainder stays sealed. This earns its
complexity: an opened can of tomato paste has about a week, and the nine
sealed ones have about two years.

**A split is quantity-neutral, so it is recorded as a pair of `TRANSFER`
events** — one negative on the source lot, one positive on the destination —
summing to zero. This keeps ADR 003's invariant intact: quantity on hand is
always the sum of that lot's events, and no other mechanism may move food
between lots.

`TRANSFER` is therefore added to the reason enum:

```
CAPTURE | COOK | CONSUME | WASTE | ADJUSTMENT | TRANSFER
```

## Consequences

- Easy: capture stays cheap for the common case (one date for ten cans), and
  expiry stays accurate for the case that actually causes waste (the opened
  one).
- Harder: the app needs an explicit "I opened one" gesture, and the split has
  to be atomic — two events written together or neither.
- `TRANSFER` must be excluded from consumption analysis. It is not food
  leaving the house, and a waste or usage report that counts it will
  double-count every split.
- New work: the split flow in the UI; atomic paired writes; a rule that no
  path other than `TRANSFER` may change a lot's identity.
- Revisit if: splits turn out to be rare in practice because people open
  things one at a time anyway, in which case the sealed-remainder case could
  be simplified.
