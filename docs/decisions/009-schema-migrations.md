# 009. The schema changes by numbered migration, never by rebuild

**Status:** accepted
**Date:** 2026-08-21

## Context

Until now the database was created by `build.sh`, which deletes the file and
replays the DDL. That is correct while the only contents are eleven seed items
regenerable from `002_seed.sql`.

ADR 008 put the database on the device. The moment the app runs on a phone,
the contents stop being reproducible: every capture, cook and waste event
exists in exactly one place, and "delete and rebuild" means telling the user
to throw away their own history.

The schema will certainly keep changing. Seeding eleven real items already
forced five changes in an afternoon — `is_opened` splitting from `opened_on`,
three columns becoming nullable, `qty_precision` learning to track its delta —
and a sixth arrived with month-precision dates. The audit that prompted this
record found more waiting: a dead `qty_on_hand_cached` column, and a write
path that only knows one of six event reasons.

So the question is not whether the schema changes but how it changes
underneath data that cannot be regenerated.

## Options considered

### Option A — Keep rebuilding from scratch
Zero machinery, and it is what already exists. Viable exactly as long as no
data matters. Rejected because the next step of the project makes data matter.

### Option B — Additive only, `CREATE TABLE IF NOT EXISTS` everywhere
Genuinely tempting: no version tracking, no ordering, no new concepts, and it
handles the common case of adding a table.

Rejected for three reasons. It cannot express a **data** change — when
`expires_on_precision` was added, every existing row needed backfilling to
`'day'`, and `IF NOT EXISTS` has nothing to say about that. It cannot express
a removal or a rename. And with no recorded version, two devices that
installed at different times can end up with quietly different schemas and no
way to detect it.

### Option C — Let a framework own the schema (SwiftData / Core Data)
Rejected on the grounds ADR 008 already established. The project chose
`Storage: None` deliberately: the schema *is* the artifact here, it is the
thing eight records were written about, and handing it to a framework would
mean re-expressing it in a different modelling language and losing the
constraints and the trigger that enforce the design.

### Option D — Numbered migrations against `PRAGMA user_version` (chosen)

## Decision

**The database records its own schema version** in SQLite's built-in
`user_version`, which is 0 in a new file. Migrations are numbered from 1.
`migrate()` applies only those above the recorded version and returns what it
ran, so a fresh install applies all of them, a partially upgraded one applies
the remainder, and an up-to-date one applies nothing.

This is ADR 003's reasoning applied to the schema itself: **the shape is never
overwritten, changes are appended, and the current shape is whatever replaying
them in order produces.** History is the truth; current state is derived.

**Migrations ship inside the library**, as `.sql` resources bundled with
`PantryCore` rather than files in `schema/`. An app in a sandbox on a phone
cannot read the repository; it has to carry its own upgrade instructions. The
canonical MySQL DDL stays in `schema/` because it is a phase 2 server artifact
with a different lifecycle.

**Migration 001 is the schema as it stands today**, not a reconstruction of
the six changes that produced it. Inventing history for a version that never
ran anywhere would be fiction. Numbering starts now.

Four properties, each pinned by a check:

- **A migration and its version bump share one transaction.** A step that
  fails halfway rolls back entirely. The alternative — a half-changed database
  claiming to be a version it is not — is unrecoverable without a backup.
- **Re-running is a no-op.** This is what allows the app to migrate on every
  launch without deciding whether it should.
- **A database newer than the build is refused, not opened.** This build
  cannot know what a later version changed, and guessing corrupts data the
  user cannot get back.
- **Versions run 1…latest with no gaps or duplicates.** A gap means a
  migration was written and never committed.

**Every command except `migrate` refuses an out-of-date schema.** Reading an
old shape tends to produce plausible wrong answers rather than errors, which
by modelling rule 4's own logic is the worse failure.

**`build.sh` applies migrations through this same code** instead of piping
SQL, so the development database and the device's are built by an identical
path and a broken migration breaks here first, where it is cheap.

## Consequences

- Easy: the schema can now change without destroying data, and the remaining
  audit findings (the dead cache column, the missing event reasons) become
  ordinary migrations rather than reasons to start over.
- Harder, and this is the discipline it costs: **a migration is immutable once
  it has run anywhere.** Editing 001 after a device has applied it means that
  device never receives the correction. Fixes are new migrations — the same
  rule these decision records follow.
- New work per schema change: a numbered file, and a data backfill wherever
  existing rows would otherwise be left with an unplanned NULL.
- Known constraint: SQLite's `ALTER TABLE` is narrow. Adding a column is easy;
  changing a constraint or dropping a column pre-3.35 requires the documented
  twelve-step table rebuild. Expect some migrations to be longer than one line.
- Implementation trap worth recording: `sqlite3_prepare_v2` compiles only the
  **first** statement of a string and silently discards the rest, so applying a
  migration through it would create one table and report success. Scripts go
  through `sqlite3_exec`. Both behaviours are pinned by checks.
- Revisit if: the phase 2 server arrives, at which point device and server
  schemas need coordinated versioning rather than one number per database.
