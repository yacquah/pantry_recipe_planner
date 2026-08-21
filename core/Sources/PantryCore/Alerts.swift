import Foundation

/// One notification the app should have pending.
///
/// A plan, not a side effect. Deciding *what* to notify is a rule and belongs
/// with the other rules; actually scheduling it needs UserNotifications, which
/// exists on the phone and not in the CLI. Keeping the two apart is what lets
/// the whole of ADR 001's alerting policy be checked without a simulator.
public struct ExpiryAlert: Sendable, Equatable {

    /// Stable across reschedules, so re-planning replaces a lot's pending
    /// alert instead of stacking a second copy on top of it. Keyed by lot
    /// rather than product because two bags of rice bought a month apart die
    /// on different days (ADR 007).
    public let identifier: String
    public let lotId: Int
    public let item: String
    public let expiresOn: String
    public let fireAt: Date
    public let leadDays: Int
    public let title: String
    public let body: String
}

public enum ExpiryAlerts {

    /// Never warn earlier than this, however long-lived the food is.
    public static let ceilingDays = 3

    /// The hour alerts land on. Morning, because every action this app can
    /// suggest — cook it, freeze it, bin it — is one you take in a kitchen
    /// while the day still has room for it.
    public static let hour = 9

    /// Spec §5: `min(3 days, 30% of applicable shelf life)`.
    ///
    /// The 30% term only ever *shortens* the warning, and that is the point.
    /// Three days' notice on something that keeps for three days is not a
    /// warning, it is a notification that arrives with the food already in
    /// trouble. Anything long-lived hits the ceiling and gets the full three.
    ///
    /// No recorded shelf life means no basis to shorten, so the ceiling
    /// stands — a missing value never invents a tighter deadline (rule 3).
    public static func leadTimeDays(shelfLifeDays: Int?) -> Int {
        guard let shelf = shelfLifeDays, shelf > 0 else { return ceilingDays }
        let proportional = Int((Double(shelf) * 0.3).rounded())
        return max(1, min(ceilingDays, proportional))
    }

    /// What should be pending, given the pantry as it stands right now.
    ///
    /// Returns the whole intended state rather than a diff. The caller clears
    /// and re-adds, so a lot that has been cooked, bombed or re-dated simply
    /// stops appearing — there is no separate cancellation path to get wrong.
    public static func plan(
        for items: [ExpiryItem],
        now: Date = Date(),
        calendar: Calendar = .current,
        limit: Int = 64
    ) -> [ExpiryAlert] {

        let today = calendar.startOfDay(for: now)

        let alerts: [ExpiryAlert] = items.compactMap { item in
            // ADR 001, in order. Each of these is a different reason to stay
            // silent and they are not interchangeable.

            // Only safety dates and perishables may interrupt anyone.
            guard item.shouldPush else { return nil }

            // UNKNOWN never notifies. It becomes a resolution task instead —
            // an alert nobody can act on trains people to swipe this app away,
            // and they will swipe the real one away with it.
            guard item.source != "unknown", item.source != "not_applicable" else { return nil }

            // A month-precision date is a real month and a fabricated day. Up
            // to thirty days of error is too much to interrupt somebody over;
            // the list still shows it, hedged. Surfaced is not notified.
            guard !item.isMonthPrecision else { return nil }

            guard let expiry = date(from: item.effectiveDate, calendar: calendar) else { return nil }

            // Already past. The list reports it; a push at this point tells
            // the user something they can see and cannot undo.
            guard expiry >= today else { return nil }

            let lead = leadTimeDays(shelfLifeDays: item.shelfLifeDays)

            guard var fire = calendar.date(
                bySettingHour: hour, minute: 0, second: 0,
                of: calendar.date(byAdding: .day, value: -lead, to: expiry) ?? expiry
            ) else { return nil }

            // The window opened while the app was not running. Fire at the
            // next morning rather than immediately: 3am is not when anybody
            // wants to be told to use up the chicken.
            if fire <= now {
                guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
                      let next = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow)
                else { return nil }
                fire = next
            }

            // Clamped past the date itself — the moment to say something has
            // gone. Do not send a warning about a deadline already missed.
            guard let endOfExpiry = calendar.date(byAdding: .day, value: 1, to: expiry),
                  fire < endOfExpiry else { return nil }

            // Counted from the morning it arrives, not from now. A plan made
            // today for an alert eight months out still has to read "in 3
            // days" when it lands, because that is when somebody reads it.
            let daysAtFire = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: fire), to: expiry
            ).day ?? lead

            return ExpiryAlert(
                identifier: "expiry.lot.\(item.lotId)",
                lotId: item.lotId,
                item: item.item,
                expiresOn: item.effectiveDate,
                fireAt: fire,
                leadDays: lead,
                title: item.item,
                body: "\(phrase(daysUntil: daysAtFire)) · \(item.wording)"
            )
        }

        // Soonest first, then capped. iOS keeps 64 pending notifications per
        // app and silently drops the rest, so choosing which 64 is better done
        // here than by whatever order the rows arrived in.
        return Array(alerts.sorted { $0.fireAt < $1.fireAt }.prefix(limit))
    }

    /// How long is left, in the words a person would use.
    static func phrase(daysUntil days: Int) -> String {
        switch days {
        case ..<0:  return "Past its date"
        case 0:     return "Today"
        case 1:     return "Tomorrow"
        default:    return "In \(days) days"
        }
    }

    /// Parses the `YYYY-MM-DD` the schema stores, in the user's own calendar.
    ///
    /// Deliberately not a DateFormatter: expiry dates are civil dates, not
    /// instants. Reading them through a formatter drags a time zone into a
    /// value that does not have one, and food does not go off an hour earlier
    /// because somebody flew east.
    static func date(from text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
