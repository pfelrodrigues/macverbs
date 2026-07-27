import ArgumentParser
import EventKit
import Foundation
import Testing

@testable import MacverbsCore

// MARK: - Config / paths

@Test func configDirectoryDefaultsUnderHome() {
    let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
    let dir = ConfigPaths.configDirectory(environment: [:], homeDirectory: home)
    #expect(dir.path == "/Users/fixture/.config/macverbs")
}

@Test func configDirectoryHonorsEnvOverride() {
    let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
    let dir = ConfigPaths.configDirectory(
        environment: [ConfigPaths.envConfigDir: "/tmp/mv-config"],
        homeDirectory: home
    )
    #expect(dir.path == "/tmp/mv-config")
}

@Test func configDirectoryExpandsTildeInEnv() {
    let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
    let dir = ConfigPaths.configDirectory(
        environment: [ConfigPaths.envConfigDir: "~/.config/macverbs"],
        homeDirectory: home
    )
    #expect(dir.path == "/Users/fixture/.config/macverbs")
}

@Test func configDirectoryIgnoresBlankEnv() {
    let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
    let dir = ConfigPaths.configDirectory(
        environment: [ConfigPaths.envConfigDir: "   "],
        homeDirectory: home
    )
    #expect(dir.path == "/Users/fixture/.config/macverbs")
}

@Test func calendarsURLAppendsFilename() {
    let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
    let url = ConfigPaths.calendarsURL(environment: [:], homeDirectory: home)
    #expect(url.lastPathComponent == ConfigPaths.calendarsFileName)
    #expect(url.path.hasSuffix("/.config/macverbs/calendars.json"))
}

@Test func loadCalendarAliasesMissingFileIsEmpty() {
    let url = URL(fileURLWithPath: "/tmp/macverbs-no-such-calendars-\(UUID().uuidString).json")
    let aliases = Config.loadCalendarAliases(from: url)
    #expect(aliases == .empty)
    #expect(aliases.labelsByUID.isEmpty)
}

@Test func loadCalendarAliasesValidMap() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macverbs-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("calendars.json")
    let json = """
        {
          "UID-WORK": "Work",
          "UID-PERSONAL": "Personal",
          "UID-ACME": "Acme"
        }
        """
    try json.write(to: url, atomically: true, encoding: .utf8)

    let aliases = Config.loadCalendarAliases(from: url)
    #expect(aliases.labelsByUID["UID-WORK"] == "Work")
    #expect(aliases.labelsByUID["UID-PERSONAL"] == "Personal")
    #expect(aliases.labelsByUID["UID-ACME"] == "Acme")
    #expect(aliases.label(forUID: "UID-WORK", fallback: "Calendário") == "Work")
    #expect(aliases.label(forUID: "unknown", fallback: "Calendário") == "Calendário")
}

@Test func loadCalendarAliasesInvalidJSONIsEmpty() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macverbs-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("calendars.json")
    try "{not valid json".write(to: url, atomically: true, encoding: .utf8)

    #expect(Config.loadCalendarAliases(from: url) == .empty)
}

@Test func loadCalendarAliasesNonObjectRootIsEmpty() throws {
    #expect(Config.decodeCalendarAliases(from: Data("[]".utf8)) == .empty)
    #expect(Config.decodeCalendarAliases(from: Data("\"x\"".utf8)) == .empty)
    #expect(Config.decodeCalendarAliases(from: Data("1".utf8)) == .empty)
}

@Test func loadCalendarAliasesSkipsNonStringValues() throws {
    let data = Data(
        """
        {"UID-OK": "Work", "UID-BAD": 42, "UID-NULL": null}
        """
        .utf8
    )
    let aliases = Config.decodeCalendarAliases(from: data)
    #expect(aliases.labelsByUID == ["UID-OK": "Work"])
}

@Test func exampleCalendarsJSONUsesFixtureLabelsOnly() throws {
    // Repo example must not ship personal account names (Vert, PYO, …).
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/macverbsTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
    let example = root.appendingPathComponent("calendars.example.json")
    #expect(FileManager.default.fileExists(atPath: example.path))

    let data = try Data(contentsOf: example)
    let aliases = Config.decodeCalendarAliases(from: data)
    #expect(!aliases.labelsByUID.isEmpty)
    let labels = Set(aliases.labelsByUID.values)
    #expect(labels.isSubset(of: ["Work", "Personal", "Acme"]))
    let forbidden = ["Vert", "PYO", "Evertec"]
    for name in forbidden {
        #expect(!labels.contains(name))
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(!text.contains(name))
    }
}

// MARK: - doctor

