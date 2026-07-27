import ArgumentParser
import EventKit
import Foundation
import Testing

@testable import MacverbsCore

// MARK: - AppleScript escape + parseRecords (contract helpers)

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
        automation: MockAutomationPermissionClient(),
        version: "0.1.0"
    )
    #expect(report.backends.appleEvents.kind == OSAScriptRunner.kind)
    #expect(report.backends.appleEvents.wired == true)
    #expect(report.backends.appleEvents.mail == .authorized)
    #expect(report.backends.appleEvents.notes == .authorized)
    #expect(!report.missing.contains { $0.contains("ScriptRunner") })
}
