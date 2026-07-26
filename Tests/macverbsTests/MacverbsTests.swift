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
    // Parser failures write usage text via CLIOutput.errFile; redirect so
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

/// One recorded `saveEvent` call for mock verification (T08).
struct MockSavedEvent: Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var calendarUID: String?
}

/// Shared log so struct mocks can record saves without mutating self in protocol methods.
final class MockEventSaveLog: @unchecked Sendable {
    private(set) var events: [MockSavedEvent] = []

    func append(_ event: MockSavedEvent) {
        events.append(event)
    }

    func reset() {
        events.removeAll()
    }
}

/// Test double for EventKit; never links EventKit / never prompts TCC.
struct MockEventStoreClient: EventStoreClient {
    var calendar: EventAuthorizationStatus = .notDetermined
    var reminders: EventAuthorizationStatus = .notDetermined
    /// Returned by `requestAccess` when current status is `.notDetermined`.
    var afterRequestCalendar: EventAuthorizationStatus = .denied
    var afterRequestReminders: EventAuthorizationStatus = .denied
    /// Optional system failure from `requestAccess`.
    var requestError: Error?
    /// Optional failure from data query methods.
    var dataError: Error?
    /// Optional failure from `saveEvent`.
    var saveError: Error?
    /// Canned event calendars (default empty).
    var calendars: [EventKitCalendarInfo] = []
    /// Canned events (default empty).
    var eventInfos: [EventKitEventInfo] = []
    /// Canned reminder lists (default empty).
    var reminderListInfos: [ReminderListInfo] = []
    /// Canned incomplete reminders (default empty).
    var reminderItems: [ReminderItem] = []
    /// Optional recorder for `saveEvent` calls (inject in tests that verify save).
    var saveLog: MockEventSaveLog?

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

    func eventCalendars() throws -> [EventKitCalendarInfo] {
        if let dataError {
            throw dataError
        }
        return calendars
    }

    func events(from start: Date, to end: Date) throws -> [EventKitEventInfo] {
        if let dataError {
            throw dataError
        }
        return eventInfos.filter { $0.startDate >= start && $0.startDate < end }
    }

    func saveEvent(
        title: String,
        start: Date,
        end: Date,
        calendarUID: String?
    ) throws {
        if let saveError {
            throw saveError
        }
        if let dataError {
            throw dataError
        }
        saveLog?
            .append(
                MockSavedEvent(
                    title: title,
                    start: start,
                    end: end,
                    calendarUID: calendarUID
                )
            )
    }

    func reminderLists() throws -> [ReminderListInfo] {
        if let dataError {
            throw dataError
        }
        return reminderListInfos
    }

    func incompleteReminders(listName: String?) throws -> [ReminderItem] {
        if let dataError {
            throw dataError
        }
        guard let listName, !listName.isEmpty else {
            return reminderItems
        }
        let known = Set(reminderListInfos.map(\.name)).union(Set(reminderItems.map(\.list)))
        if !known.contains(listName) {
            throw MacverbsError.domain("list \(listName) not found")
        }
        return reminderItems.filter { $0.list == listName }
    }
}

/// Fake EventKit surface for `EKEventStoreClient` unit tests (no live store).
final class FakeEventKitBacking: EventKitBacking, @unchecked Sendable {
    var statuses: [EventEntityType: EventAuthorizationStatus]
    var grantOnRequest: Bool
    var requestError: Error?
    var saveError: Error?
    var calendars: [EventKitCalendarInfo]
    var eventInfos: [EventKitEventInfo]
    var reminderListInfos: [ReminderListInfo]
    var reminderItems: [ReminderItem]
    private(set) var requestCalls: [EventEntityType] = []
    private(set) var savedEvents: [MockSavedEvent] = []

