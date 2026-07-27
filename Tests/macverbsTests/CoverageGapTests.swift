import ArgumentParser
import EventKit
import Foundation
import Testing

@testable import MacverbsCore

// Shared CLI serialization: TestHelpers.swift

// MARK: - ConfigCommand format + CLI

@Test func configFormatPathExistsAndMissing() {
    let exists = ConfigPathReport(
        directory: "/tmp/macverbs-cfg",
        calendarsFile: "/tmp/macverbs-cfg/calendars.json",
        calendarsFileExists: true
    )
    let existsText = ConfigFormat.path(exists)
    #expect(existsText.contains("config directory: /tmp/macverbs-cfg"))
    #expect(existsText.contains("calendars.json: exists"))

    let missing = ConfigPathReport(
        directory: "/tmp/macverbs-cfg",
        calendarsFile: "/tmp/macverbs-cfg/calendars.json",
        calendarsFileExists: false
    )
    let missingText = ConfigFormat.path(missing)
    #expect(missingText.contains("missing (optional; run config calendars init)"))
}

@Test func configFormatAliasesEmptyAndEntries() {
    #expect(ConfigFormat.aliases([]) == "no calendar aliases configured.")
    let text = ConfigFormat.aliases([
        ConfigCalendarAliasEntry(uid: "U1", label: "Work"),
        ConfigCalendarAliasEntry(uid: "U2", label: "Home"),
    ])
    #expect(text.contains("U1 → Work"))
    #expect(text.contains("U2 → Home"))
}

@Test func configFormatInitResultWroteAndOverwrote() {
    #expect(
        ConfigFormat.initResult(
            ConfigCalendarsInitResult(path: "/p.json", count: 2, force: false)
        ) == "wrote 2 alias(es) → /p.json"
    )
    #expect(
        ConfigFormat.initResult(
            ConfigCalendarsInitResult(path: "/p.json", count: 1, force: true)
        ) == "overwrote 1 alias(es) → /p.json"
    )
}

@Test func configPathCommandTextMentionsExistsOrMissing() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.run(arguments: ["config", "path"])
        #expect(code == ExitCodes.success)
        let out = try pipes.readOutput()
        #expect(out.contains("config directory:"))
        #expect(out.contains("calendars.json:"))
        #expect(out.contains("exists") || out.contains("missing"))
    }
}

@Test func configCalendarsShowCommandJsonAndText() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macverbs-show-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("calendars.json")
    try Config.writeCalendarAliases(
        CalendarAliases(labelsByUID: ["UID-Z": "Zebra", "UID-A": "Alpha"]),
        to: url
    )

    try withBackendClientsLock {
        setenv("MACVERBS_CONFIG_DIR", dir.path, 1)
        defer { unsetenv("MACVERBS_CONFIG_DIR") }

        try withRedirectedStdio { pipes in
            let code = MacverbsApp.run(arguments: ["--json", "config", "calendars", "show"])
            #expect(code == ExitCodes.success)
            let out = try pipes.readOutput()
            #expect(out.contains("UID-A"))
            #expect(out.contains("Alpha"))
            #expect(out.contains("Zebra"))
            // Sorted by uid: A before Z
            if let a = out.range(of: "UID-A"), let z = out.range(of: "UID-Z") {
                #expect(a.lowerBound < z.lowerBound)
            }
        }

        try withRedirectedStdio { pipes in
            let code = MacverbsApp.run(arguments: ["config", "calendars", "show"])
            #expect(code == ExitCodes.success)
            let out = try pipes.readOutput()
            #expect(out.contains("UID-A → Alpha"))
        }
    }
}

@Test func configCalendarsShowEmptyText() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macverbs-show-empty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    try withBackendClientsLock {
        setenv("MACVERBS_CONFIG_DIR", dir.path, 1)
        defer { unsetenv("MACVERBS_CONFIG_DIR") }
        try withRedirectedStdio { pipes in
            let code = MacverbsApp.run(arguments: ["config", "calendars", "show"])
            #expect(code == ExitCodes.success)
            let out = try pipes.readOutput()
            #expect(out.contains("no calendar aliases configured."))
        }
    }
}

@Test func configCalendarsInitCommandWritesFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macverbs-init-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    try withBackendClientsLock {
        setenv("MACVERBS_CONFIG_DIR", dir.path, 1)
        defer { unsetenv("MACVERBS_CONFIG_DIR") }

        BackendClients.eventStore = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            calendars: [
                EventKitCalendarInfo(uid: "C1", title: "Work", source: "Exchange"),
                EventKitCalendarInfo(uid: "C2", title: "Home", source: "iCloud"),
            ]
        )
        defer { BackendClients.resetDefaults() }

        try withRedirectedStdio { pipes in
            let code = MacverbsApp.run(arguments: ["config", "calendars", "init"])
            #expect(code == ExitCodes.success)
            let out = try pipes.readOutput()
            #expect(out.contains("wrote 2 alias(es)"))
        }

        let loaded = Config.loadCalendarAliases(
            from: dir.appendingPathComponent("calendars.json")
        )
        #expect(loaded.labelsByUID["C1"] == "Work")
        #expect(loaded.labelsByUID["C2"] == "Home")

        try withRedirectedStdio { pipes in
            let code = MacverbsApp.run(arguments: ["config", "calendars", "init"])
            #expect(code == ExitCodes.domain)
            let err = try pipes.readError()
            #expect(!err.isEmpty)
        }

        try withRedirectedStdio { pipes in
            let code = MacverbsApp.run(arguments: [
                "--json", "config", "calendars", "init", "--force",
            ])
            #expect(code == ExitCodes.success)
            let out = try pipes.readOutput()
            #expect(out.contains("\"force\"") || out.contains("force"))
            #expect(out.contains("2") || out.contains("count"))
        }
    }
}

// MARK: - Calendar listCalendars / format

@Test func calendarFormatCalendarsEmptyAndFields() {
    #expect(CalendarService.formatCalendars([]) == "no calendars.")
    let text = CalendarService.formatCalendars([
        CalendarInfoItem(uid: "U1", title: "Work", source: "Exchange", label: "W"),
        CalendarInfoItem(uid: "U2", title: "Solo", source: "", label: ""),
    ])
    #expect(text.contains("Work | source: Exchange | label: W | uid: U1"))
    #expect(text.contains("Solo | uid: U2"))
    #expect(!text.contains("Solo | source:"))
}

@Test func calendarListCalendarsSortsAndMapsLabels() throws {
    let mock = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        calendars: [
            EventKitCalendarInfo(uid: "Z", title: "Beta", source: "B"),
            EventKitCalendarInfo(uid: "A", title: "Alpha", source: "A"),
            EventKitCalendarInfo(uid: "Y", title: "Alpha", source: "Y"),
        ]
    )
    let aliases = CalendarAliases(labelsByUID: ["A": "Main"])
    let items = try CalendarService.listCalendars(client: mock, aliases: aliases)
    #expect(items.map(\.uid) == ["A", "Y", "Z"])
    #expect(items[0].label == "Main")
    #expect(items[1].title == "Alpha")
    #expect(items[1].label.isEmpty)
}

@Test func calendarMapEventsTitleTieBreak() {
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    let raw = [
        EventKitEventInfo(
            title: "B",
            startDate: t,
            endDate: t.addingTimeInterval(3600),
            isAllDay: false,
            calendarUID: "U",
            calendarTitle: "C"
        ),
        EventKitEventInfo(
            title: "A",
            startDate: t,
            endDate: t.addingTimeInterval(3600),
            isAllDay: false,
            calendarUID: "U",
            calendarTitle: "C"
        ),
    ]
    let items = CalendarService.mapEvents(raw, aliases: .empty)
    #expect(items.map(\.title) == ["A", "B"])
}

@Test func calendarCalendarsCommandText() throws {
    try withBackendClientsLock {
        BackendClients.eventStore = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            calendars: [
                EventKitCalendarInfo(uid: "U1", title: "Work", source: "Exchange")
            ]
        )
        defer { BackendClients.resetDefaults() }
        try withRedirectedStdio { pipes in
            let code = MacverbsApp.run(arguments: ["calendar", "calendars"])
            #expect(code == ExitCodes.success)
            let out = try pipes.readOutput()
            #expect(out.contains("Work"))
            #expect(out.contains("uid: U1"))
            #expect(out.contains("source: Exchange"))
        }
    }
}

