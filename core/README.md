# pantry — command-line slice

The first application code: capture an item, normalise it, read the expiry
chain back out. Headless on purpose — ADR 008 puts the real interface on iOS,
and the logic is what carries risk, not the UI.

## Build and run

```bash
cd cli
swift build
./.build/debug/pantry list
```

The database is the one `schema/build.sh` produces, at `/tmp/pantry.db` by
default. Point elsewhere with `--db PATH`.

```bash
pantry migrate                  # create the database, or upgrade an existing one

pantry list                     # expiring within 3 days, plus exclusions
pantry list --days 30
pantry list --all               # every lot, and where its date came from

pantry cook                     # what can I cook tonight
pantry cook --why               # ...and the working behind each verdict

pantry cook "Jollof-ish rice" --dry-run   # what cooking it would remove
pantry cook "Jollof-ish rice"             # ...and actually remove it
pantry waste   --lot 11 --qty 2 --reason freezer_burn
pantry eat     --lot 1 --qty 200
pantry recount --lot 1 --observed 4000    # what your eyes actually saw

pantry capture "half a bag of red lentils" --name "Red lentils" \
    --unit g --qty 250 --class ambient_stable --precision estimated
```

## Checks

```bash
swift run pantry-tests
```

21 checks, no database and no fixtures, because everything they cover is a
pure function. They exit non-zero on failure.

They are an ordinary executable rather than a `.testTarget`, and that is not a
preference: on macOS **both XCTest and Swift Testing ship inside Xcode**, not
in Command Line Tools, so a real test target cannot compile on this machine.
Installing a 30 GB IDE to obtain an assert function is a poor trade. Once
Xcode is installed for the iOS app, converting these to XCTest is mechanical —
each `expect(a, b, label)` becomes an `XCTAssertEqual`.

## Layout

```
Sources/PantryCore/     the logic — no printing, no argument parsing
  Database.swift        thin wrapper over the C SQLite API
  Migrations.swift      numbered schema history, applied on demand
  Migrations/           the .sql steps themselves, shipped in the bundle
  UUIDv7.swift          client-minted, time-ordered ids (ADR 005)
  Capture.swift         raw_capture -> product -> lot -> ledger, transactional
  Expiry.swift          reads ADR 001's chain out of v_lot_expiry
  Matcher.swift         ADR 004's verdict rules, as pure functions
  Consumption.swift     cook / waste / eat / recount — the write path
Sources/pantry/
  main.swift            argument parsing and output, nothing else
Sources/pantry-tests/
  main.swift            checks, runnable without Xcode
```

## Migrations

The database records its own schema version in SQLite's built-in
`PRAGMA user_version`. `migrate()` applies only the numbered steps above that
version, so a fresh install runs all of them, a partially upgraded one runs
the remainder, and an up-to-date one runs nothing.

It is the ledger idea from ADR 003 applied to the schema itself: the shape is
never overwritten, changes are appended, and the current shape is whatever
replaying them in order produces.

Three properties the checks pin down:

- **Each step and its version bump share one transaction.** A migration that
  fails halfway rolls back entirely, rather than leaving a half-changed
  database claiming to be a version it is not.
- **Re-running is a no-op**, which is what lets the app migrate on every
  launch without thinking about it.
- **A database newer than the build is refused**, not opened. This build
  cannot know what a later version changed, and guessing corrupts data.

Every command except `migrate` refuses to run against an out-of-date schema.
Reading an old shape tends to produce wrong answers rather than errors, and a
wrong answer is the worse failure.

`schema/build.sh` applies migrations through this same code rather than piping
SQL in, so the development database and the one on a phone are built by an
identical path.

## Food leaving the ledger

`CAPTURE` was the only event the code ever wrote, which made the ledger a
write-once log and left ADR 003's whole argument — that waste causes must be
recorded from day one — with nothing accumulating. Four commands close that:

