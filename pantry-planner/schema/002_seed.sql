-- Seed: the real pantry, 11 items captured 2026-08-02, with expiry dates
-- collected 2026-08-16. Gaps are preserved, not cleaned up — the point is that
-- the schema survives real data.
--
-- Dates were transcribed year/month/day. Three are month-precision, stored as
-- the resolved month-end boundary with expires_on_precision = 'month'.

-- ---------------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------------
-- days IS NULL means NOT APPLICABLE, not unknown (ADR 001).
INSERT INTO shelf_life_by_class (shelf_life_class, state, days) VALUES
  ('ambient_stable',      'sealed', NULL),
  ('ambient_stable',      'opened', NULL),
  ('ambient_stable',      'frozen', NULL),
  ('stable_until_opened', 'sealed', 730),
  ('stable_until_opened', 'opened',   7),
  ('stable_until_opened', 'frozen', 180),
  ('perishable',          'sealed',   3),
  ('perishable',          'opened',   2),
  ('perishable',          'frozen', 270);

-- ---------------------------------------------------------------------------
-- Products
-- ---------------------------------------------------------------------------
INSERT INTO product
  (id, canonical_name, brand, base_unit, shelf_life_class, countable_kind, needs_review) VALUES
  ( 1, 'Jasmine rice',                    NULL,                'g',     'ambient_stable',      NULL,           0),
  ( 2, 'Cheerios, cookies and creme',     'Cheerios',          'g',     'stable_until_opened', NULL,           0),
  ( 3, 'Indomie instant noodles',         'Indomie',           'count', 'ambient_stable',      'manufactured', 0),
  ( 4, 'Honey',                           'Clover',            'g',     'ambient_stable',      NULL,           0),
  ( 5, 'Tomato paste',                    'Essential Everyday','g',     'stable_until_opened', NULL,           0),
  -- Identity is provisional, everything else unknown. The row ADR 002 exists for.
  ( 6, 'UNRESOLVED - Lipton box',         'Lipton',            NULL,    NULL,                  NULL,           1),
  ( 7, 'Basmati rice',                    NULL,                'g',     'ambient_stable',      NULL,           1),
  ( 8, 'Whey protein powder',             NULL,                'g',     'stable_until_opened', NULL,           0),
  ( 9, 'Crunchy Oats ''n Honey bars',     NULL,                'count', 'ambient_stable',      'manufactured', 0),
  (10, 'Hot cocoa mix, double chocolate', NULL,                'g',     'stable_until_opened', NULL,           0),
  (11, 'Chicken wing pieces',             NULL,                'count', 'perishable',          'natural',      1);

-- Rule 2: density belongs to the food. The live case from the README.
INSERT INTO density (product_id, g_per_ml) VALUES (4, 1.42);

-- ADR 004: a manufactured countable has an EXACT weight, not a distribution.
-- Setting min = max = typical is how that gets recorded — 85 g is printed on
-- every Indomie pack, verified against the packaging 2026-08-16, so there is
-- no spread to represent. One count = one 85 g pack.
INSERT INTO piece_weight_curated (product_id, typical_g, min_g, max_g) VALUES
  (3, 85, 85, 85),    -- Indomie pack, printed and verified 2026-08-16
  (9, 42, 42, 42);    -- granola pouch, printed and verified 2026-08-16

-- Still absent, deliberately: chicken wings (product 11) are a NATURAL
-- countable, so no printed weight exists to read — squinting at the bag will
-- never produce one. ADR 004 tier 1 is the only route: weigh the bag once and
-- divide by 10. That yields a 'measured' value, which beats any reference
-- table because it describes the actual wings in the actual freezer.

