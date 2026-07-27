import ApplicationServices
import Foundation

// MARK: - Apple Events seam (Mail + Notes)

/// Injectable AppleScript / osascript runner.
///
/// Production uses `OSAScriptRunner` (real `/usr/bin/osascript`). Unit tests
/// inject mocks or a fake process launcher; they must never require live
/// Automation TCC.
protocol ScriptRunner: Sendable {
    /// Execute AppleScript source and return stdout.
    ///
    /// - Parameters:
    ///   - script: AppleScript source (not a file path).
    ///   - timeout: Maximum wall time for the run.
    /// - Throws: `MacverbsError` (or other `Error`) on failure.
    func run(script: String, timeout: TimeInterval) throws -> String
}

// MARK: - Automation TCC (Mail / Notes)

/// Targets controlled via Apple Events Automation privacy.
enum AutomationTarget: String, Codable, Sendable, CaseIterable {
    case mail
    case notes

    /// Human label for doctor and System Settings messages.
    var displayName: String {
        switch self {
        case .mail:
            "Mail"
        case .notes:
            "Notes"
        }
    }

    /// Bundle identifier for `AEDeterminePermissionToAutomateTarget`.
    var bundleIdentifier: String {
        switch self {
        case .mail:
            "com.apple.mail"
        case .notes:
            "com.apple.Notes"
        }
    }
}

/// Authorization status for sending Apple Events to Mail / Notes.
///
/// Read without prompting (`askUserIfNeeded: false`). Doctor and tests use this
/// seam so unit checks never require live Automation TCC.
enum AutomationAuthorizationStatus: String, Codable, Sendable {
    /// Sender may automate the target.
    case authorized
    /// User denied Automation for this target.
    case denied
    /// Not yet decided; first real send would prompt (or already would require consent).
    case notDetermined
    /// Target app is not running; AE permission cannot be resolved without launch.
    case notRunning
    /// Checker not wired / stub path.
    case unavailable
}

/// Injectable Automation permission probe (no prompts).
protocol AutomationPermissionClient: Sendable {
    /// Read Automation status for a target **without** prompting the user.
    func authorizationStatus(for target: AutomationTarget) -> AutomationAuthorizationStatus
}

/// Production probe via `AEDeterminePermissionToAutomateTarget` (`askUserIfNeeded: false`).
///
/// The Apple Events API requires the target process to be running. When Mail or
/// Notes is not running, status is `.notRunning` (not a proven denial).
struct AEAutomationPermissionClient: AutomationPermissionClient {
    /// Identity string for doctor / diagnostics.
    static let kind = "ae"

    func authorizationStatus(for target: AutomationTarget) -> AutomationAuthorizationStatus {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: target.bundleIdentifier)
        let status = AEDeterminePermissionToAutomateTarget(
            descriptor.aeDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            false
        )
        switch status {
        case noErr:
            return .authorized
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        case OSStatus(procNotFound):
            return .notRunning
        default:
            // Unexpected OSStatus: treat as not determined so doctor stays non-fatal.
            return .notDetermined
        }
    }
}

/// Test double: fixed statuses; never touches AE / TCC.
struct MockAutomationPermissionClient: AutomationPermissionClient {
    var mail: AutomationAuthorizationStatus
    var notes: AutomationAuthorizationStatus

    init(
        mail: AutomationAuthorizationStatus = .authorized,
        notes: AutomationAuthorizationStatus = .authorized
    ) {
        self.mail = mail
        self.notes = notes
    }

    func authorizationStatus(for target: AutomationTarget) -> AutomationAuthorizationStatus {
        switch target {
        case .mail:
            mail
        case .notes:
            notes
        }
    }
}

/// Pre-wiring / stub: always unavailable.
struct StubAutomationPermissionClient: AutomationPermissionClient {
    func authorizationStatus(for target: AutomationTarget) -> AutomationAuthorizationStatus {
        .unavailable
    }
}

// MARK: - Delimiters + escape + structured parse (oracle: apple.osa)

/// Field / record separators and helpers matching the Python `apple.osa` oracle.
///
/// Scripts emit records delimited by control characters (US/RS) so structured
/// data can be recovered without ambiguous text splitting.
enum AppleScript {
    /// Unit separator (U+001F) between fields inside a record.
    static let fieldSeparator = "\u{001F}"
    /// Record separator (U+001E) between records.
    static let recordSeparator = "\u{001E}"

