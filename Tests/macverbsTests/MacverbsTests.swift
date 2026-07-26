import EventKit
import Foundation
import Testing

@testable import macverbs

@Test func versionStringIsSemver() {
    let parts = Version.current.split(separator: ".")
    #expect(parts.count >= 2)
    #expect(parts.allSatisfy { Int($0) != nil })
}

// MARK: - Global --json (before subcommand)

@Test func peelJsonFlagBeforeSubcommand() {
    var argv = ["--json", "calendar", "list"]
    let json = GlobalFlags.peelLeading(&argv)
    #expect(json == true)
    #expect(argv == ["calendar", "list"])
}

@Test func peelJsonAbsentLeavesArgv() {
    var argv = ["calendar", "list", "--days", "3"]
    let json = GlobalFlags.peelLeading(&argv)
    #expect(json == false)
    #expect(argv == ["calendar", "list", "--days", "3"])
}

@Test func peelOnlyLeadingJson() {
    // Non-leading `--json` is left for domain OptionGroups (future tasks).
    var argv = ["calendar", "--json", "list"]
    let json = GlobalFlags.peelLeading(&argv)
    #expect(json == false)
    #expect(argv == ["calendar", "--json", "list"])
}

@Test func rootHelpMentionsJsonFlag() {
    let help = Macverbs.helpMessage()
    #expect(help.contains("--json"))
}

@Test func runWithLeadingJsonStillSucceedsBare() throws {
    // Bare + --json prints help and exits 0 (no domain verb yet).
    try withRedirectedStdio { _ in
        let code = MacverbsApp.run(arguments: ["--json"])
        #expect(code == ExitCodes.success)
    }
}

// MARK: - Exit codes

@Test func domainAndSystemExitCodes() {
    #expect(MacverbsError.domain("not found").processExitCode == ExitCodes.domain)
    #expect(MacverbsError.system("backend down").processExitCode == ExitCodes.system)
    #expect(ExitCodes.success == 0)
    #expect(ExitCodes.domain == 1)
    #expect(ExitCodes.system == 2)
    #expect(ExitCodes.usage == 64)
}

@Test func usageErrorReturns64() throws {
    // Parser failures write usage text via CLIOutput.standardError; redirect so
    // parallel tests that capture stdio do not race on the shared handles.
    try withRedirectedStdio { _ in
        let code = MacverbsApp.run(arguments: ["--not-a-real-flag"])
        #expect(code == ExitCodes.usage)
    }
}

@Test func unexpectedArgumentReturns64() throws {
    try withRedirectedStdio { _ in
        let code = MacverbsApp.run(arguments: ["bogus-domain"])
        #expect(code == ExitCodes.usage)
    }
}

@Test func helpReturns0() throws {
    // Help uses process stdout via ArgumentParser; still serialize against other
    // MacverbsApp.run calls that share CLIOutput handles.
    try withRedirectedStdio { _ in
        let code = MacverbsApp.run(arguments: ["--help"])
        #expect(code == ExitCodes.success)
    }
}

@Test func versionReturns0() throws {
    try withRedirectedStdio { _ in
        let code = MacverbsApp.run(arguments: ["--version"])
        #expect(code == ExitCodes.success)
    }
}

@Test func domainErrorThroughAppReturns1AndStderr() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.runCatching {
            throw MacverbsError.domain("list Work not found")
        }
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("error: list Work not found"))
        let out = try pipes.readOutput()
        #expect(out.isEmpty)
    }
}

@Test func systemErrorThroughAppReturns2AndStderr() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.runCatching {
            throw MacverbsError.system("EventKit unavailable")
        }
        #expect(code == ExitCodes.system)
        let err = try pipes.readError()
        #expect(err.contains("error: EventKit unavailable"))
        #expect(try pipes.readOutput().isEmpty)
    }
}

// MARK: - JSON emit

private struct SamplePayload: Codable, Equatable {
    var name: String
    var count: Int
}

