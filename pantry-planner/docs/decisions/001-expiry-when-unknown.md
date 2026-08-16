# 001. Expiry when unknown

**Status:** accepted
**Date:** 2026-08-15

## Context

Every one of the 11 seed items was captured without an expiry date, while the
headline v1 feature is "what is expiring in the next 3 days." Taken at face
value, the feature has no data to run on.

Entry is already settled (question 2): ask for the label date, and if there is
none, classify the item and prompt when it is perishable. This record covers
what happens *after* that — what an item with no usable date does in queries,
in notifications, and in the recipe matcher.

## Options considered

### Option A — Undated items are simply invisible to expiry
Trivially honest and never wrong. Rejected on its own terms: it silently drops
the single row that actually matters (the chicken wings) and violates
modelling rule 4, which forbids quiet exclusions.

### Option B — Write a category default into the expiry column
What most pantry apps do, and genuinely tempting: the feature works on day one
with existing data, and the estimates are usually about right.

Rejected because an invented date is indistinguishable from a label date on
the very next read — precisely the lie rule 3 exists to prevent. The deeper
problem is behavioural: a user who trusts a manufactured date throws away good
food, which means **the app becomes a cause of the waste it was built to
prevent.** That is the worst available failure mode, and it is invisible in
testing.

### Option C — Daily "N items might be expiring" notification
Rejected: an alert nobody can act on gets dismissed reflexively, and a user
trained to swipe this app's notifications away will swipe away the real one
too. Alert fatigue does not degrade the feature gracefully; it disables it.

### Option D — NULL stored, estimate derived at read time and marked (chosen)

## Decision

**1. Expiry is three distinct dates, not one.** The label date, the open date,
and the derived "act by" date the app reasons with. Label dates are themselves
not interchangeable: **use-by** is a safety date, **best-before** is a quality
date, and **sell-by** is instruction for the retailer that means nothing to
the person holding the box. Which kind was recorded is stored alongside the
date, because the three imply different actions.

**2. Shelf life is a function of state, not a property of the product.**

```
shelf_life(product, state)   state ∈ sealed | opened | frozen | cooked
```

Tomato paste is roughly two years sealed and about a week opened. Seed row 1's
rice is already open. Most real pantry waste comes from the open date rather
than the label date, which is why professional kitchens day-dot everything
they open the moment they open it, and why food-safety codes date-mark opened
ready-to-eat foods independently of the manufacturer's date.

**3. Three shelf-life classes — and "not applicable" is not "unknown".**

| Class | Seed examples | A missing date means |
|---|---|---|
| `ambient_stable` | Rice, honey, canned paste, cocoa mix | Nothing; expiry does not apply |
| `stable_until_opened` | Cereal, whey protein, tomato paste | Sealed date barely matters; open date is everything |
| `perishable` | Chicken wings (row 11) | A genuine gap worth chasing |

Conflating "not applicable" with "unknown" is what leaves a needs-attention
list pinned at ten items forever — decoration, by ADR 002's own test. Honey
has no expiry date not because capture failed but because the concept does not
apply to it.

Applied to the seed data this dissolves the alarm in the README: **"zero of 11
items have an expiry date" is really "about one item actually needs one."**
The feature was defined too broadly. It was never starved of data.

**4. Resolution chain, the same shape as ADR 004**, consulted in order:

1. Label date entered by the user — `source: label`
2. Open date + opened shelf life — `source: derived_opened`
3. Capture date + sealed shelf life for the class — `source: derived_sealed`
4. Class is `ambient_stable` — `source: not_applicable`
5. `UNKNOWN` — perishable, no date, no basis to estimate

**Storage rule:** `expires_on` is NULL unless a real date was recorded.
Estimates are computed at read time, never written to the column, and always
rendered with provenance and hedged wording — *"probably ~2 days (estimated,
no date recorded)"* versus *"best before 3 Nov (from label)."*

**Alerting rules:**

- `UNKNOWN` never generates an alert. It generates a one-time resolution task.
  Surfaced and notified are different things: undated perishables appear in
  the `excluded` count and in a "needs a date" list, and never in the daily
  notification stream.
- Lead time derives from the class rather than a global 3 days. v1 heuristic:
  `min(3 days, 30% of the applicable shelf life)`, explicitly to be tuned once
  there is real usage.
- Use-by dates alert conservatively (early), because the cost of being wrong
  is a safety risk against the loss of one chicken wing. Best-before dates
  never say "expired"; they say "past best before, likely fine." **Erring
  early on a quality date is how the app starts generating waste.**

**The recipe matcher is unaffected.** An undated item is fully available to
cook-tonight. Only FEFO ordering changes: undated lots sort last, because a
known deadline outranks an unknown one.

## Consequences

- Easy: the headline feature ships against the existing seed data, because
  most of that data never needed dates. Notifications stay quiet enough to
  keep being read.
- Harder: every expiry read is a chain evaluation returning a value plus a
  source, not a column fetch. Nothing may render a date without its
  provenance.
- New work: `shelf_life_class` on products; sealed and opened shelf-life
  tables; `opened_on` on lots; storing the label-date *kind*; the resolution
  task list; hedged date rendering everywhere in the UI.
- Interacts with ADR 003 (`opened_on` is set by an event, and lots are the
  unit of expiry) and ADR 004 (identical chain-with-a-source shape — three
  records now share it, which is the house pattern for uncertain values).
- Revisit if: the resolution task list is ignored in practice, or the
  30%-of-shelf-life lead time proves too noisy or too late in real use. Both
  are tuning failures rather than modelling failures.
