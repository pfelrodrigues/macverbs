import Foundation

// MARK: - Apple Events seam (Mail + Notes)

/// Injectable AppleScript / osascript runner.
///
/// Real implementation lands in T13. Unit tests inject mocks; the stub never
/// launches `osascript` or touches Automation TCC.
protocol ScriptRunner: Sendable {
    /// Execute AppleScript source and return stdout.
    ///
    /// - Parameters:
    ///   - script: AppleScript source (not a file path).
    ///   - timeout: Maximum wall time for the run.
    /// - Throws: `MacverbsError` (or other `Error`) on failure.
    func run(script: String, timeout: TimeInterval) throws -> String
}

// MARK: - Stub (no osascript / no Automation)

/// Default pre-wiring runner. Refuses to execute; never calls osascript.
struct StubScriptRunner: ScriptRunner {
    /// Identity string for doctor / diagnostics.
    static let kind = "stub"

    func run(script: String, timeout: TimeInterval) throws -> String {
        throw MacverbsError.system(
            "ScriptRunner not wired (Apple Events / osascript pending)"
        )
    }
}
