import ArgumentParser
import Foundation

// MARK: - Models

/// One listed calendar event for agents (`title`, `when`, `calendar`).
struct CalendarEventItem: Codable, Equatable, Sendable {
    var title: String
    /// Human time window (oracle-compatible: `YYYY-MM-DD at HH:MM - HH:MM` or date).
    var when: String
    /// Label from `calendars.json` UID map, else EventKit calendar title.
    var calendar: String
}

/// One event calendar for discovery (`calendar calendars`).
struct CalendarInfoItem: Codable, Equatable, Sendable {
    /// EventKit `calendarIdentifier` (key for `calendars.json`).
    var uid: String
    /// Title as shown in Calendar.app.
    var title: String
    /// Account/source description when available.
    var source: String
    /// Label from `calendars.json` if configured; otherwise empty.
    var label: String
}

/// Result of `calendar add` (oracle keys: `created`, `start`, `end`).
struct CalendarAddResult: Codable, Equatable, Sendable {
    /// Created event title.
    var created: String
    /// Echo of the start argument (`YYYY-MM-DD HH:MM`).
    var start: String
    /// Echo of the end argument (`YYYY-MM-DD HH:MM`).
    var end: String
}

// MARK: - List / add logic

/// Calendar domain verbs (EventKit; no icalBuddy).
enum CalendarService {
    /// Inclusive days after today for `--days` (oracle: `eventsToday+N`).
    ///
    /// - Parameter days: Non-negative count of days ahead of today (0 = today only).
    /// - Returns: Half-open range `[startOfToday, startOfToday+(days+1))`.
    static func dateRange(
        days: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> (start: Date, end: Date) {
        guard days >= 0 else {
            throw MacverbsError.domain("--days must be >= 0")
        }
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: days + 1, to: start) else {
            throw MacverbsError.system("failed to compute calendar date range")
        }
        return (start, end)
    }

    /// Format an EventKit occurrence into the oracle-style `when` string.
    ///
    /// All-day end dates are exclusive in EventKit (next midnight); multi-day
    /// all-day ranges become `YYYY-MM-DD - YYYY-MM-DD`.
    static func formatWhen(
        start: Date,
        end: Date,
        isAllDay: Bool,
        calendar: Calendar = .current
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"

        if isAllDay {
            // EventKit exclusive end → last inclusive day is end - 1 day.
            let lastDay = calendar.date(byAdding: .day, value: -1, to: end) ?? end
            let startS = dateFormatter.string(from: start)
            let endS = dateFormatter.string(from: lastDay)
            if startS == endS {
                return startS
            }
            return "\(startS) - \(endS)"
        }

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.dateFormat = "HH:mm"

        let startDate = dateFormatter.string(from: start)
        let endDate = dateFormatter.string(from: end)
        let startTime = timeFormatter.string(from: start)
        let endTime = timeFormatter.string(from: end)

        if startDate == endDate {
            return "\(startDate) at \(startTime) - \(endTime)"
        }
        return "\(startDate) at \(startTime) - \(endDate) at \(endTime)"
    }

