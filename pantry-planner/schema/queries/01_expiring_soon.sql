-- Target query 1: "What is expiring in the next 3 days?"
--
-- Reads ADR 001's chain from v_lot_expiry, and obeys modelling rule 4: the
-- answer carries its own exclusions, because a list that silently omits what
-- it could not assess is more dangerous than one that refuses to answer.
--
-- Wording follows ADR 001's asymmetry. A use-by is a safety date and pushes a
-- notification. A best-before is a quality date: it ranks the item for use and
-- shows a status, but never says "expired" and never pushes — an app that
-- makes you bin good cereal is causing the waste it exists to prevent.

.mode column
.headers on

WITH params AS (SELECT date('now') AS today, 3 AS horizon_days)
SELECT
  canonical_name AS item,
  -- A month-precision date never renders a day nobody saw.
  CASE WHEN expires_on_precision = 'month'
       THEN strftime('%Y-%m', effective_date) || ' (month only)'
       ELSE effective_date END AS acts_by,
  expiry_source AS source,
  CASE WHEN expiry_kind = 'use_by'      THEN 'USE BY - safety date'
       WHEN expiry_kind = 'best_before' THEN 'past best before, likely fine'
       ELSE 'estimated, no date recorded' END AS wording,
  CASE WHEN expiry_kind = 'use_by' OR shelf_life_class = 'perishable'
       THEN 'push' ELSE 'list only' END AS notify
FROM v_lot_expiry, params
WHERE effective_date IS NOT NULL
  AND effective_date <= date(params.today, '+' || params.horizon_days || ' days')
ORDER BY effective_date;

-- Rule 4: every aggregate reports its own exclusions.
WITH params AS (SELECT date('now') AS today, 3 AS horizon_days)
SELECT
  (SELECT COUNT(*) FROM v_lot_expiry, params
     WHERE effective_date IS NOT NULL
       AND effective_date <= date(params.today, '+' || params.horizon_days || ' days'))
                                                          AS expiring_soon,
  (SELECT COUNT(*) FROM v_lot_expiry WHERE expiry_source = 'not_applicable')
                                                          AS not_applicable,
  (SELECT COUNT(*) FROM v_lot_expiry WHERE expiry_source = 'unknown')
                                                          AS excluded_unknown,
  (SELECT COUNT(*) FROM lot)                              AS lots_total;

-- Everything the app knows about expiry, for inspection. Not a v1 screen —
-- this is how you check the chain is doing what the ADR says.
SELECT
  canonical_name AS item,
  COALESCE(CASE WHEN expires_on_precision = 'month'
                THEN strftime('%Y-%m', effective_date) || ' (month)'
                ELSE effective_date END, '-') AS acts_by,
  expiry_source AS source,
  COALESCE(expiry_kind, '-') AS kind,
  COALESCE(shelf_life_state, 'unknown') AS state
FROM v_lot_expiry
ORDER BY effective_date IS NULL, effective_date;
