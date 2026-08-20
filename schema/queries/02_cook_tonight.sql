-- Target query 2: "What can I cook tonight without a store run?"
--
-- Four-state answer per ADR 004 — never a confident yes or no across an
-- approximate bridge. A false "no" quietly kills the feature: you cook
-- something else and the food rots anyway.

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
bridge AS (
  -- ADR 004's piece-weight chain, in order. Tier 2 (this user's measurement
  -- history) is absent because there is no history yet; tier 4 (a vendored
  -- reference dataset) is not in v1.
  SELECT
    p.id AS product_id,
    COALESCE(m.measured_g, pw.typical_g) AS g_each,
    CASE
      -- Tier 1: weighed on this lot. The per-piece figure is an average, but
      -- the TOTAL it reconstructs is exact, because the total is what was
      -- actually weighed. Aggregating back over the same set is lossless —
      -- it is dividing down to a single piece that introduces error.
      WHEN m.measured_g IS NOT NULL THEN 'measured'
      -- Tier 3, manufactured: min = max records a printed weight with no
      -- spread, so it is exact in both directions.
      WHEN pw.min_g = pw.max_g      THEN 'printed'
      -- Tier 3, natural: a reference average. Genuinely approximate.
      WHEN pw.typical_g IS NOT NULL THEN 'reference'
      ELSE NULL                     -- Tier 5: no bridge exists
    END AS bridge_source
  FROM product p
  LEFT JOIN piece_weight_curated pw ON pw.product_id = p.id
  LEFT JOIN (
    -- Averaged across lots. With one lot per product this is exact; when a
    -- product has several, the FEFO lot's own measurement would be better.
    SELECT product_id, AVG(measured_piece_weight_g) AS measured_g
    FROM lot WHERE measured_piece_weight_g IS NOT NULL
    GROUP BY product_id
  ) m ON m.product_id = p.id
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
