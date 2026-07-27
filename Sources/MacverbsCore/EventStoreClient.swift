import EventKit
import Foundation

// MARK: - Real EventStoreClient (EKEventStore wrapper)

/// Production EventKit client: `EKEventStore` behind `EventStoreClient`.
///
/// Authorization reads never prompt. `requestAccess` / `ensureAccess` may prompt
/// once per entity type (TCC). Doctor must only call `authorizationStatus`.
struct EKEventStoreClient: EventStoreClient {
    /// Identity string for doctor / diagnostics.
    static let kind = "eventkit"

    private let backing: any EventKitBacking

    /// - Parameter backing: Live EventKit or a test double (default: live store).
    init(backing: any EventKitBacking = LiveEventKitBacking()) {
        self.backing = backing
    }

    /// Underlying `EKEventStore` when backed by live EventKit; otherwise `nil`.
    var eventStore: EKEventStore? {
        (backing as? LiveEventKitBacking)?.store
    }

    func authorizationStatus(for entity: EventEntityType) -> EventAuthorizationStatus {
        backing.authorizationStatus(for: entity)
    }

    func requestAccess(for entity: EventEntityType) throws -> EventAuthorizationStatus {
        let current = authorizationStatus(for: entity)
        if current != .notDetermined {
            return current
        }
        _ = try backing.requestFullAccess(for: entity)
        return authorizationStatus(for: entity)
    }

    func eventCalendars() throws -> [EventKitCalendarInfo] {
        try backing.eventCalendars()
    }

    func events(from start: Date, to end: Date) throws -> [EventKitEventInfo] {
        try backing.events(from: start, to: end)
    }

    func saveEvent(
        title: String,
        start: Date,
        end: Date,
        calendarUID: String?
    ) throws {
        try backing.saveEvent(
            title: title,
            start: start,
            end: end,
            calendarUID: calendarUID
        )
    }

    func reminderLists() throws -> [ReminderListInfo] {
        try backing.reminderLists()
    }

    func incompleteReminders(listName: String?) throws -> [ReminderItem] {
        try backing.incompleteReminders(listName: listName)
    }

    func addReminder(
        title: String,
        listName: String?,
        due: String,
        notes: String,
        priority: String
    ) throws -> ReminderCreated {
        try backing.addReminder(
            title: title,
            listName: listName,
            due: due,
            notes: notes,
            priority: priority
        )
    }

    func completeReminder(title: String, listName: String?) throws -> ReminderDoneResult {
        try backing.completeReminder(title: title, listName: listName)
    }

    func deleteReminder(title: String, listName: String?) throws -> ReminderDeleted {
        try backing.deleteReminder(title: title, listName: listName)
    }

    func moveReminder(
        title: String,
        fromList: String,
        toList: String
    ) throws -> ReminderMoved {
        try backing.moveReminder(title: title, fromList: fromList, toList: toList)
    }

    func editReminder(
        title: String,
        listName: String?,
        due: String,
        priority: String,
        notes: String
    ) throws -> ReminderEdited {
        try backing.editReminder(
            title: title,
            listName: listName,
            due: due,
            priority: priority,
            notes: notes
        )
    }

    func ensureReminderList(name: String) throws -> ReminderListEnsured {
        try backing.ensureReminderList(name: name)
    }
}
