# Working notes

The detail that would clutter the README. Current position, what is next, how
the project got here, and the threads still hanging.

Not private — this is a public repo. It is "internal" in the sense of being for
whoever is building the thing, not for someone browsing it.

---

## Where things stand

Design is settled: the spec, nine decision records and the schema are done. The
engine is complete. The app is three tabs and can both read and write.

**The loop is closed** — food can be added, be reminded about, be cooked, and
come off the ledger, all from the phone. That was the line between "a well
tested engine with a viewer" and something usable in a kitchen.

### What the engine answers

| Capability | Where it lives |
|---|---|
| Capture and the raw, never-edited layer (ADR 002) | `pantry capture` |
| Expiry chain, every date carrying its provenance (ADR 001) | `pantry list [--all] [--days N]` |
| Cook-tonight matcher, four-state answers (ADR 004) | `pantry cook --why` |
| Append-only ledger — cook, waste, eat, recount (ADR 003) | `pantry cook`, `waste`, `eat`, `recount` |
| Checkpoint rule: a recount supersedes rather than sums (ADR 005) | `v_lot_balance` |
| Numbered device migrations, carried inside the library (ADR 009) | `pantry migrate` |
| Which lots may interrupt you, when, and in what words (ADR 001, spec §5) | `pantry alerts` |
| What is on hand, how much, how far through it you are | `pantry inventory` |

### Three refusals the UI makes

All the same rule, and all easy to undo by accident later:

- A quantity bar renders **nothing** rather than empty when the amount is
  unknown. An empty bar states a measurement nobody has taken.
- An ingredient reads **"have unknown"**, never "have 0".
- **"Running low" stays empty in a full cupboard** rather than ranking its
  emptiest shelf. Threshold is `Inventory.lowThreshold` (0.35) — a heuristic to
  tune against a real kitchen, like spec §5's lead time, not a derived truth.

---

## What is left

### v1

- [ ] **Barcode capture.** Spec §2 makes v1 barcode-first. The schema is ready
      (`product_barcode`, `raw_capture.barcode`, and a `lookup_status` that
      resolves on reconnect); the scanner and the lookup are not written.
      **Needs a real device** — the simulator has no camera, so `AVFoundation`
      barcode scanning cannot be exercised there at all.

### Wanted, not v1-blocking

- [ ] **Liquid Glass.** The destination look: a dark, card-led design with a
      floating glass tab bar, in the spirit of the Apple Arcade app. Verified
      available in the iPhoneSimulator26.5 SDK — `glassEffect(_:in:)`,
      `GlassEffectContainer`, `.buttonStyle(.glass)` / `.glassProminent`,
      `TabView`+`Tab`, `tabBarMinimizeBehavior`. The app already targets 26.5
      and the test device runs 26.5.2, so **no availability guards are needed**.
      The current tab bar is a stock `TabView` on purpose: iOS 26 applies most
      of the treatment to it for free.
- [ ] **Recording a lot weighing.** `measured_piece_weight_g` is read by
      `v_piece_weight` as tier 1 of ADR 004's chain and written *only* by the
      starter seed. Nothing in the CLI or the app can record a weighing, so
      spec §4's "weigh the whole lot" step does not exist.
- [ ] **Adding recipes in the app.** Four are seeded; there is no editor.

### Phase 2 (committed, not started)

- [ ] Backend API, raw layer, normalisation service, canonical store —
      triggered by v1 being in daily use (ADR 008).

---

## Tests

Three suites, three different jobs. Logic is checked in the package where it
runs in milliseconds; the simulator is used only for what nothing else can
prove.

| Where | Framework | Covers | Command |
|---|---|---|---|
| `core/Tests/PantryCoreTests/` | Swift Testing | 48 tests, 10 suites — every rule | `swift test --package-path core` |
| `Pantry/PantryTests/` | Swift Testing | 14 tests — the store: opening, migrating, and every write path | `xcodebuild test … -only-testing:PantryTests` |
| `Pantry/PantryUITests/` | XCTest | 5 tests — tab wiring, the capture sheet, the swipe gestures | `xcodebuild test … -only-testing:PantryUITests` |

Full app run:

