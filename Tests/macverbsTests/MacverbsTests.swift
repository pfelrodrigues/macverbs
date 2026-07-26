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

@Test func runWithLeadingJsonStillSucceedsBare() {
    // Bare + --json prints help and exits 0 (no domain verb yet).
    let code = MacverbsApp.run(arguments: ["--json"])
    #expect(code == ExitCodes.success)
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

@Test func usageErrorReturns64() {
    let code = MacverbsApp.run(arguments: ["--not-a-real-flag"])
    #expect(code == ExitCodes.usage)
}

@Test func unexpectedArgumentReturns64() {
    let code = MacverbsApp.run(arguments: ["bogus-domain"])
    #expect(code == ExitCodes.usage)
}

@Test func helpReturns0() {
    let code = MacverbsApp.run(arguments: ["--help"])
    #expect(code == ExitCodes.success)
}

@Test func versionReturns0() {
    let code = MacverbsApp.run(arguments: ["--version"])
    #expect(code == ExitCodes.success)
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
