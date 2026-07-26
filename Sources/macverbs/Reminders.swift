import ArgumentParser
import EventKit
import Foundation

// MARK: - Models (JSON contract)

/// One reminder list with incomplete-item count.
///
/// Oracle keys: `name`, `pending`.
struct ReminderListInfo: Codable, Equatable, Sendable {
    var name: String
    var pending: Int
}

/// One incomplete reminder.
///
/// Oracle keys: `title`, `due`, `priority`, `notes`. Additive: `list`.
struct ReminderItem: Codable, Equatable, Sendable {
    var title: String
    /// Empty when no due date. Prefer `YYYY-MM-DD` or `YYYY-MM-DD HH:MM`.
    var due: String
    /// Empty when none; otherwise `high` / `medium` / `low` (EventKit 0–9 mapping).
    var priority: String
    /// Source list title.
    var list: String
    /// Body / notes; empty when absent.
    var notes: String
}

// MARK: - Priority + due formatting (oracle parity)

/// Shared mapping helpers for reminder fields.
enum ReminderFields {
    /// EventKit priority (0–9) → name (`""` if none).
    ///
    /// Oracle: 0 none; 1–4 high; 5 medium; 6–9 low.
    static func priorityName(_ priority: Int) -> String {
        if priority == 0 {
            return ""
        }
        if priority <= 4 {
            return "high"
        }
        if priority == 5 {
            return "medium"
        }
        return "low"
    }

    /// Format `DateComponents` from EventKit into a stable agent-facing string.
    ///
    /// Date only → `YYYY-MM-DD`. With hour/minute → `YYYY-MM-DD HH:MM`.
    static func dueString(from components: DateComponents?) -> String {
        guard let components,
            let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            return ""
        }
        if let hour = components.hour, let minute = components.minute {
            return String(
                format: "%04d-%02d-%02d %02d:%02d",
                year,
                month,
                day,
                hour,
                minute
            )
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Map an `EKReminder` into the JSON item shape.
    static func item(from reminder: EKReminder) -> ReminderItem {
        ReminderItem(
            title: reminder.title ?? "",
            due: dueString(from: reminder.dueDateComponents),
            priority: priorityName(Int(reminder.priority)),
            list: reminder.calendar?.title ?? "",
            notes: reminder.notes ?? ""
        )
    }
}

// MARK: - Text formatters

enum RemindersFormat {
    static func lists(_ items: [ReminderListInfo]) -> String {
        if items.isEmpty {
            return "no lists."
        }
        return items.map { "- \($0.name) (\($0.pending) pending)" }.joined(separator: "\n")
    }

    static func items(_ items: [ReminderItem]) -> String {
        if items.isEmpty {
            return "no pending reminders."
        }
        return items.map(formatItem).joined(separator: "\n")
    }

    private static func formatItem(_ r: ReminderItem) -> String {
        var line = "- \(r.title)"
        if !r.list.isEmpty {
            line += " | list: \(r.list)"
        }
        if !r.due.isEmpty {
            line += " | due: \(r.due)"
        }
        if !r.priority.isEmpty {
            line += " | priority: \(r.priority)"
        }
        if !r.notes.isEmpty {
            line += " | notes: \(r.notes)"
        }
        return line
    }
}

// MARK: - EventKit query (production path)

/// Synchronous EventKit queries for incomplete reminders and list metadata.
enum LiveRemindersQuery {
    /// List every reminder calendar with its incomplete count.
    static func lists(store: EKEventStore) throws -> [ReminderListInfo] {
        let calendars = store.calendars(for: .reminder)
        let raw = try fetchIncompleteRaw(store: store, calendars: nil)
        var counts: [String: Int] = [:]
        for row in raw {
            counts[row.calendarID, default: 0] += 1
        }
        // One row per EventKit calendar (count keyed by calendarIdentifier).
        return calendars.map { calendar in
            ReminderListInfo(
                name: calendar.title,
                pending: counts[calendar.calendarIdentifier] ?? 0
            )
        }
    }

    /// Incomplete reminders. `listName` nil/empty → all lists; else exact title match.
    static func incomplete(store: EKEventStore, listName: String?) throws -> [ReminderItem] {
        let all = store.calendars(for: .reminder)
        let calendars: [EKCalendar]?
        if let listName, !listName.isEmpty {
            let match = all.filter { $0.title == listName }
            if match.isEmpty {
                throw MacverbsError.domain("list \(listName) not found")
            }
            calendars = match
        } else {
            calendars = nil
        }
        return try fetchIncompleteRaw(store: store, calendars: calendars).map(\.item)
    }

    private struct RawReminderRow {
        var item: ReminderItem
        var calendarID: String
    }

    private static func fetchIncompleteRaw(
        store: EKEventStore,
        calendars: [EKCalendar]?
    ) throws -> [RawReminderRow] {
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
        return box.reminders.map { reminder in
            RawReminderRow(
                item: ReminderFields.item(from: reminder),
                calendarID: reminder.calendar?.calendarIdentifier ?? ""
            )
        }
    }

    /// Mutable carrier for EventKit completion handlers (sync bridge).
    private final class ReminderFetchBox: @unchecked Sendable {
        var reminders: [EKReminder] = []
    }
}

// MARK: - CLI

/// Domain: `macverbs reminders …`
struct RemindersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Reminders via EventKit.",
        subcommands: [
            RemindersListsCommand.self,
            RemindersListCommand.self,
        ]
    )
}

/// `macverbs reminders lists` — list names and pending counts.
struct RemindersListsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lists",
        abstract: "List reminder lists and pending counts."
    )

    func run() throws {
        let client = BackendClients.eventStore
        try client.ensureAccess(for: .reminder)
        let rows = try client.reminderLists()
        try CLIOutput.emit(rows, text: RemindersFormat.lists)
    }
}

/// `macverbs reminders list [--list NAME]` — incomplete reminders.
struct RemindersListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List incomplete reminders (optionally filter by list)."
    )

    @Option(
        name: .long,
        help: "Reminder list name. Empty = all lists."
    )
    var list: String = ""

    func run() throws {
        let client = BackendClients.eventStore
        try client.ensureAccess(for: .reminder)
        let listName: String? = list.isEmpty ? nil : list
        let rows = try client.incompleteReminders(listName: listName)
        try CLIOutput.emit(rows, text: RemindersFormat.items)
    }
}
