# 004. The countable/measurable bridge, and where piece weights come from

**Status:** accepted
**Date:** 2026-08-15

Supersedes the queued candidate "Density source: hardcoded table, or
third-party lookup?", which is answered here by the same resolution chain.

## Context

Rule 1 fixes one base unit per product, but recipes speak a different language
than the pantry does. A recipe wants 200 g of onion; the kitchen has 2 onions.
A recipe wants 1 onion; the freezer has 600 g of diced onion. Both directions
need a bridge between `count` and mass.

This is live in three seed rows, and in all three the bridging number is
missing: Indomie packs (row 3, ~85 g each, unrecorded), granola pouches
(row 9, ~42 g each, unrecorded), chicken wings (row 11).

The complication is that the bridge *looks* like density (rule 2) and is not.
Density is a physical constant — honey is ~1.42 g/ml in every jar. Piece
weight is a distribution: a real onion ranges 70–300 g, and two chicken wings
differ by nearly a factor of two.

Industry calls this **catch weight** — goods sold by piece but stocked by mass
(meat, cheese, produce). SAP, Odoo and Dynamics all support it explicitly.

## Options considered

### Option A — One unit per food, refuse the other language
Recipe asks for grams, pantry holds counts, answer is `UNKNOWN`. Honest and
trivial to build. Rejected: it silences too much of the cook-tonight feature.
Nearly every recipe mixes both languages, so most matches would return
nothing, and a feature that usually shrugs does not get used.

### Option B — Dual quantity tracking (true catch weight)
Store both a count and a mass for every item, as ERP systems do. Rejected:
it violates rule 1, doubles the capture burden on every single item, and for
manufactured countables the second number is pure redundancy (an Indomie pack
is 85 g, always). ERPs need this because money depends on it; a pantry
does not.

### Option C — Single base unit by storage, approximate bridge at match time
(chosen)

## Decision

**The base unit follows how food is stored and depleted, not how recipes talk
about it** — the same principle that confines cups to the UI boundary. Onion
is `count`.

**The bridge is a read-time concern only.** The matcher may cross it; the
ledger never does. Cooking with one onion appends −1 `count` at `measured`
precision, and grams never touch the write path. All approximation is confined
to one place: the comparison step. Stored data stays exact.

**Three kinds of countable**, which decide when the app should ask for a
weight at all:

| Kind | Per-unit weight | Prompt |
|---|---|---|
| Manufactured (Indomie, granola pouches) | Exact, printed on packaging | Yes — read it off the box |
| Natural (chicken wings, onions) | A distribution | Optional lot weighing |
| Pure (tea bags) | Irrelevant | Never |

Prompting for the weight of a tea bag is how an app teaches users to ignore
its prompts.

**Piece weight gets its own table, separate from density**, with fields
density does not need: `typical_g`, `min_g`, `max_g`, `source`. Sharing a
table would assert "1 onion = 150 g" at the same confidence as "1 cup honey =
340 g".

**Source is a resolution chain, not a table.** Callers ask
`getPieceWeight(product) -> { typical_g, min_g, max_g, source }`; the chain is
consulted in order:

1. Measured on this lot (10 wings, 1.1 kg → 110 g each)
2. This user's own measurement history for the product (median)
3. A small curated table of common foods
4. A vendored reference dataset — USDA FoodData Central, public domain and
   bulk-downloadable, so it ships *inside* the app rather than being called
   over the network (which also keeps question 6 offline-safe). **Not in v1**;
   a documented slot.
5. `UNKNOWN` — a legitimate terminal state, reported per ADR 002, never a
   guess.

The reasoning behind fixing the shape but deferring the source: **where a
number comes from is a two-way door** — swapping a curated table for a dataset
is an afternoon's work if callers never knew the difference. **The shape of
the value is a one-way door** — if callers cannot distinguish a measured value
from a guessed one, every consumer is wrong and fixing it touches everything.
Design effort belongs on the one-way door.

**Tiers 1 and 2 are what make this work beyond a curated audience.** Each
user's measurements curate their own table, converging on the foods they
actually buy — strictly better than a global median, since onions in Accra are
not onions in California. Capture therefore offers an optional **"weigh the
whole lot"** step: never blocking, offered for natural countables only.

**Answers crossing an approximate bridge are never stated confidently.** The
match result is four-state — yes, no, *probably (check)*, *can't tell* — and
shows its margin. The error costs are asymmetric: a false "no" quietly kills
the feature, because the user cooks something else and the onions rot anyway.
The user is standing in front of the pantry with working eyes; the app's job
is to narrow it to "go look at the onions," not to be confidently wrong. **Do
not resolve uncertainty the user can resolve by looking.**

**Density uses the same chain**, but tier 3 alone suffices — it is a genuine
physical constant, so a small static table is correct and will not need to
grow much.

## Consequences

- Easy: swapping or adding a piece-weight source later touches one resolver
  and no schema. The curated table can start at twenty foods without becoming
  a dead end.
- Harder: the matcher cannot return a boolean. Uncertainty has to survive all
  the way to the UI, which means a richer result type and more UI states.
- New work: `piece_weight` table; the resolver and its chain; the optional
  weigh-the-lot capture step; the four-state match result; a curated seed
  table; recording printed pack weights for seed rows 3 and 9.
- Interacts with ADR 003: piece weights derived from user history read the
  ledger's `measured` events, so the two features reinforce each other.
- Revisit if: tiers 1 and 2 stay empty because nobody weighs anything. That
  makes tier 4 urgent rather than optional, and means the weighing step needs
  to be easier, not that the chain is wrong.
