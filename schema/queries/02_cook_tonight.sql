-- Target query 2: "What can I cook tonight without a store run?"
--
-- Four-state answer per ADR 004 — never a confident yes or no across an
-- approximate bridge. A false "no" quietly kills the feature: you cook
-- something else and the food rots anyway.

.mode column
.headers on

WITH on_hand AS (
  -- Quantity is derived, never stored (ADR 003) — and derived through
  -- v_lot_balance rather than by summing here, so that a recount is honoured.
  -- ADR 005 makes an ADJUSTMENT a checkpoint that supersedes earlier events;
  -- a caller doing its own SUM cannot know that and would answer with history
  -- the user has already corrected.
  SELECT product_id,
         SUM(balance)        AS qty,
         SUM(unknown_events) AS unknown_events
  FROM v_lot_balance
  GROUP BY product_id
),
bridge AS (
  -- ADR 004's piece-weight chain, from the view both implementations share.
  -- `source` is what decides whether an answer may be stated confidently.
  SELECT product_id, grams_each AS g_each, source AS bridge_source
  FROM v_piece_weight
),
judged AS (
  SELECT
    r.name           AS recipe,
    p.canonical_name AS ingredient,
    ri.qty           AS need_qty,
    ri.unit          AS need_unit,
    p.base_unit,
    oh.qty           AS have_qty,
    b.bridge_source,
    CASE
      -- The quantity itself is unknown (basmati: bag size never recorded).
      WHEN oh.qty IS NULL OR oh.unknown_events > 0 THEN 'CANNOT_TELL'
      -- Same unit both sides: exact comparison, no bridge needed.
      WHEN ri.unit = p.base_unit AND oh.qty >= ri.qty THEN 'HAVE'
      WHEN ri.unit = p.base_unit                      THEN 'SHORT'
      -- No bridge exists (ADR 004 tier 5).
      WHEN b.g_each IS NULL                           THEN 'CANNOT_TELL'
      -- A bridge exists. Whether the answer may be stated confidently depends
      -- on WHERE the number came from, not on how comfortable the margin looks.
      WHEN ri.unit = 'g' AND p.base_unit = 'count'
           AND b.bridge_source IN ('measured','printed')
        THEN CASE WHEN oh.qty * b.g_each >= ri.qty THEN 'HAVE' ELSE 'SHORT' END
      WHEN ri.unit = 'g' AND p.base_unit = 'count'
        THEN CASE WHEN oh.qty * b.g_each >= ri.qty
                  THEN 'PROBABLY' ELSE 'PROBABLY_SHORT' END
      ELSE 'CANNOT_TELL'
    END AS verdict
  FROM recipe_ingredient ri
  JOIN recipe  r ON r.id = ri.recipe_id
  JOIN product p ON p.id = ri.product_id
  LEFT JOIN on_hand oh ON oh.product_id = ri.product_id
  LEFT JOIN bridge  b  ON b.product_id  = ri.product_id
)
SELECT
  recipe,
  CASE
    WHEN SUM(verdict = 'SHORT') > 0                        THEN 'NO'
    WHEN SUM(verdict = 'CANNOT_TELL') > 0                  THEN 'CANNOT TELL'
    WHEN SUM(verdict IN ('PROBABLY','PROBABLY_SHORT')) > 0 THEN 'PROBABLY - CHECK'
    ELSE 'YES'
  END AS answer,
  -- Never just a verdict: name the ingredient that decided it, and why.
  COALESCE(
    MAX(CASE WHEN verdict = 'SHORT' THEN ingredient || ' (short)' END),
    MAX(CASE WHEN verdict = 'CANNOT_TELL' THEN
      ingredient || ' (' ||
      CASE WHEN have_qty IS NULL THEN 'quantity unknown'
           ELSE 'needs ' || need_unit || ', stored as ' || base_unit ||
                ', no piece weight' END || ')' END),
    MAX(CASE WHEN verdict LIKE 'PROBABLY%' THEN
      ingredient || ' (via ' || bridge_source || ' piece weight)' END),
    'all ingredients confirmed') AS decided_by,
  COUNT(*)                     AS ingredients,
  SUM(verdict = 'CANNOT_TELL') AS excluded
FROM judged
GROUP BY recipe
ORDER BY
  CASE WHEN SUM(verdict = 'SHORT') > 0       THEN 3
       WHEN SUM(verdict = 'CANNOT_TELL') > 0 THEN 2
       ELSE 1 END,
  recipe;