@Test func writeJSONProducesObjectWithStableKeys() throws {
    try withRedirectedStdio { pipes in
        let value = SamplePayload(name: "Work", count: 2)
        try CLIOutput.writeJSON(value)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["name"] as? String == "Work")
        #expect(obj?["count"] as? Int == 2)
        if let countRange = text.range(of: "\"count\""),
            let nameRange = text.range(of: "\"name\"")
        {
            #expect(countRange.lowerBound < nameRange.lowerBound)
        } else {
            Issue.record("expected count and name keys in JSON")
        }
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func emitUsesJsonContextOnStdout() throws {
    try withRedirectedStdio { pipes in
        let value = SamplePayload(name: "Acme", count: 1)
        try CLIContext.$jsonOutput.withValue(true) {
            try CLIOutput.emit(value) { "\($0.name):\($0.count)" }
        }
        let text = try pipes.readOutput()
        #expect(text.contains("\"name\""))
        #expect(text.contains("Acme"))
        #expect(!text.contains("Acme:1"))
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func emitTextModeOnStdout() throws {
    try withRedirectedStdio { pipes in
        let value = SamplePayload(name: "Acme", count: 1)
        try CLIContext.$jsonOutput.withValue(false) {
            try CLIOutput.emit(value) { "\($0.name):\($0.count)" }
        }
        #expect(try pipes.readOutput().contains("Acme:1"))
        #expect(try pipes.readError().isEmpty)
    }
}

// MARK: - Seams (EventStoreClient + ScriptRunner)

/// Test double for EventKit; never links EventKit / never prompts TCC.
struct MockEventStoreClient: EventStoreClient {
    var calendar: EventAuthorizationStatus = .notDetermined
    var reminders: EventAuthorizationStatus = .notDetermined
    /// Returned by `requestAccess` when current status is `.notDetermined`.
    var afterRequestCalendar: EventAuthorizationStatus = .denied
    var afterRequestReminders: EventAuthorizationStatus = .denied
    /// Optional system failure from `requestAccess`.
    var requestError: Error?

    func authorizationStatus(for entity: EventEntityType) -> EventAuthorizationStatus {
        switch entity {
        case .event:
            calendar
        case .reminder:
            reminders
        }
    }

    func requestAccess(for entity: EventEntityType) throws -> EventAuthorizationStatus {
        if let requestError {
            throw requestError
        }
        let current = authorizationStatus(for: entity)
        if current != .notDetermined {
            return current
        }
        switch entity {
        case .event:
            return afterRequestCalendar
        case .reminder:
            return afterRequestReminders
        }
    }
}

/// Fake EventKit surface for `EKEventStoreClient` unit tests (no live store).
final class FakeEventKitBacking: EventKitBacking, @unchecked Sendable {
    var statuses: [EventEntityType: EventAuthorizationStatus]
    var grantOnRequest: Bool
    var requestError: Error?
    private(set) var requestCalls: [EventEntityType] = []

    init(
        calendar: EventAuthorizationStatus = .notDetermined,
        reminders: EventAuthorizationStatus = .notDetermined,
        grantOnRequest: Bool = false,
        requestError: Error? = nil
    ) {
        self.statuses = [.event: calendar, .reminder: reminders]
        self.grantOnRequest = grantOnRequest
        self.requestError = requestError
    }

    func authorizationStatus(for entity: EventEntityType) -> EventAuthorizationStatus {
        statuses[entity] ?? .notDetermined
    }

    func requestFullAccess(for entity: EventEntityType) throws -> Bool {
        requestCalls.append(entity)
        if let requestError {
            throw requestError
        }
        if grantOnRequest {
            statuses[entity] = .fullAccess
        } else {
            statuses[entity] = .denied
        }
        return grantOnRequest
    }
}

/// Test double for Apple Events; never runs osascript.
struct MockScriptRunner: ScriptRunner {
    var stdout: String = ""
    var error: Error?

    func run(script: String, timeout: TimeInterval) throws -> String {
        if let error {
            throw error
        }
        return stdout
    }
}

/// Fake osascript process so `OSAScriptRunner` unit tests never spawn a live process.
final class RecordingOsascriptProcess: OsascriptProcessLaunching, @unchecked Sendable {
    var result: OsascriptProcessResult = OsascriptProcessResult(
        exitStatus: 0,
        stdout: "",
        stderr: ""
    )
    var error: Error?
    private(set) var scripts: [String] = []
    private(set) var timeouts: [TimeInterval] = []

    func launch(script: String, timeout: TimeInterval) throws -> OsascriptProcessResult {
        scripts.append(script)
        timeouts.append(timeout)
        if let error {
            throw error
        }
        return result
    }
}

@Test func mockEventStoreIsInjectable() {
    let mock = MockEventStoreClient(calendar: .denied, reminders: .authorized)
    #expect(mock.authorizationStatus(for: .event) == .denied)
    #expect(mock.authorizationStatus(for: .reminder) == .authorized)
}

@Test func stubEventStoreNeverClaimsAccess() {
    let stub = StubEventStoreClient()
    for entity in EventEntityType.allCases {
        #expect(stub.authorizationStatus(for: entity) == .unavailable)
    }
}

@Test func stubEventStoreRequestAccessThrowsSystem() {
    let stub = StubEventStoreClient()
    #expect(throws: MacverbsError.self) {
        try stub.requestAccess(for: .event)
    }
    do {
        _ = try stub.requestAccess(for: .reminder)
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .system("EventKit client not wired (Calendar, Reminders; see T06)"))
        #expect(error.processExitCode == ExitCodes.system)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func ensureAccessThrowsDomainWhenDenied() {
    let mock = MockEventStoreClient(calendar: .denied, reminders: .restricted)
    do {
        try mock.ensureAccess(for: .event)
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error.processExitCode == ExitCodes.domain)
        #expect(error.message.contains("Calendar access denied"))
        #expect(error.message.contains("System Settings"))
        #expect(error.message.contains("Calendars"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
    do {
        try mock.ensureAccess(for: .reminder)
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error.message.contains("Reminders access restricted"))
        #expect(error.message.contains("Reminders"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func ensureAccessThrowsDomainWhenWriteOnly() {
    let mock = MockEventStoreClient(calendar: .writeOnly, reminders: .writeOnly)
    do {
        try mock.ensureAccess(for: .event)
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .domain(EventStoreAccess.errorMessage(for: .event, status: .writeOnly)))
        #expect(error.message.contains("write-only"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func ensureAccessSucceedsWithFullAccess() throws {
    let mock = MockEventStoreClient(calendar: .fullAccess, reminders: .authorized)
    try mock.ensureAccess(for: .event)
    try mock.ensureAccess(for: .reminder)
}

@Test func ensureAccessRequestsWhenNotDeterminedThenDenies() {
    let mock = MockEventStoreClient(
        calendar: .notDetermined,
        reminders: .notDetermined,
        afterRequestCalendar: .denied,
        afterRequestReminders: .denied
    )
    do {
        try mock.ensureAccess(for: .event)
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error.processExitCode == ExitCodes.domain)
        #expect(error.message.contains("Calendar access denied"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func ensureAccessRequestsWhenNotDeterminedThenGrants() throws {
    let mock = MockEventStoreClient(
        calendar: .notDetermined,
        reminders: .notDetermined,
        afterRequestCalendar: .fullAccess,
        afterRequestReminders: .fullAccess
    )
    try mock.ensureAccess(for: .event)
    try mock.ensureAccess(for: .reminder)
}

@Test func eventStoreAccessErrorMessagesAreActionable() {
    let denied = EventStoreAccess.errorMessage(for: .event, status: .denied)
    #expect(denied.contains("Calendar access denied"))
    #expect(denied.contains("System Settings → Privacy & Security → Calendars"))

    let restricted = EventStoreAccess.errorMessage(for: .reminder, status: .restricted)
    #expect(restricted.contains("Reminders access restricted"))
    #expect(restricted.contains("Privacy & Security → Reminders"))
}

@Test func ekEventStoreClientMapsViaFakeBacking() throws {
    let fake = FakeEventKitBacking(calendar: .fullAccess, reminders: .denied)
    let client = EKEventStoreClient(backing: fake)
    #expect(client.authorizationStatus(for: .event) == .fullAccess)
    #expect(client.authorizationStatus(for: .reminder) == .denied)
    #expect(client.eventStore == nil)

    // Already determined: requestAccess does not call backing request.
    #expect(try client.requestAccess(for: .event) == .fullAccess)
    #expect(fake.requestCalls.isEmpty)

    do {
        try client.ensureAccess(for: .reminder)
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error.message.contains("Reminders access denied"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func ekEventStoreClientRequestAccessPromptsOnce() throws {
    let fake = FakeEventKitBacking(
        calendar: .notDetermined,
        reminders: .notDetermined,
        grantOnRequest: true
    )
    let client = EKEventStoreClient(backing: fake)
    #expect(try client.requestAccess(for: .event) == .fullAccess)
    #expect(fake.requestCalls == [.event])
    #expect(client.authorizationStatus(for: .event) == .fullAccess)

    // Second call: already determined, no second prompt.
    #expect(try client.requestAccess(for: .event) == .fullAccess)
    #expect(fake.requestCalls == [.event])
}

@Test func ekEventStoreClientRequestAccessPropagatesSystemError() {
    let fake = FakeEventKitBacking(
        calendar: .notDetermined,
        requestError: MacverbsError.system("EventKit access request failed: boom")
    )
    let client = EKEventStoreClient(backing: fake)
    do {
        _ = try client.requestAccess(for: .event)
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .system("EventKit access request failed: boom"))
        #expect(error.processExitCode == ExitCodes.system)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func liveEventKitBackingMapsAuthorizationStatuses() {
    #expect(LiveEventKitBacking.map(.notDetermined) == .notDetermined)
    #expect(LiveEventKitBacking.map(.restricted) == .restricted)
    #expect(LiveEventKitBacking.map(.denied) == .denied)
    #expect(LiveEventKitBacking.map(.fullAccess) == .fullAccess)
    #expect(LiveEventKitBacking.map(.writeOnly) == .writeOnly)
}

@Test func doctorReportsEventKitKindWhenWired() {
    let report = Doctor.probe(
        eventStore: EKEventStoreClient(
            backing: FakeEventKitBacking(calendar: .fullAccess, reminders: .fullAccess)
        ),
        scriptRunner: MockScriptRunner(),
        version: "0.1.0"
    )
    #expect(report.backends.eventKit.kind == EKEventStoreClient.kind)
    #expect(report.backends.eventKit.calendar == .fullAccess)
    #expect(report.backends.eventKit.reminders == .fullAccess)
    #expect(report.ok == true)
    #expect(report.missing.isEmpty)
}

@Test func domainErrorThroughAppForDeniedCalendar() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.runCatching {
            try MockEventStoreClient(calendar: .denied).ensureAccess(for: .event)
        }
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("error: Calendar access denied"))
        #expect(err.contains("System Settings"))
        #expect(try pipes.readOutput().isEmpty)
    }
}

@Test func mockScriptRunnerReturnsCannedOutput() throws {
    let mock = MockScriptRunner(stdout: "Work\(UnicodeScalar(0x1F)!)")
    #expect(try mock.run(script: "return 1", timeout: 1) == "Work\u{1F}")
}

@Test func stubScriptRunnerRefusesWithoutOsascript() {
    let stub = StubScriptRunner()
    #expect(throws: MacverbsError.self) {
        try stub.run(script: "return 1", timeout: 1)
    }
}

@Test func backendClientsDefaultsWireEventKitAndOsascript() throws {
    try withBackendClientsLock {
        BackendClients.resetDefaults()
        #expect(BackendClients.eventStore is EKEventStoreClient)
        #expect(BackendClients.scriptRunner is OSAScriptRunner)
    }
}

@Test func backendClientsAcceptMocks() throws {
    try withBackendClientsLock {
        BackendClients.resetDefaults()
        defer { BackendClients.resetDefaults() }

        BackendClients.eventStore = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess
        )
        BackendClients.scriptRunner = MockScriptRunner(stdout: "ok")

        #expect(
            BackendClients.eventStore.authorizationStatus(for: .event) == .fullAccess
        )
        let out = try BackendClients.scriptRunner.run(script: "x", timeout: 1)
        #expect(out == "ok")
    }
}