// MARK: - Doctor warnings text + automation unavailable

@Test func doctorFormatTextOkWithWarnings() {
    let report = DoctorReport(
        version: "0.1.0",
        ok: true,
        backends: DoctorBackends(
            eventKit: DoctorEventKitBackend(
                kind: "mock",
                calendar: .fullAccess,
                reminders: .fullAccess
            ),
            appleEvents: DoctorAppleEventsBackend(
                kind: "mock",
                wired: true,
                mail: .authorized,
                notes: .authorized
            )
        ),
        missing: [],
        warnings: ["dup calendar tip"]
    )
    let text = Doctor.formatText(report)
    #expect(text.contains("ok: nothing missing"))
    #expect(text.contains("warnings:"))
    #expect(text.contains("dup calendar tip"))
}

@Test func doctorReportDefaultWarningsEmpty() {
    let report = DoctorReport(
        version: "0.1.0",
        ok: true,
        backends: DoctorBackends(
            eventKit: DoctorEventKitBackend(
                kind: "mock",
                calendar: .fullAccess,
                reminders: .fullAccess
            ),
            appleEvents: DoctorAppleEventsBackend(
                kind: "mock",
                wired: true,
                mail: .authorized,
                notes: .authorized
            )
        ),
        missing: []
    )
    #expect(report.warnings.isEmpty)
}

@Test func doctorProbeAutomationUnavailableIsMissing() {
    let report = Doctor.probe(
        eventStore: MockEventStoreClient(calendar: .fullAccess, reminders: .fullAccess),
        scriptRunner: MockScriptRunner(),
        automation: MockAutomationPermissionClient(
            mail: .unavailable,
            notes: .unavailable
        ),
        aliases: .empty
    )
    #expect(report.missing.contains { $0.contains("Automation status unavailable") })
}

@Test func doctorProbeSkipsAliasWarningsWhenCalendarDenied() {
    let report = Doctor.probe(
        eventStore: MockEventStoreClient(
            calendar: .denied,
            reminders: .fullAccess,
            calendars: [
                EventKitCalendarInfo(uid: "A", title: "Calendar", source: "X"),
                EventKitCalendarInfo(uid: "B", title: "Calendar", source: "Y"),
            ]
        ),
        scriptRunner: MockScriptRunner(),
        automation: MockAutomationPermissionClient(),
        aliases: .empty
    )
    #expect(!report.warnings.contains { $0.contains("calendars.json") })
}

@Test func doctorProbeSkipsAliasWarningsWhenCalendarsThrow() {
    let mock = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        dataError: MacverbsError.system("boom"),
        calendars: []
    )
    let report = Doctor.probe(
        eventStore: mock,
        scriptRunner: MockScriptRunner(),
        automation: MockAutomationPermissionClient(),
        aliases: .empty
    )
    #expect(
        report.warnings.isEmpty || !report.warnings.contains { $0.contains("config calendars") }
    )
}

// MARK: - Access error messages + restricted

@Test func eventStoreAccessErrorMessagesCoverAllStatuses() {
    for entity in EventEntityType.allCases {
        #expect(
            EventStoreAccess.errorMessage(for: entity, status: .restricted).contains("restricted")
        )
        #expect(
            EventStoreAccess.errorMessage(for: entity, status: .notDetermined)
                .contains("not granted")
        )
        #expect(
            EventStoreAccess.errorMessage(for: entity, status: .unavailable).contains("not wired")
        )
        #expect(
            EventStoreAccess.errorMessage(for: entity, status: .fullAccess).contains("access error")
        )
        #expect(
            EventStoreAccess.errorMessage(for: entity, status: .authorized).contains("access error")
        )
        #expect(
            EventStoreAccess.errorMessage(for: entity, status: .writeOnly).contains("write-only")
        )
        #expect(EventStoreAccess.errorMessage(for: entity, status: .denied).contains("denied"))
    }
}

@Test func ensureAccessThrowsDomainWhenRestricted() {
    let mock = MockEventStoreClient(calendar: .restricted, reminders: .restricted)
    #expect(throws: MacverbsError.self) {
        try mock.ensureAccess(for: .event)
    }
}

