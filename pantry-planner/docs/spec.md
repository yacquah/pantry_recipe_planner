# v1 Specification

> Answer these in prose, before drawing a single table. If a question feels hard
> to answer, that is the signal — it is a design decision hiding, and it belongs
> in `docs/decisions/` rather than being resolved silently in code later.

## 1. What is the smallest useful thing v1 can do?

Two things, in priority order:

1. **Expiry awareness.** Send a notification when an item is about to expire,
   and answer "what is expiring in the next 3 days?" on demand.
2. **Cook-tonight matching.** Answer "what can I cook tonight without a store
   run?"

Where expiry data comes from (0 of 11 seed items have a date recorded):

- I enter dates from the label — most packaged items have one.
- If there is no label date, the app classifies the item: shelf-stable items
  need no date; perishable items prompt me for one.
- If it is perishable and no date can be provided, the value is `UNKNOWN` —
  never a guessed date, never a zero. How `UNKNOWN` items behave in queries
  and notifications is ADR 001 (see question 5).

Honest cost of including (2): it pulls the entire reconciliation pipeline —
base units, density, countable-vs-measurable (question 4), and a source of
recipes — into v1. (1) can ship alone; (2) cannot ship without the hard part.

## 2. How does an item get in?

Both paths, barcode first:

1. Capture starts by asking for a barcode, with a small visual cue showing
   what one looks like. No barcode, or a scan that returns nothing → manual
   entry.
2. Either way the result may be incomplete. If required fields are missing,
   the app prompts for exactly what is needed ("the Lipton box — how many
   tea bags inside?").
3. Manual fields show format examples, so types stay clean — numbers where
   numbers are needed, never free text.
4. If a required field genuinely cannot be provided, the item still lands in
   the canonical store with that field NULL and a needs-review flag. Identity
   matters most; quantity can always be improved later. Capture is never
   blocked. There is no separate pending queue — the raw layer (MongoDB)
   already is one.
5. Every aggregate reports its own exclusions. A query that sums pantry
   weight and silently skips three NULL rows returns a plausible number
   nobody questions — more dangerous than refusing to answer. Return shape:
   `{ total: 10739, unit: "g", excluded: 3 }`; UI shows "3 items not
   counted." Flags that nothing surfaces are just decoration. (ADR 002.)

## 3. How does an item get out?

Nothing is ever deleted, and no quantity is ever overwritten. Food leaves via
an **append-only event ledger**: every movement is a signed delta with a
reason, and the quantity on hand is derived by summing them. One mechanism,
several meanings — the reason code carries the difference, not a separate
table per event type.

Reasons: `CAPTURE` (+), `COOK` (−, linked to a recipe), `CONSUME` (− eating
straight from the bag), `WASTE` (−), `ADJUSTMENT` (±, a recount).

`WASTE` carries a sub-reason, because the whole point of the app is to reduce
it and different causes route to different fixes:

| Sub-reason | What it means | What it indicts |
|---|---|---|
| `expired` | Passed its date, thrown out | The app itself — this is the failure v1 exists to prevent |
| `spoiled` | Went bad *before* its date | Storage or an optimistic shelf-life estimate |
| `freezer_burn` | Frozen too long or badly wrapped | Storage (the chicken wings, seed row 11) |
| `disliked` | Bought it, would not eat it | Purchasing, not pantry management |
| `accident` | Dropped, spilled, contaminated | Nothing — noise, but must not pollute the others |

Cooking half a recipe, eating from the bag, and binning something are the same
mechanism with different reasons — and the numbers they produce differ in
quality, so each event records its `precision`: `measured` (a scale),
`derived` (the recipe said 360 g), or `estimated` (eyeballed). This mirrors
the `confidence` column already in the seed data, applied at consumption time.

Drift is accepted rather than denied. Countables decrement exactly (3 Indomie
packs). Measurables pre-fill the recipe amount as an editable default — one
tap to accept (`derived`), easy to override with a real number (`measured`).
Never decrement silently. **Recount is a first-class gesture**: an
`ADJUSTMENT` event recording the observed amount and the delta needed to
reconcile. The gap between computed and observed is itself data.

When an item hits zero it goes inactive, not deleted. Rebuying creates a new
lot; it does not resurrect the old one. Expiry belongs to the **lot**, not the
product — two bags of rice bought a month apart die on different days — so
cooking draws from the lot expiring soonest (FEFO, first expired first out).

See ADR 003.

## 4. What does "1 onion" mean when a recipe wants 200 g of onion?

<!-- The countable-vs-measurable boundary. Applies directly to seed rows 3, 9
     and 11 (Indomie packs, granola pouches, chicken wings). -->

## 5. What happens to an item with no expiry date at all?

<!-- This is the whole of ADR 001. All 11 seed items are in this state. -->

## 6. Does the app work offline?

<!-- A phone in a kitchen with bad wifi is the normal case, not the edge case.
     If yes: what happens when two devices edit the same item? -->

## 7. What am I explicitly NOT building?

<!-- Write this one down properly. It is the question that saves the project.
     Candidates to rule out for v1: users and auth, nutrition tracking,
     shopping lists, purchase history, storage locations, recipe import,
     substitution groups. -->

---

## Out of scope for v1

<!-- Move firm decisions up from question 7 into this list as you make them,
     so they stop being reconsidered every week. -->
