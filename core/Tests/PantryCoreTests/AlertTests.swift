import Testing
import Foundation
import PantryCore

@Suite("Notification lead time — spec §5")
struct LeadTimeTests {

    /// min(3 days, 30% of applicable shelf life). The ceiling applies to nearly
    /// everything; the proportional term only bites on food that does not last
    /// long enough for three days' warning to mean anything.
    @Test("anything long-lived hits the three-day ceiling",
          arguments: [730, 270, 10])
    func ceiling(shelfLife: Int) {
        #expect(ExpiryAlerts.leadTimeDays(shelfLifeDays: shelfLife) == 3)
    }

    @Test("30% shortens the warning for short-lived food",
          arguments: [(shelf: 7, lead: 2), (shelf: 3, lead: 1), (shelf: 2, lead: 1)])
    func proportional(shelf: Int, lead: Int) {
        #expect(ExpiryAlerts.leadTimeDays(shelfLifeDays: shelf) == lead)
    }

    /// Rule 3: a missing shelf life is not a short one. With no basis to
    /// shorten the warning, the ceiling stands.
    @Test("a missing shelf life never invents a tighter deadline",
          arguments: [nil, 0])
    func noBasisToShorten(shelfLife: Int?) {
        #expect(ExpiryAlerts.leadTimeDays(shelfLifeDays: shelfLife) == 3)
    }
}

@Suite("Who may interrupt anybody — ADR 001")
struct AlertEligibilityTests {

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 12))!

    static func item(
        _ name: String, _ date: String, source: String = "label", kind: String? = nil,
        cls: String? = nil, shelf: Int? = nil, monthOnly: Bool = false, lot: Int = 1
    ) -> ExpiryItem {
        ExpiryItem(
            lotId: lot, item: name, effectiveDate: date, isMonthPrecision: monthOnly,
            source: source, kind: kind, daysLeft: 0, shelfLifeClass: cls, shelfLifeDays: shelf
        )
    }

    static func plan(_ items: [ExpiryItem]) -> [ExpiryAlert] {
        ExpiryAlerts.plan(for: items, now: now, calendar: calendar)
    }

    @Test("a perishable schedules")
    func perishableSchedules() {
        #expect(Self.plan([Self.item("Wings", "2026-09-01", source: "derived_frozen",
                                     cls: "perishable", shelf: 270)]).count == 1)
    }

    @Test("a use-by date schedules whatever its class")
    func useBySchedules() {
        #expect(Self.plan([Self.item("Fish", "2026-09-01", kind: "use_by",
                                     cls: "stable_until_opened", shelf: 730)]).count == 1)
    }

    /// Four separate reasons to stay silent, and they are not interchangeable.
    /// A best-before is a quality date; an UNKNOWN becomes a resolution task,
    /// because an alert nobody can act on teaches people to swipe this app away
    /// and they will swipe the real one away with it; a month-only date is a
    /// real month and an invented day; a past date is reported, not pushed.
    @Test("nothing else interrupts anyone", arguments: [
        (why: "a best-before is a quality date",
         item: item("Cheerios", "2026-09-01", kind: "best_before", cls: "stable_until_opened", shelf: 730)),
        (why: "food that does not expire",
         item: item("Rice", "2026-09-01", source: "not_applicable", cls: "ambient_stable")),
        (why: "an unknown becomes a resolution task",
         item: item("Lipton box", "2026-09-01", source: "unknown", cls: "perishable", shelf: 3)),
        (why: "a month-precision date is too vague",
         item: item("Basmati", "2026-09-01", cls: "perishable", shelf: 30, monthOnly: true)),
        (why: "a date already past cannot be acted on",
         item: item("Old wings", "2026-08-01", source: "derived_frozen", cls: "perishable", shelf: 270)),
    ])
    func staysSilent(why: String, item: ExpiryItem) {
        #expect(Self.plan([item]).isEmpty, "\(why)")
    }
}

@Suite("When the alert lands, and what it says")
struct AlertContentTests {

    typealias Fixture = AlertEligibilityTests

    @Test("fires three days before, in the morning, worded for the day it arrives")
    func timingAndWording() throws {
        let wings = ExpiryItem(
            lotId: 11, item: "Chicken wing pieces", effectiveDate: "2026-09-10",
            isMonthPrecision: false, source: "derived_frozen", kind: nil, daysLeft: 20,
            shelfLifeClass: "perishable", shelfLifeDays: 270
        )

        // #require rather than `if let`: a plan that scheduled nothing must fail
        // the test, not skip the assertions inside it.
        let alert = try #require(Fixture.plan([wings]).first, "the wings should have been scheduled")

        let parts = Fixture.calendar.dateComponents([.month, .day, .hour], from: alert.fireAt)
        #expect(parts.day == 7, "three days before the 10th")
        #expect(parts.month == 9)
        #expect(parts.hour == 9, "in the morning, when a kitchen can act on it")

        // Counted from the morning it arrives, not from the day it was planned.
        #expect(alert.body == "In 3 days · estimated — no date recorded")
        #expect(alert.identifier == "expiry.lot.11",
                "keyed by lot, so rescheduling replaces rather than duplicates")
    }

    @Test("a safety date says so plainly, and gets a shorter warning")
    func useByWording() throws {
        let fish = ExpiryItem(
            lotId: 2, item: "Fresh fish", effectiveDate: "2026-08-24", isMonthPrecision: false,
            source: "label", kind: "use_by", daysLeft: 3,
            shelfLifeClass: "perishable", shelfLifeDays: 3
        )
        let alert = try #require(Fixture.plan([fish]).first, "the use-by fish should have been scheduled")
        #expect(alert.leadDays == 1, "a three-day shelf life gets one day's warning")
        #expect(alert.body.contains("USE BY"))
    }

    /// Two bags bought a month apart die on different days (ADR 007).
    @Test("two lots of one product are two deadlines, soonest first")
    func perLotIdentity() {
        let bagOne = ExpiryItem(lotId: 21, item: "Basmati rice", effectiveDate: "2026-09-05",
                                isMonthPrecision: false, source: "derived_frozen", kind: nil,
                                daysLeft: 15, shelfLifeClass: "perishable", shelfLifeDays: 270)
        let bagTwo = ExpiryItem(lotId: 22, item: "Basmati rice", effectiveDate: "2026-10-05",
                                isMonthPrecision: false, source: "derived_frozen", kind: nil,
                                daysLeft: 45, shelfLifeClass: "perishable", shelfLifeDays: 270)

        let both = Fixture.plan([bagTwo, bagOne])
        #expect(both.count == 2)
        #expect(both.map(\.identifier) == ["expiry.lot.21", "expiry.lot.22"])
    }

    /// iOS keeps 64 pending notifications and silently drops the rest, so
    /// choosing which 64 is better done here than by row order.
    @Test("capped at what iOS will actually hold")
    func capped() {
        let many = (1...80).map { n in
            ExpiryItem(lotId: n, item: "Lot \(n)", effectiveDate: "2027-01-01",
                       isMonthPrecision: false, source: "derived_frozen", kind: nil,
                       daysLeft: 100, shelfLifeClass: "perishable", shelfLifeDays: 270)
        }
        #expect(Fixture.plan(many).count == 64)
    }
}
