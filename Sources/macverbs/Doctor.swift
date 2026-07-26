import ArgumentParser
import Foundation

// MARK: - Report model

/// Structured doctor report (JSON + text).
struct DoctorReport: Codable, Equatable, Sendable {
    /// Semantic version of this binary.
    var version: String
    /// True when nothing is listed under `missing`.
    var ok: Bool
    /// Backend readiness snapshot (no TCC prompts).
    var backends: DoctorBackends
    /// Human-readable gaps (empty when fully ready).
    var missing: [String]
}

struct DoctorBackends: Codable, Equatable, Sendable {
    var eventKit: DoctorEventKitBackend
    var appleEvents: DoctorAppleEventsBackend
}

struct DoctorEventKitBackend: Codable, Equatable, Sendable {
    /// Implementation identity (`stub` until T06).
    var kind: String
    var calendar: EventAuthorizationStatus
    var reminders: EventAuthorizationStatus
}

struct DoctorAppleEventsBackend: Codable, Equatable, Sendable {
    /// Implementation identity (`osascript` when real; `stub` in tests).
    var kind: String
    /// Whether a real runner is available (false for stub).
    var wired: Bool
}

// MARK: - Probe (pure; injectable clients)

enum Doctor {
    /// Build a report using the given clients. Never prompts for TCC.
    static func probe(
        eventStore: any EventStoreClient = BackendClients.eventStore,
        scriptRunner: any ScriptRunner = BackendClients.scriptRunner,
        version: String = Version.current
    ) -> DoctorReport {
        let calendar = eventStore.authorizationStatus(for: .event)
        let reminders = eventStore.authorizationStatus(for: .reminder)
        let eventKitKind = eventKitKindName(eventStore)
        let scriptKind = scriptRunnerKindName(scriptRunner)
        let scriptWired = !(scriptRunner is StubScriptRunner)

        var missing: [String] = []
        if eventStore is StubEventStoreClient
            || calendar == .unavailable
            || reminders == .unavailable
        {
            missing.append(
                "EventKit client not wired (Calendar, Reminders; see T06)"
            )
        } else {
            if calendar == .denied || calendar == .restricted {
                missing.append(
                    "Calendar access \(calendar.rawValue); enable in System Settings → Privacy & Security → Calendars"
                )
            } else if calendar == .notDetermined {
                missing.append(
                    "Calendar access not determined (will prompt on first use)"
                )
            }
            if reminders == .denied || reminders == .restricted {
                missing.append(
                    "Reminders access \(reminders.rawValue); enable in System Settings → Privacy & Security → Reminders"
                )
            } else if reminders == .notDetermined {
                missing.append(
                    "Reminders access not determined (will prompt on first use)"
                )
            }
        }

        if !scriptWired {
            missing.append(
                "ScriptRunner not wired (Mail, Notes via Apple Events; see T13)"
            )
        }

        let backends = DoctorBackends(
            eventKit: DoctorEventKitBackend(
                kind: eventKitKind,
                calendar: calendar,
                reminders: reminders
            ),
            appleEvents: DoctorAppleEventsBackend(
                kind: scriptKind,
                wired: scriptWired
            )
        )

        return DoctorReport(
            version: version,
            ok: missing.isEmpty,
            backends: backends,
            missing: missing
        )
    }

    /// Format a human-readable multi-line summary.
    static func formatText(_ report: DoctorReport) -> String {
        var lines: [String] = []
        lines.append("macverbs doctor \(report.version)")
        lines.append(
            "EventKit: \(report.backends.eventKit.kind) (calendar=\(report.backends.eventKit.calendar.rawValue), reminders=\(report.backends.eventKit.reminders.rawValue))"
        )
        lines.append(
            "Apple Events: \(report.backends.appleEvents.kind) (wired=\(report.backends.appleEvents.wired))"
        )
        if report.missing.isEmpty {
            lines.append("ok: nothing missing")
        } else {
            lines.append("missing:")
            for item in report.missing {
                lines.append("  - \(item)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func eventKitKindName(_ client: any EventStoreClient) -> String {
        if client is StubEventStoreClient {
            return StubEventStoreClient.kind
        }
        return String(describing: type(of: client))
    }

    private static func scriptRunnerKindName(_ runner: any ScriptRunner) -> String {
        if runner is StubScriptRunner {
            return StubScriptRunner.kind
        }
        if runner is OSAScriptRunner {
            return OSAScriptRunner.kind
        }
        return String(describing: type(of: runner))
    }
}

// MARK: - CLI

/// Meta command: environment readiness without TCC prompts.
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report environment readiness (no permission prompts)."
    )

    func run() throws {
        let report = Doctor.probe()
        try CLIOutput.emit(report, text: Doctor.formatText)
    }
}