    /// Map raw EventKit rows + aliases into sorted CLI items.
    static func mapEvents(
        _ raw: [EventKitEventInfo],
        aliases: CalendarAliases,
        calendar: Calendar = .current
    ) -> [CalendarEventItem] {
        let sorted = raw.sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate {
                return lhs.startDate < rhs.startDate
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return sorted.map { event in
            let label = aliases.label(forUID: event.calendarUID, fallback: event.calendarTitle)
            return CalendarEventItem(
                title: event.title,
                when: formatWhen(
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    calendar: calendar
                ),
                calendar: label
            )
        }
    }

    /// List upcoming events for `days` ahead of `now` (recurring expanded by EventKit).
    static func list(
        days: Int = 7,
        eventStore: any EventStoreClient = BackendClients.eventStore,
        aliases: CalendarAliases = Config.loadCalendarAliases(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> [CalendarEventItem] {
        try eventStore.ensureAccess(for: .event)
        let range = try dateRange(days: days, now: now, calendar: calendar)
        let raw = try eventStore.events(from: range.start, to: range.end)
        return mapEvents(raw, aliases: aliases, calendar: calendar)
    }

    /// Parse oracle datetime `YYYY-MM-DD HH:MM` in the given calendar/time zone.
    static func parseDateTime(
        _ string: String,
        calendar: Calendar = .current
    ) throws -> Date {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = formatter.date(from: trimmed) else {
            throw MacverbsError.domain(
                "invalid date '\(string)' (expected YYYY-MM-DD HH:MM)"
            )
        }
        return date
    }

    /// Resolve `--calendar` to an EventKit UID.
    ///
    /// Empty name → `nil` (store default). Otherwise match alias label, EventKit
    /// title, or UID. Throws domain when no match.
    static func resolveCalendarUID(
        name: String,
        calendars: [EventKitCalendarInfo],
        aliases: CalendarAliases
    ) throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }

        // Prefer config alias label (disambiguates same-named calendars).
        for (uid, label) in aliases.labelsByUID where label == trimmed {
            if calendars.contains(where: { $0.uid == uid }) {
                return uid
            }
        }

        // EventKit calendar title (oracle: Calendar.app name).
        if let match = calendars.first(where: { $0.title == trimmed }) {
            return match.uid
        }

        // Allow passing the raw UID when known.
        if calendars.contains(where: { $0.uid == trimmed }) {
            return trimmed
        }

        throw MacverbsError.domain("calendar \(trimmed) not found")
    }

    /// Create a timed event. `--calendar` empty uses the EventKit default calendar.
    static func add(
        title: String,
        start: String,
        end: String,
        calendarName: String = "",
        eventStore: any EventStoreClient = BackendClients.eventStore,
        aliases: CalendarAliases = Config.loadCalendarAliases(),
        calendar: Calendar = .current
    ) throws -> CalendarAddResult {
        try eventStore.ensureAccess(for: .event)

        let startDate = try parseDateTime(start, calendar: calendar)
        let endDate = try parseDateTime(end, calendar: calendar)
        guard endDate > startDate else {
            throw MacverbsError.domain("--end must be after --start")
        }

        let known = try eventStore.eventCalendars()
        let uid = try resolveCalendarUID(
            name: calendarName,
            calendars: known,
            aliases: aliases
        )
        try eventStore.saveEvent(
            title: title,
            start: startDate,
            end: endDate,
            calendarUID: uid
        )
        return CalendarAddResult(created: title, start: start, end: end)
    }

    /// Human text for a list result (English public CLI).
    static func formatText(_ items: [CalendarEventItem]) -> String {
        if items.isEmpty {
            return "no events."
        }
        return
            items.map { item in
                "- \(item.title) | \(item.when) | \(item.calendar)"
            }
            .joined(separator: "\n")
    }

    /// Human text for an add result.
    static func formatAdd(_ result: CalendarAddResult) -> String {
        "created: \(result.created)"
    }

    /// List event calendars with UID/title/source and optional config label.
    static func listCalendars(
        client: any EventStoreClient = BackendClients.eventStore,
        aliases: CalendarAliases = Config.loadCalendarAliases()
    ) throws -> [CalendarInfoItem] {
        try client.ensureAccess(for: .event)
        let calendars = try client.eventCalendars()
        return
            calendars
            .sorted { lhs, rhs in
                if lhs.title != rhs.title {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                        == .orderedAscending
                }
                return lhs.uid < rhs.uid
            }
            .map { cal in
                CalendarInfoItem(
                    uid: cal.uid,
                    title: cal.title,
                    source: cal.source,
                    label: aliases.labelsByUID[cal.uid] ?? ""
                )
            }
    }

    static func formatCalendars(_ items: [CalendarInfoItem]) -> String {
        if items.isEmpty {
            return "no calendars."
        }
        return
            items.map { item in
                var line = "- \(item.title)"
                if !item.source.isEmpty {
                    line += " | source: \(item.source)"
                }
                if !item.label.isEmpty {
                    line += " | label: \(item.label)"
                }
                line += " | uid: \(item.uid)"
                return line
            }
            .joined(separator: "\n")
    }
}

// MARK: - CLI

/// `macverbs calendar` domain.
struct CalendarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Calendar events (EventKit).",
        subcommands: [
            CalendarListCommand.self,
            CalendarAddCommand.self,
            CalendarCalendarsCommand.self,
        ]
    )
}

/// `macverbs calendar calendars` — discover UIDs for calendars.json.
struct CalendarCalendarsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendars",
        abstract: "List event calendars with UID (for calendars.json)."
    )

    func run() throws {
        let items = try CalendarService.listCalendars()
        try CLIOutput.emit(items, text: CalendarService.formatCalendars)
    }
}

/// `macverbs calendar list [--days N]`.
struct CalendarListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List upcoming events (recurring expanded; labels from config)."
    )

    @Option(
        name: .long,
        help: "Days ahead of today to include (default: 7; 0 = today only)."
    )
    var days: Int = 7

    func run() throws {
        let items = try CalendarService.list(days: days)
        try CLIOutput.emit(items, text: CalendarService.formatText)
    }
}

/// `macverbs calendar add TITLE --start --end [--calendar]`.
struct CalendarAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a timed calendar event (EventKit)."
    )

    @Argument(help: "Event title.")
    var title: String

    @Option(name: .long, help: "Start datetime (YYYY-MM-DD HH:MM).")
    var start: String

    @Option(name: .long, help: "End datetime (YYYY-MM-DD HH:MM).")
    var end: String

    @Option(
        name: .long,
        help: "Calendar alias, title, or UID. Empty = default calendar."
    )
    var calendar: String = ""

    func run() throws {
        let result = try CalendarService.add(
            title: title,
            start: start,
            end: end,
            calendarName: calendar
        )
        try CLIOutput.emit(result, text: CalendarService.formatAdd)
    }
}