-- ---------------------------------------------------------------------------
-- Lots — one per acquisition (ADR 007). Ten identical cans are ONE lot.
-- ---------------------------------------------------------------------------
INSERT INTO lot
  (id, product_id, acquired_on, expires_on, expiry_kind, expires_on_precision,
   is_opened, opened_on, is_frozen, container_type, units_per_container,
   size_per_unit, needs_review, notes) VALUES
  -- Month-precision "27/10". Best-before, so it resolves to month end.
  -- Open, but nobody recorded when: is_opened=1 with opened_on NULL is exactly
  -- the state the schema had to be widened to express.
  ( 1,  1, '2026-08-02', '2027-10-31', 'best_before', 'month',
        1, NULL, 0, 'bag',    1, 2270, 0,
        'Label: "Best by 27/10" - month precision, no day. 5 lb = 2270 g. Quantity is an estimate: "two and a half bags".'),
  ( 2,  2, '2026-08-02', '2027-04-03', 'best_before', 'day',
        NULL, NULL, 0, 'box', 1,  425, 0,
        'Label: "Exp/Best by 27/04/03" - printed as both. Read as a quality date.'),
  -- Date supplied separately; this item was absent from the expiry capture.
  ( 3,  3, '2026-08-02', '2026-09-04', 'best_before', 'day',
        0, NULL, 0, 'bag',    5, 85, 0,
        '2 bags x 5 packs = 10 packs. Pack weight 85 g, printed and verified.'),
  ( 4,  4, '2026-08-02', '2028-05-08', 'best_before', 'day',
        NULL, NULL, 0, 'bottle', 1, 340, 0,
        'Label: "Best by 28/05/08". Recipes ask for cups; density row exists.'),
  -- 12 oz = 340 g, confirmed against the can. The 170 g suspicion was wrong.
  ( 5,  5, '2026-08-02', '2028-09-07', 'best_before', 'day',
        0, NULL, 0, 'can',    1,  340, 0,
        'Label: "Best by 28/09/07". Net wt 12 oz (340 g) VERIFIED against packaging.'),
  -- Has a date, but still no idea what the product is or how much there is.
  ( 6,  6, '2026-08-02', '2027-04-30', 'best_before', 'month',
        NULL, NULL, NULL, 'box', NULL, NULL, 1,
        'Label: "Exp 27/04" - month precision, and the word appears overwritten or struck through. Tea bags? Soup mix? Product, unit and quantity all unresolved.'),
  ( 7,  7, '2026-08-02', '2027-10-31', 'best_before', 'month',
        NULL, NULL, 0, 'bag',  1, NULL, 1,
        'Label: "Best by 27/10" - month precision. Bag size never recorded.'),
  ( 8,  8, '2026-08-02', '2027-03-24', 'best_before', 'day',
        NULL, NULL, 0, 'bottle', 1, 899, 0,
        'Label: "Expiry 27/03/24". Read as a quality date: a shelf-stable powder alerting like a safety date would make the app cause waste. Verify 899 g; common tub size is 907 g.'),
  -- Checked and genuinely blank. Absence of a date here is an observation,
  -- not a gap in the capture.
  ( 9,  9, '2026-08-02', NULL, NULL, NULL,
        NULL, NULL, 0, 'box',  49, 42, 0,
        'Packaging inspected: no date printed. Nested packaging box > pouch > bar. Pouch weight 42 g, printed and verified.'),
  (10, 10, '2026-08-02', '2027-08-25', 'best_before', 'day',
        NULL, NULL, 0, 'box',   1,  435, 0,
        'Label: "Expiry 27/08/25". Read as a quality date. Measured by scoop in practice; scoop-to-gram is a density case.'),
  -- FROZEN, confirmed. This was the single biggest unknown in the dataset and
  -- it swings the shelf life from 3 days to 270.
  (11, 11, '2026-08-02', NULL, NULL, NULL,
        NULL, NULL, 1, 'loose', 1, NULL, 1,
        'Frozen, confirmed. Packaging carries sell-by dates, not transcribed - and a sell-by is the retailer''s date, so it would not drive alerts anyway (ADR 001).');

