# 006. What v1 does not build

**Status:** accepted
**Date:** 2026-08-15

## Context

The spec calls question 7 "the question that saves the project." By the time it
was asked, five earlier records had already voted on most of it: ADR 005 made
accounts deferrable and forced recipes to be local, ADR 003 made purchase and
waste history accrue for free, ADR 001 needed `frozen` as a state.

What was left was to make the cuts explicit, so they stop being reconsidered
every week, and to notice that "no" means three different things.

## Options considered

### Option A — One flat "not in v1" list
Rejected as too blunt. It hides the distinction that matters: some cuts
destroy data permanently and some merely withhold a screen. Treating them
alike leads to either recording nothing (unrecoverable) or building
everything (never shipping).

### Option B — Cut features but keep every field "just in case"
Rejected in the other direction. Every retained field is a prompt, a
validation rule, and a migration. ADR 004 already established that attention
is the scarce resource.

### Option C — Three grades of "no" (chosen)

## Decision

**Three kinds of cut:**

1. **Cut, nothing recorded.** Building it later starts from scratch, which is
   acceptable because these are separate products.
2. **Cut as a feature, data accrues.** No screen; the events are written
   regardless. Switching it on later is cheap.
3. **Cut as a feature, one field survives** because the arithmetic needs it.

Governing rule: **record what is already passing through, expose
deliberately.** A `WASTE` sub-reason on an event being written anyway costs a
tap. A *prompt* for data no v1 feature consumes costs attention — the same
reasoning that stops ADR 004 asking for the weight of a tea bag.

### Cut, nothing recorded

- **Users, accounts, auth.** ADR 005 authenticates a device rather than a
  person, which is what makes this deferrable instead of half-built.
- **Nutrition tracking.** A different product. Worth flagging that the
  vendored USDA dataset (ADR 004) *contains* nutrient data, so it will be
  sitting on disk, unused, being tempting. Leave it.
- **Shopping lists.** The most tempting cut, since the app already knows what
  is low and "add to list" is the obvious next tap. Two reasons to refuse: it
  is a second full workflow (ordering, stores, checking off), and it inverts
  the purpose — this app exists to make food get *used*, not bought.
- **Recipe import, scraping, recipe APIs.** Import is the barcode problem
  again in a harder form: free-text ingredient parsing ("1 large onion,
  diced") is the same reconciliation problem with messier input. ADR 005
  already required recipes to be local.
- **Substitution groups.** The jasmine/basmati question stays queued and
  unanswered. It is safe to defer *because* import is cut: hand-entered
  recipes reference the author's own products directly, so nothing in v1 ever
  has to decide whether two rices are interchangeable. Import is what would
  force it.
- **Household sharing, multi-device collaboration.** ADR 005 already produces
  correct merge semantics, so this stays cheap to add later.

### Cut as a feature, data accrues

- **Purchase history.** `CAPTURE` events are a purchase log already (ADR 003).
  No screen, no "you buy tomato paste every three weeks" analysis, no deletion
  of the underlying rows.
- **Waste analytics.** `WASTE` sub-reasons are recorded from day one with
  nothing to display them. This is deliberate: the question "am I wasting
  less" needs months of history before it can be asked, so the recording must
  start long before the feature does.

### Cut as a feature, one field survives

- **Storage locations.** No fridge/freezer/pantry browsing, no per-location
  views. But `frozen` remains as a *state* (ADR 001), because shelf life
  depends on it. Same word, two concepts — keep the one the maths needs and
  cut the one that is merely organisation.

### In v1, for the avoidance of doubt

Barcode and manual capture; the event ledger; expiry with provenance and
notifications; the count/mass bridge with optional lot weighing; offline-first
operation; and a small hand-entered recipe set large enough to exercise the
matcher honestly.

## Consequences

- Easy: v1 has a boundary that can be pointed at, and the tempting features
  each have a written reason attached rather than a vague "later".
- Harder: hand-entering recipes is real work, and it is the most likely place
  for v1 to stall. Ten recipes that are actually cooked beats fifty that are
  not.
- The deferred features stay genuinely cheap only if the accruing data keeps
  accruing. If `WASTE` reasons stop being recorded because nothing displays
  them, the analytics feature dies quietly and this record was wrong.
- Revisit if: a second person starts using it (reopens accounts, sharing,
  substitution), or the hand-entered recipe set proves too small to make
  cook-tonight useful (reopens import, and with it substitution).