// MARK: - AppleScript escape + parseRecords (oracle parity)

@Test func appleScriptEscapeBackslashAndQuote() {
    #expect(AppleScript.escape(#"a\b"c"#) == #"a\\b\"c"#)
}

@Test func appleScriptEscapePlainStringUnchanged() {
    #expect(AppleScript.escape("Work") == "Work")
    #expect(AppleScript.escape("") == "")
}

@Test func parseRecordsEmptyInput() {
    #expect(AppleScript.parseRecords("", fields: ["a"]).isEmpty)
    #expect(
        AppleScript.parseRecords(
            AppleScript.recordSeparator + "\n",
            fields: ["a"]
        )
        .isEmpty
    )
}

@Test func parseRecordsMulti() {
    let fs = AppleScript.fieldSeparator
    let rs = AppleScript.recordSeparator
    let out = "x\(fs)1\(rs)y\(fs)2\(rs)"
    let rows = AppleScript.parseRecords(out, fields: ["name", "n"])
    #expect(rows.count == 2)
    #expect(rows[0]["name"] == "x")
    #expect(rows[0]["n"] == "1")
    #expect(rows[1]["name"] == "y")
    #expect(rows[1]["n"] == "2")
}

@Test func parseRecordsPadsAndStrips() {
    // Single field only; remaining keys pad to empty after strip.
    let out = " x \(AppleScript.recordSeparator)"
    let rows = AppleScript.parseRecords(out, fields: ["a", "b"])
    #expect(rows.count == 1)
    #expect(rows[0]["a"] == "x")
    #expect(rows[0]["b"] == "")
}

