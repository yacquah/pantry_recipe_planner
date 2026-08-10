# v1 Specification

> Answer these in prose, before drawing a single table. If a question feels hard
> to answer, that is the signal — it is a design decision hiding, and it belongs
> in `docs/decisions/` rather than being resolved silently in code later.

## 1. What is the smallest useful thing v1 can do?

<!-- Proposed: "tells me what is expiring in the next 3 days." Note that the
     seed data currently has zero expiry dates, so this is blocked on ADR 001. -->

## 2. How does an item get in?

<!-- Barcode, manual entry, or both. Crucially: what happens when the barcode
     scan returns nothing, or returns a product you cannot identify? -->

## 3. How does an item get out?

<!-- Decrement on cook, or delete outright? Sneakier than it looks: cooking
     half a recipe, throwing food away, and eating straight from the bag are
     three different events. -->

## 4. What does "1 onion" mean when a recipe wants 200 g of onion?

<!-- The countable-vs-measurable boundary. Applies directly to seed rows 3, 9
     and 11 (Indomie packs, granola pouches, chicken wings). -->

## 5. What happens to an item with no expiry date at all?

<!-- This is the whole of ADR 001. All 11 seed items are in this state. -->

## 6. Does the app work offline?

<!-- A phone in a kitchen with bad wifi is the normal case, not the edge case.
     If yes: what happens when two devices edit the same item? -->

## 7. What am I explicitly NOT building?

<!-- Write this one down properly. It is the question that saves the project.
     Candidates to rule out for v1: users and auth, nutrition tracking,
     shopping lists, purchase history, storage locations, recipe import,
     substitution groups. -->

---

## Out of scope for v1

<!-- Move firm decisions up from question 7 into this list as you make them,
     so they stop being reconsidered every week. -->
