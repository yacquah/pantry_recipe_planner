-- Pantry Planner — canonical store (MySQL 8.0.16+)
--
-- This is the trusted side of the boundary. Nothing reaches these tables
-- without passing through normalisation; raw captures live in MongoDB.
--
-- Conventions, all traceable to a decision record:
--   * DECIMAL everywhere for quantities, never FLOAT. Binary floating point
--     cannot represent 0.1 exactly, and an app whose whole premise is not
--     lying with numbers should not accumulate rounding error in the ledger.
--   * NULL is the storage form of UNKNOWN (ADR 002, modelling rule 3).
--     There is no sentinel string and no zero standing in for missing.
--   * Quantity is never stored as mutable state. It is SUM(pantry_event)
--     (ADR 003); lot.qty_on_hand_cached is a cache, never the truth.
--
-- Requires 8.0.16 or later: CHECK constraints are parsed but ignored before it.

SET NAMES utf8mb4;


-- ---------------------------------------------------------------------------
-- product — the canonical identity of a food, independent of packaging.
-- ---------------------------------------------------------------------------
CREATE TABLE product (
  id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  canonical_name    VARCHAR(160)    NOT NULL,
  brand             VARCHAR(80)     NULL,

  -- Rule 1: one base unit per product, chosen once, never mixed.
  -- Nullable because ADR 002 makes identity the ONLY hard requirement: seed
  -- row 6 ("a Lipton box") has no knowable unit, and refusing to store it
  -- would make the app's own worst case unrepresentable. Chosen once means
  -- chosen once it is known.
  base_unit         ENUM('g','ml','count') NULL,

  -- ADR 001. Decides whether a missing expiry date matters at all.
  -- Nullable for the same reason.
  shelf_life_class  ENUM('ambient_stable','stable_until_opened','perishable')
                    NULL,

  -- ADR 004. Only meaningful for countables; decides whether the app should
  -- ever ask for a piece weight (never, for 'pure' — see the tea bags).
  countable_kind    ENUM('manufactured','natural','pure') NULL,

  needs_review      TINYINT(1)      NOT NULL DEFAULT 0,   -- ADR 002
  created_at        DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

  -- MySQL treats NULLs as distinct in a UNIQUE index, so unbranded products
  -- would duplicate freely. Collapsing NULL to '' in a generated column is
  -- what actually enforces one row per (name, brand).
  brand_key         VARCHAR(80) GENERATED ALWAYS AS (COALESCE(brand,'')) STORED,

  PRIMARY KEY (id),
  UNIQUE KEY uq_product_identity (canonical_name, brand_key),
  KEY ix_product_review (needs_review),

  CONSTRAINT ck_product_countable_kind
    CHECK (countable_kind IS NULL OR base_unit = 'count')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- ---------------------------------------------------------------------------
-- product_barcode — many barcodes may point at one food (pack sizes differ).
-- ---------------------------------------------------------------------------
CREATE TABLE product_barcode (
  barcode     VARCHAR(32)     NOT NULL,
  product_id  BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (barcode),
  KEY ix_barcode_product (product_id),
  CONSTRAINT fk_barcode_product FOREIGN KEY (product_id) REFERENCES product(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- ---------------------------------------------------------------------------
-- recipe / recipe_ingredient — hand-entered and local (ADR 005, ADR 006).
-- ---------------------------------------------------------------------------
CREATE TABLE recipe (
  id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  name      VARCHAR(160)    NOT NULL,
  servings  INT UNSIGNED    NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_recipe_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE recipe_ingredient (
  recipe_id   BIGINT UNSIGNED NOT NULL,
  -- A real foreign key, not a free-text ingredient string. This is the payoff
  -- of cutting recipe import (ADR 006): recipes are authored against products
  -- that already exist, so v1 never has to parse "1 large onion, diced" and
  -- never has to decide whether jasmine substitutes for basmati.
  product_id  BIGINT UNSIGNED NOT NULL,
  qty         DECIMAL(12,3)   NOT NULL,
  unit        ENUM('g','ml','count') NOT NULL,   -- base units; cups stay in the UI
  PRIMARY KEY (recipe_id, product_id),
  KEY ix_ri_product (product_id),
  CONSTRAINT fk_ri_recipe  FOREIGN KEY (recipe_id)  REFERENCES recipe(id) ON DELETE CASCADE,
  CONSTRAINT fk_ri_product FOREIGN KEY (product_id) REFERENCES product(id),
  CONSTRAINT ck_ri_qty_positive CHECK (qty > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- ---------------------------------------------------------------------------
-- lot — a set of physically interchangeable units of one product sharing an
-- expiry date and an open state (ADR 007). Ten identical cans are one lot.
-- ---------------------------------------------------------------------------
CREATE TABLE lot (
  id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  product_id        BIGINT UNSIGNED NOT NULL,
  acquired_on       DATE            NOT NULL,

  -- ADR 001: NULL unless a real date was recorded. Estimates are derived at
  -- read time and never written here, because a written estimate becomes
  -- indistinguishable from a label date on the very next read.
  expires_on        DATE            NULL,
  expiry_kind       ENUM('use_by','best_before','sell_by') NULL,

  -- Real packaging prints year+month only about a third of the time. Storing
  -- "2027-10" in a DATE column invents a day nobody saw, so precision is
  -- recorded and the UI renders "October 2027". expires_on holds the RESOLVED
  -- BOUNDARY, not the printed characters: month-precision best-before resolves
  -- to the LAST day of the month (what the manufacturer means), month-precision
  -- use-by to the FIRST, since ADR 001 errs early on safety and late on quality.
  expires_on_precision ENUM('day','month') NULL,

  -- Three separate facts, because the seed data has all three states.
  -- Seed row 1 is open but nobody wrote down when, and seed row 11 might be
  -- fresh or frozen and nobody knows. A NOT NULL default of 0 on either of
  -- these would silently assert "sealed" and "fresh" — a zero standing in for
  -- missing, which is precisely what rule 3 forbids.
  is_opened         TINYINT(1)      NULL,
  opened_on         DATE            NULL,
  is_frozen         TINYINT(1)      NULL,

  -- Packaging shape only. Quantity is NOT here; it is SUM(pantry_event).
  container_type      VARCHAR(32)   NULL,
  units_per_container INT UNSIGNED  NULL,
  size_per_unit       DECIMAL(10,3) NULL,

  -- ADR 004 tier 1: the strongest piece-weight source, when the lot was weighed.
  measured_piece_weight_g DECIMAL(10,3) NULL,

  -- ADR 003: convenience only. The ledger is truth; a reconcile job compares
  -- them and raises an alarm when they disagree.
  qty_on_hand_cached  DECIMAL(12,3) NULL,

  needs_review      TINYINT(1)      NOT NULL DEFAULT 0,
  notes             TEXT            NULL,

  -- Derived state for the shelf-life lookup. Freezing outranks opening
  -- because it suspends spoilage: an opened bag in the freezer behaves frozen.
  -- ADR 001 also lists 'cooked', which is deliberately absent — cooked food is
  -- not a pantry lot in v1.
  -- NULL when the state itself is unknown, which propagates honestly into the
  -- shelf-life lookup instead of guessing 'sealed'.
  shelf_life_state  VARCHAR(8) GENERATED ALWAYS AS (
                      CASE WHEN is_frozen = 1 THEN 'frozen'
                           WHEN is_opened = 1 THEN 'opened'
                           WHEN is_frozen = 0 AND is_opened = 0 THEN 'sealed'
                           ELSE NULL END
                    ) STORED,

  PRIMARY KEY (id),
  -- Redundant against the primary key, and deliberately so: it is what allows
  -- pantry_event to carry a composite foreign key (see below).
  UNIQUE KEY uq_lot_identity (id, product_id),
  KEY ix_lot_product (product_id),
  KEY ix_lot_expiry (expires_on),
  KEY ix_lot_state (shelf_life_state),

  CONSTRAINT fk_lot_product FOREIGN KEY (product_id) REFERENCES product(id),

  -- A date without its kind is unusable: use-by is a safety date and
  -- best-before is a quality date, and they imply opposite alerting (ADR 001).
  CONSTRAINT ck_lot_expiry_kind
    CHECK (expires_on IS NULL
           OR (expiry_kind IS NOT NULL AND expires_on_precision IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- ---------------------------------------------------------------------------
-- pantry_event — the ledger (ADR 003). Append-only by convention: nothing in
-- the application may UPDATE or DELETE a row here. Corrections are new rows.
-- ---------------------------------------------------------------------------
CREATE TABLE pantry_event (
  -- Minted on the client as UUIDv7 (ADR 005), never by the database. A lost
  -- response makes the phone retry, and only a client-side id lets the server
  -- upsert idempotently instead of double-decrementing. UUIDv7 sorts by time.
  -- CHAR(36) is chosen over BINARY(16) for legibility while learning; the
  -- swap is mechanical if the row count ever justifies it.
  id              CHAR(36)        NOT NULL,

  lot_id          BIGINT UNSIGNED NOT NULL,
  -- Denormalised from lot, kept honest by the composite foreign key below,
  -- which makes a mismatched pair structurally impossible rather than merely
  -- discouraged.
  product_id      BIGINT UNSIGNED NOT NULL,

  -- NULL is legal: an unknown amount was consumed. Any aggregate over this
  -- column must report the count it skipped (modelling rule 4, ADR 002).
  delta_base_unit DECIMAL(12,3)   NULL,

  reason          ENUM('CAPTURE','COOK','CONSUME','WASTE','ADJUSTMENT','TRANSFER')
                  NOT NULL,

  -- ADR 003. Required on waste, forbidden elsewhere. The five values partition
  -- into different failures: 'expired' indicts the app's own forecasting,
  -- 'spoiled'/'freezer_burn' indict storage, 'disliked' indicts purchasing,
  -- 'accident' is noise that must not pollute the other four.
  waste_reason    ENUM('expired','spoiled','freezer_burn','disliked','accident')
                  NULL,

  -- How well the number is known. Named qty_precision because PRECISION is
  -- reserved in MySQL. Nullable in lockstep with the delta: precision
  -- describes a number, and seed row 6 has no number to describe.
  qty_precision   ENUM('measured','derived','estimated') NULL,

  recipe_id       BIGINT UNSIGNED NULL,

  -- ADJUSTMENT only: what the recount actually saw. delta_base_unit carries
  -- the correction needed to reach it, so SUM() stays valid.
  observed_qty    DECIMAL(12,3)   NULL,

  -- Two clocks, both kept (ADR 005). occurred_at is the device's account of
  -- when the human acted; received_at is the server's and is authoritative for
  -- ordering, because phone clocks are wrong often enough to corrupt a ledger.
  occurred_at     DATETIME(3)     NOT NULL,
  received_at     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

  device_id       VARCHAR(64)     NOT NULL,

  PRIMARY KEY (id),
  KEY ix_event_lot_time     (lot_id, occurred_at),
  KEY ix_event_product_time (product_id, occurred_at),
  KEY ix_event_reason_time  (reason, occurred_at),

  CONSTRAINT fk_event_lot
    FOREIGN KEY (lot_id, product_id) REFERENCES lot(id, product_id),
  CONSTRAINT fk_event_recipe
    FOREIGN KEY (recipe_id) REFERENCES recipe(id),

  -- Read "=" between two booleans as "if and only if".
  CONSTRAINT ck_event_waste_reason
    CHECK ((reason = 'WASTE') = (waste_reason IS NOT NULL)),
  CONSTRAINT ck_event_observed_qty
    CHECK ((reason = 'ADJUSTMENT') = (observed_qty IS NOT NULL)),
  CONSTRAINT ck_event_recipe_only_on_cook
    CHECK (reason = 'COOK' OR recipe_id IS NULL),
  CONSTRAINT ck_event_precision_tracks_delta
    CHECK ((delta_base_unit IS NULL) = (qty_precision IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- ---------------------------------------------------------------------------
-- Reference data. Vendored and shipped with the app so the kitchen works with
-- no signal (ADR 005). None of it is user data.
-- ---------------------------------------------------------------------------

-- ADR 001. days IS NULL means "not applicable" — which is emphatically not the
-- same as unknown. Honey has no expiry because the concept does not apply to
-- it, and conflating the two is what pins a needs-attention list at ten items
-- forever.
CREATE TABLE shelf_life_by_class (
  shelf_life_class ENUM('ambient_stable','stable_until_opened','perishable') NOT NULL,
  state            VARCHAR(8)   NOT NULL,   -- sealed | opened | frozen
  days             INT UNSIGNED NULL,
  PRIMARY KEY (shelf_life_class, state)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Per-product override, consulted before the class default.
CREATE TABLE shelf_life_by_product (
  product_id  BIGINT UNSIGNED NOT NULL,
  state       VARCHAR(8)      NOT NULL,
  days        INT UNSIGNED    NULL,
  PRIMARY KEY (product_id, state),
  CONSTRAINT fk_slp_product FOREIGN KEY (product_id) REFERENCES product(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ADR 004 tier 3. Deliberately separate from density: density is a physical
-- constant, piece weight is a distribution, and storing them in one table
-- would assert "1 onion = 150 g" with the confidence of "1 cup honey = 340 g".
CREATE TABLE piece_weight_curated (
  product_id BIGINT UNSIGNED NOT NULL,
  typical_g  DECIMAL(10,3)   NOT NULL,
  min_g      DECIMAL(10,3)   NULL,
  max_g      DECIMAL(10,3)   NULL,
  PRIMARY KEY (product_id),
  CONSTRAINT fk_pwc_product FOREIGN KEY (product_id) REFERENCES product(id),
  CONSTRAINT ck_pwc_range CHECK (
    (min_g IS NULL OR min_g <= typical_g) AND
    (max_g IS NULL OR max_g >= typical_g)
  )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Rule 2: density belongs to the food, not to the units.
CREATE TABLE density (
  product_id BIGINT UNSIGNED NOT NULL,
  g_per_ml   DECIMAL(8,4)    NOT NULL,
  PRIMARY KEY (product_id),
  CONSTRAINT fk_density_product FOREIGN KEY (product_id) REFERENCES product(id),
  CONSTRAINT ck_density_positive CHECK (g_per_ml > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
