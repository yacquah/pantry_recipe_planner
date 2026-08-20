# 008. v1 ships without a server; the backend is phase 2

**Status:** accepted
**Date:** 2026-08-16

## Context

The architecture in the README was drawn in week one, before ADRs 005 and 006
existed: iOS client → backend API → MongoDB (raw) → normalisation → MySQL
(canonical) → recipe matcher.

Two later decisions quietly hollowed it out. ADR 005 made the **device** the
primary store and demoted the server to a sync peer. ADR 006 cut accounts,
household sharing and multi-device collaboration. Together they leave the
server exactly one job in v1: backing up a database that has only ever had one
copy — which iCloud already does, for free, with no code.

Meanwhile the schema stage produced a SQLite database that answers both v1
questions against the real pantry. The thing that was supposed to require a
backend has been running without one.

This project has **two stated goals**, and they pull in different directions:
an app actually used in a kitchen, and the experience of having built a
backend. Both are real. The question is not which to abandon but in which
order to do them.

## Options considered

### Option A — Build the stack first, as drawn
Rejected for v1: weeks of infrastructure delivering nothing anyone can open in
a kitchen. It is the kind of work that feels productive for a month and is the
most common way a project of this shape dies.

### Option B — Device only, backend deferred indefinitely
Rejected because it discards a genuine goal. "Later" with no trigger and no
record is how an intention quietly stops existing.

### Option C — Device-only v1, backend as a committed phase 2 (chosen)

## Decision

**v1 has no server.** One SQLite database on the device — the schema in
`schema/001_device_sqlite.sql`.

**The raw/canonical boundary survives intact**, because it was never really
about MongoDB. Raw captures land in a `raw_capture` table in the same SQLite
file: document-shaped payloads in a JSON column, never edited, with
normalisation reading from it and writing the canonical tables. The principle
is a *discipline*, not a consequence of running two database engines, and it
holds in one file.

**Data safety is the platform's job** in v1. iCloud backup, not a service.

**The backend is phase 2, and it is committed rather than hoped for.** Its
trigger is concrete: v1 working and in daily use. Its purpose is explicitly
both sync and learning, and that is recorded here so it cannot later be
mistaken for scope creep.

Sequencing it second is **better for learning, not merely faster.** A backend
built first would be served against an imaginary client, and its most
interesting problems would be invisible. Built second, it arrives with a real
schema, real data, and a real client already emitting events — so idempotent
sync, conflict handling, and migration stop being abstractions and become
things that either work or visibly do not. Building it first would mostly mean
designing the schema twice.

**Nothing in ADR 005 is reversed.** Client-minted UUIDv7 identifiers, two
retained timestamps, checkpoint semantics for recounts, and the ledger as its
own outbox all still apply and cost nothing today; the outbox simply has no
peer to drain to yet, and `received_at` defaults to local insertion time until
a server exists to stamp it. Keeping them now is precisely what makes phase 2
a feature rather than a rewrite.

**`schema/001_canonical_mysql.sql` stays in the repository** as the phase 2
target. It is not dead code — it is the second half of a migration that has
not started. Both DDL files change together, which is the mitigation for the
usual failure here: a device schema quietly drifting away from a server schema
nobody is running.

## Consequences

- Easy: v1 is buildable by one person in a reasonable time, and the first code
  written is an app rather than infrastructure.
- Easy: everything works offline already, because there is nothing to be
  offline *from* except the barcode lookup — a third-party API that ADR 005
  had already made optional.
- Harder: no cross-device story and no way to inspect the data except on the
  phone or by rebuilding locally.
- New work in v1: a `raw_capture` table, which the device schema does not have
  yet — it currently models only the canonical side.
- Named risk: phase 2 never happens, and this becomes Option B by neglect.
  The trigger above is the guard; if v1 is in daily use and the backend has
  not started, that is the signal, not a scheduling accident.
- Phase 2 reopens a question this decision does not settle: whether the raw
  layer needs MongoDB at all, given it works as a JSON column. Queued.
