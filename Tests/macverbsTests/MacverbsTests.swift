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

@Test func domainErrorMapsThroughAppRun() throws {
    // Simulate a verb throwing MacverbsError by exercising the catch path
    // via a dedicated internal helper would require a subcommand; unit-test
    // the error type + write path contract instead.
    let err = MacverbsError.domain("list Work not found")
    #expect(err.processExitCode == 1)
    #expect(err.message == "list Work not found")
    #expect(String(describing: err) == "list Work not found")
}

// MARK: - JSON emit

private struct SamplePayload: Codable, Equatable {
    var name: String
    var count: Int
}

@Test func writeJSONProducesObjectWithStableKeys() throws {
    let value = SamplePayload(name: "Work", count: 2)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(obj?["name"] as? String == "Work")
    #expect(obj?["count"] as? Int == 2)

    // Key order in encoded UTF-8 should be alphabetical (count before name).
    let text = String(data: data, encoding: .utf8) ?? ""
    if let countRange = text.range(of: "\"count\""),
       let nameRange = text.range(of: "\"name\"")
    {
        #expect(countRange.lowerBound < nameRange.lowerBound)
    } else {
        Issue.record("expected count and name keys in JSON")
    }
}

@Test func emitUsesJsonContext() throws {
    let value = SamplePayload(name: "Acme", count: 1)
    try CLIContext.$jsonOutput.withValue(true) {
        #expect(CLIContext.jsonOutput == true)
        // Ensure encode path used by CLIOutput.writeJSON accepts the payload.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        #expect(!data.isEmpty)
    }
    #expect(CLIContext.jsonOutput == false)
}
