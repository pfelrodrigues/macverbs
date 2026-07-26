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

/// Result of `reminders add` (oracle: `created`, `list`).
struct ReminderCreated: Codable, Equatable, Sendable {
    var created: String
    /// List title, or `"(first)"` when `--list` was empty (oracle default list).
    var list: String
}

/// Result of `reminders done` (oracle: `done`).
struct ReminderDoneResult: Codable, Equatable, Sendable {
    var done: String
}

/// Result of `reminders delete` (oracle: `deleted`).
struct ReminderDeleted: Codable, Equatable, Sendable {
    var deleted: String
}

// MARK: - Priority + due formatting (oracle parity)

/// Shared mapping helpers for reminder fields.
enum ReminderFields {
    /// Label reported when `--list` is empty (oracle uses default / first list).
    static let defaultListLabel = "(first)"

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

    /// Name → EventKit priority for writes (oracle `PRIORITY` map).
    ///
    /// high→1, medium→5, low→9, empty/none→0.
    static func priorityValue(_ name: String) throws -> Int {
        switch name {
        case "", "none":
            return 0
        case "high":
            return 1
        case "medium":
            return 5
        case "low":
            return 9
        default:
            throw MacverbsError.domain(
                "invalid priority '\(name)' (expected high|medium|low)"
            )
        }
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

    /// Parse agent due string into EventKit `DateComponents`.
    ///
    /// Accepts `YYYY-MM-DD` or `YYYY-MM-DD HH:MM`. Date-only defaults to 09:00
    /// (oracle AppleScript parity). Empty → `nil` (no due).
    static func parseDue(_ due: String) throws -> DateComponents? {
        let trimmed = due.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        let parts = trimmed.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: true
        )
        let dateBits = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard dateBits.count == 3,
            dateBits[0].count == 4,
            let year = Int(dateBits[0]),
            let month = Int(dateBits[1]),
            let day = Int(dateBits[2]),
            (1...12).contains(month),
            (1...31).contains(day)
        else {
            throw MacverbsError.domain(
                "invalid due '\(due)' (expected YYYY-MM-DD or YYYY-MM-DD HH:MM)"
            )
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        if parts.count == 2 {
            let timeBits = parts[1]
                .split(
                    separator: ":",
                    omittingEmptySubsequences: false
                )
            guard timeBits.count == 2,
                let hour = Int(timeBits[0]),
                let minute = Int(timeBits[1]),
                (0...23).contains(hour),
                (0...59).contains(minute)
            else {
                throw MacverbsError.domain(
                    "invalid due '\(due)' (expected YYYY-MM-DD or YYYY-MM-DD HH:MM)"
                )
            }
            components.hour = hour
            components.minute = minute
        } else {
            // Oracle `_due_block`: date-only → 09:00.
            components.hour = 9
            components.minute = 0
        }
        return components
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

    static func created(_ result: ReminderCreated) -> String {
        "created: \(result.created)"
    }

    static func done(_ result: ReminderDoneResult) -> String {
        "done: \(result.done)"
    }

    static func deleted(_ result: ReminderDeleted) -> String {
        "deleted: \(result.deleted)"
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

    /// Create a reminder (oracle `reminder_add`).
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

// MARK: - CLI

/// Domain: `macverbs reminders …`
struct RemindersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Reminders via EventKit.",
        subcommands: [
            RemindersListsCommand.self,
            RemindersListCommand.self,
            RemindersAddCommand.self,
            RemindersDoneCommand.self,
            RemindersDeleteCommand.self,
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

/// `macverbs reminders add TITLE [--list] [--due] [--notes] [--priority]`
struct RemindersAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a reminder."
    )

    @Argument(help: "Reminder title.")
    var title: String

    @Option(name: .long, help: "List name. Empty = default list.")
    var list: String = ""

    @Option(name: .long, help: "Due date: YYYY-MM-DD or YYYY-MM-DD HH:MM.")
    var due: String = ""

    @Option(name: .long, help: "Notes / body.")
    var notes: String = ""

    @Option(
        name: .long,
        help: "Priority: high, medium, or low."
    )
    var priority: String = ""

    func run() throws {
        if !priority.isEmpty {
            _ = try ReminderFields.priorityValue(priority)
        }
        let client = BackendClients.eventStore
        try client.ensureAccess(for: .reminder)
        let listName: String? = list.isEmpty ? nil : list
        let result = try client.addReminder(
            title: title,
            listName: listName,
            due: due,
            notes: notes,
            priority: priority
        )
        try CLIOutput.emit(result, text: RemindersFormat.created)
    }
}

/// `macverbs reminders done TITLE [--list]` — complete by title (+ list).
struct RemindersDoneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "done",
        abstract: "Mark a reminder complete (exact title match)."
    )

    @Argument(help: "Reminder title (exact match).")
    var title: String

    @Option(name: .long, help: "List name. Empty = default list.")
    var list: String = ""

    func run() throws {
        let client = BackendClients.eventStore
        try client.ensureAccess(for: .reminder)
        let listName: String? = list.isEmpty ? nil : list
        let result = try client.completeReminder(title: title, listName: listName)
        try CLIOutput.emit(result, text: RemindersFormat.done)
    }
}

/// `macverbs reminders delete TITLE [--list]` — delete without completing.
struct RemindersDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a reminder without completing it (exact title match)."
    )

    @Argument(help: "Reminder title (exact match).")
    var title: String

    @Option(name: .long, help: "List name. Empty = default list.")
    var list: String = ""

    func run() throws {
        let client = BackendClients.eventStore
        try client.ensureAccess(for: .reminder)
        let listName: String? = list.isEmpty ? nil : list
        let result = try client.deleteReminder(title: title, listName: listName)
        try CLIOutput.emit(result, text: RemindersFormat.deleted)
    }
}