    init(
        calendar: EventAuthorizationStatus = .notDetermined,
        reminders: EventAuthorizationStatus = .notDetermined,
        grantOnRequest: Bool = false,
        requestError: Error? = nil,
        saveError: Error? = nil,
        calendars: [EventKitCalendarInfo] = [],
        eventInfos: [EventKitEventInfo] = [],
        reminderListInfos: [ReminderListInfo] = [],
        reminderItems: [ReminderItem] = []
    ) {
        self.statuses = [.event: calendar, .reminder: reminders]
        self.grantOnRequest = grantOnRequest
        self.requestError = requestError
        self.saveError = saveError
        self.calendars = calendars
        self.eventInfos = eventInfos
        self.reminderListInfos = reminderListInfos
        self.reminderItems = reminderItems
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

    func eventCalendars() throws -> [EventKitCalendarInfo] {
        calendars
    }

    func events(from start: Date, to end: Date) throws -> [EventKitEventInfo] {
        eventInfos.filter { $0.startDate >= start && $0.startDate < end }
    }

    func saveEvent(
        title: String,
        start: Date,
        end: Date,
        calendarUID: String?
    ) throws {
        if let saveError {
            throw saveError
        }
        if let calendarUID {
            guard calendars.contains(where: { $0.uid == calendarUID }) else {
                throw MacverbsError.domain("calendar not found")
            }
        }
        savedEvents.append(
            MockSavedEvent(
                title: title,
                start: start,
                end: end,
                calendarUID: calendarUID
            )
        )
    }

    func reminderLists() throws -> [ReminderListInfo] {
        reminderListInfos
    }

    func incompleteReminders(listName: String?) throws -> [ReminderItem] {
        guard let listName, !listName.isEmpty else {
            return reminderItems
        }
        let known = Set(reminderListInfos.map(\.name)).union(Set(reminderItems.map(\.list)))
        if !known.contains(listName) {
            throw MacverbsError.domain("list \(listName) not found")
        }
        return reminderItems.filter { $0.list == listName }
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

// MARK: - Calendar list (T07)

/// Fixed UTC calendar for deterministic `when` strings in unit tests.
private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

/// Build a UTC `Date` from Y-M-D H:M components.
private func utcDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 0,
    _ minute: Int = 0
) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return utcCalendar().date(from: components)!
}

@Test func calendarDateRangeDaysSeven() throws {
    let cal = utcCalendar()
    let now = utcDate(2026, 7, 26, 15, 30)
    let range = try CalendarService.dateRange(days: 7, now: now, calendar: cal)
    #expect(range.start == utcDate(2026, 7, 26))
    // Exclusive end: start of day after today+7 (= Aug 3 when today is Jul 26).
    #expect(range.end == utcDate(2026, 8, 3))
}

@Test func calendarDateRangeTodayOnly() throws {
    let cal = utcCalendar()
    let now = utcDate(2026, 7, 26, 9, 0)
    let range = try CalendarService.dateRange(days: 0, now: now, calendar: cal)
    #expect(range.start == utcDate(2026, 7, 26))
    #expect(range.end == utcDate(2026, 7, 27))
}

@Test func calendarDateRangeRejectsNegativeDays() {
    do {
        _ = try CalendarService.dateRange(days: -1, now: utcDate(2026, 7, 26))
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .domain("--days must be >= 0"))
        #expect(error.processExitCode == ExitCodes.domain)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func calendarFormatWhenTimedSameDay() {
    let when = CalendarService.formatWhen(
        start: utcDate(2026, 7, 26, 10, 0),
        end: utcDate(2026, 7, 26, 10, 30),
        isAllDay: false,
        calendar: utcCalendar()
    )
    #expect(when == "2026-07-26 at 10:00 - 10:30")
}

@Test func calendarFormatWhenTimedMultiDay() {
    let when = CalendarService.formatWhen(
        start: utcDate(2026, 7, 26, 22, 0),
        end: utcDate(2026, 7, 27, 9, 0),
        isAllDay: false,
        calendar: utcCalendar()
    )
    #expect(when == "2026-07-26 at 22:00 - 2026-07-27 at 09:00")
}

@Test func calendarFormatWhenAllDaySingle() {
    let when = CalendarService.formatWhen(
        start: utcDate(2026, 7, 26),
        end: utcDate(2026, 7, 27),
        isAllDay: true,
        calendar: utcCalendar()
    )
    #expect(when == "2026-07-26")
}

@Test func calendarFormatWhenAllDayMulti() {
    let when = CalendarService.formatWhen(
        start: utcDate(2026, 7, 26),
        end: utcDate(2026, 7, 29),
        isAllDay: true,
        calendar: utcCalendar()
    )
    #expect(when == "2026-07-26 - 2026-07-28")
}

@Test func calendarMapEventsUsesAliasThenFallbackAndSorts() {
    let aliases = CalendarAliases(labelsByUID: ["UID-WORK": "Work"])
    let raw = [
        EventKitEventInfo(
            title: "Later",
            startDate: utcDate(2026, 7, 26, 15, 0),
            endDate: utcDate(2026, 7, 26, 16, 0),
            isAllDay: false,
            calendarUID: "UID-WORK",
            calendarTitle: "Calendario"
        ),
        EventKitEventInfo(
            title: "Earlier",
            startDate: utcDate(2026, 7, 26, 9, 0),
            endDate: utcDate(2026, 7, 26, 9, 30),
            isAllDay: false,
            calendarUID: "UID-OTHER",
            calendarTitle: "Personal"
        ),
    ]
    let items = CalendarService.mapEvents(raw, aliases: aliases, calendar: utcCalendar())
    #expect(items.count == 2)
    #expect(items[0].title == "Earlier")
    #expect(items[0].calendar == "Personal")
    #expect(items[0].when == "2026-07-26 at 09:00 - 09:30")
    #expect(items[1].title == "Later")
    #expect(items[1].calendar == "Work")
    #expect(items[1].when == "2026-07-26 at 15:00 - 16:00")
}

@Test func calendarListWithMockReturnsItems() throws {
    let store = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        eventInfos: [
            EventKitEventInfo(
                title: "Standup",
                startDate: utcDate(2026, 7, 26, 10, 0),
                endDate: utcDate(2026, 7, 26, 10, 30),
                isAllDay: false,
                calendarUID: "UID-WORK",
                calendarTitle: "Calendario"
            ),
            EventKitEventInfo(
                title: "Tomorrow",
                startDate: utcDate(2026, 7, 27, 10, 0),
                endDate: utcDate(2026, 7, 27, 11, 0),
                isAllDay: false,
                calendarUID: "UID-WORK",
                calendarTitle: "Calendario"
            ),
        ]
    )
    let items = try CalendarService.list(
        days: 0,
        eventStore: store,
        aliases: CalendarAliases(labelsByUID: ["UID-WORK": "Work"]),
        now: utcDate(2026, 7, 26, 8, 0),
        calendar: utcCalendar()
    )
    #expect(items.count == 1)
    #expect(
        items[0]
            == CalendarEventItem(
                title: "Standup",
                when: "2026-07-26 at 10:00 - 10:30",
                calendar: "Work"
            )
    )
}

