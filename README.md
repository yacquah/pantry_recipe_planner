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

Design is settled — the spec, nine decision records and the schema are done.
**The engine is complete; the iOS app has its first screen.**

### The engine (`core/`) — done

A headless Swift package: `PantryCore` holds the logic, `pantry` is a thin CLI
over it, and the iOS app imports the same library rather than reimplementing
any of it. 48 tests across 10 suites pass via `swift test`.

| Capability | Where it lives |
|---|---|
| Capture and the raw, never-edited layer (ADR 002) | `pantry capture` |
| Expiry chain, every date carrying its provenance (ADR 001) | `pantry list [--all] [--days N]` |
| Cook-tonight matcher, four-state answers (ADR 004) | `pantry cook --why` |
| Append-only ledger — cook, waste, eat, recount (ADR 003) | `pantry cook`, `waste`, `eat`, `recount` |
| Checkpoint rule: a recount supersedes rather than sums (ADR 005) | `v_lot_balance` |
| Numbered device migrations, carried inside the library (ADR 009) | `pantry migrate` |
| Which lots may interrupt you, when, and in what words (ADR 001, spec §5) | `pantry alerts` |
| What is on hand, how much, and how far through it you are | `pantry inventory` |

### The app (`Pantry/`) — three tabs

SwiftUI, a single SQLite database in Application Support, no logic of its own.

**Pantry** opens on what is about to go bad, each date labelled with where it
came from, then what is running low and what the app cannot describe. **Cook**
answers what is possible tonight with the four-state verdict intact —
`CANNOT TELL` is styled as a question, not a refusal, because making it look
like failure is how a four-state answer quietly becomes three. **Add** records
an item by hand; only a name is required (ADR 002). Food leaves the same way it
arrives: swipe a lot to record eating, binning or a recount, or cook a recipe
from the Cook tab with the amounts editable before anything is written.

**Expiry reminders work.** The phone schedules them, defers the permission
prompt until there is something real to ask about, and reports what iOS
confirms it is holding rather than what was planned.

Three things the UI refuses to do, all the same rule: a quantity bar renders
nothing rather than empty when the amount is unknown, an ingredient reads
"have unknown" rather than "have 0", and "running low" stays empty in a full
cupboard instead of ranking its emptiest shelf.

14 store tests and 5 UI tests run with `xcodebuild test`.

### What v1 still needs

- [ ] **Barcode capture.** Spec §2 makes v1 barcode-first. The schema is ready
      (`product_barcode`, `raw_capture.barcode`, and a `lookup_status` that
      resolves on reconnect); the scanner and the lookup are not written.

Offline-first needs no work — it falls out of keeping one SQLite file on the
device (ADR 008).

**Phase 2 (committed, not started)**

- [ ] Backend API, raw layer, normalisation service, canonical store —
      triggered by v1 being in daily use (ADR 008)

## Build log

Three phases: two weeks of design before any application code, then the engine,
then the client. Each entry says what it settled, because the point of the
sequence is that nothing was coded until the ambiguity was gone.

**Design — 10–16 August**

| Milestone | What it settled |
|---|---|
| Inventoried the real pantry by hand | 11 items, `data/seed/` — the dataset everything else is tested against |
| Answered the spec's seven questions | Including the two that turned into ADRs 001 and 004 |
| Wrote nine decision records | Each with its rejected options, so reversals stay cheap |
| Drafted the schema in two dialects | Canonical MySQL and device SQLite, seeded with the real 11 items |
| Proved both target queries in raw SQL | Expiry and cook-tonight answerable before a line of Swift |

**Engine — 20 August**

| Milestone | What it settled |
|---|---|
| `raw_capture` layer added to the device schema | Untrusted data lands raw and is never edited (ADR 008) |
| Weighed the frozen wings | Closed the last missing count/mass bridge |
| Thin vertical slice in Swift | Capture an item, derive its expiry, list it |
| Cook-tonight matcher, plus the check suite | Four-state answers that never overstate confidence |
| Numbered migrations | The device database can now change safely after release |
| The write path and the checkpoint rule | ADR 005 implemented rather than only described; checks 33 → 47 |

**Client — 20–21 August**

| Milestone | What it settled |
|---|---|
| Declared iOS support on the package | So the app links `PantryCore` instead of forking the logic |
| Moved the starter inventory into the library | A sandboxed app cannot read the repository it was built from |
| iOS app and its expiring list | Verified on a clean simulator install, tap-driven |
| Expiry reminders, end to end | The headline v1 feature. Lead time varies by shelf life; four separate reasons to stay silent; checks 47 → 73 |

**Tooling — 31 August**

| Milestone | What it settled |
|---|---|
| Hand-rolled check runner → Swift Testing | The original runner could not tell "did not run" from "passed", and one assertion behind an unreachable branch had been silently skipping. Ported against the old runner, then removed it |
| Three tabs, and writing from the phone | An inventory API the engine never had, `CANNOT TELL` given a design of its own, and the store made testable — its database path was hard-wired to the real pantry |
| Food can leave the ledger from the phone | The loop closed. Until this, capture was the only write path, so quantities only ever rose and "running low" was unreachable by construction |

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
schema/          Canonical MySQL DDL, target queries, build.sh
core/            Swift package — PantryCore plus a headless CLI. The device
                 schema lives here as numbered migrations, and the starter
                 inventory beside them, because the app has to carry both.
Pantry/          The iOS app. SwiftUI over PantryCore as a local package
                 dependency — no logic of its own.
```
