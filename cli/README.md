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
pantry list                     # expiring within 3 days, plus exclusions
pantry list --days 30
pantry list --all               # every lot, and where its date came from

pantry capture "half a bag of red lentils" --name "Red lentils" \
    --unit g --qty 250 --class ambient_stable --precision estimated
```

## Layout

```
Sources/PantryCore/     the logic — no printing, no argument parsing
  Database.swift        thin wrapper over the C SQLite API
  UUIDv7.swift          client-minted, time-ordered ids (ADR 005)
  Capture.swift         raw_capture -> product -> lot -> ledger, transactional
  Expiry.swift          reads ADR 001's chain out of v_lot_expiry
Sources/pantry/
  main.swift            argument parsing and output, nothing else
```

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