@Test func calendarListDeniedThrowsDomain() {
    let store = MockEventStoreClient(calendar: .denied, reminders: .fullAccess)
    do {
        _ = try CalendarService.list(days: 7, eventStore: store)
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error.processExitCode == ExitCodes.domain)
        #expect(error.message.contains("Calendar access denied"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func calendarListPropagatesSystemDataError() {
    var store = MockEventStoreClient(calendar: .fullAccess, reminders: .fullAccess)
    store.dataError = MacverbsError.system("EventKit query failed")
    do {
        _ = try CalendarService.list(
            days: 1,
            eventStore: store,
            now: utcDate(2026, 7, 26),
            calendar: utcCalendar()
        )
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .system("EventKit query failed"))
        #expect(error.processExitCode == ExitCodes.system)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func calendarFormatTextEmptyAndItems() {
    #expect(CalendarService.formatText([]) == "no events.")
    let text = CalendarService.formatText([
        CalendarEventItem(
            title: "Standup",
            when: "2026-07-26 at 10:00 - 10:30",
            calendar: "Work"
        )
    ])
    #expect(text == "- Standup | 2026-07-26 at 10:00 - 10:30 | Work")
}

@Test func calendarListCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        BackendClients.eventStore = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            eventInfos: [
                EventKitEventInfo(
                    title: "Standup",
                    startDate: Date().addingTimeInterval(3600),
                    endDate: Date().addingTimeInterval(5400),
                    isAllDay: false,
                    calendarUID: "UID-ACME",
                    calendarTitle: "Shared"
                )
            ]
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["--json", "calendar", "list", "--days", "1"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(arr?.count == 1)
        #expect(arr?[0]["title"] as? String == "Standup")
        #expect(arr?[0]["calendar"] as? String == "Shared")
        #expect(arr?[0]["when"] as? String != nil)
        if let calRange = text.range(of: "\"calendar\""),
            let titleRange = text.range(of: "\"title\""),
            let whenRange = text.range(of: "\"when\"")
        {
            #expect(calRange.lowerBound < titleRange.lowerBound)
            #expect(titleRange.lowerBound < whenRange.lowerBound)
        } else {
            Issue.record("expected calendar/title/when keys")
        }
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func calendarListCommandTextOnStdout() throws {
    try withRedirectedStdio { pipes in
        BackendClients.eventStore = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            eventInfos: []
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["calendar", "list"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("no events."))
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func calendarListCommandDeniedExit1() throws {
    try withRedirectedStdio { pipes in
        BackendClients.eventStore = MockEventStoreClient(
            calendar: .denied,
            reminders: .fullAccess
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["calendar", "list"])
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("error: Calendar access denied"))
        #expect(try pipes.readOutput().isEmpty)
    }
}

@Test func calendarListCommandNegativeDaysExit1() throws {
    try withRedirectedStdio { pipes in
        BackendClients.eventStore = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["calendar", "list", "--days=-3"])
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("error: --days must be >= 0"))
        #expect(try pipes.readOutput().isEmpty)
    }
}

