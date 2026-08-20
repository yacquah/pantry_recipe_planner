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

The base unit follows **how the food is stored and depleted, not how recipes
talk about it** — the same principle that keeps cups at the UI boundary in
rule 1. Onions sit in the kitchen as onions and leave one at a time, so onion
is `count`. Recipe grams are a translation at the edge.

Crucially, **the bridge between count and mass is consulted only when
matching a recipe — never when writing to the ledger.** Cooking with one
onion records −1 `count` at `measured` precision; grams never enter it. Stored
data stays exact; only the *question* is approximate.

Not all countables are alike, and the difference decides when to ask for a
weight:

| Kind | Examples | Per-unit weight | Prompt for it? |
|---|---|---|---|
| Manufactured | Indomie packs, granola pouches (rows 3, 9) | Exact, printed on the packaging | Yes — read it off the box |
| Natural | Chicken wings (row 11), onions | A distribution, 70–300 g for an onion | Optionally, by weighing the lot |
| Pure | Lipton tea bags (row 6) | Irrelevant — no recipe asks for grams of tea bag | Never |

Piece weight lives in **its own table, not the density table.** Density is a
physical constant; piece weight is a distribution. Storing them together would
state "1 onion = 150 g" with the same confidence as "1 cup honey = 340 g," and
one of those is a lie. Piece weight carries `typical_g`, `min_g`, `max_g` and
a `source`.

Where the number comes from is a resolution chain, consulted in order:

1. Measured on this lot — 10 wings weighed at 1.1 kg, so 110 g each.
2. This user's own history for the product — the median of their past
   measurements.
3. A small curated table covering common foods.
4. A vendored reference dataset (USDA FoodData Central), shipped with the app
   rather than called over the network. **Not in v1** — a documented slot.
5. `UNKNOWN`. Never a guess.

Tiers 1 and 2 are what let this work for users whose foods nobody curated: the
app learns each person's piece weights from their own measurements, which
beats a global median anyway, since onions differ by region. So capture offers
an optional **"weigh the whole lot"** step — never blocking, offered for
natural countables only.

Answers that cross an approximate bridge are never stated confidently. The
match result is four-state — yes, no, **probably (check)**, and **can't tell**
— and shows its margin: *"Needs ~200 g onion. You have 2 onions ≈ 300 g
(range 140–600). Probably fine — check."* A false "no" quietly kills the
feature, since the onions rot while you cook something else. Do not resolve
uncertainty the user can resolve by looking. "Can't tell" is reported, not
dropped (rule 4).

See ADR 004.

## 5. What happens to an item with no expiry date at all?

At entry: ask for the label date. If there is none, classify the item; prompt
when it is perishable. What follows is what an item with no usable date
actually *does*.

**Expiry is not one date, it is three.** The label date (whatever the
packaging says), the open date (when the seal was broken), and the derived
"act by" date the app alerts on. Label dates are not interchangeable either —
**use-by** is a safety date, **best-before** is a quality date, and
**sell-by** is for the shop and means nothing here. Which kind it is gets
stored.

**Shelf life is a function of state, not a property of the product:**
`shelf_life(product, state)` where state is `sealed | opened | frozen |
cooked`. Tomato paste is ~2 years sealed and about a week opened. Seed row 1's
rice is *already open*. Most real pantry waste comes from the open date, not
the label date — which is why professional kitchens day-dot everything they
open.

**Three shelf-life classes, and "not applicable" is not "unknown":**

| Class | Seed examples | A missing date means |
|---|---|---|
| `ambient_stable` | Rice, honey, canned paste, cocoa | Nothing. Expiry does not apply — out of scope for the feature |
| `stable_until_opened` | Cereal, whey protein, tomato paste | The sealed date barely matters; the open date is everything |
| `perishable` | Chicken wings (row 11) | A real gap worth chasing |

Conflating "not applicable" with "unknown" is what produces a needs-attention
list stuck at 10 items forever — decoration, by ADR 002's own test. Applied to
the seed data, **"zero of 11 items have an expiry date" resolves to roughly
one item that actually needs one.** The feature was defined too broadly; it
was never starved of data.

**Resolution chain** (same shape as ADR 004), in order:

1. Label date entered by the user — `source: label`
2. Open date + opened shelf life — `source: derived_opened`
3. Capture date + sealed shelf life for the class — `source: derived_sealed`
4. Class is `ambient_stable` — `source: not_applicable`, not a gap
5. `UNKNOWN` — perishable, no date, no basis to estimate

**`expires_on` is NULL whenever no real date was recorded.** Estimates are
computed at read time and always rendered with provenance and hedged wording:
*"Chicken wings — probably ~2 days (estimated, no date recorded)"* against
*"Cheerios — best before 3 Nov (from label)."* An invented date written into
the column would be indistinguishable from a real one on the next read.

**Alerting:**

- `UNKNOWN` never triggers an alert. It creates a one-time resolution task.
  Surfaced is not the same as notified — an alert that cannot be acted on gets
  dismissed reflexively, and a user trained to swipe this app away will swipe
  away the real alert too.
- Lead time comes from the class, not a global 3 days. v1 heuristic:
  `min(3 days, 30% of applicable shelf life)`, to be tuned against reality.
- Use-by dates alert conservatively. Best-before dates never say "expired" —
  they say "past best before, likely fine." **An over-eager app makes the user
  bin good food, which means the app is now causing the waste it exists to
  prevent.**

Cook-tonight is unaffected: undated items are fully available. Only FEFO
ordering changes — undated lots sort last, since a known deadline outranks an
unknown one.

See ADR 001.

## 6. Does the app work offline?

