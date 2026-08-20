# Pantry Planner

Tracks what food is actually in my kitchen, what is about to go bad, and what I
can cook tonight without a store run.

## Why this exists

The interesting problem is not the CRUD. It is that the data arrives messy from
three directions at once and has to be reconciled before any feature works:

- A barcode API returns `"Gold Medal All Purpose Flour, 5 LB Bag"`.
- A recipe asks for `2 cups flour`.
- My pantry has `1.4 kg` left.

Answering "can I make this?" requires all three to become the same kind of
number first. That reconciliation is the project.

## Architecture

Untrusted data lands raw, gets normalised at a single boundary, and only then
enters the canonical store. Nothing downstream reads unvalidated data.

That principle is a discipline, not a product of running two database engines,
so it holds in a single file. **v1 has no server** (ADR 008) — one SQLite
database on the phone:

```
iOS client (SQLite)
    raw_capture (JSON, never edited)
          |
          v
    Normalisation
          |
          v
    Canonical tables  ->  Expiry chain
          ^               Recipe matcher
          |
   Food data API (barcode lookup, optional — ADR 005)
```

**Phase 2 is the backend**, built once v1 is in daily use — against a schema,
a dataset and a client that already exist, which is what makes sync and
idempotency teachable rather than theoretical:

```
iOS client  ->  Backend API  ->  MongoDB (raw blobs)  ->  Normalisation layer
                                        ^                        |
                                Food data API                    v
                                                            MySQL (canonical)
```

The `data/seed/` spreadsheet mirrors this deliberately: `raw_capture` is never
edited, `normalized` is derived from it.

## Core modelling rules

1. **One base unit per product** — `g`, `ml`, or `count`. Chosen once, never
   mixed. Cups, tablespoons and ounces exist only at the UI boundary.
2. **Density is a property of the food, not of the units.** A cup of flour is
   ~120 g; a cup of honey is ~340 g. There is no universal conversion, so
   conversions live in their own table keyed by product.
3. **Unknown is a value, not a zero.** Missing data returns `UNKNOWN` and forces
   a handled case. Zero is a lie that arithmetic will silently propagate.
   (Stored as `NULL`, never a literal string — see ADR 002.)
4. **Every aggregate reports its own exclusions.** A total that silently skips
   `NULL` rows returns a plausible number nobody questions — more dangerous
   than refusing to answer. Return shapes carry an `excluded` count and the UI
   surfaces it: "3 items not counted." Flags nothing surfaces are decoration.
   (ADR 002.)

## Status

Week 3 — design complete, schema built and proven against real data.
Application code next.

**Design (done)**

- [x] Real pantry inventoried by hand (11 items, `data/seed/`)
- [x] `docs/spec.md` completed — all seven questions answered
- [x] Eight decision records, each with its rejected options
- [x] Schema drafted in two dialects and seeded with the real pantry
- [x] Two target queries answerable in raw SQL

**v1 build (next)**

- [x] `raw_capture` table added to the device schema (ADR 008)
- [x] Weigh the frozen wings — the last missing count/mass bridge
- [x] Thin vertical slice: capture an item, derive its expiry, list it (`cli/`)
- [ ] Expiry notifications
- [ ] Cook-tonight matcher

**Phase 2 (committed, not started)**

- [ ] Backend API, raw layer, normalisation service, canonical store —
      triggered by v1 being in daily use (ADR 008)

## What the seed data already taught me

- Nested packaging is unavoidable (2 bags x 5 packs; 1 box x 49 pouches).
- Two rice varieties raise substitution before any code exists.
- Honey is recorded in grams but cooked in cups — the density case, live.
- One row ("a Lipton box") has an ambiguous product, no quantity and no unit.
  Every real inventory has rows like this. The schema must represent it.
- **Zero of 11 items have an expiry date.** The headline v1 feature looked like
  it had no data to run on — until ADR 001 separated "not applicable" from
  "unknown". Rice and honey do not need dates; about one item (the wings)
  actually does. The feature was defined too broadly, not starved of data.

## Layout

```
data/seed/       Hand-collected starting inventory
docs/spec.md     What v1 does, and explicitly what it does not
docs/schema.md   The logical model, and why it is shaped that way
docs/decisions/  One record per significant choice, including rejected options
schema/          DDL, seed, target queries, and build.sh
cli/             Swift package — PantryCore library plus a headless CLI
```