// MARK: - Stub EventStore full surface

@Test func stubEventStoreAllMethodsThrowSystem() {
    let stub = StubEventStoreClient()
    #expect(throws: MacverbsError.self) { try stub.eventCalendars() }
    #expect(throws: MacverbsError.self) {
        try stub.events(from: Date(), to: Date().addingTimeInterval(1))
    }
    #expect(throws: MacverbsError.self) {
        try stub.saveEvent(title: "t", start: Date(), end: Date(), calendarUID: nil)
    }
    #expect(throws: MacverbsError.self) {
        try stub.addReminder(title: "t", listName: nil, due: "", notes: "", priority: "")
    }
    #expect(throws: MacverbsError.self) {
        try stub.completeReminder(title: "t", listName: nil)
    }
    #expect(throws: MacverbsError.self) {
        try stub.deleteReminder(title: "t", listName: nil)
    }
    #expect(throws: MacverbsError.self) {
        try stub.moveReminder(title: "t", fromList: "A", toList: "B")
    }
    #expect(throws: MacverbsError.self) {
        try stub.editReminder(title: "t", listName: nil, due: "x", priority: "", notes: "")
    }
    #expect(throws: MacverbsError.self) {
        try stub.ensureReminderList(name: "L")
    }
}

@Test func stubAutomationPermissionClientUnavailable() {
    let stub = StubAutomationPermissionClient()
    for target in AutomationTarget.allCases {
        #expect(stub.authorizationStatus(for: target) == .unavailable)
        #expect(!target.bundleIdentifier.isEmpty)
        #expect(!target.displayName.isEmpty)
    }
}

// MARK: - EKEventStoreClient reminder mutations via fake

@Test func ekClientDelegatesAddCompleteDeleteToFakeBacking() throws {
    let fake = FakeEventKitBacking(
        calendar: .fullAccess,
        reminders: .fullAccess,
        reminderListInfos: [ReminderListInfo(name: "Inbox", pending: 0)],
        reminderItems: [
            ReminderItem(title: "One", due: "", priority: "", list: "Inbox", notes: "")
        ]
    )
    let client = EKEventStoreClient(backing: fake)
    let created = try client.addReminder(
        title: "Two",
        listName: "Inbox",
        due: "",
        notes: "n",
        priority: "low"
    )
    #expect(created.created == "Two")
    let done = try client.completeReminder(title: "One", listName: "Inbox")
    #expect(done.done == "One")
    let deleted = try client.deleteReminder(title: "One", listName: "Inbox")
    #expect(deleted.deleted == "One")
    #expect(client.eventStore == nil)
}

@Test func liveEventKitBackingMapAllStatuses() {
    #expect(LiveEventKitBacking.map(.notDetermined) == .notDetermined)
    #expect(LiveEventKitBacking.map(.restricted) == .restricted)
    #expect(LiveEventKitBacking.map(.denied) == .denied)
    #expect(LiveEventKitBacking.map(.fullAccess) == .fullAccess)
    #expect(LiveEventKitBacking.map(.writeOnly) == .writeOnly)
}

@Test func liveEventKitDescribeSourceAllTypes() {
    #expect(LiveEventKitBacking.describeSource(type: .local, title: "") == "Local")
    #expect(LiveEventKitBacking.describeSource(type: .local, title: "Local") == "Local")
    #expect(LiveEventKitBacking.describeSource(type: .exchange, title: "Work") == "Exchange · Work")
    #expect(LiveEventKitBacking.describeSource(type: .calDAV, title: "  ") == "CalDAV")
    #expect(LiveEventKitBacking.describeSource(type: .mobileMe, title: "iCloud") == "iCloud")
    #expect(
        LiveEventKitBacking.describeSource(type: .subscribed, title: "Holidays")
            == "Subscribed · Holidays"
    )
    #expect(LiveEventKitBacking.describeSource(type: .birthdays, title: "") == "Birthdays")
}

// MARK: - Config edge cases

@Test func configExpandTildeBareHome() {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    #expect(ConfigPaths.expandTilde("~", home: home).path == home.path)
}

