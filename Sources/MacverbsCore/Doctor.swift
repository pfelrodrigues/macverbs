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
    /// Human-readable gaps with System Settings hints (empty when fully ready).
    var missing: [String]
    /// Non-blocking advisories (e.g. calendars.json setup). Does not affect `ok`.
    var warnings: [String] = []
}

struct DoctorBackends: Codable, Equatable, Sendable {
    var eventKit: DoctorEventKitBackend
    var appleEvents: DoctorAppleEventsBackend
}

struct DoctorEventKitBackend: Codable, Equatable, Sendable {
    /// Implementation identity (`eventkit` when real; `stub` in tests).
    var kind: String
    var calendar: EventAuthorizationStatus
    var reminders: EventAuthorizationStatus
}

struct DoctorAppleEventsBackend: Codable, Equatable, Sendable {
    /// Implementation identity (`osascript` when real; `stub` in tests).
    var kind: String
    /// Whether a real runner is available (false for stub).
    var wired: Bool
    /// Automation TCC for Mail (Apple Events).
    var mail: AutomationAuthorizationStatus
    /// Automation TCC for Notes (Apple Events).
    var notes: AutomationAuthorizationStatus
}

// MARK: - Probe (pure; injectable clients)

enum Doctor {
    /// Build a report using the given clients. Never prompts for TCC.
    static func probe(
        eventStore: any EventStoreClient = BackendClients.eventStore,
        scriptRunner: any ScriptRunner = BackendClients.scriptRunner,
        automation: any AutomationPermissionClient = BackendClients.automation,
        aliases: CalendarAliases = Config.loadCalendarAliases(),
        version: String = Version.current
    ) -> DoctorReport {
        let calendar = eventStore.authorizationStatus(for: .event)
        let reminders = eventStore.authorizationStatus(for: .reminder)
        let eventKitKind = eventKitKindName(eventStore)
        let scriptKind = scriptRunnerKindName(scriptRunner)
        let scriptWired = !(scriptRunner is StubScriptRunner)

        let mailStatus: AutomationAuthorizationStatus
        let notesStatus: AutomationAuthorizationStatus
        if scriptWired {
            mailStatus = automation.authorizationStatus(for: .mail)
            notesStatus = automation.authorizationStatus(for: .notes)
        } else {
            mailStatus = .unavailable
            notesStatus = .unavailable
        }

        var missing: [String] = []
        if eventStore is StubEventStoreClient
            || calendar == .unavailable
            || reminders == .unavailable
        {
            missing.append(
                "EventKit client not wired (Calendar, Reminders)"
            )
        } else {
            appendEventKitGaps(entity: .event, status: calendar, into: &missing)
            appendEventKitGaps(entity: .reminder, status: reminders, into: &missing)
        }

        if !scriptWired {
            missing.append(
                "ScriptRunner not wired (Mail, Notes via Apple Events)"
            )
        } else {
            appendAutomationGaps(target: .mail, status: mailStatus, into: &missing)
            appendAutomationGaps(target: .notes, status: notesStatus, into: &missing)
        }

        var warnings: [String] = []
        appendCalendarAliasWarnings(
            eventStore: eventStore,
            calendarStatus: calendar,
            aliases: aliases,
            into: &warnings
        )

        let backends = DoctorBackends(
            eventKit: DoctorEventKitBackend(
                kind: eventKitKind,
                calendar: calendar,
                reminders: reminders
            ),
            appleEvents: DoctorAppleEventsBackend(
                kind: scriptKind,
                wired: scriptWired,
                mail: mailStatus,
                notes: notesStatus
            )
        )

        return DoctorReport(
            version: version,
            ok: missing.isEmpty,
            backends: backends,
            missing: missing,
            warnings: warnings
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
            "Apple Events: \(report.backends.appleEvents.kind) (wired=\(report.backends.appleEvents.wired), mail=\(report.backends.appleEvents.mail.rawValue), notes=\(report.backends.appleEvents.notes.rawValue))"
        )
        if report.missing.isEmpty {
            lines.append("ok: nothing missing")
        } else {
            lines.append("missing:")
            for item in report.missing {
                lines.append("  - \(item)")
            }
        }
        if !report.warnings.isEmpty {
            lines.append("warnings:")
            for item in report.warnings {
                lines.append("  - \(item)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Non-blocking calendars.json / duplicate-title advisories.
    private static func appendCalendarAliasWarnings(
        eventStore: any EventStoreClient,
        calendarStatus: EventAuthorizationStatus,
        aliases: CalendarAliases,
        into warnings: inout [String]
    ) {
        guard calendarStatus.allowsFullAccess else {
            return
        }
        let calendars: [EventKitCalendarInfo]
        do {
            calendars = try eventStore.eventCalendars()
        } catch {
            return
        }
        let unaliased = Config.unaliasedDuplicateUIDs(
            calendars: calendars,
            aliases: aliases
        )
        if !unaliased.isEmpty {
            let dupTitles = Config.duplicateTitles(in: calendars).joined(separator: ", ")
            warnings.append(
                "\(unaliased.count) calendar(s) share title(s) [\(dupTitles)] without calendars.json aliases — run: macverbs config calendars init"
            )
        }
    }

    // MARK: Gap messages (actionable System Settings paths)

    private static let automationSettings =
        "System Settings → Privacy & Security → Automation"

    private static func appendEventKitGaps(
        entity: EventEntityType,
        status: EventAuthorizationStatus,
        into missing: inout [String]
    ) {
        let name = entity.displayName
        let settings =
            "System Settings → Privacy & Security → \(entity.privacySettingsPane)"
        switch status {
        case .denied:
            missing.append("\(name) access denied; enable in \(settings)")
        case .restricted:
            missing.append("\(name) access restricted; enable in \(settings)")
        case .writeOnly:
            missing.append(
                "\(name) access is write-only; full access required — enable in \(settings)"
            )
        case .notDetermined:
            missing.append(
                "\(name) access not determined (will prompt on first use); or enable in \(settings)"
            )
        case .unavailable, .fullAccess, .authorized:
            break
        }
    }

    private static func appendAutomationGaps(
        target: AutomationTarget,
        status: AutomationAuthorizationStatus,
        into missing: inout [String]
    ) {
        let name = target.displayName
        switch status {
        case .denied:
            missing.append(
                "\(name) Automation denied; enable \(name) under \(automationSettings)"
            )
        case .notDetermined:
            missing.append(
                "\(name) Automation not determined (will prompt on first use); or enable \(name) under \(automationSettings)"
            )
        case .unavailable:
            missing.append(
                "\(name) Automation status unavailable"
            )
        case .notRunning:
            // Not a proven gap: AE API requires the target process to be running.
            // Report status in backends; re-run doctor with the app open to verify.
            break
        case .authorized:
            break
        }
    }

    private static func eventKitKindName(_ client: any EventStoreClient) -> String {
        if client is StubEventStoreClient {
            return StubEventStoreClient.kind
        }
        if client is EKEventStoreClient {
            return EKEventStoreClient.kind
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
        abstract: "Report environment readiness (no permission prompts).",
        discussion: """
            Reports EventKit and Automation status without prompting.
            Example: macverbs doctor   |   macverbs --json doctor
            """
    )

    func run() throws {
        let report = Doctor.probe()
        try CLIOutput.emit(report, text: Doctor.formatText)
    }
}