```bash
xcodebuild test -project Pantry/Pantry.xcodeproj -scheme Pantry \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Two testability decisions worth not undoing

`PantryStore.init` takes `databaseURL:` and `schedulesNotifications:`. Both
exist purely so tests are writable at all: without the first, every test runs
against the real pantry in Application Support; with notifications on, the
first scheduled alert trips a system permission alert and the test hangs.

### Gotcha: UI tests and the fold

`waitForExistence` is satisfied by an element below the bottom of a list, and
swiping one silently does nothing — which looks exactly like a broken gesture.
Scroll until `isHittable` first. This cost an hour once already.

---

## Device and provisioning

- App deployment target **iOS 26.5**. Test iPhone runs **26.5.2**.
- Running on device today uses **free provisioning** — a personal team, and the
  install **stops launching after 7 days** until rebuilt from Xcode.
- The **$99/yr Apple Developer Program** was subscribed to on 2026-08-31 and was
  *pending* at the time of writing. Once it clears: Xcode → Settings → Accounts,
  then set Team on all three targets (`Pantry`, `PantryTests`, `PantryUITests`)
  and provisioning lasts a year.
- Local notifications need **no** paid membership. Only push (APNs) would.

---

## Open threads

- **Basmati rice is the only item with an unknown quantity.** The bag size was
  never recorded, so it is the sole `CANNOT TELL` in cook-tonight. It needs a
  kitchen scale, not a design decision.
- **The Lipton box has no unit**, which is why it has no quantity. Both surface
  under "Needs attention" rather than being quietly counted as zero.
- **Phase 2's backend language is deliberately open** (ADR 008) and is the
  natural place for TypeScript practice.

---

## Build log

Four phases: two weeks of design before any application code, then the engine,
then the client, then the tooling and UI. Each entry says what it settled,
because the point of the sequence is that nothing was coded until the ambiguity
was gone.

**Design — 10–16 August**

| Milestone | What it settled |
|---|---|
| Inventoried the real pantry by hand | 11 items, `data/seed/` — the dataset everything else is tested against |
| Answered the spec's seven questions | Including the two that turned into ADRs 001 and 004 |
| Wrote nine decision records | Each with its rejected options, so reversals stay cheap |
| Drafted the schema in two dialects | Canonical MySQL and device SQLite, seeded with the real 11 items |
| Proved both target queries in raw SQL | Expiry and cook-tonight answerable before a line of Swift |

**Engine — 20 August**

| Milestone | What it settled |
|---|---|
| `raw_capture` layer added to the device schema | Untrusted data lands raw and is never edited (ADR 008) |
| Weighed the frozen wings | Closed the last missing count/mass bridge |
| Thin vertical slice in Swift | Capture an item, derive its expiry, list it |
| Cook-tonight matcher, plus the check suite | Four-state answers that never overstate confidence |
| Numbered migrations | The device database can now change safely after release |
| The write path and the checkpoint rule | ADR 005 implemented rather than only described; checks 33 → 47 |

**Client — 20–21 August**

| Milestone | What it settled |
|---|---|
| Declared iOS support on the package | So the app links `PantryCore` instead of forking the logic |
| Moved the starter inventory into the library | A sandboxed app cannot read the repository it was built from |
| iOS app and its expiring list | Verified on a clean simulator install, tap-driven |
| Expiry reminders, end to end | The headline v1 feature. Lead time varies by shelf life; four separate reasons to stay silent; checks 47 → 73 |

**Tooling and UI — 31 August**

| Milestone | What it settled |
|---|---|
| Hand-rolled check runner → Swift Testing | The original runner could not tell "did not run" from "passed", and one assertion behind an unreachable branch had been silently skipping. Ported against the old runner, then removed it |
| Three tabs, and writing from the phone | An inventory API the engine never had, `CANNOT TELL` given a design of its own, and the store made testable — its database path was hard-wired to the real pantry |
| Food can leave the ledger from the phone | The loop closed. Until this, capture was the only write path, so quantities only ever rose and "running low" was unreachable by construction |
| First run on a real iPhone | Free provisioning, 7-day install |

---

## What the seed data taught us

- Nested packaging is unavoidable (2 bags × 5 packs; 1 box × 49 pouches).
- Two rice varieties raise substitution before any code exists.
- Honey is recorded in grams but cooked in cups — the density case, live.
- One row ("a Lipton box") has an ambiguous product, no quantity and no unit.
  Every real inventory has rows like this. The schema must represent it.
- **Zero of 11 items have an expiry date.** The headline v1 feature looked like
  it had no data to run on — until ADR 001 separated "not applicable" from
  "unknown". Rice and honey do not need dates; about one item (the wings)
  actually does. The feature was defined too broadly, not starved of data.
