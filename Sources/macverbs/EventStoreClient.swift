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
                "\(name) EventKit client not wired (Calendar, Reminders; see T06)"
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

    /// Create an incomplete reminder (oracle `reminder_add`).
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

// MARK: - Live EKEventStore

/// Production backing over a long-lived `EKEventStore`.
final class LiveEventKitBacking: EventKitBacking, @unchecked Sendable {
    /// Shared store for calendar and reminder verbs (T07+).
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
                    title: cal.title
                )
            }
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

// MARK: - Stub (no EventKit / no TCC)

/// Test / pre-wiring client. Always reports `unavailable`; never touches EventKit.
struct StubEventStoreClient: EventStoreClient {
    /// Identity string for doctor / diagnostics.
    static let kind = "stub"

    func authorizationStatus(for entity: EventEntityType) -> EventAuthorizationStatus {
        .unavailable
    }

    func requestAccess(for entity: EventEntityType) throws -> EventAuthorizationStatus {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders; see T06)"
        )
    }

    func eventCalendars() throws -> [EventKitCalendarInfo] {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders; see T06)"
        )
    }

    func events(from start: Date, to end: Date) throws -> [EventKitEventInfo] {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders; see T06)"
        )
    }

    func saveEvent(
        title: String,
        start: Date,
        end: Date,
        calendarUID: String?
    ) throws {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders; see T06)"
        )
    }

    func reminderLists() throws -> [ReminderListInfo] {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders; see T06)"
        )
    }

    func incompleteReminders(listName: String?) throws -> [ReminderItem] {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders; see T06)"
        )
    }

    func addReminder(
        title: String,
        listName: String?,
        due: String,
        notes: String,
        priority: String
    ) throws -> ReminderCreated {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders; see T06)"
        )
    }

    func completeReminder(title: String, listName: String?) throws -> ReminderDoneResult {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders; see T06)"
        )
    }

    func deleteReminder(title: String, listName: String?) throws -> ReminderDeleted {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders; see T06)"
        )
    }

    func moveReminder(
        title: String,
        fromList: String,
        toList: String
    ) throws -> ReminderMoved {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders; see T06)"
        )
    }

    func editReminder(
        title: String,
        listName: String?,
        due: String,
        priority: String,
        notes: String
    ) throws -> ReminderEdited {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders; see T06)"
        )
    }

    func ensureReminderList(name: String) throws -> ReminderListEnsured {
        throw MacverbsError.system(
            "EventKit client not wired (Calendar, Reminders; see T06)"
        )
    }
}

// MARK: - Process-wide injection point

/// Injectable backends for CLI verbs and doctor.
///
/// CLI entry is single-threaded; tests replace clients serially (same pattern as
/// `CLIOutput.outFile`).
enum BackendClients {
    /// Production: real EventKit wrapper (T06).
    nonisolated(unsafe) static var eventStore: any EventStoreClient = EKEventStoreClient()
    /// Production: real osascript runner (T13).
    nonisolated(unsafe) static var scriptRunner: any ScriptRunner = OSAScriptRunner()

    /// Restore production defaults (call from test teardown when overriding).
    static func resetDefaults() {
        eventStore = EKEventStoreClient()
        scriptRunner = OSAScriptRunner()
    }
}
