# 002. Incomplete capture: land with NULL, report exclusions

**Status:** accepted
**Date:** 2026-08-10

## Context

Capture data arrives incomplete from both entry paths: a barcode scan can
return nothing (loose chicken wings, seed row 11) or a partial product, and
manual entry has gaps. The live worst case is seed row 6 — "a Lipton box":
ambiguous product, no quantity, no unit. The app prompts for exactly the
missing fields ("how many tea bags inside?"), but the user may genuinely not
know. Something must happen to the item anyway, because it is a real thing
sitting in the pantry.

## Options considered

### Option A — Block until complete
No canonical row without all required fields. Rejected: it makes seed row 6
unrepresentable, and a capture flow that can be abandoned mid-kitchen loses
data permanently.

### Option B — Hold in a pending queue
Save the raw capture but create no canonical row until resolved. Rejected as
redundant: the raw layer (MongoDB) already *is* the pending queue — every
capture lands there first and is transformed later. A second queue duplicates
it, and hides a real item from inventory views in the meantime.

### Option C — Land canonical with NULL, flagged (chosen)
Identity is the only hard requirement — even a provisional one ("Lipton box,
product unresolved"). Everything else may be NULL.

## Decision

Prompt for exactly the missing fields at capture time. If a field cannot be
provided, the item lands in the canonical store anyway: identity required,
every other field nullable, plus a needs-review flag. Identity matters most;
quantity can always be improved later.

Storage note: UNKNOWN is the *concept* (modelling rule 3); **NULL is its
storage form**. Never a literal "UNKNOWN" string, never 0.

The discipline that makes this safe: **every aggregate reports its own
exclusions.** A query that sums pantry weight and silently skips three NULL
rows is more dangerous than one that refuses to answer, because it returns a
plausible number nobody questions. Return shape:

```
{ total: 10739, unit: "g", excluded: 3 }
```

and the UI shows "3 items not counted." Flags that nothing surfaces are just
decoration.

## Consequences

- Easy: capture never blocks; the Lipton box is representable on day one.
- Harder: every query must define its NULL behaviour explicitly, and every
  aggregate's return shape carries `excluded` — no bare numbers anywhere.
- New work: needs-review flag column; a UI surface that lists flagged items;
  normalisation rules for promoting a resolved field from NULL.
- Revisit if: flagged rows accumulate without ever being resolved — that
  means the prompt design is failing, not the schema.