@Test func calendarHelpListsCommand() {
    let help = Macverbs.helpMessage()
    #expect(help.contains("calendar"))
    let calHelp = CalendarCommand.helpMessage()
    #expect(calHelp.contains("list"))
    #expect(calHelp.contains("add"))
}

@Test func ekClientDelegatesEventsToFakeBacking() throws {
    let start = utcDate(2026, 7, 26, 10, 0)
    let end = utcDate(2026, 7, 26, 11, 0)
    let fake = FakeEventKitBacking(
        calendar: .fullAccess,
        reminders: .fullAccess,
        eventInfos: [
            EventKitEventInfo(
                title: "Sync",
                startDate: start,
                endDate: end,
                isAllDay: false,
                calendarUID: "U1",
                calendarTitle: "Acme"
            )
        ]
    )
    let client = EKEventStoreClient(backing: fake)
    let items = try client.events(from: utcDate(2026, 7, 26), to: utcDate(2026, 7, 27))
    #expect(items.count == 1)
    #expect(items[0].title == "Sync")
    #expect(try client.eventCalendars().isEmpty)
}

// MARK: - Calendar add (T08)

@Test func calendarParseDateTimeValid() throws {
    let date = try CalendarService.parseDateTime(
        "2026-07-05 10:00",
        calendar: utcCalendar()
    )
    #expect(date == utcDate(2026, 7, 5, 10, 0))
}