    /// Escape a string for interpolation inside AppleScript double quotes.
    ///
    /// Order matches the oracle: backslash first, then double quote.
    static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Parse RS/FS-delimited osascript stdout into dictionaries keyed by `fields`.
    ///
    /// Empty / whitespace-only records are dropped. Missing fields pad to `""`.
    /// Field values are stripped of surrounding whitespace.
    static func parseRecords(_ output: String, fields: [String]) -> [[String: String]] {
        guard !fields.isEmpty else {
            return []
        }
        let rawRecords = output.split(
            separator: Character(recordSeparator),
            omittingEmptySubsequences: false
        )
        var result: [[String: String]] = []
        for raw in rawRecords {
            let rec = String(raw)
            if rec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            var parts =
                rec.split(
                    separator: Character(fieldSeparator),
                    omittingEmptySubsequences: false
                )
                .map(String.init)
            if parts.count < fields.count {
                parts.append(
                    contentsOf: Array(repeating: "", count: fields.count - parts.count)
                )
            }
            var row: [String: String] = [:]
            row.reserveCapacity(fields.count)
            for (index, name) in fields.enumerated() {
                row[name] = parts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            result.append(row)
        }
        return result
    }
}

// MARK: - Process result (injectable launch seam)

/// Captured result of launching osascript (or a test double).
struct OsascriptProcessResult: Sendable, Equatable {
    /// Process exit status (`0` = success).
    var exitStatus: Int32
    /// Standard output (raw; not trimmed).
    var stdout: String
    /// Standard error (raw).
    var stderr: String
}

/// Low-level osascript launcher. Injectable so `OSAScriptRunner` unit tests never
/// spawn a real process.
protocol OsascriptProcessLaunching: Sendable {
    /// Run AppleScript source via osascript (or a fake).
    func launch(script: String, timeout: TimeInterval) throws -> OsascriptProcessResult
}

// MARK: - Real /usr/bin/osascript

/// Production launcher: `/usr/bin/osascript -e <script>`.
struct OsascriptProcess: OsascriptProcessLaunching {
    /// Absolute path to the system osascript binary.
    static let defaultExecutablePath = "/usr/bin/osascript"

    /// Absolute path to the system osascript binary (overridable in tests).
    static let executablePath = defaultExecutablePath

    /// Binary used for this launcher instance (default: system osascript).
    var executablePath: String = Self.defaultExecutablePath

    func launch(script: String, timeout: TimeInterval) throws -> OsascriptProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-e", script]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw MacverbsError.system(
                "failed to launch osascript: \(error.localizedDescription)"
            )
        }

        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in
            group.leave()
        }

        let waitResult = group.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            process.terminate()
            // Wait briefly for the process to exit after SIGTERM so pipes drain.
            _ = group.wait(timeout: .now() + 2)
            throw MacverbsError.system(
                "AppleScript timed out after \(Self.formatTimeout(timeout))s"
            )
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        return OsascriptProcessResult(
            exitStatus: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func formatTimeout(_ timeout: TimeInterval) -> String {
        if timeout == floor(timeout) {
            return String(Int(timeout))
        }
        return String(timeout)
    }
}

// MARK: - Real ScriptRunner

/// ScriptRunner backed by osascript. Process launch is injectable for tests.
struct OSAScriptRunner: ScriptRunner {
    /// Identity string for doctor / diagnostics.
    static let kind = "osascript"

    /// Default timeout when callers do not override (oracle: 30s).
    static let defaultTimeout: TimeInterval = 30

    private let process: any OsascriptProcessLaunching

    /// - Parameter process: Launcher (default: real `/usr/bin/osascript`).
    init(process: any OsascriptProcessLaunching = OsascriptProcess()) {
        self.process = process
    }

    func run(script: String, timeout: TimeInterval) throws -> String {
        let result = try process.launch(script: script, timeout: timeout)
        if result.exitStatus != 0 {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacverbsError.system(msg.isEmpty ? "AppleScript failed" : msg)
        }
        return result.stdout
    }
}

// MARK: - Stub (no osascript / no Automation)

/// Pre-wiring / test runner. Refuses to execute; never calls osascript.
struct StubScriptRunner: ScriptRunner {
    /// Identity string for doctor / diagnostics.
    static let kind = "stub"

    func run(script: String, timeout: TimeInterval) throws -> String {
        throw MacverbsError.system(
            "ScriptRunner not wired (Apple Events / osascript pending)"
        )
    }
}