Yes — **local-first**, not "online with an offline fallback." The device is the
primary store; the server is a sync peer, not the source of truth. Writes land
locally and always succeed; sync is background reconciliation.

The distinction matters because it removes a whole class of bug: there is no
separate offline code path to forget to test. There is one path, and the
network only affects how quickly other devices hear about it.

**What must be on the device:** the event ledger, the derived inventory, the
reference tables (piece weight, density, shelf life — all vendored per ADR
004), and the v1 recipe set. The two headline questions — what is expiring,
what can I cook — must be answerable in a basement with no signal. Anything
remote is enrichment, never a dependency.

**What may be remote:** barcode product lookup. Scanning works offline (the
camera is local); the code is stored on the raw capture and resolved on
reconnect. Per ADR 002 the user still supplies a provisional identity, so the
item is usable immediately. When the lookup lands it *proposes* a correction
rather than silently overwriting what the user typed.

**Sync is the outbox pattern, and the ledger is already the outbox.** Local
events are pushed when a connection exists; anything unacknowledged is
retried. No separate sync layer, because ADR 003's log is the thing being
synced.

Two mechanics make retries safe:

- **The client mints event IDs** (UUIDv7 — time-sortable), and the server
  upserts by ID. A lost response means a retry, and a retry must not become a
  second decrement. Server-generated auto-increment IDs cannot do this.
- **Two timestamps, both kept.** `occurred_at` comes from the device and
  records when the human acted; `received_at` comes from the server and is
  authoritative for ordering. Device clocks are wrong often enough that
  trusting them for ordering breaks the ledger, and reconciling them into one
  number would throw away the truth about the world.

**Two devices editing the same item.** Deltas commute: −360 g and −200 g sum
to −560 g in any order, so concurrent consumption merges with no conflict
resolution at all. (The ledger is, without having planned it, a PN-Counter
CRDT — commutative, associative, and made idempotent by client-side IDs.)

The exception is `ADJUSTMENT`, which is an *absolute assertion* and does not
commute. Its resolution follows the physics: a recount observes reality, and
reality already reflects everything that happened before the observation,
whether the app knew about it or not. So **an `ADJUSTMENT` is a checkpoint**:

```
balance = checkpoint value + Σ deltas where occurred_at > checkpoint time
```

Late-arriving events from *before* a checkpoint are kept in the ledger — they
still feed waste analysis and piece-weight learning — but they are excluded
from the balance and flagged, per rule 4. Eyes beat the ledger.

The result is that **v1 has no conflict-resolution UI**, because the data
model leaves nothing to resolve.

**Scope:** v1 is one user, offline-capable, multi-device tolerated but not
designed for. Sync authenticates a *device*, not a *user* — no accounts, which
keeps auth out of v1 (see question 7).

See ADR 005.

## 7. What am I explicitly NOT building?

There are **three different kinds of "no"** here, and collapsing them is how
projects either bloat or lose data they can never recover:

1. **Cut, and nothing is recorded.** Gone. Building it later starts from
   scratch — which is fine, because these are separate products.
2. **Cut as a feature, but the data still accrues.** No screen, no reports;
   the underlying events are written anyway. Cheap to switch on later.
3. **Cut as a feature, but one field survives** because the maths needs it.

The governing rule: **record what is already passing through, expose
deliberately.** Adding a `WASTE` reason to an event that is being written
anyway costs one tap. Adding a *prompt* for data no v1 feature uses costs
attention, which is the scarcer resource (ADR 004 refuses to ask for the
weight of a tea bag for the same reason).

Notable calls:

- **Recipe import is the barcode problem again, in a harder form.** Free-text
  ingredient parsing ("1 large onion, diced") is the same reconciliation
  problem as barcode strings, with worse input. Cutting it is not just scope
  discipline — and it has a happy side effect below.
- **Cutting import is what makes cutting substitution safe.** Hand-entered
  recipes reference the user's own products directly, so "is jasmine rice the
  same as basmati" never has to be answered in v1. Import is what would force
  the question.
- **Storage locations are cut, but `frozen` survives** — not as a place to
  browse by, as a state that changes shelf life (ADR 001). Same word, two
  concepts; keep the one the maths needs.
- **Purchase history is cut, but `CAPTURE` events already are one.** ADR 003
  means the log accrues whether or not anything displays it.
- **Shopping lists are the most tempting cut**, because the app already knows
  what is low. But they invert the purpose: this app exists to make food get
  used, not bought.

See ADR 006.

---

## Out of scope for v1

Settled. Not to be reopened without a new ADR superseding 006.

**Cut, nothing recorded**

- Users, accounts and auth — sync authenticates a device, not a person (ADR 005)
- Nutrition tracking — a different product, even though the vendored USDA data
  contains the nutrients (ADR 004)
- Shopping lists — inverts the purpose of the app
- Recipe import, URL scraping, recipe APIs — recipes are hand-entered and local
  (ADR 005)
- Substitution groups — unnecessary while recipes are authored against one's
  own products
- Household sharing and multi-device collaboration — merge semantics are
  already correct, so this stays cheap to add (ADR 005)

**Cut as a feature, data accrues anyway**

- Purchase history — `CAPTURE` events are already a purchase log (ADR 003)
- Waste analytics and dashboards — `WASTE` reasons are recorded from day one,
  with no screen to show them (ADR 003)

**Cut as a feature, one field survives**

- Storage locations — no browsing by place, but `frozen` remains a state
  because shelf life depends on it (ADR 001)

**In v1 for the avoidance of doubt:** barcode and manual capture, the event
ledger, expiry with provenance and notifications, the count/mass bridge with
optional lot weighing, offline-first operation, and a small hand-entered
recipe set sufficient to exercise the matcher honestly.
