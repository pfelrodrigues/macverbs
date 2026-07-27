import ArgumentParser
import EventKit
import Foundation
import Testing

@testable import MacverbsCore

// MARK: - Notes list / read / create / search

@Test func notesScriptsListContainsOracleMarkers() {
    let s = NotesScripts.list(folder: "Work")
    #expect(s.contains("tell application \"Notes\""))
    #expect(s.contains("notes of folder \"Work\""))
    #expect(s.contains("modification date of n"))
    #expect(s.contains("character id 31"))
    #expect(s.contains("character id 30"))
}

@Test func notesScriptsListDefaultFolder() {
    let s = NotesScripts.list()
    #expect(s.contains("notes of folder \"Notes\""))
}

@Test func notesScriptsReadAndCreateEscape() {
    let read = NotesScripts.read(title: #"T"itle"#)
    #expect(read.contains(#"name is "T\"itle""#))
    #expect(read.contains("plaintext of"))

    let create = NotesScripts.create(title: "T", body: #"B"ody"#, folder: "F")
    #expect(create.contains(#"name:"T""#))
    #expect(create.contains(#"body:"B\"ody""#))
    #expect(create.contains("folder \"F\""))
    #expect(create.contains("return \"ok\""))
}

@Test func notesScriptsSearchContainsQuery() {
    let s = NotesScripts.search(query: "q")
    #expect(s.contains("name contains \"q\""))
    #expect(s.contains("plaintext contains \"q\""))
    #expect(s.contains("every note whose"))
}

@Test func notesListParsesRecords() throws {
    let fs = AppleScript.fieldSeparator
    let rs = AppleScript.recordSeparator
    let out = "Standup notes\(fs)Saturday\(rs)Inbox zero\(fs)Monday\(rs)"
    let items = try Notes.list(runner: MockScriptRunner(stdout: out))
    #expect(
        items == [
            NoteItem(title: "Standup notes", modified: "Saturday"),
            NoteItem(title: "Inbox zero", modified: "Monday"),
        ]
    )
}

@Test func notesListEmptyOutput() throws {
    #expect(try Notes.list(runner: MockScriptRunner(stdout: "")).isEmpty)
}

@Test func notesListPropagatesSystemError() {
    let runner = MockScriptRunner(error: MacverbsError.system("AppleScript failed"))
    do {
        _ = try Notes.list(runner: runner)
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .system("AppleScript failed"))
        #expect(error.processExitCode == ExitCodes.system)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func notesReadStripsBody() throws {
    let result = try Notes.read(
        title: "Standup notes",
        runner: MockScriptRunner(stdout: "  Hello from the meeting\n")
    )
    #expect(result == NoteBody(title: "Standup notes", body: "Hello from the meeting"))
}

@Test func notesCreateReturnsTitleAndFolder() throws {
    let result = try Notes.create(
        title: "Standup notes",
        body: "Hello",
        folder: "Work",
        runner: MockScriptRunner(stdout: "ok")
    )
    #expect(result == NoteCreateResult(created: "Standup notes", folder: "Work"))
}

@Test func notesSearchParsesRecords() throws {
    let fs = AppleScript.fieldSeparator
    let rs = AppleScript.recordSeparator
    let out = "Found\(fs)today\(rs)"
    let items = try Notes.search(query: "q", runner: MockScriptRunner(stdout: out))
    #expect(items == [NoteItem(title: "Found", modified: "today")])
}

@Test func notesFormatListText() {
    #expect(Notes.formatList([]) == "no notes.")
    let text = Notes.formatList([
        NoteItem(title: "Standup notes", modified: "Saturday")
    ])
    #expect(text == "- Standup notes | Saturday")
}

@Test func notesFormatBodyAndCreate() {
    #expect(Notes.formatBody(NoteBody(title: "T", body: "")) == "(empty)")
    #expect(Notes.formatBody(NoteBody(title: "T", body: "hello")) == "hello")
    #expect(
        Notes.formatCreate(NoteCreateResult(created: "Standup notes", folder: "Notes"))
            == "created: Standup notes"
    )
}

