import ArgumentParser
import EventKit
import Foundation

// MARK: - EventKit query + mutations (production path)

/// Synchronous EventKit queries and mutations for reminders.
enum LiveRemindersQuery {
    /// List every reminder calendar with its incomplete count.
    static func lists(store: EKEventStore) throws -> [ReminderListInfo] {
        let calendars = store.calendars(for: .reminder)
        let raw = try fetchIncompleteRaw(store: store, calendars: nil)
        var counts: [String: Int] = [:]
        for row in raw {
            counts[row.calendarID, default: 0] += 1
        }
        return calendars.map { calendar in
            ReminderListInfo(
                name: calendar.title,
                pending: counts[calendar.calendarIdentifier] ?? 0
            )
        }
    }

    /// Incomplete reminders. `listName` nil/empty → all lists; else exact title match.
    static func incomplete(store: EKEventStore, listName: String?) throws -> [ReminderItem] {
        let calendars: [EKCalendar]?
        if let listName, !listName.isEmpty {
            calendars = [try resolveList(store: store, listName: listName)]
        } else {
            calendars = nil
        }
        return try fetchIncompleteRaw(store: store, calendars: calendars).map(\.item)
    }

    /// Create a reminder (reminders add).
    static func add(
        store: EKEventStore,
        title: String,
        listName: String?,
        due: String,
        notes: String,
        priority: String
    ) throws -> ReminderCreated {
        let calendar = try resolveList(store: store, listName: listName)
        let dueComponents = try ReminderFields.parseDue(due)
        let priorityValue = try ReminderFields.priorityValue(priority)

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        if !notes.isEmpty {
            reminder.notes = notes
        }
        if priorityValue != 0 {
            reminder.priority = priorityValue
        }
        if let dueComponents {
            reminder.dueDateComponents = dueComponents
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw MacverbsError.system(
                "EventKit save failed: \(error.localizedDescription)"
            )
        }

        let reportedList: String
        if let listName, !listName.isEmpty {
            reportedList = listName
        } else {
            reportedList = ReminderFields.defaultListLabel
        }
        return ReminderCreated(created: title, list: reportedList)
    }

