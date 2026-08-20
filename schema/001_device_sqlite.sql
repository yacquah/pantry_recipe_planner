-- Pantry Planner — device replica (SQLite 3.31+, for generated columns)
--
-- Not a test rig. ADR 005 makes the phone the primary store, and on iOS that
-- store is SQLite, so this is the schema that actually runs in the kitchen.
-- It mirrors schema/001_canonical_mysql.sql; the differences are dialect only:
--   ENUM            -> TEXT with a CHECK
--   AUTO_INCREMENT  -> INTEGER PRIMARY KEY
--   DATETIME(3)     -> TEXT (ISO-8601)
--   DECIMAL         -> NUMERIC affinity (SQLite has no fixed-point type; the
--                      canonical store keeps real DECIMAL, so money-grade
--                      arithmetic happens server-side)

PRAGMA foreign_keys = ON;

CREATE TABLE product (
  id               INTEGER PRIMARY KEY,
  canonical_name   TEXT NOT NULL,
  brand            TEXT NULL,
  -- Nullable: ADR 002 makes identity the only hard requirement, and seed row 6
  -- ("a Lipton box") has no knowable unit.
  base_unit        TEXT NULL CHECK (base_unit IN ('g','ml','count')),
  shelf_life_class TEXT NULL CHECK (shelf_life_class IN
                     ('ambient_stable','stable_until_opened','perishable')),
  countable_kind   TEXT NULL CHECK (countable_kind IN
                     ('manufactured','natural','pure')),
  needs_review     INTEGER NOT NULL DEFAULT 0,
  created_at       TEXT NOT NULL DEFAULT (datetime('now')),
  brand_key        TEXT GENERATED ALWAYS AS (COALESCE(brand,'')) STORED,
  CHECK (countable_kind IS NULL OR base_unit = 'count')
);
CREATE UNIQUE INDEX uq_product_identity ON product(canonical_name, brand_key);

CREATE TABLE product_barcode (
  barcode    TEXT PRIMARY KEY,
  product_id INTEGER NOT NULL REFERENCES product(id)
);

CREATE TABLE recipe (
  id       INTEGER PRIMARY KEY,
  name     TEXT NOT NULL UNIQUE,
  servings INTEGER NULL
);

CREATE TABLE recipe_ingredient (
  recipe_id  INTEGER NOT NULL REFERENCES recipe(id) ON DELETE CASCADE,
  -- A real foreign key, not free text: the payoff of cutting import (ADR 006).
  product_id INTEGER NOT NULL REFERENCES product(id),
  qty        NUMERIC NOT NULL CHECK (qty > 0),
  unit       TEXT NOT NULL CHECK (unit IN ('g','ml','count')),
  PRIMARY KEY (recipe_id, product_id)
);

CREATE TABLE lot (
  id                      INTEGER PRIMARY KEY,
  product_id              INTEGER NOT NULL REFERENCES product(id),
  acquired_on             TEXT NOT NULL,
  -- Only dates a human read off a label. Estimates are derived at read time
  -- and never written here (ADR 001).
  expires_on              TEXT NULL,
  expiry_kind             TEXT NULL CHECK (expiry_kind IN
                            ('use_by','best_before','sell_by')),
  -- Packaging often prints only year and month; storing that as a date invents
  -- a day. Month-precision best-before resolves to the last day of the month,
  -- month-precision use-by to the first (ADR 001: err early on safety).
  expires_on_precision    TEXT NULL CHECK (expires_on_precision IN ('day','month')),
  -- All three nullable: seed row 1 is open but undated, seed row 11 may be
  -- fresh or frozen and nobody knows.
  is_opened               INTEGER NULL,
  opened_on               TEXT NULL,
  is_frozen               INTEGER NULL,
  container_type          TEXT NULL,
  units_per_container     INTEGER NULL,
  size_per_unit           NUMERIC NULL,
  measured_piece_weight_g NUMERIC NULL,
  qty_on_hand_cached      NUMERIC NULL,
  needs_review            INTEGER NOT NULL DEFAULT 0,
  notes                   TEXT NULL,
  -- Frozen outranks opened: freezing suspends spoilage. NULL when unknown.
  shelf_life_state        TEXT GENERATED ALWAYS AS (
                            CASE WHEN is_frozen = 1 THEN 'frozen'
                                 WHEN is_opened = 1 THEN 'opened'
                                 WHEN is_frozen = 0 AND is_opened = 0 THEN 'sealed'
                                 ELSE NULL END
                          ) STORED,
  CHECK (expires_on IS NULL
         OR (expiry_kind IS NOT NULL AND expires_on_precision IS NOT NULL)),
  UNIQUE (id, product_id)          -- enables the composite FK below
);
CREATE INDEX ix_lot_expiry ON lot(expires_on);