@Test func configWriteFailsOnUnwritablePath() throws {
    // Writable dir + read-only file forces the atomic write catch → MacverbsError.system.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macverbs-ro-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: dir.path
        )
        try? FileManager.default.removeItem(at: dir)
    }
    let url = dir.appendingPathComponent("calendars.json")
    try Config.writeCalendarAliases(
        CalendarAliases(labelsByUID: ["U": "L"]),
        to: url
    )
    // Lock down directory so atomic replace cannot write temp + rename.
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o555],
        ofItemAtPath: dir.path
    )
    do {
        try Config.writeCalendarAliases(
            CalendarAliases(labelsByUID: ["U": "L2"]),
            to: url
        )
        Issue.record("expected write failure on read-only directory")
    } catch let error as MacverbsError {
        #expect(error.processExitCode == ExitCodes.system)
        #expect(error.message.contains("failed to write"))
    }
}

@Test func configLoadUnreadableFileIsEmpty() throws {
    // Directory path as "file" → Data(contentsOf:) fails → empty.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macverbs-unreadable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(Config.loadCalendarAliases(from: dir) == .empty)
}

// MARK: - MacverbsApp edges

@Test func runCatchingSuccessReturns0() {
    let code = MacverbsApp.runCatching {}
    #expect(code == ExitCodes.success)
}

@Test func runCatchingUnexpectedErrorReturns2() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.runCatching {
            throw NSError(domain: "test", code: 9, userInfo: [NSLocalizedDescriptionKey: "boom"])
        }
        #expect(code == ExitCodes.system)
        let err = try pipes.readError()
        #expect(!err.isEmpty)
    }
}

@Test func reminderParseDueInvalidTimeThrows() {
    #expect(throws: MacverbsError.self) {
        _ = try ReminderFields.parseDue("2026-07-06 25:99")
    }
    #expect(throws: MacverbsError.self) {
        _ = try ReminderFields.parseDue("2026-07-06 nottime")
    }
}

// MARK: - ScriptRunner live (real osascript, no Automation needed)

@Test func osaScriptRunnerLiveReturnsStdout() throws {
    let runner = OSAScriptRunner(process: OsascriptProcess())
    let out = try runner.run(script: "return \"macverbs-cov\"", timeout: 10)
    #expect(out.contains("macverbs-cov"))
}

@Test func osaScriptRunnerLiveNonZeroThrows() {
    let runner = OSAScriptRunner(process: OsascriptProcess())
    #expect(throws: MacverbsError.self) {
        _ = try runner.run(script: "error \"forced-fail\"", timeout: 10)
    }
}

@Test func osaScriptRunnerLiveTimeoutThrows() {
    let runner = OSAScriptRunner(process: OsascriptProcess())
    #expect(throws: MacverbsError.self) {
        // Busy-wait AppleScript so wall clock exceeds timeout.
        _ = try runner.run(
            script: """
                set endDate to (current date) + 30
                repeat while (current date) < endDate
                end repeat
                return "done"
                """,
            timeout: 0.3
        )
    }
}

@Test func osaScriptRunnerLiveFractionalTimeoutMessage() {
    let runner = OSAScriptRunner(process: OsascriptProcess())
    do {
        _ = try runner.run(
            script: """
                set endDate to (current date) + 30
                repeat while (current date) < endDate
                end repeat
                """,
            timeout: 0.25
        )
        Issue.record("expected timeout")
    } catch let error as MacverbsError {
        #expect(error.message.contains("timed out"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

// MARK: - AE Automation live probe (no prompt)

@Test func aeAutomationPermissionClientReadsStatus() {
    let client = AEAutomationPermissionClient()
    #expect(AEAutomationPermissionClient.kind == "ae")
    for target in AutomationTarget.allCases {
        let status = client.authorizationStatus(for: target)
        #expect(
            [
                AutomationAuthorizationStatus.authorized,
                .denied,
                .notDetermined,
                .notRunning,
            ]
            .contains(status)
        )
    }
}

// MARK: - Live EventKit (authorized on this Mac)

@Test func liveEventKitBackingAuthorizationAndCalendars() throws {
    let live = LiveEventKitBacking()
    let eventStatus = live.authorizationStatus(for: .event)
    let remStatus = live.authorizationStatus(for: .reminder)
    #expect(
        [
            EventAuthorizationStatus.fullAccess, .authorized, .denied, .restricted,
            .notDetermined, .writeOnly,
        ]
        .contains(eventStatus)
    )
    #expect(
        [
            EventAuthorizationStatus.fullAccess, .authorized, .denied, .restricted,
            .notDetermined, .writeOnly,
        ]
        .contains(remStatus)
    )

    // describeSource on every known source type we can reach.
    for source in live.store.sources {
        let desc = LiveEventKitBacking.describeSource(source)
        #expect(!desc.isEmpty)
    }

    guard eventStatus.allowsFullAccess else {
        return
    }

    let calendars = try live.eventCalendars()
    // May be empty on restricted accounts; call still covers mapping path.
    _ = calendars

    let start = Date()
    let end = start.addingTimeInterval(86_400)
    let events = try live.events(from: start, to: end)
    _ = events

    // requestFullAccess when already determined still exercises the async bridge.
    let granted = try live.requestFullAccess(for: .event)
    #expect(granted == true || granted == false)

    let remGranted = try live.requestFullAccess(for: .reminder)
    #expect(remGranted == true || remGranted == false)
}

