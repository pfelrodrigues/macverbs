import EventKit
import Foundation

// MARK: - Stub (no EventKit / no TCC)

/// Test / pre-wiring client. Always reports `unavailable`; never touches EventKit.
struct StubEventStoreClient: EventStoreClient {
    /// Identity string for doctor / diagnostics.
    static let kind = "stub"

    func authorizationStatus(for entity: EventEntityType) -> EventAuthorizationStatus {
        .unavailable
    }

    func requestAccess(for entity: EventEntityType) throws -> EventAuthorizationStatus {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders)"
        )
    }

    func eventCalendars() throws -> [EventKitCalendarInfo] {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders)"
        )
    }

    func events(from start: Date, to end: Date) throws -> [EventKitEventInfo] {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders)"
        )
    }

    func saveEvent(
        title: String,
        start: Date,
        end: Date,
        calendarUID: String?
    ) throws {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders)"
        )
    }

    func reminderLists() throws -> [ReminderListInfo] {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders)"
        )
    }

    func incompleteReminders(listName: String?) throws -> [ReminderItem] {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders)"
        )
    }

    func addReminder(
        title: String,
        listName: String?,
        due: String,
        notes: String,
        priority: String
    ) throws -> ReminderCreated {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders)"
        )
    }

    func completeReminder(title: String, listName: String?) throws -> ReminderDoneResult {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders)"
        )
    }

    func deleteReminder(title: String, listName: String?) throws -> ReminderDeleted {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders)"
        )
    }

    func moveReminder(
        title: String,
        fromList: String,
        toList: String
    ) throws -> ReminderMoved {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders)"
        )
    }

    func editReminder(
        title: String,
        listName: String?,
        due: String,
        priority: String,
        notes: String
    ) throws -> ReminderEdited {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders)"
        )
    }

    func ensureReminderList(name: String) throws -> ReminderListEnsured {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders)"
        )
    }
}