CREATE TABLE pantry_event (
  id              TEXT PRIMARY KEY,          -- client-minted UUIDv7 (ADR 005)
  lot_id          INTEGER NOT NULL,
  product_id      INTEGER NOT NULL,
  delta_base_unit NUMERIC NULL,              -- NULL = amount unknown
  reason          TEXT NOT NULL CHECK (reason IN
                    ('CAPTURE','COOK','CONSUME','WASTE','ADJUSTMENT','TRANSFER')),
  waste_reason    TEXT NULL CHECK (waste_reason IN
                    ('expired','spoiled','freezer_burn','disliked','accident')),
  -- Nullable in lockstep with the delta: precision describes a number, and
  -- seed row 6 has no number to describe.
  qty_precision   TEXT NULL CHECK (qty_precision IN
                    ('measured','derived','estimated')),
  recipe_id       INTEGER NULL REFERENCES recipe(id),
  observed_qty    NUMERIC NULL,
  occurred_at     TEXT NOT NULL,
  received_at     TEXT NOT NULL DEFAULT (datetime('now')),
  device_id       TEXT NOT NULL,
  -- Makes a product/lot mismatch structurally impossible.
  FOREIGN KEY (lot_id, product_id) REFERENCES lot(id, product_id),
  -- "=" between two booleans reads as "if and only if".
  CHECK ((reason = 'WASTE')      = (waste_reason IS NOT NULL)),
  CHECK ((reason = 'ADJUSTMENT') = (observed_qty IS NOT NULL)),
  CHECK (reason = 'COOK' OR recipe_id IS NULL),
  CHECK ((delta_base_unit IS NULL) = (qty_precision IS NULL))
);
CREATE INDEX ix_event_lot_time ON pantry_event(lot_id, occurred_at);
CREATE INDEX ix_event_reason   ON pantry_event(reason, occurred_at);

-- days IS NULL means NOT APPLICABLE, which is not the same as unknown.
CREATE TABLE shelf_life_by_class (
  shelf_life_class TEXT NOT NULL,
  state            TEXT NOT NULL,
  days             INTEGER NULL,
  PRIMARY KEY (shelf_life_class, state)
);

CREATE TABLE shelf_life_by_product (
  product_id INTEGER NOT NULL REFERENCES product(id),
  state      TEXT NOT NULL,
  days       INTEGER NULL,
  PRIMARY KEY (product_id, state)
);

-- Separate from density on purpose: density is a constant, piece weight is a
-- distribution (ADR 004).
CREATE TABLE piece_weight_curated (
  product_id INTEGER PRIMARY KEY REFERENCES product(id),
  typical_g  NUMERIC NOT NULL,
  min_g      NUMERIC NULL,
  max_g      NUMERIC NULL,
  CHECK ((min_g IS NULL OR min_g <= typical_g) AND
         (max_g IS NULL OR max_g >= typical_g))
);

CREATE TABLE density (
  product_id INTEGER PRIMARY KEY REFERENCES product(id),
  g_per_ml   NUMERIC NOT NULL CHECK (g_per_ml > 0)
);

-- ---------------------------------------------------------------------------
-- ADR 001's resolution chain, as a view. Lives here rather than in a query
-- file because more than one caller needs it: the expiry list, the
-- notification job, and FEFO ordering when cooking.
--
-- expiry_source is returned alongside the date and is never dropped. A date
-- without its provenance is indistinguishable from one a human read off a
-- label, which is the specific lie ADR 001 exists to prevent.
-- ---------------------------------------------------------------------------
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