@Test func calendarParseDateTimeInvalid() {
    do {
        _ = try CalendarService.parseDateTime("not-a-date", calendar: utcCalendar())
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error.processExitCode == ExitCodes.domain)
        #expect(error.message.contains("invalid date"))
        #expect(error.message.contains("YYYY-MM-DD HH:MM"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func calendarResolveUIDByAliasTitleAndUID() throws {
    let calendars = [
        EventKitCalendarInfo(uid: "UID-WORK", title: "Calendario"),
        EventKitCalendarInfo(uid: "UID-ACME", title: "Acme"),
    ]
    let aliases = CalendarAliases(labelsByUID: ["UID-WORK": "Work"])

    #expect(
        try CalendarService.resolveCalendarUID(
            name: "",
            calendars: calendars,
            aliases: aliases
        ) == nil
    )
    #expect(
        try CalendarService.resolveCalendarUID(
            name: "Work",
            calendars: calendars,
            aliases: aliases
        ) == "UID-WORK"
    )
    #expect(
        try CalendarService.resolveCalendarUID(
            name: "Acme",
            calendars: calendars,
            aliases: aliases
        ) == "UID-ACME"
    )
    #expect(
        try CalendarService.resolveCalendarUID(
            name: "UID-ACME",
            calendars: calendars,
            aliases: aliases
        ) == "UID-ACME"
    )
}

@Test func calendarResolveMissingThrowsDomain() {
    do {
        _ = try CalendarService.resolveCalendarUID(
            name: "Missing",
            calendars: [EventKitCalendarInfo(uid: "U1", title: "Work")],
            aliases: .empty
        )
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .domain("calendar Missing not found"))
        #expect(error.processExitCode == ExitCodes.domain)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func calendarAddWithMockVerifiesSave() throws {
    let log = MockEventSaveLog()
    let store = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        calendars: [
            EventKitCalendarInfo(uid: "UID-WORK", title: "Calendario"),
            EventKitCalendarInfo(uid: "UID-ACME", title: "Acme"),
        ],
        saveLog: log
    )
    let result = try CalendarService.add(
        title: "Standup",
        start: "2026-07-05 10:00",
        end: "2026-07-05 11:00",
        calendarName: "Work",
        eventStore: store,
        aliases: CalendarAliases(labelsByUID: ["UID-WORK": "Work"]),
        calendar: utcCalendar()
    )
    #expect(
        result
            == CalendarAddResult(
                created: "Standup",
                start: "2026-07-05 10:00",
                end: "2026-07-05 11:00"
            )
    )
    #expect(log.events.count == 1)
    #expect(log.events[0].title == "Standup")
    #expect(log.events[0].start == utcDate(2026, 7, 5, 10, 0))
    #expect(log.events[0].end == utcDate(2026, 7, 5, 11, 0))
    #expect(log.events[0].calendarUID == "UID-WORK")
}

@Test func calendarAddDefaultCalendarSavesWithNilUID() throws {
    let log = MockEventSaveLog()
    let store = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        calendars: [EventKitCalendarInfo(uid: "UID-ACME", title: "Acme")],
        saveLog: log
    )
    let result = try CalendarService.add(
        title: "E",
        start: "2026-07-05 10:00",
        end: "2026-07-05 11:00",
        calendarName: "",
        eventStore: store,
        aliases: .empty,
        calendar: utcCalendar()
    )
    #expect(result.created == "E")
    #expect(log.events.count == 1)
    #expect(log.events[0].calendarUID == nil)
}

