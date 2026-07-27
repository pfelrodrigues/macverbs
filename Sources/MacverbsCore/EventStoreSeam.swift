import EventKit
import Foundation

// MARK: - EventKit seam (Calendar + Reminders)

/// Entity types backed by EventKit.
enum EventEntityType: String, Codable, Sendable, CaseIterable {
    case event
    case reminder

    /// Human label for errors and doctor (`Calendar` / `Reminders`).
    var displayName: String {
        switch self {
        case .event:
            "Calendar"
        case .reminder:
            "Reminders"
        }
    }

    /// System Settings pane name under Privacy & Security.
    var privacySettingsPane: String {
        switch self {
        case .event:
            "Calendars"
        case .reminder:
            "Reminders"
        }
    }
}

/// Authorization status for an EventKit entity type.
///
/// Values mirror EventKit's model conceptually. The `unavailable` case is used by
/// the pre-wiring stub / tests that never touch EventKit.
enum EventAuthorizationStatus: String, Codable, Sendable {
    /// User has not been asked yet (real client may prompt on requestAccess).
    case notDetermined
    /// Restricted by parental controls / MDM.
    case restricted
    /// User denied access.
    case denied
    /// Access granted (generic / legacy full access).
    case authorized
    /// Full read/write access (macOS 14+ EventKit).
    case fullAccess
    /// Write-only access (macOS 14+ EventKit).
    case writeOnly
    /// Backend not wired; no EventKit call was made.
    case unavailable

    /// Whether status permits full read/write use for calendar and reminder verbs.
    var allowsFullAccess: Bool {
        switch self {
        case .fullAccess, .authorized:
            true
        case .notDetermined, .restricted, .denied, .writeOnly, .unavailable:
            false
        }
    }
}

/// Clear domain-error messages when EventKit access is missing or insufficient.
enum EventStoreAccess {
    /// Domain message for a non-granted status (exit 1).
    static func errorMessage(
        for entity: EventEntityType,
        status: EventAuthorizationStatus
    ) -> String {
        let name = entity.displayName
        let settings =
            "System Settings → Privacy & Security → \(entity.privacySettingsPane)"
        switch status {
        case .denied:
            return "\(name) access denied; enable in \(settings)"
        case .restricted:
            return "\(name) access restricted; enable in \(settings)"
        case .writeOnly:
            return
                "\(name) access is write-only; full access required — enable in \(settings)"
        case .notDetermined:
            return "\(name) access not granted; enable in \(settings)"
        case .unavailable:
            return
                "\(name) EventKit client not wired (Calendar, Reminders)"
        case .fullAccess, .authorized:
            return "\(name) access error"
        }
    }
}

// MARK: - Event data transfer (Calendar list)

/// Calendar metadata from EventKit (event calendars only).
struct EventKitCalendarInfo: Equatable, Sendable {
    /// EventKit `calendarIdentifier` (stable UID used in `calendars.json`).
    var uid: String
    /// Calendar title as shown in Calendar.app.
    var title: String
    /// Account/source description (e.g. `Exchange · Work`, `CalDAV`). Empty when unknown.
    var source: String = ""
}

/// One event occurrence (recurring series already expanded by EventKit).
struct EventKitEventInfo: Equatable, Sendable {
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    /// Owning calendar UID (`calendarIdentifier`).
    var calendarUID: String
    /// Owning calendar title (fallback label when config has no alias).
    var calendarTitle: String
}

/// Injectable EventKit store seam.
///
/// Production: `EKEventStoreClient` wraps `EKEventStore`. Unit tests inject mocks
/// or a fake `EventKitBacking`; they must not require live TCC prompts.
protocol EventStoreClient: Sendable {
    /// Read current authorization **without** prompting for access.
    func authorizationStatus(for entity: EventEntityType) -> EventAuthorizationStatus

    /// Request full access when status is still not determined (may prompt TCC).
    ///
    /// When already determined, returns the current status without prompting.
    /// Denied / restricted are returned as statuses (not thrown); only system
    /// failures throw.
    func requestAccess(for entity: EventEntityType) throws -> EventAuthorizationStatus

    /// Event calendars known to the store (empty when unwired).
    ///
    /// Callers must `ensureAccess(for: .event)` first in production paths.
    func eventCalendars() throws -> [EventKitCalendarInfo]

    /// Events in `[start, end)` with recurring instances expanded by EventKit.
    ///
    /// - Parameters:
    ///   - start: Inclusive range start.
    ///   - end: Exclusive range end (EventKit predicate convention).
    func events(from start: Date, to end: Date) throws -> [EventKitEventInfo]

