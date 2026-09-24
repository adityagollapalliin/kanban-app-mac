import Foundation
import UserNotifications
import LocalBoardCore
import LocalBoardStore

/// Reminders for cards that are due.
///
/// Local notifications only — `UNUserNotificationCenter` scheduling on this
/// Mac, with no remote push, no device token and nothing registered with
/// Apple's servers. The app has no network entitlement, so it could not reach
/// a push service even if it wanted to.
///
/// Off until asked for. A notification nobody agreed to is an interruption,
/// and a board that starts pinging on the day it is installed is a board
/// people turn off entirely rather than configure.
@MainActor
final class DueDateReminders {

    /// Notifications are rescheduled wholesale rather than diffed. There are
    /// tens of them, the operating system takes the whole set in one call, and
    /// a diff would be a second model of what is already scheduled — which is
    /// exactly the kind of thing that drifts out of step and starts sending
    /// reminders for cards that were finished last week.
    private static let prefix = "localboard.due."

    private let center = UNUserNotificationCenter.current()

    /// Asks the user, once. Returns whether reminders may be sent.
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Replaces every scheduled reminder with one per upcoming due card.
    ///
    /// Cards already overdue get nothing: a notification about a date that has
    /// passed tells the user something they can see on the board, at a moment
    /// they did not choose.
    func reschedule(for tasks: [BoardTask], tags: [String: String], now: Date = .now) async {
        let existing = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: existing)

        guard await authorizationStatus() == .authorized else { return }

        let calendar = Calendar.current
        for task in tasks {
            guard task.completedAt == nil, !task.trashed, let due = task.dueDate else { continue }

            // Nine in the morning on the day it is due, which is when someone
            // can still do something about it — not midnight, when they cannot.
            var components = calendar.dateComponents([.year, .month, .day], from: due)
            components.hour = 9
            guard let fireAt = calendar.date(from: components), fireAt > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = tags[task.id] ?? "Due today"
            content.body = task.title
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour], from: fireAt),
                repeats: false
            )

            try? await center.add(UNNotificationRequest(
                identifier: Self.prefix + task.id,
                content: content,
                trigger: trigger
            ))
        }
    }

    /// Clears everything this app has scheduled, for turning reminders off.
    func cancelAll() async {
        let existing = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: existing)
    }
}
