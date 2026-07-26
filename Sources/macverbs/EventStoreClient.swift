import Foundation

// MARK: - EventKit seam (Calendar + Reminders)

/// Entity types backed by EventKit.
enum EventEntityType: String, Codable, Sendable, CaseIterable {
    case event
    case reminder
}

/// Authorization status for an EventKit entity type.
///
/// Values mirror EventKit's model conceptually. The `unavailable` case is used by
/// the pre-wiring stub so doctor can report honestly without linking EventKit yet.
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
}

/// Injectable EventKit store seam.
///
/// Real `EKEventStore` wrapper lands in T06. Unit tests inject mocks; the stub
/// never imports or calls EventKit (no TCC).
protocol EventStoreClient: Sendable {
    /// Read current authorization **without** prompting for access.
    func authorizationStatus(for entity: EventEntityType) -> EventAuthorizationStatus
}

// MARK: - Stub (no EventKit / no TCC)

/// Default pre-wiring client. Always reports `unavailable`; never touches EventKit.
struct StubEventStoreClient: EventStoreClient {
    /// Identity string for doctor / diagnostics.
    static let kind = "stub"

    func authorizationStatus(for entity: EventEntityType) -> EventAuthorizationStatus {
        .unavailable
    }
}

// MARK: - Process-wide injection point

/// Injectable backends for CLI verbs and doctor.
///
/// CLI entry is single-threaded; tests replace clients serially (same pattern as
/// `CLIOutput.standardOutput`).
enum BackendClients {
    nonisolated(unsafe) static var eventStore: any EventStoreClient = StubEventStoreClient()
    /// Real osascript runner (T13). EventKit remains stub until T06.
    nonisolated(unsafe) static var scriptRunner: any ScriptRunner = OSAScriptRunner()

    /// Restore production defaults (call from test teardown when overriding).
    static func resetDefaults() {
        eventStore = StubEventStoreClient()
        scriptRunner = OSAScriptRunner()
    }
}