-- ---------------------------------------------------------------------------
-- Ledger — the initial capture. Quantity lives HERE, never on the lot.
-- ---------------------------------------------------------------------------
INSERT INTO pantry_event
  (id, lot_id, product_id, delta_base_unit, reason, waste_reason, qty_precision,
   recipe_id, observed_qty, occurred_at, device_id) VALUES
  -- 2.5 bags x 2270 g. "Half a bag" was eyeballed, so: estimated.
  ('0191a6c0-0001-7000-8000-000000000001',  1,  1, 5675, 'CAPTURE', NULL, 'estimated', NULL, NULL, '2026-08-02T18:22:11.031', 'iphone-yaw-1'),
  ('0191a6c0-0002-7000-8000-000000000002',  2,  2,  425, 'CAPTURE', NULL, 'derived',   NULL, NULL, '2026-08-02T18:22:31.114', 'iphone-yaw-1'),
  -- Counting is exact, so: measured.
  ('0191a6c0-0003-7000-8000-000000000003',  3,  3,   10, 'CAPTURE', NULL, 'measured',  NULL, NULL, '2026-08-02T18:22:48.700', 'iphone-yaw-1'),
  ('0191a6c0-0004-7000-8000-000000000004',  4,  4,  340, 'CAPTURE', NULL, 'derived',   NULL, NULL, '2026-08-02T18:23:02.482', 'iphone-yaw-1'),
  ('0191a6c0-0005-7000-8000-000000000005',  5,  5, 3400, 'CAPTURE', NULL, 'derived',   NULL, NULL, '2026-08-02T18:23:20.905', 'iphone-yaw-1'),
  -- No quantity knowable, so delta AND precision are both NULL.
  ('0191a6c0-0006-7000-8000-000000000006',  6,  6, NULL, 'CAPTURE', NULL, NULL,        NULL, NULL, '2026-08-02T18:23:41.223', 'iphone-yaw-1'),
  ('0191a6c0-0007-7000-8000-000000000007',  7,  7, NULL, 'CAPTURE', NULL, NULL,        NULL, NULL, '2026-08-02T18:23:58.660', 'iphone-yaw-1'),
  ('0191a6c0-0008-7000-8000-000000000008',  8,  8,  899, 'CAPTURE', NULL, 'derived',   NULL, NULL, '2026-08-02T18:24:15.019', 'iphone-yaw-1'),
  ('0191a6c0-0009-7000-8000-000000000009',  9,  9,   49, 'CAPTURE', NULL, 'measured',  NULL, NULL, '2026-08-02T18:24:33.771', 'iphone-yaw-1'),
  ('0191a6c0-000a-7000-8000-00000000000a', 10, 10,  435, 'CAPTURE', NULL, 'derived',   NULL, NULL, '2026-08-02T18:24:51.402', 'iphone-yaw-1'),
  ('0191a6c0-000b-7000-8000-00000000000b', 11, 11,   10, 'CAPTURE', NULL, 'measured',  NULL, NULL, '2026-08-02T18:25:09.888', 'iphone-yaw-1');

-- ---------------------------------------------------------------------------
-- Recipes — hand-entered against products that already exist (ADR 006).
-- Ingredients are foreign keys, never free text.
-- ---------------------------------------------------------------------------
INSERT INTO recipe (id, name, servings) VALUES
  (1, 'Jollof-ish rice', 2),
  (2, 'Wings and rice',  2),
  (3, 'Noodle bowl',     1),
  (4, 'Basmati side',    2);

INSERT INTO recipe_ingredient (recipe_id, product_id, qty, unit) VALUES
  (1,  1, 400, 'g'),      -- jasmine rice
  (1,  5, 340, 'g'),      -- tomato paste
  (2, 11,   6, 'count'),  -- wings, asked for in the unit they are stored in
  (2,  1, 300, 'g'),
  (3,  3,   2, 'count'),  -- Indomie
  (3, 11, 200, 'g'),      -- wings in GRAMS, stored as count, no piece weight exists
  (4,  7, 250, 'g');      -- basmati, whose on-hand quantity is unknown

-- One cook, so "quantity is derived, not stored" is visibly true.
INSERT INTO pantry_event
  (id, lot_id, product_id, delta_base_unit, reason, waste_reason, qty_precision,
   recipe_id, observed_qty, occurred_at, device_id) VALUES
  ('0191a6c0-0010-7000-8000-000000000010', 1, 1, -400, 'COOK', NULL, 'derived', 1, NULL, '2026-08-07T19:04:00.000', 'iphone-yaw-1'),
  ('0191a6c0-0011-7000-8000-000000000011', 5, 5, -340, 'COOK', NULL, 'derived', 1, NULL, '2026-08-07T19:04:00.000', 'iphone-yaw-1');
