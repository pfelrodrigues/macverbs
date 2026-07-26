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

/// Test double for EventKit; never links EventKit.
struct MockEventStoreClient: EventStoreClient {
    var calendar: EventAuthorizationStatus = .notDetermined
    var reminders: EventAuthorizationStatus = .notDetermined

    func authorizationStatus(for entity: EventEntityType) -> EventAuthorizationStatus {
        switch entity {
        case .event:
            calendar
        case .reminder:
            reminders
        }
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

@Test func backendClientsDefaultsAreStubs() {
    BackendClients.resetDefaults()
    #expect(BackendClients.eventStore is StubEventStoreClient)
    #expect(BackendClients.scriptRunner is StubScriptRunner)
}

@Test func backendClientsAcceptMocks() throws {
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
    #expect(try BackendClients.scriptRunner.run(script: "x", timeout: 1) == "ok")
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
        BackendClients.resetDefaults()
        let code = MacverbsApp.run(arguments: ["--json", "doctor"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["ok"] as? Bool == false)
        #expect(obj?["version"] as? String == Version.current)
        let missing = obj?["missing"] as? [String]
        #expect(missing?.isEmpty == false)
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func doctorCommandTextOnStdout() throws {
    try withRedirectedStdio { pipes in
        BackendClients.resetDefaults()
        let code = MacverbsApp.run(arguments: ["doctor"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("macverbs doctor"))
        #expect(text.contains("missing:"))
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func doctorHelpListsCommand() {
    let help = Macverbs.helpMessage()
    #expect(help.contains("doctor"))
}

// MARK: - Stdio test helpers

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

/// Serialize stdio redirection — Swift Testing runs cases in parallel by default.
private let stdioTestLock = NSLock()

private func withRedirectedStdio(_ body: (StdioPipes) throws -> Void) throws {
    stdioTestLock.lock()
    defer { stdioTestLock.unlock() }

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
