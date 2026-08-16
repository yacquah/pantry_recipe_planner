# 005. Local-first, with the ledger as its own outbox

**Status:** accepted
**Date:** 2026-08-15

## Context

A phone in a kitchen with bad wifi is the normal case, not the edge case. Both
v1 features are asked in exactly that spot: "what is expiring" while standing
at the fridge, "what can I cook" while standing at the pantry.

ADR 003 already did most of this work without being aimed at it — an
append-only ledger merges across devices in a way a mutable quantity column
never could. What remains is which data must be local, how sync retries stay
safe, and the one case where events genuinely do not merge cleanly.

## Options considered

### Option A — Online-first with an offline fallback
The common shape: normal path hits the API, a cache serves reads when the
network is down, writes queue in a separate mechanism. Rejected because it
creates two code paths that must agree, and the second one is exercised only
when things are already going wrong. Offline-only bugs are the hardest class
of bug to reproduce, and this architecture manufactures them.

### Option B — Full CRDT document store (Automerge, Yjs)
Genuinely solves multi-device merge in general. Rejected as over-engineering:
the delta ledger is *already* effectively a PN-Counter, so the general
machinery buys almost nothing here, and the one case it would help with
(absolute recounts) has a cleaner domain-specific answer below.

### Option C — Local-first, server as sync peer (chosen)

## Decision

**The device is the primary store; the server is a sync peer.** Writes land
locally and always succeed. Sync is background reconciliation, not part of the
write path. There is one code path regardless of connectivity, which is the
main point — an offline mode you can forget to test is an offline mode that
will be broken.

**On the device:** the event ledger, the derived inventory, the reference
tables (piece weight, density, shelf life — already vendored by ADR 004), and
the v1 recipe set. Both headline questions must be answerable with no signal.
Anything remote is enrichment and never a dependency.

**Remote is allowed only for barcode product lookup.** The camera is local, so
scanning always works; the code rides along on the raw capture and resolves on
reconnect. ADR 002 still requires a provisional identity at capture, so the
item is usable immediately. When the lookup lands it *proposes* a correction —
a machine lookup never silently overwrites what a human typed.

**Sync is the outbox pattern, and the ledger is already the outbox.** Events
not yet acknowledged by the server are the queue. No separate sync layer
exists, because ADR 003's log is the thing being synced.

Two mechanics make retries safe:

- **The client mints event IDs — UUIDv7, so they sort by time.** The server
  upserts by ID. A lost response causes a retry, and a retry must not become a
  second decrement. Server-side auto-increment IDs structurally cannot provide
  this, which is why the default instinct is wrong here.
- **Two timestamps, both retained.** `occurred_at` is the device's record of
  when the human acted; `received_at` is the server's and is authoritative for
  ordering. Device clocks are wrong often enough that ordering by them
  corrupts the ledger, and collapsing the two into one number would discard
  the truth about the world.

**Concurrent edits.** Deltas commute, so two devices consuming from the same
lot merge by summing with no conflict resolution whatsoever.

The exception is `ADJUSTMENT`, an absolute assertion, which does not commute.
The resolution follows the physics rather than the plumbing: **a recount
observes reality, and reality already includes everything that happened before
the observation** — whether or not the app had heard about it. Therefore an
`ADJUSTMENT` is a checkpoint:

```
balance = checkpoint value + Σ deltas where occurred_at > checkpoint time
```

Events from before a checkpoint that arrive after it are retained in the
ledger — they still feed waste analysis and piece-weight learning — but are
excluded from the balance and flagged, per modelling rule 4. Eyes beat the
ledger.

**Consequently v1 ships no conflict-resolution UI**, because the model leaves
nothing to resolve. Identity edits (renaming a product) are cosmetic and
recoverable, so last-write-wins is sufficient there.

**Scope.** v1 is one user, offline-capable, multi-device tolerated but not
designed for. Sync authenticates a *device*, not a *user*: no accounts, which
keeps auth out of v1 entirely (question 7). The distinction is what lets the
decision be deferred rather than made badly now.

## Consequences

- Easy: the app works in a basement. Multi-device arrives nearly free later,
  since the merge semantics are already correct.
- Harder: the device needs a real local database and schema migrations, and
  the reference tables have to be shipped and versioned inside the app.
- Constrains v1 recipes: they must be local, which rules out a live recipe API
  as a v1 dependency and feeds directly into question 7.
- New work: local store; outbox drain and retry; UUIDv7 generation on device;
  `received_at` server-side; checkpoint-aware balance computation; the
  propose-a-correction flow for late barcode resolution.
- Interacts with ADR 003 (the ledger is the sync unit and the outbox) and
  ADR 004 (vendored reference data is what makes offline lookups possible).
- Revisit if: real multi-device use appears, or a genuine collaboration case
  emerges (a shared household pantry) — that would reopen accounts, per-user
  attribution, and possibly Option B.