@Test func calendarAddMissingCalendarThrowsDomain() {
    let log = MockEventSaveLog()
    let store = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        calendars: [EventKitCalendarInfo(uid: "UID-ACME", title: "Acme")],
        saveLog: log
    )
    do {
        _ = try CalendarService.add(
            title: "E",
            start: "2026-07-05 10:00",
            end: "2026-07-05 11:00",
            calendarName: "Ghost",
            eventStore: store,
            aliases: .empty,
            calendar: utcCalendar()
        )
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .domain("calendar Ghost not found"))
        #expect(error.processExitCode == ExitCodes.domain)
        #expect(log.events.isEmpty)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func calendarAddEndBeforeStartThrowsDomain() {
    let store = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        calendars: [EventKitCalendarInfo(uid: "U1", title: "Work")]
    )
    do {
        _ = try CalendarService.add(
            title: "E",
            start: "2026-07-05 11:00",
            end: "2026-07-05 10:00",
            eventStore: store,
            calendar: utcCalendar()
        )
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .domain("--end must be after --start"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func calendarAddDeniedThrowsDomain() {
    let store = MockEventStoreClient(calendar: .denied, reminders: .fullAccess)
    do {
        _ = try CalendarService.add(
            title: "E",
            start: "2026-07-05 10:00",
            end: "2026-07-05 11:00",
            eventStore: store,
            calendar: utcCalendar()
        )
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error.processExitCode == ExitCodes.domain)
        #expect(error.message.contains("Calendar access denied"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func calendarAddPropagatesSaveSystemError() {
    var store = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        calendars: [EventKitCalendarInfo(uid: "U1", title: "Work")]
    )
    store.saveError = MacverbsError.system("EventKit save failed: boom")
    do {
        _ = try CalendarService.add(
            title: "E",
            start: "2026-07-05 10:00",
            end: "2026-07-05 11:00",
            calendarName: "Work",
            eventStore: store,
            calendar: utcCalendar()
        )
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .system("EventKit save failed: boom"))
        #expect(error.processExitCode == ExitCodes.system)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func calendarFormatAddText() {
    #expect(
        CalendarService.formatAdd(
            CalendarAddResult(
                created: "Standup",
                start: "2026-07-05 10:00",
                end: "2026-07-05 11:00"
            )
        ) == "created: Standup"
    )
}

@Test func calendarAddCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        let log = MockEventSaveLog()
        BackendClients.eventStore = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            calendars: [EventKitCalendarInfo(uid: "UID-ACME", title: "Acme")],
            saveLog: log
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: [
                "--json",
                "calendar",
                "add",
                "E",
                "--start",
                "2026-07-05 10:00",
                "--end",
                "2026-07-05 11:00",
                "--calendar",
                "Acme",
            ]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["created"] as? String == "E")
        #expect(obj?["start"] as? String == "2026-07-05 10:00")
        #expect(obj?["end"] as? String == "2026-07-05 11:00")
        if let createdRange = text.range(of: "\"created\""),
            let endRange = text.range(of: "\"end\""),
            let startRange = text.range(of: "\"start\"")
        {
            #expect(createdRange.lowerBound < endRange.lowerBound)
            #expect(endRange.lowerBound < startRange.lowerBound)
        } else {
            Issue.record("expected created/end/start keys")
        }
        #expect(log.events.count == 1)
        #expect(log.events[0].title == "E")
        #expect(log.events[0].calendarUID == "UID-ACME")
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func calendarAddCommandTextOnStdout() throws {
    try withRedirectedStdio { pipes in
        BackendClients.eventStore = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            calendars: [EventKitCalendarInfo(uid: "UID-ACME", title: "Acme")]
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: [
                "calendar",
                "add",
                "E",
                "--start",
                "2026-07-05 10:00",
                "--end",
                "2026-07-05 11:00",
            ]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("created: E"))
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func calendarAddCommandMissingCalendarExit1() throws {
    try withRedirectedStdio { pipes in
        BackendClients.eventStore = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            calendars: [EventKitCalendarInfo(uid: "UID-ACME", title: "Acme")]
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: [
                "calendar",
                "add",
                "E",
                "--start",
                "2026-07-05 10:00",
                "--end",
                "2026-07-05 11:00",
                "--calendar",
                "Ghost",
            ]
        )
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("error: calendar Ghost not found"))
        #expect(try pipes.readOutput().isEmpty)
    }
}

