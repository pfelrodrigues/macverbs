import EventKit
import Foundation

// MARK: - Live EKEventStore

/// Production backing over a long-lived `EKEventStore`.
final class LiveEventKitBacking: EventKitBacking, @unchecked Sendable {
    /// Shared store for calendar and reminder verbs.
    let store: EKEventStore

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    func authorizationStatus(for entity: EventEntityType) -> EventAuthorizationStatus {
        let ekType = Self.ekEntityType(entity)
        return Self.map(EKEventStore.authorizationStatus(for: ekType))
    }

    func requestFullAccess(for entity: EventEntityType) throws -> Bool {
        let box = RequestBox()
        let semaphore = DispatchSemaphore(value: 0)

        switch entity {
        case .event:
            store.requestFullAccessToEvents { granted, error in
                box.granted = granted
                box.error = error
                semaphore.signal()
            }
        case .reminder:
            store.requestFullAccessToReminders { granted, error in
                box.granted = granted
                box.error = error
                semaphore.signal()
            }
        }

        semaphore.wait()

        if let requestError = box.error {
            throw MacverbsError.system(
                "EventKit access request failed: \(requestError.localizedDescription)"
            )
        }
        return box.granted
    }

    func eventCalendars() throws -> [EventKitCalendarInfo] {
        store.calendars(for: .event)
            .map { cal in
                EventKitCalendarInfo(
                    uid: cal.calendarIdentifier,
                    title: cal.title,
                    source: Self.describeSource(cal.source)
                )
            }
    }

    /// Human-readable EventKit source for disambiguation in config init.
    static func describeSource(_ source: EKSource) -> String {
        describeSource(type: source.sourceType, title: source.title)
    }

    /// Pure mapping of EventKit source type + title (unit-testable without a live store).
    static func describeSource(type: EKSourceType, title: String) -> String {
        let typeName: String
        switch type {
        case .local:
            typeName = "Local"
        case .exchange:
            typeName = "Exchange"
        case .calDAV:
            typeName = "CalDAV"
        case .mobileMe:
            typeName = "iCloud"
        case .subscribed:
            typeName = "Subscribed"
        case .birthdays:
            typeName = "Birthdays"
        @unknown default:
            typeName = "Other"
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare(typeName) == .orderedSame {
            return typeName
        }
        return "\(typeName) · \(trimmed)"
    }

    func events(from start: Date, to end: Date) throws -> [EventKitEventInfo] {
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: calendars
        )
        // EventKit expands recurring events into individual occurrences for the range.
        return store.events(matching: predicate)
            .map { event in
                EventKitEventInfo(
                    title: event.title ?? "",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarUID: event.calendar.calendarIdentifier,
                    calendarTitle: event.calendar.title
                )
            }
    }

    func saveEvent(
        title: String,
        start: Date,
        end: Date,
        calendarUID: String?
    ) throws {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        if let calendarUID {
            guard let calendar = store.calendar(withIdentifier: calendarUID) else {
                throw MacverbsError.domain("calendar not found")
            }
            event.calendar = calendar
        } else {
            guard let calendar = store.defaultCalendarForNewEvents else {
                throw MacverbsError.domain("no default calendar available")
            }
            event.calendar = calendar
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw MacverbsError.system(
                "EventKit save failed: \(error.localizedDescription)"
            )
        }
    }

    func reminderLists() throws -> [ReminderListInfo] {
        try LiveRemindersQuery.lists(store: store)
    }

    func incompleteReminders(listName: String?) throws -> [ReminderItem] {
        try LiveRemindersQuery.incomplete(store: store, listName: listName)
    }

    func addReminder(
        title: String,
        listName: String?,
        due: String,
        notes: String,
        priority: String
    ) throws -> ReminderCreated {
        try LiveRemindersQuery.add(
            store: store,
            title: title,
            listName: listName,
            due: due,
            notes: notes,
            priority: priority
        )
    }

    func completeReminder(title: String, listName: String?) throws -> ReminderDoneResult {
        try LiveRemindersQuery.complete(store: store, title: title, listName: listName)
    }

    func deleteReminder(title: String, listName: String?) throws -> ReminderDeleted {
        try LiveRemindersQuery.delete(store: store, title: title, listName: listName)
    }

    func moveReminder(
        title: String,
        fromList: String,
        toList: String
    ) throws -> ReminderMoved {
        try LiveRemindersQuery.move(
            store: store,
            title: title,
            fromList: fromList,
            toList: toList
        )
    }

    func editReminder(
        title: String,
        listName: String?,
        due: String,
        priority: String,
        notes: String
    ) throws -> ReminderEdited {
        try LiveRemindersQuery.edit(
            store: store,
            title: title,
            listName: listName,
            due: due,
            priority: priority,
            notes: notes
        )
    }

    func ensureReminderList(name: String) throws -> ReminderListEnsured {
        try LiveRemindersQuery.ensureList(store: store, name: name)
    }

    /// Mutable result carrier for EventKit completion handlers (sync bridge).
    private final class RequestBox: @unchecked Sendable {
        var granted = false
        var error: Error?
    }

    /// Map EventKit status into the CLI seam enum.
    static func map(_ status: EKAuthorizationStatus) -> EventAuthorizationStatus {
        switch status {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .fullAccess:
            .fullAccess
        case .writeOnly:
            .writeOnly
        @unknown default:
            // Legacy `.authorized` aliases `.fullAccess` on modern SDKs.
            .fullAccess
        }
    }

    private static func ekEntityType(_ entity: EventEntityType) -> EKEntityType {
        switch entity {
        case .event:
            .event
        case .reminder:
            .reminder
        }
    }
}