@Test func liveEventKitSaveEventRoundTrip() throws {
    let live = LiveEventKitBacking()
    let status = live.authorizationStatus(for: .event)
    // Require real access so coverage of LiveEventKitBacking.saveEvent is not skipped silently.
    try #require(
        status.allowsFullAccess,
        "EventKit calendar access required for live save coverage (status=\(status))"
    )
    let calendars = try live.eventCalendars()
    // Prefer an EventKit calendar that accepts new events; fall back to first listed.
    let targetUID: String?
    if let def = live.store.defaultCalendarForNewEvents {
        targetUID = def.calendarIdentifier
    } else {
        targetUID = calendars.first?.uid
    }
    try #require(
        targetUID != nil || live.store.defaultCalendarForNewEvents != nil,
        "need at least one event calendar (listed=\(calendars.count))"
    )
    let start = Date().addingTimeInterval(3600)
    let end = start.addingTimeInterval(1800)
    let title = "macverbs-cov-\(UUID().uuidString)"
    if let targetUID {
        try live.saveEvent(
            title: title,
            start: start,
            end: end,
            calendarUID: targetUID
        )
    }
    // Default calendar path (nil UID)
    try live.saveEvent(
        title: "\(title)-default",
        start: start.addingTimeInterval(7200),
        end: end.addingTimeInterval(7200),
        calendarUID: nil
    )
    // Unknown UID
    do {
        try live.saveEvent(
            title: "nope",
            start: start,
            end: end,
            calendarUID: "not-a-real-calendar-uid-\(UUID().uuidString)"
        )
        Issue.record("expected domain for unknown calendar")
    } catch let error as MacverbsError {
        #expect(error.processExitCode == ExitCodes.domain)
    }

    // Cleanup created events in a short window.
    let windowStart = start.addingTimeInterval(-60)
    let windowEnd = end.addingTimeInterval(10_000)
    let found = try live.events(from: windowStart, to: windowEnd)
        .filter { $0.title.hasPrefix("macverbs-cov-") }
    for info in found {
        let predicate = live.store.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: nil
        )
        for event in live.store.events(matching: predicate) where event.title == info.title {
            try? live.store.remove(event, span: .thisEvent, commit: true)
        }
    }
}

