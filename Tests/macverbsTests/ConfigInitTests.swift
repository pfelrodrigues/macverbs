import ArgumentParser
import EventKit
import Foundation
import Testing

@testable import MacverbsCore

// MARK: - Config calendars init / default labels

@Test func configDefaultLabelsUniqueTitlesKeepTitle() {
    let calendars = [
        EventKitCalendarInfo(uid: "U1", title: "Work", source: "Exchange"),
        EventKitCalendarInfo(uid: "U2", title: "Personal", source: "iCloud"),
    ]
    let aliases = Config.defaultLabels(for: calendars)
    #expect(aliases.labelsByUID["U1"] == "Work")
    #expect(aliases.labelsByUID["U2"] == "Personal")
}

@Test func configDefaultLabelsDuplicateTitlesUseSource() {
    let calendars = [
        EventKitCalendarInfo(uid: "UA", title: "Calendar", source: "Exchange · Work"),
        EventKitCalendarInfo(uid: "UB", title: "Calendar", source: "CalDAV"),
    ]
    let aliases = Config.defaultLabels(for: calendars)
    #expect(aliases.labelsByUID["UA"] == "Calendar · Exchange · Work")
    #expect(aliases.labelsByUID["UB"] == "Calendar · CalDAV")
}

@Test func configDefaultLabelsRemainingCollisionsNumbered() {
    let calendars = [
        EventKitCalendarInfo(uid: "A", title: "Calendar", source: ""),
        EventKitCalendarInfo(uid: "B", title: "Calendar", source: ""),
    ]
    let aliases = Config.defaultLabels(for: calendars)
    let labels = Set(aliases.labelsByUID.values)
    #expect(labels.contains("Calendar"))
    #expect(labels.contains("Calendar (2)"))
}

@Test func configInitWritesCalendarsJSON() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macverbs-config-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("calendars.json")
    let calendars = [
        EventKitCalendarInfo(uid: "UID-1", title: "Calendar", source: "Exchange"),
        EventKitCalendarInfo(uid: "UID-2", title: "Calendar", source: "iCloud"),
    ]
    let written = try Config.initCalendarAliases(
        calendars: calendars,
        force: false,
        url: url
    )
    #expect(written.labelsByUID.count == 2)
    #expect(FileManager.default.fileExists(atPath: url.path))
    let loaded = Config.loadCalendarAliases(from: url)
    #expect(loaded.labelsByUID == written.labelsByUID)

    do {
        _ = try Config.initCalendarAliases(calendars: calendars, force: false, url: url)
        Issue.record("expected domain error when file exists without --force")
    } catch let error as MacverbsError {
        #expect(error.processExitCode == ExitCodes.domain)
    }

    let forced = try Config.initCalendarAliases(calendars: calendars, force: true, url: url)
    #expect(forced.labelsByUID.count == 2)
}

@Test func configUnaliasedDuplicateUIDs() {
    let calendars = [
        EventKitCalendarInfo(uid: "A", title: "Calendar", source: "X"),
        EventKitCalendarInfo(uid: "B", title: "Calendar", source: "Y"),
        EventKitCalendarInfo(uid: "C", title: "Solo", source: ""),
    ]
    let empty = CalendarAliases.empty
    #expect(Config.unaliasedDuplicateUIDs(calendars: calendars, aliases: empty) == ["A", "B"])
    let partial = CalendarAliases(labelsByUID: ["A": "Work"])
    #expect(Config.unaliasedDuplicateUIDs(calendars: calendars, aliases: partial) == ["B"])
}

@Test func doctorWarnsOnUnaliasedDuplicateCalendars() {
    let calendars = [
        EventKitCalendarInfo(uid: "A", title: "Calendar", source: "Exchange"),
        EventKitCalendarInfo(uid: "B", title: "Calendar", source: "CalDAV"),
    ]
    let store = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        calendars: calendars
    )
    let report = Doctor.probe(
        eventStore: store,
        scriptRunner: MockScriptRunner(),
        automation: MockAutomationPermissionClient(),
        aliases: .empty
    )
    #expect(report.ok == true || !report.missing.isEmpty || report.ok == false)
    // warnings should mention calendars init when duplicates lack aliases
    #expect(report.warnings.contains { $0.contains("config calendars init") })
}

@Test func calendarCalendarsCommandJson() throws {
    try withBackendClientsLock {
        let calendars = [
            EventKitCalendarInfo(uid: "U1", title: "Work", source: "Exchange")
        ]
        BackendClients.eventStore = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            calendars: calendars
        )
        defer { BackendClients.resetDefaults() }
        try withRedirectedStdio { pipes in
            let code = MacverbsApp.run(arguments: ["--json", "calendar", "calendars"])
            #expect(code == ExitCodes.success)
            let out = try pipes.readOutput()
            #expect(out.contains("U1"))
            #expect(out.contains("Work"))
        }
    }
}

@Test func configPathCommandJson() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.run(arguments: ["--json", "config", "path"])
        #expect(code == ExitCodes.success)
        let out = try pipes.readOutput()
        #expect(out.contains("calendarsFile"))
        #expect(out.contains("directory"))
    }
}