@Test func ekClientDelegatesSaveToFakeBacking() throws {
    let start = utcDate(2026, 7, 5, 10, 0)
    let end = utcDate(2026, 7, 5, 11, 0)
    let fake = FakeEventKitBacking(
        calendar: .fullAccess,
        reminders: .fullAccess,
        calendars: [EventKitCalendarInfo(uid: "UID-ACME", title: "Acme")]
    )
    let client = EKEventStoreClient(backing: fake)
    try client.saveEvent(
        title: "Sync",
        start: start,
        end: end,
        calendarUID: "UID-ACME"
    )
    #expect(fake.savedEvents.count == 1)
    #expect(fake.savedEvents[0].title == "Sync")
    #expect(fake.savedEvents[0].calendarUID == "UID-ACME")
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

// MARK: - Reminders lists + list (T09)

@Test func reminderPriorityNameMapping() {
    #expect(ReminderFields.priorityName(0) == "")
    #expect(ReminderFields.priorityName(1) == "high")
    #expect(ReminderFields.priorityName(4) == "high")
    #expect(ReminderFields.priorityName(5) == "medium")
    #expect(ReminderFields.priorityName(6) == "low")
    #expect(ReminderFields.priorityName(9) == "low")
}

@Test func reminderDueStringFormats() {
    #expect(ReminderFields.dueString(from: nil) == "")
    var dateOnly = DateComponents()
    dateOnly.year = 2026
    dateOnly.month = 7
    dateOnly.day = 6
    #expect(ReminderFields.dueString(from: dateOnly) == "2026-07-06")
    var withTime = dateOnly
    withTime.hour = 14
    withTime.minute = 30
    #expect(ReminderFields.dueString(from: withTime) == "2026-07-06 14:30")
}

@Test func remindersFormatListsAndItems() {
    #expect(RemindersFormat.lists([]) == "no lists.")
    #expect(
        RemindersFormat.lists([ReminderListInfo(name: "Work", pending: 2)])
            == "- Work (2 pending)"
    )
    #expect(RemindersFormat.items([]) == "no pending reminders.")
    let line = RemindersFormat.items([
        ReminderItem(
            title: "Buy milk",
            due: "2026-07-06",
            priority: "high",
            list: "Personal",
            notes: "2%"
        )
    ])
    #expect(line.contains("Buy milk"))
    #expect(line.contains("list: Personal"))
    #expect(line.contains("due: 2026-07-06"))
    #expect(line.contains("priority: high"))
    #expect(line.contains("notes: 2%"))
}

@Test func mockReminderListsAndFilter() throws {
    var mock = MockEventStoreClient(calendar: .fullAccess, reminders: .fullAccess)
    mock.reminderListInfos = [
        ReminderListInfo(name: "Work", pending: 1),
        ReminderListInfo(name: "Personal", pending: 1),
    ]
    mock.reminderItems = [
        ReminderItem(title: "A", due: "", priority: "", list: "Work", notes: ""),
        ReminderItem(
            title: "B",
            due: "2026-07-06",
            priority: "medium",
            list: "Personal",
            notes: "x"
        ),
    ]
    #expect(try mock.reminderLists().count == 2)
    #expect(try mock.incompleteReminders(listName: nil).count == 2)
    let work = try mock.incompleteReminders(listName: "Work")
    #expect(work.count == 1 && work[0].title == "A")
    do {
        _ = try mock.incompleteReminders(listName: "Missing")
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .domain("list Missing not found"))
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Test func stubReminderQueriesThrowSystem() {
    let stub = StubEventStoreClient()
    #expect(throws: MacverbsError.self) {
        try stub.reminderLists()
    }
    #expect(throws: MacverbsError.self) {
        try stub.incompleteReminders(listName: nil)
    }
}

@Test func ekClientDelegatesRemindersToFakeBacking() throws {
    let fake = FakeEventKitBacking(
        calendar: .fullAccess,
        reminders: .fullAccess,
        reminderListInfos: [ReminderListInfo(name: "Inbox", pending: 1)],
        reminderItems: [
            ReminderItem(
                title: "Task",
                due: "2026-07-06 09:00",
                priority: "low",
                list: "Inbox",
                notes: ""
            )
        ]
    )
    let client = EKEventStoreClient(backing: fake)
    #expect(try client.reminderLists() == [ReminderListInfo(name: "Inbox", pending: 1)])
    let items = try client.incompleteReminders(listName: "Inbox")
    #expect(items.count == 1)
    #expect(items[0].title == "Task")
    #expect(items[0].priority == "low")
}