@Test func doctorProbeWithStubsListsMissing() {
    let report = Doctor.probe(
        eventStore: StubEventStoreClient(),
        scriptRunner: StubScriptRunner(),
        automation: StubAutomationPermissionClient(),
        version: Version.current
    )
    #expect(report.ok == false)
    #expect(report.version == Version.current)
    #expect(report.backends.eventKit.kind == "stub")
    #expect(report.backends.eventKit.calendar == .unavailable)
    #expect(report.backends.eventKit.reminders == .unavailable)
    #expect(report.backends.appleEvents.kind == "stub")
    #expect(report.backends.appleEvents.wired == false)
    #expect(report.backends.appleEvents.mail == .unavailable)
    #expect(report.backends.appleEvents.notes == .unavailable)
    #expect(report.missing.contains { $0.contains("EventKit") })
    #expect(report.missing.contains { $0.contains("ScriptRunner") })
}

@Test func doctorProbeWithMocksCanBeOk() {
    let report = Doctor.probe(
        eventStore: MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess
        ),
        scriptRunner: MockScriptRunner(stdout: ""),
        automation: MockAutomationPermissionClient(),
        version: "9.9.9"
    )
    #expect(report.ok == true)
    #expect(report.missing.isEmpty)
    #expect(report.backends.appleEvents.wired == true)
    #expect(report.backends.appleEvents.mail == .authorized)
    #expect(report.backends.appleEvents.notes == .authorized)
    #expect(report.backends.eventKit.calendar == .fullAccess)
}

@Test func doctorProbeReportsDeniedAccessWhenWired() {
    let report = Doctor.probe(
        eventStore: MockEventStoreClient(calendar: .denied, reminders: .restricted),
        scriptRunner: MockScriptRunner(),
        automation: MockAutomationPermissionClient(),
        version: "0.1.0"
    )
    #expect(report.ok == false)
    #expect(report.missing.contains { $0.contains("Calendar") && $0.contains("denied") })
    #expect(
        report.missing.contains { $0.contains("Reminders") && $0.contains("restricted") }
    )
    #expect(report.missing.contains { $0.contains("System Settings") })
}

@Test func doctorProbeReportsWriteOnlyCalendar() {
    let report = Doctor.probe(
        eventStore: MockEventStoreClient(calendar: .writeOnly, reminders: .fullAccess),
        scriptRunner: MockScriptRunner(),
        automation: MockAutomationPermissionClient(),
        version: "0.1.0"
    )
    #expect(report.ok == false)
    #expect(
        report.missing.contains {
            $0.contains("Calendar") && $0.contains("write-only") && $0.contains("System Settings")
        }
    )
}

@Test func doctorProbeReportsAutomationDeniedAndNotDetermined() {
    let report = Doctor.probe(
        eventStore: MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess
        ),
        scriptRunner: MockScriptRunner(),
        automation: MockAutomationPermissionClient(mail: .denied, notes: .notDetermined),
        version: "0.1.0"
    )
    #expect(report.ok == false)
    #expect(report.backends.appleEvents.mail == .denied)
    #expect(report.backends.appleEvents.notes == .notDetermined)
    #expect(
        report.missing.contains {
            $0.contains("Mail") && $0.contains("denied") && $0.contains("Automation")
        }
    )
    #expect(
        report.missing.contains {
            $0.contains("Notes") && $0.contains("not determined") && $0.contains("Automation")
        }
    )
    #expect(report.missing.contains { $0.contains("System Settings") })
}

@Test func doctorProbeAutomationNotRunningIsNotMissing() {
    let report = Doctor.probe(
        eventStore: MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess
        ),
        scriptRunner: MockScriptRunner(),
        automation: MockAutomationPermissionClient(mail: .notRunning, notes: .notRunning),
        version: "0.1.0"
    )
    #expect(report.ok == true)
    #expect(report.missing.isEmpty)
    #expect(report.backends.appleEvents.mail == .notRunning)
    #expect(report.backends.appleEvents.notes == .notRunning)
}

@Test func doctorFormatTextIncludesMissingBullets() {
    let report = Doctor.probe(
        eventStore: StubEventStoreClient(),
        scriptRunner: StubScriptRunner(),
        automation: StubAutomationPermissionClient()
    )
    let text = Doctor.formatText(report)
    #expect(text.contains("macverbs doctor"))
    #expect(text.contains("EventKit: stub"))
    #expect(text.contains("mail=unavailable"))
    #expect(text.contains("notes=unavailable"))
    #expect(text.contains("missing:"))
    #expect(text.contains("EventKit client not wired"))
}