@Test func notesListCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        let fs = AppleScript.fieldSeparator
        let rs = AppleScript.recordSeparator
        BackendClients.scriptRunner = MockScriptRunner(
            stdout: "Standup notes\(fs)Saturday\(rs)"
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["--json", "notes", "list"])
        #expect(code == ExitCodes.success)
        let out = try pipes.readOutput()
        #expect(out.contains("\"title\""))
        #expect(out.contains("\"modified\""))
        #expect(out.contains("Standup notes"))
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func notesListCommandRespectsFolderFlag() throws {
    try withRedirectedStdio { pipes in
        let runner = RecordingScriptRunner(stdout: "")
        BackendClients.scriptRunner = runner
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["notes", "list", "--folder", "Work"])
        #expect(code == ExitCodes.success)
        #expect(runner.scripts.count == 1)
        #expect(runner.scripts[0].contains("folder \"Work\""))
        let out = try pipes.readOutput()
        #expect(out.contains("no notes."))
    }
}

@Test func notesListCommandTextEmpty() throws {
    try withRedirectedStdio { pipes in
        BackendClients.scriptRunner = MockScriptRunner(stdout: "")
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["notes", "list"])
        #expect(code == ExitCodes.success)
        let out = try pipes.readOutput()
        #expect(out.contains("no notes."))
    }
}

@Test func notesReadCommandJsonAndText() throws {
    try withRedirectedStdio { pipes in
        BackendClients.scriptRunner = MockScriptRunner(stdout: "Hello from the meeting")
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["--json", "notes", "read", "Standup notes"])
        #expect(code == ExitCodes.success)
        let out = try pipes.readOutput()
        #expect(out.contains("\"title\""))
        #expect(out.contains("\"body\""))
        #expect(out.contains("Standup notes"))
        #expect(out.contains("Hello from the meeting"))
    }

    try withRedirectedStdio { pipes in
        BackendClients.scriptRunner = MockScriptRunner(stdout: "plain body")
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["notes", "read", "T"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput().trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text == "plain body")
    }
}

@Test func notesCreateCommandJsonAndFolder() throws {
    try withRedirectedStdio { pipes in
        let runner = RecordingScriptRunner(stdout: "ok")
        BackendClients.scriptRunner = runner
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: [
                "--json", "notes", "create", "Standup notes", "Hello",
                "--folder", "Work",
            ]
        )
        #expect(code == ExitCodes.success)
        #expect(runner.scripts.count == 1)
        #expect(runner.scripts[0].contains("folder \"Work\""))
        #expect(runner.scripts[0].contains(#"name:"Standup notes""#))
        #expect(runner.scripts[0].contains(#"body:"Hello""#))
        let out = try pipes.readOutput()
        #expect(out.contains("\"created\""))
        #expect(out.contains("\"folder\""))
        #expect(out.contains("Standup notes"))
        #expect(out.contains("Work"))
    }
}

@Test func notesCreateCommandTextDefaultFolder() throws {
    try withRedirectedStdio { pipes in
        let runner = RecordingScriptRunner(stdout: "ok")
        BackendClients.scriptRunner = runner
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["notes", "create", "T", "B"])
        #expect(code == ExitCodes.success)
        #expect(runner.scripts[0].contains("folder \"Notes\""))
        let out = try pipes.readOutput()
        #expect(out.contains("created: T"))
    }
}

@Test func notesSearchCommandText() throws {
    try withRedirectedStdio { pipes in
        let fs = AppleScript.fieldSeparator
        let rs = AppleScript.recordSeparator
        BackendClients.scriptRunner = MockScriptRunner(stdout: "Found\(fs)today\(rs)")
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["notes", "search", "q"])
        #expect(code == ExitCodes.success)
        let out = try pipes.readOutput()
        #expect(out.contains("- Found | today"))
    }
}

@Test func notesHelpMentionsFolder() {
    let help = Macverbs.helpMessage()
    #expect(help.contains("notes"))
    let notesHelp = NotesCommand.helpMessage()
    #expect(notesHelp.contains("list"))
    #expect(notesHelp.contains("read"))
    #expect(notesHelp.contains("create"))
    #expect(notesHelp.contains("search"))
    let listHelp = NotesListCommand.helpMessage()
    #expect(listHelp.contains("--folder"))
    #expect(listHelp.contains("Notes"))
    let createHelp = NotesCreateCommand.helpMessage()
    #expect(createHelp.contains("--folder"))
}
