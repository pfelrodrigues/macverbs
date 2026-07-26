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

// MARK: - List logic

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
}

// MARK: - CLI

/// `macverbs calendar` domain.
struct CalendarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Calendar events (EventKit).",
        subcommands: [CalendarListCommand.self]
    )
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