@Test func doctorCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        // Inject mocks so host TCC does not make this test flaky.
        // Holds BackendClients lock via withRedirectedStdio (shared global lock).
        BackendClients.eventStore = MockEventStoreClient(
            calendar: .notDetermined,
            reminders: .notDetermined
        )
        BackendClients.scriptRunner = OSAScriptRunner(process: RecordingOsascriptProcess())
        BackendClients.automation = MockAutomationPermissionClient(
            mail: .denied,
            notes: .notDetermined
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["--json", "doctor"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["ok"] as? Bool == false)
        #expect(obj?["version"] as? String == Version.current)
        let missing = obj?["missing"] as? [String]
        #expect(missing?.isEmpty == false)
        #expect(missing?.contains { $0.contains("Calendar") } == true)
        #expect(missing?.contains { $0.contains("Mail") && $0.contains("Automation") } == true)
        #expect(missing?.contains { $0.contains("System Settings") } == true)
        let backends = obj?["backends"] as? [String: Any]
        let eventKit = backends?["eventKit"] as? [String: Any]
        #expect(eventKit?["calendar"] as? String == "notDetermined")
        let appleEvents = backends?["appleEvents"] as? [String: Any]
        #expect(appleEvents?["kind"] as? String == OSAScriptRunner.kind)
        #expect(appleEvents?["wired"] as? Bool == true)
        #expect(appleEvents?["mail"] as? String == "denied")
        #expect(appleEvents?["notes"] as? String == "notDetermined")
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func doctorCommandTextOnStdout() throws {
    try withRedirectedStdio { pipes in
        BackendClients.eventStore = MockEventStoreClient(
            calendar: .denied,
            reminders: .denied
        )
        BackendClients.scriptRunner = OSAScriptRunner(process: RecordingOsascriptProcess())
        BackendClients.automation = MockAutomationPermissionClient(
            mail: .denied,
            notes: .denied
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["doctor"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("macverbs doctor"))
        #expect(text.contains("missing:"))
        #expect(text.contains("Calendar"))
        #expect(text.contains("Mail"))
        #expect(text.contains("System Settings"))
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func doctorCommandWithProductionEventKitKind() throws {
    try withRedirectedStdio { pipes in
        BackendClients.eventStore = EKEventStoreClient(
            backing: FakeEventKitBacking(calendar: .fullAccess, reminders: .fullAccess)
        )
        BackendClients.scriptRunner = OSAScriptRunner(process: RecordingOsascriptProcess())
        BackendClients.automation = MockAutomationPermissionClient()
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["--json", "doctor"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["ok"] as? Bool == true)
        let backends = obj?["backends"] as? [String: Any]
        let eventKit = backends?["eventKit"] as? [String: Any]
        #expect(eventKit?["kind"] as? String == EKEventStoreClient.kind)
        let appleEvents = backends?["appleEvents"] as? [String: Any]
        #expect(appleEvents?["mail"] as? String == "authorized")
        #expect(appleEvents?["notes"] as? String == "authorized")
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func doctorHelpListsCommand() {
    let help = Macverbs.helpMessage()
    #expect(help.contains("doctor"))
}

@Test func mockAutomationPermissionClientIsInjectable() {
    let mock = MockAutomationPermissionClient(mail: .denied, notes: .notRunning)
    #expect(mock.authorizationStatus(for: .mail) == .denied)
    #expect(mock.authorizationStatus(for: .notes) == .notRunning)
}

// MARK: - Shell completions

@Test func generateCompletionScriptFishCoversDomains() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.run(arguments: ["--generate-completion-script", "fish"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("complete -c 'macverbs'"))
        for domain in ["calendar", "reminders", "mail", "notes", "doctor"] {
            #expect(text.contains(domain), "fish script missing domain \(domain)")
        }
        for flag in ["json", "mailbox", "priority"] {
            #expect(text.contains(flag), "fish script missing \(flag)")
        }
        #expect(text.contains("high medium low"))
        #expect(text.contains("inbox archive"))
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func generateCompletionScriptZshCoversDomains() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.run(arguments: ["--generate-completion-script", "zsh"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("#compdef macverbs"))
        for domain in ["calendar", "reminders", "mail", "notes", "doctor"] {
            #expect(text.contains(domain), "zsh script missing domain \(domain)")
        }
        #expect(text.contains("json"))
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func generateCompletionScriptBashCoversDomains() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.run(arguments: ["--generate-completion-script", "bash"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("_macverbs") || text.contains("macverbs"))
        for domain in ["calendar", "reminders", "mail", "notes", "doctor"] {
            #expect(text.contains(domain), "bash script missing domain \(domain)")
        }
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func generateCompletionScriptRejectsUnknownShell() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.run(arguments: ["--generate-completion-script", "power"])
        // ArgumentParser treats unknown shell as a message (still success path text
        // or usage); either way stderr/stdout must mention valid shells.
        let out = try pipes.readOutput()
        let err = try pipes.readError()
        let combined = out + err
        #expect(combined.contains("fish") || combined.contains("zsh") || combined.contains("bash"))
        #expect(code == ExitCodes.success || code == ExitCodes.usage)
    }
}