    /// Create and persist a timed calendar event.
    ///
    /// - Parameters:
    ///   - title: Event summary.
    ///   - start: Inclusive start.
    ///   - end: EventKit end date.
    ///   - calendarUID: Target calendar identifier; `nil` uses the store default
    ///     for new events.
    /// - Throws: `MacverbsError.domain` when the UID is unknown or there is no
    ///   default calendar; `MacverbsError.system` on EventKit save failure.
    func saveEvent(
        title: String,
        start: Date,
        end: Date,
        calendarUID: String?
    ) throws

    /// Reminder lists with incomplete counts (caller must `ensureAccess` first).
    func reminderLists() throws -> [ReminderListInfo]

    /// Incomplete reminders. `listName` nil → all lists; else exact title match.
    ///
    /// - Throws: `MacverbsError.domain` when a named list is missing.
    func incompleteReminders(listName: String?) throws -> [ReminderItem]

    /// Create an incomplete reminder (reminders add).
    func addReminder(
        title: String,
        listName: String?,
        due: String,
        notes: String,
        priority: String
    ) throws -> ReminderCreated

    /// Complete first incomplete title match (optional list).
    func completeReminder(title: String, listName: String?) throws -> ReminderDoneResult

    /// Delete first incomplete title match (optional list).
    func deleteReminder(title: String, listName: String?) throws -> ReminderDeleted

    /// Move first incomplete title match from `fromList` to `toList`.
    func moveReminder(
        title: String,
        fromList: String,
        toList: String
    ) throws -> ReminderMoved

    /// Edit due / priority / notes on first incomplete title match.
    func editReminder(
        title: String,
        listName: String?,
        due: String,
        priority: String,
        notes: String
    ) throws -> ReminderEdited

    /// Ensure a reminder list exists (idempotent).
    func ensureReminderList(name: String) throws -> ReminderListEnsured
}

extension EventStoreClient {
    /// Ensure full access for `entity`, requesting once if not determined.
    ///
    /// - Throws: `MacverbsError.domain` with a clear System Settings hint when
    ///   access is denied, restricted, write-only, unavailable, or still not
    ///   granted after a request.
    func ensureAccess(for entity: EventEntityType) throws {
        var status = authorizationStatus(for: entity)
        if status == .notDetermined {
            status = try requestAccess(for: entity)
        }
        guard status.allowsFullAccess else {
            throw MacverbsError.domain(
                EventStoreAccess.errorMessage(for: entity, status: status)
            )
        }
    }
}

// MARK: - Injectable EventKit surface (test seam)

/// Low-level EventKit operations used by `EKEventStoreClient`.
///
/// Production uses `LiveEventKitBacking` (`EKEventStore`). Unit tests inject a
/// fake so authorization mapping and denial errors never touch live TCC.
protocol EventKitBacking: Sendable {
    /// Current authorization without prompting.
    func authorizationStatus(for entity: EventEntityType) -> EventAuthorizationStatus

    /// Request full access (may prompt). Returns whether the user granted access.
    func requestFullAccess(for entity: EventEntityType) throws -> Bool

    /// Event calendars from the store.
    func eventCalendars() throws -> [EventKitCalendarInfo]

    /// Events in `[start, end)` with recurrence expansion.
    func events(from start: Date, to end: Date) throws -> [EventKitEventInfo]

    /// Create and persist a timed calendar event (`calendarUID` nil → default).
    func saveEvent(
        title: String,
        start: Date,
        end: Date,
        calendarUID: String?
    ) throws

    /// Reminder lists with incomplete counts (no auth prompt).
    func reminderLists() throws -> [ReminderListInfo]

    /// Incomplete reminders. `listName` nil → all; else exact title match.
    func incompleteReminders(listName: String?) throws -> [ReminderItem]

    func addReminder(
        title: String,
        listName: String?,
        due: String,
        notes: String,
        priority: String
    ) throws -> ReminderCreated

    func completeReminder(title: String, listName: String?) throws -> ReminderDoneResult

    func deleteReminder(title: String, listName: String?) throws -> ReminderDeleted

    func moveReminder(
        title: String,
        fromList: String,
        toList: String
    ) throws -> ReminderMoved

    func editReminder(
        title: String,
        listName: String?,
        due: String,
        priority: String,
        notes: String
    ) throws -> ReminderEdited

    func ensureReminderList(name: String) throws -> ReminderListEnsured
}