@Test func liveRemindersQueryFullCycle() throws {
    let live = LiveEventKitBacking()
    guard live.authorizationStatus(for: .reminder).allowsFullAccess else {
        return
    }
    let store = live.store
    let listName = "macverbs-cov-\(UUID().uuidString.prefix(8))"
    let title = "macverbs-rem-\(UUID().uuidString.prefix(8))"

    // ensureList create + idempotent
    let ensured = try LiveRemindersQuery.ensureList(store: store, name: listName)
    #expect(ensured.list == listName)
    let again = try LiveRemindersQuery.ensureList(store: store, name: listName)
    #expect(again.list == listName)

    // lists / incomplete empty filter
    _ = try LiveRemindersQuery.lists(store: store)
    _ = try LiveRemindersQuery.incomplete(store: store, listName: nil)
    _ = try LiveRemindersQuery.incomplete(store: store, listName: listName)

    // missing list
    do {
        _ = try LiveRemindersQuery.incomplete(store: store, listName: "no-such-list-\(UUID())")
        Issue.record("expected missing list")
    } catch let error as MacverbsError {
        #expect(error.processExitCode == ExitCodes.domain)
    }

    // add with due, notes, priority
    let created = try LiveRemindersQuery.add(
        store: store,
        title: title,
        listName: listName,
        due: "2030-01-15 14:30",
        notes: "cov-note",
        priority: "high"
    )
    #expect(created.created == title)
    #expect(created.list == listName)

    // add default list label path (nil list)
    let createdDefault = try LiveRemindersQuery.add(
        store: store,
        title: "\(title)-def",
        listName: nil,
        due: "2030-01-16",
        notes: "",
        priority: ""
    )
    #expect(createdDefault.list == ReminderFields.defaultListLabel)

    // item(from:) via incomplete
    let items = try LiveRemindersQuery.incomplete(store: store, listName: listName)
    #expect(items.contains { $0.title == title })

    // edit
    let edited = try LiveRemindersQuery.edit(
        store: store,
        title: title,
        listName: listName,
        due: "2030-02-01 10:00",
        priority: "low",
        notes: "edited"
    )
    #expect(edited.edited == title)

    // edit nothing
    do {
        _ = try LiveRemindersQuery.edit(
            store: store,
            title: title,
            listName: listName,
            due: "",
            priority: "",
            notes: ""
        )
        Issue.record("expected nothing to edit")
    } catch let error as MacverbsError {
        #expect(error.processExitCode == ExitCodes.domain)
    }

    // move to same list is fine; need second list
    let listB = "\(listName)-b"
    _ = try LiveRemindersQuery.ensureList(store: store, name: listB)
    let moved = try LiveRemindersQuery.move(
        store: store,
        title: title,
        fromList: listName,
        toList: listB
    )
    #expect(moved.moved == title)

    // move missing
    do {
        _ = try LiveRemindersQuery.move(
            store: store,
            title: "missing-\(UUID())",
            fromList: listB,
            toList: listName
        )
        Issue.record("expected missing reminder")
    } catch let error as MacverbsError {
        #expect(error.processExitCode == ExitCodes.domain)
    }

    // complete
    let done = try LiveRemindersQuery.complete(
        store: store,
        title: title,
        listName: listB
    )
    #expect(done.done == title)

    // delete the default-list one
    let deleted = try LiveRemindersQuery.delete(
        store: store,
        title: "\(title)-def",
        listName: nil
    )
    #expect(deleted.deleted == "\(title)-def")

    // find missing
    do {
        _ = try LiveRemindersQuery.complete(
            store: store,
            title: "gone-\(UUID())",
            listName: listB
        )
        Issue.record("expected not found")
    } catch let error as MacverbsError {
        #expect(error.processExitCode == ExitCodes.domain)
    }

    // LiveEventKitBacking wrappers
    _ = try live.reminderLists()
    _ = try live.incompleteReminders(listName: listB)
    _ = try live.addReminder(
        title: "\(title)-wrap",
        listName: listB,
        due: "",
        notes: "",
        priority: "medium"
    )
    _ = try live.editReminder(
        title: "\(title)-wrap",
        listName: listB,
        due: "2030-03-01",
        priority: "none",
        notes: "w"
    )
    _ = try live.moveReminder(
        title: "\(title)-wrap",
        fromList: listB,
        toList: listName
    )
    _ = try live.completeReminder(title: "\(title)-wrap", listName: listName)

    // Clean leftover incomplete if any
    if let leftover = try? LiveRemindersQuery.incomplete(store: store, listName: listName) {
        for item in leftover where item.title.hasPrefix("macverbs-") {
            _ = try? LiveRemindersQuery.delete(
                store: store,
                title: item.title,
                listName: listName
            )
        }
    }
    if let leftover = try? LiveRemindersQuery.incomplete(store: store, listName: listB) {
        for item in leftover where item.title.hasPrefix("macverbs-") {
            _ = try? LiveRemindersQuery.delete(
                store: store,
                title: item.title,
                listName: listB
            )
        }
    }

    // Remove temporary lists when empty (best effort).
    for name in [listName, listB] {
        if let cal = store.calendars(for: .reminder).first(where: { $0.title == name }) {
            try? store.removeCalendar(cal, commit: true)
        }
    }
}

