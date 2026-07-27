import ArgumentParser
import EventKit
import Foundation

// MARK: - CLI

/// Domain: `macverbs reminders …`
struct RemindersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Reminders via EventKit.",
        discussion: """
            Examples:
              macverbs --json reminders lists
              macverbs reminders list --list Inbox
              macverbs reminders add "Task" --list Work --due 2026-08-01
            Exact title match for done/move/edit/delete. Prefer re-list after writes.

            """,
        subcommands: [
            RemindersListsCommand.self,
            RemindersListCommand.self,
            RemindersAddCommand.self,
            RemindersDoneCommand.self,
            RemindersMoveCommand.self,
            RemindersEditCommand.self,
            RemindersMklistCommand.self,
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
        help: "Priority: high, medium, or low.",
        completion: .list(["high", "medium", "low"])
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

/// `macverbs reminders move TITLE --from SRC --to DST`
struct RemindersMoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a reminder between lists (exact title match)."
    )

    @Argument(help: "Reminder title (exact match).")
    var title: String

    @Option(name: .customLong("from"), help: "Source list name (required).")
    var from: String

    @Option(name: .customLong("to"), help: "Destination list name (required).")
    var to: String

    func run() throws {
        let client = BackendClients.eventStore
        try client.ensureAccess(for: .reminder)
        let result = try client.moveReminder(
            title: title,
            fromList: from,
            toList: to
        )
        try CLIOutput.emit(result, text: RemindersFormat.moved)
    }
}

/// `macverbs reminders edit TITLE [--list] [--due] [--priority] [--notes]`
struct RemindersEditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit due date, priority, and/or notes (exact title match)."
    )

    @Argument(help: "Reminder title (exact match).")
    var title: String

    @Option(name: .long, help: "List name. Empty = default list.")
    var list: String = ""

    @Option(name: .long, help: "Due date: YYYY-MM-DD or YYYY-MM-DD HH:MM.")
    var due: String = ""

    @Option(
        name: .long,
        help: "Priority: high, medium, low, or none (clear).",
        completion: .list(["high", "medium", "low", "none"])
    )
    var priority: String = ""

    @Option(name: .long, help: "Notes / body.")
    var notes: String = ""

    func run() throws {
        if !priority.isEmpty {
            _ = try ReminderFields.priorityValue(priority)
        }
        let client = BackendClients.eventStore
        try client.ensureAccess(for: .reminder)
        let listName: String? = list.isEmpty ? nil : list
        let result = try client.editReminder(
            title: title,
            listName: listName,
            due: due,
            priority: priority,
            notes: notes
        )
        try CLIOutput.emit(result, text: RemindersFormat.edited)
    }
}

/// `macverbs reminders mklist NAME` — create list if missing (idempotent).
struct RemindersMklistCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mklist",
        abstract: "Ensure a reminder list exists (create if missing)."
    )

    @Argument(help: "List name.")
    var name: String

    func run() throws {
        let client = BackendClients.eventStore
        try client.ensureAccess(for: .reminder)
        let result = try client.ensureReminderList(name: name)
        try CLIOutput.emit(result, text: RemindersFormat.listEnsured)
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
