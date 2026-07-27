import EventKit
import Foundation

// MARK: - Process-wide injection point

/// Injectable backends for CLI verbs and doctor.
///
/// CLI entry is single-threaded; tests replace clients serially (same pattern as
/// `CLIOutput.outFile`).
enum BackendClients {
    /// Production: real EventKit wrapper.
    nonisolated(unsafe) static var eventStore: any EventStoreClient = EKEventStoreClient()
    /// Production: real osascript runner.
    nonisolated(unsafe) static var scriptRunner: any ScriptRunner = OSAScriptRunner()
    /// Production: AE Automation probe for Mail/Notes (no prompts).
    nonisolated(unsafe) static var automation: any AutomationPermissionClient =
        AEAutomationPermissionClient()

    /// Restore production defaults (call from test teardown when overriding).
    static func resetDefaults() {
        eventStore = EKEventStoreClient()
        scriptRunner = OSAScriptRunner()
        automation = AEAutomationPermissionClient()
    }
}