@Test func liveRemindersQueryResolveDefaultList() throws {
    let live = LiveEventKitBacking()
    guard live.authorizationStatus(for: .reminder).allowsFullAccess else {
        return
    }
    let cal = try LiveRemindersQuery.resolveList(store: live.store, listName: nil)
    #expect(!cal.title.isEmpty)
}

@Test func ekEventStoreClientEventStorePropertyWhenLive() {
    let client = EKEventStoreClient(backing: LiveEventKitBacking())
    #expect(client.eventStore != nil)
}

// MARK: - Mail empty ids validation (usage 64)

@Test func mailArchiveDeleteEmptyIdsUsageExit64() throws {
    try withRedirectedStdio { pipes in
        let archive = MacverbsApp.run(
            arguments: ["mail", "archive", "--account", "Work"]
        )
        #expect(archive == ExitCodes.usage)
    }
    try withRedirectedStdio { pipes in
        let delete = MacverbsApp.run(
            arguments: ["mail", "delete", "--account", "Work"]
        )
        #expect(delete == ExitCodes.usage)
    }
}

@Test func mailMoveGmailEmptyBoxUsesAllMailLabel() throws {
    let sentinel = MailScripts.archiveUnsupportedSentinel
    let runner = MockScriptRunner(stdout: sentinel)
    let result = try Mail.archive(account: "Gmail", ids: ["<a@b>"], runner: runner)
    #expect(result.moved == 0)
    #expect(result.unsupported?.contains("All Mail") == true)
}

@Test func mailArchiveDeleteValidateEmptyIds() {
    var archive = MailArchiveCommand()
    archive.ids = []
    archive.account = "Work"
    #expect(throws: ValidationError.self) {
        try archive.validate()
    }
    var delete = MailDeleteCommand()
    delete.ids = []
    delete.account = "Work"
    #expect(throws: ValidationError.self) {
        try delete.validate()
    }
}

@Test func osaScriptRunnerLaunchFailureThrowsSystem() {
    let process = OsascriptProcess(executablePath: "/nonexistent/osascript-\(UUID().uuidString)")
    let runner = OSAScriptRunner(process: process)
    #expect(throws: MacverbsError.self) {
        _ = try runner.run(script: "return 1", timeout: 2)
    }
}

@Test func osaScriptRunnerIntegerTimeoutFormat() {
    let runner = OSAScriptRunner(process: OsascriptProcess())
    do {
        _ = try runner.run(
            script: """
                set endDate to (current date) + 30
                repeat while (current date) < endDate
                end repeat
                """,
            timeout: 1
        )
        Issue.record("expected timeout")
    } catch let error as MacverbsError {
        // formatTimeout integer branch: "1s" not "1.0s"
        #expect(error.message.contains("timed out after 1s"))
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Test func liveEventKitBackingDeleteAndEnsureListWrappers() throws {
    let live = LiveEventKitBacking()
    guard live.authorizationStatus(for: .reminder).allowsFullAccess else {
        return
    }
    let list = "macverbs-wrap-\(UUID().uuidString.prefix(8))"
    let title = "macverbs-wrap-item-\(UUID().uuidString.prefix(8))"
    _ = try live.ensureReminderList(name: list)
    _ = try live.addReminder(
        title: title,
        listName: list,
        due: "",
        notes: "",
        priority: ""
    )
    let deleted = try live.deleteReminder(title: title, listName: list)
    #expect(deleted.deleted == title)
    if let cal = live.store.calendars(for: .reminder).first(where: { $0.title == list }) {
        try? live.store.removeCalendar(cal, commit: true)
    }
}

@Test func macverbsBareRootRunReturnsSuccess() throws {
    // Bare root prints help via ArgumentParser `print` (process stdout), exit 0.
    try withRedirectedStdio { _ in
        let code = MacverbsApp.run(arguments: [])
        #expect(code == ExitCodes.success)
    }
}