- **`cook "Recipe"`** plans first and writes second. It converts each
  ingredient into the product's own base unit, draws from lots in **FEFO**
  order (first expired, first out — undated lots last, since a known deadline
  outranks an unknown one), and refuses a recipe it cannot satisfy unless
  `--force`. `--dry-run` shows the plan without writing. Plan and execute are
  separate types, which is why the dry run is not a second code path that can
  drift from the real one.
- **`waste --reason ...`** records *why*, not just how much. That column is
  the one that answers "am I wasting less, and at what."
- **`eat`** is eating straight from the bag — same mechanism, different meaning.
- **`recount --observed N`** writes an `ADJUSTMENT`: what your eyes actually
  saw, which then supersedes everything before it.

Two rules the code follows that are easy to get wrong. Counting is exact, so
taking 2 packs is `measured`; measuring 400 g out of a bag is `derived`.
And a requirement that converts to a fraction of a piece rounds to a whole one
and **never to zero** — needing a little still means taking one.

## Balance, and why it is a view

`v_lot_balance` is the single answer to "how much is in this lot", and it
implements ADR 005's checkpoint rule: a recount is not another delta, it
*replaces* the balance, because a recount observes reality and reality already
contains everything that happened before it.

```
balance = the observed value at the last recount
        + only the deltas that occurred after it
```

Earlier events stay in the ledger — they still feed waste analysis — but are
excluded from the balance and reported as `superseded_events` rather than
dropped silently.

The matcher used to sum `pantry_event` itself and would therefore have ignored
recounts entirely. It reads the view now. `v_piece_weight` exists for the same
reason: cooking and matching both need ADR 004's bridge, and two copies of a
resolution chain is precisely the drift a view prevents.

## Where the logic lives, and why it differs by feature

The **expiry chain is a SQL view**, because three consumers must agree exactly
— the list, the notification job, and FEFO ordering when cooking. A view is
the only way to guarantee they cannot drift apart.

The **matcher's verdict rules are Swift**, because they have one consumer and
encode policy that will keep changing as ADR 004 is refined. As pure functions
they can be pinned down by checks with no database in the way. SQL fetches
facts; Swift decides what they mean.

`schema/queries/02_cook_tonight.sql` still exists and implements the same rules
independently. Running both and comparing is a genuine cross-check — they were
written separately and agree.

The two-target split is deliberate. When the iOS app arrives it imports
`PantryCore` unchanged and supplies a different interface; had the logic lived
inside the executable, all of it would need rewriting.

## What this slice proves

- **A capture is atomic.** Four tables are written in one transaction. Try
  `--unit kg` (not a legal base unit) and the raw row rolls back with
  everything else — a lot with no capture event would report a quantity of
  nothing, which is a lie rather than an absence.
- **Identity is the only hard requirement** (ADR 002). `pantry capture "x"
  --name "UNRESOLVED - stock cubes"` succeeds with a NULL unit, NULL class and
  NULL quantity, and flags itself for review.
- **NULL is not zero.** An item captured without a quantity stores NULL, and
  the CLI says so rather than printing `0`.
- **Answers carry their exclusions** (modelling rule 4). Every `list` reports
  how many lots it could not assess.
- **Surfaced is not notified** (ADR 001). `list --all` shows which items would
  actually push: only use-by dates and perishables. Every date currently in
  the pantry is a best-before, so nothing pushes — correct, and worth seeing.

## Notes for reading the Swift

Two lines tend to puzzle people arriving from Python.

`SQLITE_TRANSIENT` in `Database.swift` is a C constant Swift cannot import, so
it is rebuilt with `unsafeBitCast`. It tells SQLite to copy the bytes being
bound rather than trusting them to outlive the call.

`PRAGMA foreign_keys = ON` is issued on every connection because SQLite
disables foreign keys by default, for compatibility with code written before
2009. Without it, the schema's composite key silently enforces nothing.
