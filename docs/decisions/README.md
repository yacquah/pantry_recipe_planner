# Decision records

One file per significant choice. Numbered, immutable once written — if a
decision changes, write a new record that supersedes the old one rather than
editing history.

Five lines is a perfectly good record. The value is not in the prose, it is in
the **rejected options**: three months from now the useful question is never
"what did I do" (the code says that) but "what did I already rule out, and why."

## Naming

`NNN-short-kebab-title.md`, e.g. `001-expiry-when-unknown.md`

## Index

| # | Title | Status |
|---|-------|--------|
| 001 | [Expiry when unknown](001-expiry-when-unknown.md) | Accepted |
| 002 | [Incomplete capture: land with NULL, report exclusions](002-incomplete-capture.md) | Accepted |
| 003 | [Food leaves via an append-only event ledger](003-consumption-event-ledger.md) | Accepted |
| 004 | [The countable/measurable bridge, and where piece weights come from](004-countable-measurable-bridge.md) | Accepted |
| 005 | [Local-first, with the ledger as its own outbox](005-local-first-sync.md) | Accepted |
| 006 | [What v1 does not build](006-v1-scope-boundary.md) | Accepted |
| 007 | [What a lot is, and when one splits](007-lot-granularity.md) | Accepted |
| 008 | [v1 ships without a server; the backend is phase 2](008-no-server-in-v1.md) | Accepted |

## Candidates queued

- Rice substitution: are jasmine and basmati interchangeable? (seed rows 1, 7)
  — deferred by ADR 006; recipes reference own products, so v1 never asks
- Does the raw layer need MongoDB at all, given it works as a JSON column in
  SQLite? (phase 2, raised by ADR 008)
- Cached `qty_on_hand`: reconcile job cadence, and what happens when the cache
  and the ledger disagree (ADR 003)
- Cached `qty_on_hand`: reconcile job cadence, and what happens when the cache
  and the ledger disagree (ADR 003)
