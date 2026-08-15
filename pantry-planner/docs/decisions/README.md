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
| 001 | Expiry when unknown | Not yet written |
| 002 | [Incomplete capture: land with NULL, report exclusions](002-incomplete-capture.md) | Accepted |
| 003 | [Food leaves via an append-only event ledger](003-consumption-event-ledger.md) | Accepted |

## Candidates queued

- Rice substitution: are jasmine and basmati interchangeable? (seed rows 1, 7)
- Density source: hardcoded table, or third-party lookup?
- Lot granularity: does restocking the same product always open a new lot, or
  may identical unopened packages share one? (ADR 003 assumes lot-level expiry)
- Cached `qty_on_hand`: reconcile job cadence, and what happens when the cache
  and the ledger disagree (ADR 003)