@Test func remindersListsCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        var mock = MockEventStoreClient(calendar: .fullAccess, reminders: .fullAccess)
        mock.reminderListInfos = [
            ReminderListInfo(name: "Work", pending: 3),
            ReminderListInfo(name: "Personal", pending: 0),
        ]
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["--json", "reminders", "lists"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(arr?.count == 2)
        #expect(arr?[0]["name"] as? String == "Work")
        #expect(arr?[0]["pending"] as? Int == 3)
        #expect(arr?[1]["name"] as? String == "Personal")
        #expect(arr?[1]["pending"] as? Int == 0)
        if let nameRange = text.range(of: "\"name\""),
            let pendingRange = text.range(of: "\"pending\"")
        {
            #expect(nameRange.lowerBound < pendingRange.lowerBound)
        } else {
            Issue.record("expected name/pending keys")
        }
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func remindersListCommandJsonWithListFilter() throws {
    try withRedirectedStdio { pipes in
        var mock = MockEventStoreClient(calendar: .fullAccess, reminders: .fullAccess)
        mock.reminderListInfos = [ReminderListInfo(name: "Work", pending: 1)]
        mock.reminderItems = [
            ReminderItem(
                title: "Ship",
                due: "2026-07-06 14:30",
                priority: "high",
                list: "Work",
                notes: "tag:release"
            ),
            ReminderItem(
                title: "Other",
                due: "",
                priority: "",
                list: "Personal",
                notes: ""
            ),
        ]
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: ["--json", "reminders", "list", "--list", "Work"]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(arr?.count == 1)
        #expect(arr?[0]["title"] as? String == "Ship")
        #expect(arr?[0]["due"] as? String == "2026-07-06 14:30")
        #expect(arr?[0]["priority"] as? String == "high")
        #expect(arr?[0]["list"] as? String == "Work")
        #expect(arr?[0]["notes"] as? String == "tag:release")
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func remindersListCommandAllListsText() throws {
    try withRedirectedStdio { pipes in
        var mock = MockEventStoreClient(calendar: .fullAccess, reminders: .fullAccess)
        mock.reminderItems = [
            ReminderItem(
                title: "A",
                due: "",
                priority: "",
                list: "Work",
                notes: ""
            )
        ]
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["reminders", "list"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("- A"))
        #expect(text.contains("list: Work"))
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func remindersListsCommandDeniedExit1() throws {
    try withRedirectedStdio { pipes in
        BackendClients.eventStore = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .denied
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["reminders", "lists"])
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("error: Reminders access denied"))
        #expect(try pipes.readOutput().isEmpty)
    }
}

@Test func remindersListCommandMissingListExit1() throws {
    try withRedirectedStdio { pipes in
        var mock = MockEventStoreClient(calendar: .fullAccess, reminders: .fullAccess)
        mock.reminderListInfos = [ReminderListInfo(name: "Work", pending: 0)]
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: ["reminders", "list", "--list", "Acme"]
        )
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("error: list Acme not found"))
        #expect(try pipes.readOutput().isEmpty)
    }
}

@Test func remindersHelpListsCommands() {
    let help = Macverbs.helpMessage()
    #expect(help.contains("reminders"))
    let remHelp = RemindersCommand.helpMessage()
    #expect(remHelp.contains("lists"))
    #expect(remHelp.contains("list"))
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
        CLIOutput.outFile = .standardOutput
        CLIOutput.errFile = .standardError
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
    CLIOutput.outFile = pipes.outWrite
    CLIOutput.errFile = pipes.errWrite
    defer { pipes.restore() }
    try body(pipes)
}
