-- 002. One definition of "how much is in this lot".
--
-- Until now every caller summed pantry_event itself. That was fine while the
-- only event reason was CAPTURE, and wrong the moment ADJUSTMENT exists —
-- ADR 005 says a recount is a CHECKPOINT, not another delta.
--
-- The reasoning is physical rather than technical: a recount observes reality,
-- and reality already reflects everything that happened before the observation,
-- whether or not the app had heard about it. So a checkpoint absorbs every
-- earlier event, and only what happened afterwards is added to it.
--
--     balance = observed value at the last recount
--             + deltas that occurred after it
--
-- This lives in a view for the same reason the expiry chain does: several
-- consumers must agree exactly — the matcher, the cook command, FEFO lot
-- selection, and the app's UI. A view is the only way to guarantee they
-- cannot drift.
--
-- Events from before a checkpoint stay in the ledger. They still feed waste
-- analysis and piece-weight learning; they are simply excluded from the
-- balance, which is what "eyes beat the ledger" means in practice.

CREATE VIEW v_lot_balance AS
WITH checkpoint AS (
  -- SQLite guarantees that when MAX() is used with bare columns, those columns
  -- come from the row holding the maximum. So this is the latest recount per
  -- lot, with its observed value, in one pass.
  SELECT lot_id,
         MAX(occurred_at) AS at,
         observed_qty     AS value,
         id               AS event_id
    FROM pantry_event
   WHERE reason = 'ADJUSTMENT'
   GROUP BY lot_id
)
SELECT
  l.id          AS lot_id,
  l.product_id,
  c.at          AS checkpoint_at,

  CASE
    WHEN c.at IS NULL
      -- No recount has ever happened: the balance is the whole ledger. NULL
      -- when every delta is NULL, which is an honest "we do not know" rather
      -- than a zero.
      THEN SUM(e.delta_base_unit)
    ELSE
      c.value + COALESCE(
        SUM(CASE WHEN e.occurred_at > c.at THEN e.delta_base_unit END), 0)
  END AS balance,

  -- How many of the events that COUNT toward this balance had an unknown
  -- amount. Modelling rule 4: an aggregate reports its own exclusions, so
  -- callers can say "3 items not counted" instead of quietly being wrong.
  SUM(CASE
        WHEN e.delta_base_unit IS NULL
         AND (c.at IS NULL OR e.occurred_at > c.at)
        THEN 1 ELSE 0
      END) AS unknown_events,

  -- Events from before the checkpoint, retained but not counted. Surfacing
  -- the number keeps the exclusion visible rather than silent.
  -- Compared by id, not just time: the checkpoint event shares its own
  -- timestamp and must not be counted as something it superseded.
  SUM(CASE
        WHEN c.at IS NOT NULL
         AND e.occurred_at <= c.at
         AND e.id <> c.event_id
        THEN 1 ELSE 0
      END) AS superseded_events

FROM lot l
LEFT JOIN pantry_event e ON e.lot_id = l.id
LEFT JOIN checkpoint   c ON c.lot_id = l.id
GROUP BY l.id;
