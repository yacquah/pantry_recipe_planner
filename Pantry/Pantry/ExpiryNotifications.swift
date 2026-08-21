import Foundation
import UserNotifications
import PantryCore

/// Puts PantryCore's alert plan into iOS's notification centre.
///
/// Deliberately thin, like the rest of the app. Which lots deserve to
/// interrupt somebody, how much warning each one gets and what the text says
/// are all decided in `ExpiryAlerts` and checked there without a simulator.
/// Nothing in this file makes a judgement; it schedules what it is handed.
@MainActor
enum ExpiryNotifications {

    /// Every request this app owns is prefixed, so clearing our own pending
    /// alerts can never disturb a notification scheduled by something else.
    private static let prefix = "expiry.lot."

    enum Permission {
        case granted
        case denied
        case notAskedYet
    }

    static func permission() async -> Permission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied:                               return .denied
        default:                                    return .notAskedYet
        }
    }

    /// Asks, once, and only when there is something real to ask about.
    ///
    /// A permission prompt on first launch arrives before the app has shown it
    /// can be useful, and a refusal is close to permanent — iOS will not ask
    /// twice. The caller waits until the pantry actually contains something
    /// that would notify, so the question has a visible reason behind it.
    @discardableResult
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Replaces every pending expiry alert with the current plan.
    ///
    /// Whole state, not a diff. A lot that has been cooked, thrown out or
    /// re-dated simply stops appearing in the plan and its alert disappears
    /// with it — there is no separate cancellation path that could be missed,
    /// which is the same reasoning the ledger uses for balances.
    static func sync(_ alerts: [ExpiryAlert], calendar: Calendar = .current) async {
        let centre = UNUserNotificationCenter.current()

        let ours = await centre.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        centre.removePendingNotificationRequests(withIdentifiers: ours)

        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            // Deep-linking to the lot is not built yet; carrying the id costs
            // nothing now and is what a tap would need later.
            content.userInfo = ["lotId": alert.lotId]

            let when = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute], from: alert.fireAt
            )

            try? await centre.add(
                UNNotificationRequest(
                    identifier: alert.identifier,
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
                )
            )
        }
    }

    /// What is actually pending, for display and for checking by hand.
    static func pending() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(prefix) }
            .map(\.identifier)
    }
}
