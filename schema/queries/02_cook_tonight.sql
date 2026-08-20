-- Target query 2: "What can I cook tonight without a store run?"
--
-- Four-state answer per ADR 004 — never a confident yes or no across an
-- approximate or missing bridge. A false "no" quietly kills the feature: you
-- cook something else and the food rots anyway.

.mode column
.headers on

WITH on_hand AS (
  -- Quantity is derived, never stored (ADR 003).
  SELECT
    l.product_id,
    SUM(e.delta_base_unit) AS qty,
    SUM(CASE WHEN e.delta_base_unit IS NULL THEN 1 ELSE 0 END) AS unknown_events
  FROM pantry_event e
  JOIN lot l ON l.id = e.lot_id
  GROUP BY l.product_id
),
judged AS (
  SELECT
    r.name           AS recipe,
    p.canonical_name AS ingredient,
    ri.qty           AS need_qty,
    ri.unit          AS need_unit,
    p.base_unit,
    oh.qty           AS have_qty,
    CASE
      -- The quantity itself is unknown (basmati: bag size never recorded).
      WHEN oh.qty IS NULL OR oh.unknown_events > 0        THEN 'CANNOT_TELL'
      -- Same unit both sides: exact comparison, no bridge needed.
      WHEN ri.unit = p.base_unit AND oh.qty >= ri.qty     THEN 'HAVE'
      WHEN ri.unit = p.base_unit                          THEN 'SHORT'
      -- Bridge present but approximate: hedge, never a firm answer.
      WHEN ri.unit = 'g' AND p.base_unit = 'count' AND pw.typical_g IS NOT NULL
           AND oh.qty * pw.typical_g >= ri.qty            THEN 'PROBABLY'
      WHEN ri.unit = 'g' AND p.base_unit = 'count' AND pw.typical_g IS NOT NULL
                                                          THEN 'PROBABLY_SHORT'
      -- Bridge needed and missing (ADR 004 tier 5).
      ELSE 'CANNOT_TELL'
    END AS verdict
  FROM recipe_ingredient ri
  JOIN recipe  r ON r.id = ri.recipe_id
  JOIN product p ON p.id = ri.product_id
  LEFT JOIN on_hand oh ON oh.product_id = ri.product_id
  LEFT JOIN piece_weight_curated pw ON pw.product_id = ri.product_id
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
    'all ingredients confirmed') AS decided_by,
  COUNT(*)                    AS ingredients,
  SUM(verdict = 'CANNOT_TELL') AS excluded
FROM judged
GROUP BY recipe
ORDER BY
  CASE WHEN SUM(verdict = 'SHORT') > 0       THEN 3
       WHEN SUM(verdict = 'CANNOT_TELL') > 0 THEN 2
       ELSE 1 END,
  recipe;