    /// Complete first incomplete match by exact title within resolved list.
    static func complete(
        store: EKEventStore,
        title: String,
        listName: String?
    ) throws -> ReminderDoneResult {
        let reminder = try findIncomplete(store: store, title: title, listName: listName)
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw MacverbsError.system(
                "EventKit save failed: \(error.localizedDescription)"
            )
        }
        return ReminderDoneResult(done: title)
    }

    /// Delete first incomplete match by exact title within resolved list.
    static func delete(
        store: EKEventStore,
        title: String,
        listName: String?
    ) throws -> ReminderDeleted {
        let reminder = try findIncomplete(store: store, title: title, listName: listName)
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw MacverbsError.system(
                "EventKit remove failed: \(error.localizedDescription)"
            )
        }
        return ReminderDeleted(deleted: title)
    }

    /// Move first incomplete match from `fromList` to `toList` (exact titles).
    static func move(
        store: EKEventStore,
        title: String,
        fromList: String,
        toList: String
    ) throws -> ReminderMoved {
        let source = try resolveList(store: store, listName: fromList)
        let destination = try resolveList(store: store, listName: toList)
        let rows = try fetchIncompleteReminders(store: store, calendars: [source])
        guard let match = rows.first(where: { ($0.title ?? "") == title }) else {
            throw MacverbsError.domain("reminder \(title) not found")
        }
        match.calendar = destination
        do {
            try store.save(match, commit: true)
        } catch {
            throw MacverbsError.system(
                "EventKit save failed: \(error.localizedDescription)"
            )
        }
        return ReminderMoved(moved: title, from: fromList, to: toList)
    }

    /// Edit due / priority / notes on first incomplete title match.
    ///
    /// At least one of `due`, `priority`, or `notes` must be non-empty .
    /// `priority` may be `none` to clear. Empty `listName` → default list.
    static func edit(
        store: EKEventStore,
        title: String,
        listName: String?,
        due: String,
        priority: String,
        notes: String
    ) throws -> ReminderEdited {
        if due.isEmpty && priority.isEmpty && notes.isEmpty {
            throw MacverbsError.domain(
                "nothing to edit: provide --due, --priority, or --notes"
            )
        }
        let reminder = try findIncomplete(store: store, title: title, listName: listName)
        if !due.isEmpty {
            // parseDue throws on invalid non-empty input; nil only for empty (handled above).
            if let dueComponents = try ReminderFields.parseDue(due) {
                reminder.dueDateComponents = dueComponents
            }
        }
        if !priority.isEmpty {
            reminder.priority = try ReminderFields.priorityValue(priority)
        }
        if !notes.isEmpty {
            reminder.notes = notes
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw MacverbsError.system(
                "EventKit save failed: \(error.localizedDescription)"
            )
        }
        return ReminderEdited(edited: title)
    }

    /// Ensure a reminder list exists (idempotent; create when missing).
    static func ensureList(
        store: EKEventStore,
        name: String
    ) throws -> ReminderListEnsured {
        let existing = store.calendars(for: .reminder)
        if existing.contains(where: { $0.title == name }) {
            return ReminderListEnsured(list: name)
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = name
        if let defaultList = store.defaultCalendarForNewReminders() {
            calendar.source = defaultList.source
        } else if let source = store.sources.first(where: { $0.sourceType == .local })
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first
        {
            calendar.source = source
        } else {
            throw MacverbsError.domain("no calendar source available for new list")
        }
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw MacverbsError.system(
                "EventKit saveCalendar failed: \(error.localizedDescription)"
            )
        }
        return ReminderListEnsured(list: name)
    }

    /// Resolve list by exact title; empty/nil → default (or first) list.
    static func resolveList(store: EKEventStore, listName: String?) throws -> EKCalendar {
        let all = store.calendars(for: .reminder)
        if let listName, !listName.isEmpty {
            guard let match = all.first(where: { $0.title == listName }) else {
                throw MacverbsError.domain("list \(listName) not found")
            }
            return match
        }
        if let defaultList = store.defaultCalendarForNewReminders() {
            return defaultList
        }
        guard let first = all.first else {
            throw MacverbsError.domain("no reminder lists available")
        }
        return first
    }

    /// First incomplete reminder with exact title in the resolved list.
    static func findIncomplete(
        store: EKEventStore,
        title: String,
        listName: String?
    ) throws -> EKReminder {
        let calendar = try resolveList(store: store, listName: listName)
        let rows = try fetchIncompleteReminders(store: store, calendars: [calendar])
        guard let match = rows.first(where: { ($0.title ?? "") == title }) else {
            throw MacverbsError.domain("reminder \(title) not found")
        }
        return match
    }

    private struct RawReminderRow {
        var item: ReminderItem
        var calendarID: String
    }

    private static func fetchIncompleteRaw(
        store: EKEventStore,
        calendars: [EKCalendar]?
    ) throws -> [RawReminderRow] {
        try fetchIncompleteReminders(store: store, calendars: calendars)
            .map { reminder in
                RawReminderRow(
                    item: ReminderFields.item(from: reminder),
                    calendarID: reminder.calendar?.calendarIdentifier ?? ""
                )
            }
    }

    private static func fetchIncompleteReminders(
        store: EKEventStore,
        calendars: [EKCalendar]?
    ) throws -> [EKReminder] {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )
        let box = ReminderFetchBox()
        let semaphore = DispatchSemaphore(value: 0)
        store.fetchReminders(matching: predicate) { reminders in
            box.reminders = reminders ?? []
            semaphore.signal()
        }
        semaphore.wait()
        return box.reminders
    }

    private final class ReminderFetchBox: @unchecked Sendable {
        var reminders: [EKReminder] = []
    }
}