@Test func parseRecordsEmptyFieldsList() {
    #expect(AppleScript.parseRecords("x", fields: []).isEmpty)
}

// MARK: - OSAScriptRunner with fake process (no live osascript)

@Test func osaScriptRunnerReturnsStdoutOnSuccess() throws {
    let fake = RecordingOsascriptProcess()
    fake.result = OsascriptProcessResult(exitStatus: 0, stdout: "saida", stderr: "")
    let runner = OSAScriptRunner(process: fake)
    #expect(try runner.run(script: "return 1", timeout: 5) == "saida")
    #expect(fake.scripts == ["return 1"])
    #expect(fake.timeouts == [5])
}

@Test func osaScriptRunnerThrowsSystemOnNonZeroWithStderr() {
    let fake = RecordingOsascriptProcess()
    fake.result = OsascriptProcessResult(exitStatus: 1, stdout: "", stderr: "boom\n")
    let runner = OSAScriptRunner(process: fake)
    #expect(throws: MacverbsError.self) {
        try runner.run(script: "s", timeout: 1)
    }
    do {
        _ = try runner.run(script: "s", timeout: 1)
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .system("boom"))
        #expect(error.processExitCode == ExitCodes.system)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func osaScriptRunnerThrowsGenericMessageWhenStderrEmpty() {
    let fake = RecordingOsascriptProcess()
    fake.result = OsascriptProcessResult(exitStatus: 1, stdout: "", stderr: "  \n")
    let runner = OSAScriptRunner(process: fake)
    do {
        _ = try runner.run(script: "s", timeout: 1)
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .system("AppleScript failed"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func osaScriptRunnerPropagatesLaunchErrors() {
    let fake = RecordingOsascriptProcess()
    fake.error = MacverbsError.system("failed to launch osascript: noent")
    let runner = OSAScriptRunner(process: fake)
    do {
        _ = try runner.run(script: "s", timeout: 1)
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .system("failed to launch osascript: noent"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func doctorReportsOsascriptKindWhenWired() {
    let report = Doctor.probe(
        eventStore: StubEventStoreClient(),
        scriptRunner: OSAScriptRunner(process: RecordingOsascriptProcess()),
        version: "0.1.0"
    )
    #expect(report.backends.appleEvents.kind == OSAScriptRunner.kind)
    #expect(report.backends.appleEvents.wired == true)
    #expect(!report.missing.contains { $0.contains("ScriptRunner") })
}

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
        version: "0.1.0"
    )
    #expect(report.ok == false)
    #expect(report.version == "0.1.0")
    #expect(report.backends.eventKit.kind == "stub")
    #expect(report.backends.eventKit.calendar == .unavailable)
    #expect(report.backends.eventKit.reminders == .unavailable)
    #expect(report.backends.appleEvents.kind == "stub")
    #expect(report.backends.appleEvents.wired == false)
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
        version: "9.9.9"
    )
    #expect(report.ok == true)
    #expect(report.missing.isEmpty)
    #expect(report.backends.appleEvents.wired == true)
    #expect(report.backends.eventKit.calendar == .fullAccess)
}

@Test func doctorProbeReportsDeniedAccessWhenWired() {
    let report = Doctor.probe(
        eventStore: MockEventStoreClient(calendar: .denied, reminders: .restricted),
        scriptRunner: MockScriptRunner(),
        version: "0.1.0"
    )
    #expect(report.ok == false)
    #expect(report.missing.contains { $0.contains("Calendar") && $0.contains("denied") })
    #expect(
        report.missing.contains { $0.contains("Reminders") && $0.contains("restricted") }
    )
}

@Test func doctorFormatTextIncludesMissingBullets() {
    let report = Doctor.probe(
        eventStore: StubEventStoreClient(),
        scriptRunner: StubScriptRunner()
    )
    let text = Doctor.formatText(report)
    #expect(text.contains("macverbs doctor"))
    #expect(text.contains("EventKit: stub"))
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
        let backends = obj?["backends"] as? [String: Any]
        let eventKit = backends?["eventKit"] as? [String: Any]
        #expect(eventKit?["calendar"] as? String == "notDetermined")
        let appleEvents = backends?["appleEvents"] as? [String: Any]
        #expect(appleEvents?["kind"] as? String == OSAScriptRunner.kind)
        #expect(appleEvents?["wired"] as? Bool == true)
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
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["doctor"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("macverbs doctor"))
        #expect(text.contains("missing:"))
        #expect(text.contains("Calendar"))
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func doctorCommandWithProductionEventKitKind() throws {
    try withRedirectedStdio { pipes in
        BackendClients.eventStore = EKEventStoreClient(
            backing: FakeEventKitBacking(calendar: .fullAccess, reminders: .fullAccess)
        )
        BackendClients.scriptRunner = OSAScriptRunner(process: RecordingOsascriptProcess())
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
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func doctorHelpListsCommand() {
    let help = Macverbs.helpMessage()
    #expect(help.contains("doctor"))
}

// MARK: - Mail accounts + unread (T14)

@Test func mailScriptsAccountsContainsOracleMarkers() {
    let s = MailScripts.accounts()
    #expect(s.contains("tell application \"Mail\""))
    #expect(s.contains("repeat with acct in accounts"))
    #expect(s.contains("account type of acct"))
    #expect(s.contains("email addresses of acct"))
    #expect(s.contains("character id 31"))
    #expect(s.contains("character id 30"))
}

@Test func mailScriptsUnreadContainsOracleMarkers() {
    let s = MailScripts.unread()
    #expect(s.contains("tell application \"Mail\""))
    #expect(s.contains("repeat with acct in accounts"))
    #expect(s.contains("unread count of mb"))
    #expect(s.contains("if u > 0 then"))
}

@Test func mailAccountsParsesRecords() throws {
    let fs = AppleScript.fieldSeparator
    let rs = AppleScript.recordSeparator
    let out = "Work\(fs)imap\(fs)a@x.com\(rs)Personal\(fs)exchange\(fs)b@y.com\(rs)"
    let items = try Mail.accounts(runner: MockScriptRunner(stdout: out))
    #expect(
        items == [
            MailAccount(name: "Work", type: "imap", email: "a@x.com"),
            MailAccount(name: "Personal", type: "exchange", email: "b@y.com"),
        ]
    )
}

@Test func mailAccountsEmptyOutput() throws {
    let items = try Mail.accounts(runner: MockScriptRunner(stdout: ""))
    #expect(items.isEmpty)
}

@Test func mailAccountsPropagatesSystemError() {
    let runner = MockScriptRunner(error: MacverbsError.system("AppleScript failed"))
    do {
        _ = try Mail.accounts(runner: runner)
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .system("AppleScript failed"))
        #expect(error.processExitCode == ExitCodes.system)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func mailUnreadParsesIntCounts() throws {
    let fs = AppleScript.fieldSeparator
    let rs = AppleScript.recordSeparator
    let out = "Work\(fs)5\(rs)Personal\(fs)2\(rs)"
    let items = try Mail.unread(runner: MockScriptRunner(stdout: out))
    #expect(
        items == [
            MailUnreadCount(account: "Work", unread: 5),
            MailUnreadCount(account: "Personal", unread: 2),
        ]
    )
}

@Test func mailUnreadEmptyAndBadCount() throws {
    #expect(try Mail.unread(runner: MockScriptRunner(stdout: "")).isEmpty)
    let fs = AppleScript.fieldSeparator
    let rs = AppleScript.recordSeparator
    let items = try Mail.unread(runner: MockScriptRunner(stdout: "Acme\(fs)\(rs)"))
    #expect(items == [MailUnreadCount(account: "Acme", unread: 0)])
}

@Test func mailFormatAccountsText() {
    #expect(Mail.formatAccounts([]) == "no accounts.")
    let text = Mail.formatAccounts([
        MailAccount(name: "Work", type: "imap", email: "a@x.com")
    ])
    #expect(text == "- Work | imap | a@x.com")
}

@Test func mailFormatUnreadText() {
    #expect(Mail.formatUnread([]) == "no unread.")
    let text = Mail.formatUnread([MailUnreadCount(account: "Work", unread: 3)])
    #expect(text == "- Work: 3 unread")
}

@Test func mailAccountsCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        let fs = AppleScript.fieldSeparator
        let rs = AppleScript.recordSeparator
        BackendClients.scriptRunner = MockScriptRunner(
            stdout: "Work\(fs)imap\(fs)user@example.com\(rs)"
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["--json", "mail", "accounts"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(arr?.count == 1)
        #expect(arr?[0]["name"] as? String == "Work")
        #expect(arr?[0]["type"] as? String == "imap")
        #expect(arr?[0]["email"] as? String == "user@example.com")
        // Sorted keys: email before name before type.
        if let emailRange = text.range(of: "\"email\""),
            let nameRange = text.range(of: "\"name\""),
            let typeRange = text.range(of: "\"type\"")
        {
            #expect(emailRange.lowerBound < nameRange.lowerBound)
            #expect(nameRange.lowerBound < typeRange.lowerBound)
        } else {
            Issue.record("expected email/name/type keys")
        }
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func mailUnreadCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        let fs = AppleScript.fieldSeparator
        let rs = AppleScript.recordSeparator
        BackendClients.scriptRunner = MockScriptRunner(stdout: "Work\(fs)5\(rs)")
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["--json", "mail", "unread"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(arr?.count == 1)
        #expect(arr?[0]["account"] as? String == "Work")
        #expect(arr?[0]["unread"] as? Int == 5)
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func mailAccountsCommandTextOnStdout() throws {
    try withRedirectedStdio { pipes in
        let fs = AppleScript.fieldSeparator
        let rs = AppleScript.recordSeparator
        BackendClients.scriptRunner = MockScriptRunner(
            stdout: "Personal\(fs)imap\(fs)p@x.com\(rs)"
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["mail", "accounts"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("- Personal | imap | p@x.com"))
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func mailUnreadCommandTextOnStdout() throws {
    try withRedirectedStdio { pipes in
        BackendClients.scriptRunner = MockScriptRunner(stdout: "")
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["mail", "unread"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("no unread."))
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func mailAccountsSystemFailureExit2() throws {
    try withRedirectedStdio { pipes in
        BackendClients.scriptRunner = MockScriptRunner(
            error: MacverbsError.system("Mail not running")
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["mail", "accounts"])
        #expect(code == ExitCodes.system)
        let err = try pipes.readError()
        #expect(err.contains("error: Mail not running"))
        #expect(try pipes.readOutput().isEmpty)
    }
}

@Test func mailHelpListsSubcommands() {
    let help = Macverbs.helpMessage()
    #expect(help.contains("mail"))
    let mailHelp = MailCommand.helpMessage()
    #expect(mailHelp.contains("accounts"))
    #expect(mailHelp.contains("unread"))
}

// MARK: - Stdio / global backend test helpers

private struct StdioPipes {
    let outRead: FileHandle
    let errRead: FileHandle
    let outWrite: FileHandle
    let errWrite: FileHandle

    func readOutput() throws -> String {
        outWrite.closeFile()
        let data = outRead.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func readError() throws -> String {
        errWrite.closeFile()
        let data = errRead.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func restore() {
        CLIOutput.standardOutput = .standardOutput
        CLIOutput.standardError = .standardError
        outRead.closeFile()
        errRead.closeFile()
    }
}

/// Serialize process-global CLI state — Swift Testing runs cases in parallel.
/// Covers `CLIOutput` stdio handles and `BackendClients` injection.
private let globalCLIStateLock = NSLock()

private func withBackendClientsLock(_ body: () throws -> Void) throws {
    globalCLIStateLock.lock()
    defer { globalCLIStateLock.unlock() }
    try body()
}

private func withRedirectedStdio(_ body: (StdioPipes) throws -> Void) throws {
    globalCLIStateLock.lock()
    defer { globalCLIStateLock.unlock() }

    let outPipe = Pipe()
    let errPipe = Pipe()
    let pipes = StdioPipes(
        outRead: outPipe.fileHandleForReading,
        errRead: errPipe.fileHandleForReading,
        outWrite: outPipe.fileHandleForWriting,
        errWrite: errPipe.fileHandleForWriting
    )
    CLIOutput.standardOutput = pipes.outWrite
    CLIOutput.standardError = pipes.errWrite
    defer { pipes.restore() }
    try body(pipes)
}
