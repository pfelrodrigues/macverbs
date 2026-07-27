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

/// Result of `reminders add` (`created`, `list`).
struct ReminderCreated: Codable, Equatable, Sendable {
    var created: String
    /// List title, or `"(first)"` when `--list` was empty (default list).
    var list: String
}

/// Result of `reminders done` (`done`).
struct ReminderDoneResult: Codable, Equatable, Sendable {
    var done: String
}

/// Result of `reminders delete` (`deleted`).
struct ReminderDeleted: Codable, Equatable, Sendable {
    var deleted: String
}

/// Result of `reminders move` (`moved`, `from`, `to`).
struct ReminderMoved: Codable, Equatable, Sendable {
    var moved: String
    var from: String
    var to: String
}

/// Result of `reminders edit` (`edited`).
struct ReminderEdited: Codable, Equatable, Sendable {
    var edited: String
}

/// Result of `reminders mklist` (`list`).
struct ReminderListEnsured: Codable, Equatable, Sendable {
    var list: String
}

// MARK: - Priority + due formatting (contract)

/// Shared mapping helpers for reminder fields.
enum ReminderFields {
    /// Label reported when `--list` is empty (default is / first list).
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

    /// Name → EventKit priority for writes (priority map).
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
                "invalid priority '\(name)' (expected high|medium|low|none)"
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
    /// (date-only default time). Empty → `nil` (no due).
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

    static func moved(_ result: ReminderMoved) -> String {
        "moved: \(result.moved) (\(result.from) → \(result.to))"
    }

    static func edited(_ result: ReminderEdited) -> String {
        "edited: \(result.edited)"
    }

    static func listEnsured(_ result: ReminderListEnsured) -> String {
        "list ensured: \(result.list)"
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
