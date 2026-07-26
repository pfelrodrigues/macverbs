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
}

// MARK: - Process-wide injection point

/// Injectable backends for CLI verbs and doctor.
///
/// CLI entry is single-threaded; tests replace clients serially (same pattern as
/// `CLIOutput.standardOutput`).
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
