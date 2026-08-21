-- 003. ADR 004's piece-weight chain, in one place.
--
-- The matcher already resolved this inline. Cooking now needs the same
-- conversion — a recipe asking for 200 g of a food stored by the piece has to
-- know how many pieces to take off the ledger — and two copies of a resolution
-- chain is exactly the drift a view exists to prevent.
--
-- Order is the chain from ADR 004. Tier 2 (this user's measurement history)
-- and tier 4 (a vendored reference dataset) are not implemented; when they
-- arrive they slot in here and every caller gets them at once.
--
-- `source` is returned alongside the number and must never be dropped: it is
-- what decides whether an answer derived through this bridge may be stated
-- confidently. Aggregating up over the same set that was weighed is lossless;
-- dividing down to a single piece is not.

CREATE VIEW v_piece_weight AS
SELECT
  p.id AS product_id,

  COALESCE(measured.grams_each, curated.typical_g) AS grams_each,

  CASE
    -- Tier 1: weighed on this lot. Exact for totals.
    WHEN measured.grams_each IS NOT NULL     THEN 'measured'
    -- Tier 3, manufactured: min = max means a printed weight with no spread.
    WHEN curated.min_g = curated.max_g       THEN 'printed'
    -- Tier 3, natural: a reference average. Genuinely approximate.
    WHEN curated.typical_g IS NOT NULL       THEN 'reference'
    -- Tier 5: no bridge exists. Callers must say so rather than guess.
    ELSE NULL
  END AS source,

  curated.min_g,
  curated.max_g

FROM product p
LEFT JOIN piece_weight_curated curated ON curated.product_id = p.id
LEFT JOIN (
  -- Averaged across lots. With one lot per product this is exact; when a
  -- product has several, the FEFO lot's own measurement would be better.
  SELECT product_id, AVG(measured_piece_weight_g) AS grams_each
    FROM lot
   WHERE measured_piece_weight_g IS NOT NULL
   GROUP BY product_id
) measured ON measured.product_id = p.id;
