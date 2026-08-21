-- 004. Expose the shelf life a date was derived from, so lead time can vary.
--
-- Spec §5 sets the notification lead time at `min(3 days, 30% of applicable
-- shelf life)`. The 30% half needs a number the view already computes and then
-- throws away: COALESCE(slp.days, slc.days), the shelf life for this lot's
-- state. Without it every caller would have to re-join shelf_life_by_class and
-- shelf_life_by_product itself, which is the drift v_lot_expiry exists to
-- prevent.
--
-- It is returned for label-dated lots too, where it did NOT produce the date.
-- That is deliberate: a label date still belongs to a food with a shelf life,
-- and how fast that food goes off is what decides how much warning is useful.
-- Three days' notice on a bag of salad and on a tin of tomatoes are not the
-- same gesture, however the date was arrived at.
--
-- NULL keeps its usual meaning (rule 3) — no shelf life is recorded for this
-- class and state, so no lead time can be derived from one and callers fall
-- back to the 3-day ceiling. ambient_stable rows are NULL by design.
--
-- A view cannot be altered in SQLite, only replaced. Dropping and recreating
-- is safe here because a view holds no data; the SELECT below is 001's, with
-- one column added and nothing else touched.

DROP VIEW v_lot_expiry;

CREATE VIEW v_lot_expiry AS
SELECT
  l.id                    AS lot_id,
  l.product_id,
  p.canonical_name,
  p.brand,
  p.shelf_life_class,
  l.shelf_life_state,
  l.expiry_kind,
  l.expires_on_precision,

  -- New in 004. The shelf life applicable to this lot in its current state.
  COALESCE(slp.days, slc.days) AS shelf_life_days,

  CASE
    WHEN l.expires_on IS NOT NULL THEN 'label'
    WHEN l.shelf_life_state = 'opened' AND l.opened_on IS NOT NULL
         AND COALESCE(slp.days, slc.days) IS NOT NULL THEN 'derived_opened'
    WHEN l.shelf_life_state IS NOT NULL
         AND COALESCE(slp.days, slc.days) IS NOT NULL
      THEN 'derived_' || l.shelf_life_state
    WHEN p.shelf_life_class = 'ambient_stable' THEN 'not_applicable'
    ELSE 'unknown'
  END AS expiry_source,
  CASE
    WHEN l.expires_on IS NOT NULL THEN l.expires_on
    WHEN l.shelf_life_state = 'opened' AND l.opened_on IS NOT NULL
         AND COALESCE(slp.days, slc.days) IS NOT NULL
      THEN date(l.opened_on,   '+' || COALESCE(slp.days, slc.days) || ' days')
    WHEN l.shelf_life_state IS NOT NULL
         AND COALESCE(slp.days, slc.days) IS NOT NULL
      THEN date(l.acquired_on, '+' || COALESCE(slp.days, slc.days) || ' days')
    ELSE NULL
  END AS effective_date
FROM lot l
JOIN product p ON p.id = l.product_id
LEFT JOIN shelf_life_by_class slc
  ON slc.shelf_life_class = p.shelf_life_class AND slc.state = l.shelf_life_state
LEFT JOIN shelf_life_by_product slp
  ON slp.product_id = p.id AND slp.state = l.shelf_life_state;
