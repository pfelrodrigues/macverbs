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
///
/// Class so reminder mutation cycles update shared state after BackendClients injection.
final class MockEventStoreClient: EventStoreClient, @unchecked Sendable {
    var calendar: EventAuthorizationStatus = .notDetermined
    var reminders: EventAuthorizationStatus = .notDetermined
    var afterRequestCalendar: EventAuthorizationStatus = .denied
    var afterRequestReminders: EventAuthorizationStatus = .denied
    var requestError: Error?
    var dataError: Error?
    var saveError: Error?
    var calendars: [EventKitCalendarInfo] = []
    var eventInfos: [EventKitEventInfo] = []
    var reminderListInfos: [ReminderListInfo] = []
    var reminderItems: [ReminderItem] = []
    var saveLog: MockEventSaveLog?
    var defaultListName: String = "Work"

    init(
        calendar: EventAuthorizationStatus = .notDetermined,
        reminders: EventAuthorizationStatus = .notDetermined,
        afterRequestCalendar: EventAuthorizationStatus = .denied,
        afterRequestReminders: EventAuthorizationStatus = .denied,
        requestError: Error? = nil,
        dataError: Error? = nil,
        saveError: Error? = nil,
        calendars: [EventKitCalendarInfo] = [],
        eventInfos: [EventKitEventInfo] = [],
        reminderListInfos: [ReminderListInfo] = [],
        reminderItems: [ReminderItem] = [],
        saveLog: MockEventSaveLog? = nil,
        defaultListName: String = "Work"
    ) {
        self.calendar = calendar
        self.reminders = reminders
        self.afterRequestCalendar = afterRequestCalendar
        self.afterRequestReminders = afterRequestReminders
        self.requestError = requestError
        self.dataError = dataError
        self.saveError = saveError
        self.calendars = calendars
        self.eventInfos = eventInfos
        self.reminderListInfos = reminderListInfos
        self.reminderItems = reminderItems
        self.saveLog = saveLog
        self.defaultListName = defaultListName
    }

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
        try ensureKnownList(listName)
        return reminderItems.filter { $0.list == listName }
    }

    func addReminder(
        title: String,
        listName: String?,
        due: String,
        notes: String,
        priority: String
    ) throws -> ReminderCreated {
        if let dataError {
            throw dataError
        }
        let dueComponents = try ReminderFields.parseDue(due)
        _ = try ReminderFields.priorityValue(priority)
        let resolvedList = try resolveListName(listName)
        let dueStr = ReminderFields.dueString(from: dueComponents)
        let prioStr = priority.isEmpty ? "" : priority
        reminderItems.append(
            ReminderItem(
                title: title,
                due: dueStr,
                priority: prioStr,
                list: resolvedList,
                notes: notes
            )
        )
        let reported: String
        if let listName, !listName.isEmpty {
            reported = listName
        } else {
            reported = ReminderFields.defaultListLabel
        }
        return ReminderCreated(created: title, list: reported)
    }

    func completeReminder(title: String, listName: String?) throws -> ReminderDoneResult {
        if let dataError {
            throw dataError
        }
        let index = try findIncompleteIndex(title: title, listName: listName)
        reminderItems.remove(at: index)
        return ReminderDoneResult(done: title)
    }

    func deleteReminder(title: String, listName: String?) throws -> ReminderDeleted {
        if let dataError {
            throw dataError
        }
        let index = try findIncompleteIndex(title: title, listName: listName)
        reminderItems.remove(at: index)
        return ReminderDeleted(deleted: title)
    }

    func moveReminder(
        title: String,
        fromList: String,
        toList: String
    ) throws -> ReminderMoved {
        if let dataError {
            throw dataError
        }
        try ensureKnownList(fromList)
        try ensureKnownList(toList)
        guard
            let index = reminderItems.firstIndex(where: {
                $0.title == title && $0.list == fromList
            })
        else {
            throw MacverbsError.domain("reminder \(title) not found")
        }
        var item = reminderItems[index]
        item.list = toList
        reminderItems[index] = item
        return ReminderMoved(moved: title, from: fromList, to: toList)
    }

    func editReminder(
        title: String,
        listName: String?,
        due: String,
        priority: String,
        notes: String
    ) throws -> ReminderEdited {
        if let dataError {
            throw dataError
        }
        if due.isEmpty && priority.isEmpty && notes.isEmpty {
            throw MacverbsError.domain(
                "nothing to edit: provide --due, --priority, or --notes"
            )
        }
        let index = try findIncompleteIndex(title: title, listName: listName)
        var item = reminderItems[index]
        if !due.isEmpty {
            let dueComponents = try ReminderFields.parseDue(due)
            item.due = ReminderFields.dueString(from: dueComponents)
        }
        if !priority.isEmpty {
            _ = try ReminderFields.priorityValue(priority)
            item.priority = priority == "none" ? "" : priority
        }
        if !notes.isEmpty {
            item.notes = notes
        }
        reminderItems[index] = item
        return ReminderEdited(edited: title)
    }

    func ensureReminderList(name: String) throws -> ReminderListEnsured {
        if let dataError {
            throw dataError
        }
        let known = Set(reminderListInfos.map(\.name)).union(Set(reminderItems.map(\.list)))
        if !known.contains(name) {
            reminderListInfos.append(ReminderListInfo(name: name, pending: 0))
        }
        return ReminderListEnsured(list: name)
    }

    private func resolveListName(_ listName: String?) throws -> String {
        if let listName, !listName.isEmpty {
            try ensureKnownList(listName)
            return listName
        }
        if !defaultListName.isEmpty {
            return defaultListName
        }
        if let first = reminderListInfos.first?.name {
            return first
        }
        throw MacverbsError.domain("no reminder lists available")
    }

    private func ensureKnownList(_ listName: String) throws {
        let known = Set(reminderListInfos.map(\.name)).union(Set(reminderItems.map(\.list)))
        if !known.contains(listName) && listName != defaultListName {
            throw MacverbsError.domain("list \(listName) not found")
        }
    }

    private func findIncompleteIndex(title: String, listName: String?) throws -> Int {
        let resolved = try resolveListName(listName)
        guard
            let index = reminderItems.firstIndex(where: {
                $0.title == title && $0.list == resolved
            })
        else {
            throw MacverbsError.domain("reminder \(title) not found")
        }
        return index
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

    func addReminder(
        title: String,
        listName: String?,
        due: String,
        notes: String,
        priority: String
    ) throws -> ReminderCreated {
        _ = try ReminderFields.parseDue(due)
        _ = try ReminderFields.priorityValue(priority)
        let reported: String
        if let listName, !listName.isEmpty {
            let known = Set(reminderListInfos.map(\.name)).union(Set(reminderItems.map(\.list)))
            if !known.contains(listName) {
                throw MacverbsError.domain("list \(listName) not found")
            }
            reported = listName
        } else {
            reported = ReminderFields.defaultListLabel
        }
        return ReminderCreated(created: title, list: reported)
    }

    func completeReminder(title: String, listName: String?) throws -> ReminderDoneResult {
        if let listName, !listName.isEmpty {
            let known = Set(reminderListInfos.map(\.name)).union(Set(reminderItems.map(\.list)))
            if !known.contains(listName) {
                throw MacverbsError.domain("list \(listName) not found")
            }
        }
        let scope: [ReminderItem]
        if let listName, !listName.isEmpty {
            scope = reminderItems.filter { $0.list == listName }
        } else {
            scope = reminderItems
        }
        guard scope.contains(where: { $0.title == title }) else {
            throw MacverbsError.domain("reminder \(title) not found")
        }
        return ReminderDoneResult(done: title)
    }

    func deleteReminder(title: String, listName: String?) throws -> ReminderDeleted {
        if let listName, !listName.isEmpty {
            let known = Set(reminderListInfos.map(\.name)).union(Set(reminderItems.map(\.list)))
            if !known.contains(listName) {
                throw MacverbsError.domain("list \(listName) not found")
            }
        }
        let scope: [ReminderItem]
        if let listName, !listName.isEmpty {
            scope = reminderItems.filter { $0.list == listName }
        } else {
            scope = reminderItems
        }
        guard scope.contains(where: { $0.title == title }) else {
            throw MacverbsError.domain("reminder \(title) not found")
        }
        return ReminderDeleted(deleted: title)
    }

    func moveReminder(
        title: String,
        fromList: String,
        toList: String
    ) throws -> ReminderMoved {
        let known = Set(reminderListInfos.map(\.name)).union(Set(reminderItems.map(\.list)))
        if !known.contains(fromList) {
            throw MacverbsError.domain("list \(fromList) not found")
        }
        if !known.contains(toList) {
            throw MacverbsError.domain("list \(toList) not found")
        }
        guard reminderItems.contains(where: { $0.title == title && $0.list == fromList })
        else {
            throw MacverbsError.domain("reminder \(title) not found")
        }
        return ReminderMoved(moved: title, from: fromList, to: toList)
    }

    func editReminder(
        title: String,
        listName: String?,
        due: String,
        priority: String,
        notes: String
    ) throws -> ReminderEdited {
        if due.isEmpty && priority.isEmpty && notes.isEmpty {
            throw MacverbsError.domain(
                "nothing to edit: provide --due, --priority, or --notes"
            )
        }
        if !due.isEmpty {
            _ = try ReminderFields.parseDue(due)
        }
        if !priority.isEmpty {
            _ = try ReminderFields.priorityValue(priority)
        }
        if let listName, !listName.isEmpty {
            let known = Set(reminderListInfos.map(\.name)).union(Set(reminderItems.map(\.list)))
            if !known.contains(listName) {
                throw MacverbsError.domain("list \(listName) not found")
            }
        }
        let scope: [ReminderItem]
        if let listName, !listName.isEmpty {
            scope = reminderItems.filter { $0.list == listName }
        } else {
            scope = reminderItems
        }
        guard scope.contains(where: { $0.title == title }) else {
            throw MacverbsError.domain("reminder \(title) not found")
        }
        return ReminderEdited(edited: title)
    }

    func ensureReminderList(name: String) throws -> ReminderListEnsured {
        let known = Set(reminderListInfos.map(\.name))
        if !known.contains(name) {
            reminderListInfos.append(ReminderListInfo(name: name, pending: 0))
        }
        return ReminderListEnsured(list: name)
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
    let store = MockEventStoreClient(calendar: .fullAccess, reminders: .fullAccess)
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
    let store = MockEventStoreClient(
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
    #expect(mailHelp.contains("list"))
    #expect(mailHelp.contains("read"))
    #expect(mailHelp.contains("archive"))
    #expect(mailHelp.contains("delete"))
    #expect(mailHelp.contains("attachments"))
    #expect(mailHelp.contains("draft"))
    #expect(mailHelp.contains("compose"))
}

// MARK: - Mail list + read (T15)

@Test func mailScriptsListContainsInboxCandidatesAndLimit() {
    let s = MailScripts.list(account: "Work", limit: 5, mailbox: .inbox)
    #expect(s.contains("tell application \"Mail\""))
    #expect(s.contains("set boxNames to"))
    #expect(s.contains("INBOX"))
    #expect(s.contains("Caixa de Entrada"))
    #expect(s.contains("if n > 5 then set n to 5"))
    #expect(s.contains(#"(name of acct) is "Work""#))
    #expect(s.contains("message id of msg"))
    #expect(s.contains("rdFlag to \"read\""))
    #expect(s.contains("rdFlag to \"unread\""))
}

@Test func mailScriptsListArchiveUsesArchiveCandidates() {
    let s = MailScripts.list(account: "", limit: 20, mailbox: .archive)
    #expect(s.contains("[Gmail]/Todos os e-mails"))
    #expect(s.contains("[Gmail]/All Mail"))
    #expect(s.contains("Archive"))
    #expect(s.contains("Arquivo Morto"))
    // Empty account still emits the all-accounts filter form.
    #expect(s.contains(#"("" is "" or (name of acct) is "")"#))
}

@Test func mailScriptsReadSearchesInboxAndArchive() {
    let s = MailScripts.read(messageID: "abc@x", account: "")
    #expect(s.contains(#""abc@x""#))
    #expect(s.contains("__NOTFOUND__"))
    #expect(s.contains("INBOX"))
    #expect(s.contains("[Gmail]/Todos os e-mails"))
    #expect(s.contains("message id is"))
}

@Test func mailScriptsReadEscapesQuotesInMessageID() {
    let s = MailScripts.read(messageID: #"id"with"quote"#, account: "Acme")
    #expect(s.contains(#""id\"with\"quote""#))
    #expect(s.contains(#"(name of acct) is "Acme""#))
}

@Test func mailListParsesRecords() throws {
    let fs = AppleScript.fieldSeparator
    let rs = AppleScript.recordSeparator
    let out =
        "Work\(fs)Standup\(fs)Alice <a@x.com>\(fs)Sat\(fs)unread\(fs)<id1@x>\(rs)"
        + "Personal\(fs)Hi\(fs)Bob\(fs)Sun\(fs)read\(fs)<id2@x>\(rs)"
    let items = try Mail.list(runner: MockScriptRunner(stdout: out))
    #expect(
        items == [
            MailMessageItem(
                account: "Work",
                subject: "Standup",
                sender: "Alice <a@x.com>",
                date: "Sat",
                read: "unread",
                id: "<id1@x>"
            ),
            MailMessageItem(
                account: "Personal",
                subject: "Hi",
                sender: "Bob",
                date: "Sun",
                read: "read",
                id: "<id2@x>"
            ),
        ]
    )
}

@Test func mailListEmptyAndNegativeLimit() throws {
    #expect(try Mail.list(runner: MockScriptRunner(stdout: "")).isEmpty)
    do {
        _ = try Mail.list(limit: -1, runner: MockScriptRunner(stdout: ""))
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .domain("--limit must be >= 0"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func mailListPassesScriptOptionsToRunner() throws {
    let recorder = RecordingOsascriptProcess()
    recorder.result = OsascriptProcessResult(exitStatus: 0, stdout: "", stderr: "")
    let runner = OSAScriptRunner(process: recorder)
    _ = try Mail.list(account: "Acme", limit: 3, mailbox: .archive, runner: runner)
    #expect(recorder.scripts.count == 1)
    let s = recorder.scripts[0]
    #expect(s.contains(#"(name of acct) is "Acme""#))
    #expect(s.contains("if n > 3 then set n to 3"))
    #expect(s.contains("[Gmail]/All Mail"))
}

@Test func mailReadParsesBody() throws {
    let body = "De: a@x\nAssunto: Hi\nData: today\n\nHello"
    let result = try Mail.read(messageID: "mid", runner: MockScriptRunner(stdout: body))
    #expect(result == MailMessageBody(body: body))
}

@Test func mailReadNotFoundIsDomainError() {
    do {
        _ = try Mail.read(
            messageID: "<missing@x>",
            runner: MockScriptRunner(stdout: "__NOTFOUND__\n")
        )
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error == .domain("message <missing@x> not found"))
        #expect(error.processExitCode == ExitCodes.domain)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func mailFormatListText() {
    #expect(Mail.formatList([]) == "no messages.")
    let text = Mail.formatList([
        MailMessageItem(
            account: "Work",
            subject: "S",
            sender: "R",
            date: "d",
            read: "read",
            id: "1"
        )
    ])
    #expect(text == "[read] (Work) S | R | d | id:1")
}

@Test func mailFormatBodyText() {
    #expect(Mail.formatBody(MailMessageBody(body: "")) == "(empty)")
    #expect(Mail.formatBody(MailMessageBody(body: "hello")) == "hello")
}

@Test func mailListCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        let fs = AppleScript.fieldSeparator
        let rs = AppleScript.recordSeparator
        BackendClients.scriptRunner = MockScriptRunner(
            stdout: "Work\(fs)Subj\(fs)Sender\(fs)Date\(fs)unread\(fs)<m@x>\(rs)"
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["--json", "mail", "list", "--limit", "5"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(arr?.count == 1)
        #expect(arr?[0]["account"] as? String == "Work")
        #expect(arr?[0]["subject"] as? String == "Subj")
        #expect(arr?[0]["sender"] as? String == "Sender")
        #expect(arr?[0]["date"] as? String == "Date")
        #expect(arr?[0]["read"] as? String == "unread")
        #expect(arr?[0]["id"] as? String == "<m@x>")
        // Sorted keys: account, date, id, read, sender, subject
        if let accountRange = text.range(of: "\"account\""),
            let dateRange = text.range(of: "\"date\""),
            let idRange = text.range(of: "\"id\""),
            let readRange = text.range(of: "\"read\""),
            let senderRange = text.range(of: "\"sender\""),
            let subjectRange = text.range(of: "\"subject\"")
        {
            #expect(accountRange.lowerBound < dateRange.lowerBound)
            #expect(dateRange.lowerBound < idRange.lowerBound)
            #expect(idRange.lowerBound < readRange.lowerBound)
            #expect(readRange.lowerBound < senderRange.lowerBound)
            #expect(senderRange.lowerBound < subjectRange.lowerBound)
        } else {
            Issue.record("expected mail list JSON keys")
        }
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailListCommandTextOnStdout() throws {
    try withRedirectedStdio { pipes in
        let fs = AppleScript.fieldSeparator
        let rs = AppleScript.recordSeparator
        BackendClients.scriptRunner = MockScriptRunner(
            stdout: "Acme\(fs)S\(fs)R\(fs)d\(fs)read\(fs)1\(rs)"
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: ["mail", "list", "--mailbox", "archive", "--account", "Acme"]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("[read] (Acme) S | R | d | id:1"))
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailListCommandEmptyText() throws {
    try withRedirectedStdio { pipes in
        BackendClients.scriptRunner = MockScriptRunner(stdout: "")
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["mail", "list"])
        #expect(code == ExitCodes.success)
        let _out = try pipes.readOutput()
        #expect(_out.contains("no messages."))
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailReadCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        BackendClients.scriptRunner = MockScriptRunner(
            stdout: "De: a\nAssunto: b\n\nbody text"
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: ["--json", "mail", "read", "<id@x>", "--account", "Work"]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["body"] as? String == "De: a\nAssunto: b\n\nbody text")
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailReadCommandTextOnStdout() throws {
    try withRedirectedStdio { pipes in
        BackendClients.scriptRunner = MockScriptRunner(stdout: "plain body")
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["mail", "read", "mid-1"])
        #expect(code == ExitCodes.success)
        let _out = try pipes.readOutput()
        #expect(_out.contains("plain body"))
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailReadNotFoundExit1() throws {
    try withRedirectedStdio { pipes in
        BackendClients.scriptRunner = MockScriptRunner(stdout: "__NOTFOUND__")
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["mail", "read", "ghost"])
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("error: message ghost not found"))
        let _outEmpty = try pipes.readOutput()
        #expect(_outEmpty.isEmpty)
    }
}

@Test func mailListNegativeLimitExit1() throws {
    try withRedirectedStdio { pipes in
        BackendClients.scriptRunner = MockScriptRunner(stdout: "")
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["mail", "list", "--limit=-1"])
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("error: --limit must be >= 0"))
        let _outEmpty = try pipes.readOutput()
        #expect(_outEmpty.isEmpty)
    }
}

@Test func mailListInvalidMailboxUsageExit64() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.run(arguments: ["mail", "list", "--mailbox", "trash"])
        #expect(code == ExitCodes.usage)
        let _outEmpty = try pipes.readOutput()
        #expect(_outEmpty.isEmpty)
    }
}

// MARK: - Mail archive + delete (T16)

@Test func mailScriptsMoveArchiveUsesArchiveCandidatesAndRecount() {
    let s = MailScripts.move(
        account: "Work",
        ids: ["<a@x>", "<b@x>"],
        target: .archive
    )
    #expect(s.contains("tell application \"Mail\""))
    #expect(s.contains("[Gmail]/Todos os e-mails"))
    #expect(s.contains("Archive"))
    #expect(!s.contains("Itens Excluídos"))
    #expect(s.contains(#"(name of acct) is "Work""#))
    #expect(s.contains(#"{"<a@x>", "<b@x>"}"#))
    #expect(s.contains("set reqCount to (count of idList)"))
    #expect(s.contains("set remaining to"))
    #expect(s.contains("set matches to (messages of ib whose message id is ms)"))
    #expect(s.contains("repeat with m in matches"))
    #expect(s.contains("move m to tb"))
    #expect(s.contains("delay 1"))
}

@Test func mailScriptsMoveArchiveHasGmailGuard() {
    let s = MailScripts.move(account: "Acme", ids: ["<a@x>"], target: .archive)
    #expect(s.contains(MailScripts.archiveUnsupportedSentinel))
    #expect(
        s.contains(
            #"tbName contains "Todos os e-mails" or tbName contains "All Mail""#
        )
    )
}

@Test func mailScriptsMoveDeleteHasNoGmailGuardAndUsesTrash() {
    let s = MailScripts.move(account: "Personal", ids: ["<c@x>"], target: .delete)
    #expect(!s.contains(MailScripts.archiveUnsupportedSentinel))
    #expect(s.contains("[Gmail]/Lixeira"))
    #expect(s.contains("Itens Excluídos"))
    #expect(s.contains("Deleted Messages"))
    #expect(!s.contains("[Gmail]/Todos os e-mails"))
}

@Test func mailScriptsMoveEscapesQuotes() {
    let s = MailScripts.move(account: #"a"b"#, ids: [#"i"d"#], target: .archive)
    #expect(s.contains(#"(name of acct) is "a\"b""#))
    #expect(s.contains(#""i\"d""#))
}

@Test func mailMoveParsesCounts() throws {
    let fs = AppleScript.fieldSeparator
    let out = "2\(fs)2\(fs)0"
    let recorder = RecordingOsascriptProcess()
    recorder.result = OsascriptProcessResult(exitStatus: 0, stdout: out, stderr: "")
    let runner = OSAScriptRunner(process: recorder)
    let r = try Mail.move(
        account: "Work",
        ids: ["<a>", "<b>"],
        target: .archive,
        runner: runner
    )
    #expect(
        r
            == MailMoveResult(
                account: "Work",
                action: "archive",
                moved: 2,
                requested: 2,
                remaining: 0,
                unsupported: nil
            )
    )
    #expect(recorder.scripts.count == 1)
    #expect(recorder.scripts[0].contains(#"(name of acct) is "Work""#))
}

@Test func mailMoveReportsRemaining() throws {
    let fs = AppleScript.fieldSeparator
    let r = try Mail.move(
        account: "Personal",
        ids: ["<a>", "<b>"],
        target: .delete,
        runner: MockScriptRunner(stdout: "2\(fs)1\(fs)1")
    )
    #expect(r.moved == 1)
    #expect(r.remaining == 1)
    #expect(r.action == "delete")
    #expect(r.unsupported == nil)
}

@Test func mailMoveEmptyScriptOutputDefaultsToZeros() throws {
    let r = try Mail.move(
        account: "Personal",
        ids: ["<a>"],
        target: .archive,
        runner: MockScriptRunner(stdout: "")
    )
    #expect(r.requested == 0)
    #expect(r.moved == 0)
    #expect(r.remaining == 0)
}

@Test func mailMoveRequiresAccount() {
    do {
        _ = try Mail.move(
            account: "",
            ids: ["<a>"],
            target: .archive,
            runner: MockScriptRunner(stdout: "1\u{001F}1\u{001F}0")
        )
        Issue.record("expected domain error for empty account")
    } catch let error as MacverbsError {
        #expect(error == .domain("--account is required for archive/delete"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func mailMoveRequiresAtLeastOneId() {
    do {
        _ = try Mail.move(
            account: "Work",
            ids: [],
            target: .delete,
            runner: MockScriptRunner(stdout: "")
        )
        Issue.record("expected domain error for empty ids")
    } catch let error as MacverbsError {
        #expect(error == .domain("at least one message id is required"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func mailMoveArchiveGmailUnsupported() throws {
    let fs = AppleScript.fieldSeparator
    let out = "\(MailScripts.archiveUnsupportedSentinel)\(fs)[Gmail]/Todos os e-mails"
    let r = try Mail.archive(
        account: "Acme",
        ids: ["<a>", "<b>"],
        runner: MockScriptRunner(stdout: out)
    )
    #expect(r.moved == 0)
    #expect(r.remaining == 2)
    #expect(r.requested == 2)
    #expect(r.action == "archive")
    let reason = try #require(r.unsupported)
    #expect(reason.contains("Gmail"))
    #expect(reason.contains("Todos os e-mails"))
    #expect(reason.contains("not supported"))
}

@Test func mailFormatMoveText() {
    #expect(
        Mail.formatMove(
            MailMoveResult(
                account: "Work",
                action: "archive",
                moved: 3,
                requested: 3,
                remaining: 0,
                unsupported: nil
            )
        ) == "Work: 3/3 archived"
    )
    let partial = Mail.formatMove(
        MailMoveResult(
            account: "Personal",
            action: "delete",
            moved: 1,
            requested: 2,
            remaining: 1,
            unsupported: nil
        )
    )
    #expect(partial.contains("Personal: 1/2 deleted"))
    #expect(partial.contains("1 remaining in inbox"))
    let unsupported = Mail.formatMove(
        MailMoveResult(
            account: "Acme",
            action: "archive",
            moved: 0,
            requested: 1,
            remaining: 1,
            unsupported: "archive is not supported on this account (Gmail)"
        )
    )
    #expect(unsupported == "Acme: archive is not supported on this account (Gmail)")
    #expect(!unsupported.contains("archived"))
}

@Test func mailArchiveCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        let fs = AppleScript.fieldSeparator
        BackendClients.scriptRunner = MockScriptRunner(stdout: "1\(fs)1\(fs)0")
        defer { BackendClients.scriptRunner = OSAScriptRunner() }
        let code = MacverbsApp.run(
            arguments: ["--json", "mail", "archive", "<a>", "--account", "Work"]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(obj?["moved"] as? Int == 1)
        #expect(obj?["requested"] as? Int == 1)
        #expect(obj?["remaining"] as? Int == 0)
        #expect(obj?["account"] as? String == "Work")
        #expect(obj?["action"] as? String == "archive")
        #expect(obj?["unsupported"] == nil)
        // Sorted keys: account, action, moved, remaining, requested
        if let accountRange = text.range(of: "\"account\""),
            let actionRange = text.range(of: "\"action\""),
            let movedRange = text.range(of: "\"moved\"")
        {
            #expect(accountRange.lowerBound < actionRange.lowerBound)
            #expect(actionRange.lowerBound < movedRange.lowerBound)
        } else {
            Issue.record("expected archive JSON keys")
        }
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailArchiveCommandTextOnStdout() throws {
    try withRedirectedStdio { pipes in
        let fs = AppleScript.fieldSeparator
        BackendClients.scriptRunner = MockScriptRunner(stdout: "2\(fs)2\(fs)0")
        defer { BackendClients.scriptRunner = OSAScriptRunner() }
        let code = MacverbsApp.run(
            arguments: ["mail", "archive", "<a>", "<b>", "--account", "Work"]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("Work: 2/2 archived"))
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailDeleteCommandWithRemainingText() throws {
    try withRedirectedStdio { pipes in
        let fs = AppleScript.fieldSeparator
        BackendClients.scriptRunner = MockScriptRunner(stdout: "1\(fs)0\(fs)1")
        defer { BackendClients.scriptRunner = OSAScriptRunner() }
        let code = MacverbsApp.run(
            arguments: ["mail", "delete", "<a>", "--account", "Personal"]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("Personal: 0/1 deleted"))
        #expect(text.contains("remaining in inbox"))
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailArchiveRequiresAccountUsageExit64() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.run(arguments: ["mail", "archive", "<a>"])
        #expect(code == ExitCodes.usage)
        let _outEmpty = try pipes.readOutput()
        #expect(_outEmpty.isEmpty)
    }
}

@Test func mailDeleteRequiresAccountUsageExit64() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.run(arguments: ["mail", "delete", "<a>"])
        #expect(code == ExitCodes.usage)
        let _outEmpty = try pipes.readOutput()
        #expect(_outEmpty.isEmpty)
    }
}

@Test func mailArchiveGmailReportsUnsupported() throws {
    try withRedirectedStdio { pipes in
        let fs = AppleScript.fieldSeparator
        let out =
            "\(MailScripts.archiveUnsupportedSentinel)\(fs)[Gmail]/Todos os e-mails"
        BackendClients.scriptRunner = MockScriptRunner(stdout: out)
        defer { BackendClients.scriptRunner = OSAScriptRunner() }
        let code = MacverbsApp.run(
            arguments: ["mail", "archive", "<a>", "--account", "Acme"]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("not supported"))
        #expect(text.contains("Gmail"))
        #expect(!text.contains("archived"))
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailArchiveGmailUnsupportedJsonOmitsNullUnsupportedKeyShape() throws {
    try withRedirectedStdio { pipes in
        let fs = AppleScript.fieldSeparator
        let out =
            "\(MailScripts.archiveUnsupportedSentinel)\(fs)[Gmail]/All Mail"
        BackendClients.scriptRunner = MockScriptRunner(stdout: out)
        defer { BackendClients.scriptRunner = OSAScriptRunner() }
        let code = MacverbsApp.run(
            arguments: [
                "--json", "mail", "archive", "<a>", "--account", "Acme",
            ]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(obj?["moved"] as? Int == 0)
        #expect(obj?["remaining"] as? Int == 1)
        #expect(obj?["requested"] as? Int == 1)
        let unsupported = obj?["unsupported"] as? String
        #expect(unsupported?.contains("Gmail") == true)
        #expect(unsupported?.contains("All Mail") == true)
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

// MARK: - Mail attachments (T17)

@Test func mailScriptsAttachmentsSearchesInboxAndArchiveAndSaves() {
    let s = MailScripts.attachments(
        messageID: "<msg1@x>",
        destDir: "/tmp/dest",
        account: "Work"
    )
    #expect(s.contains("tell application \"Mail\""))
    #expect(s.contains("INBOX"))
    #expect(s.contains("Caixa de Entrada"))
    #expect(s.contains("[Gmail]/Todos os e-mails"))
    #expect(s.contains("[Gmail]/All Mail"))
    #expect(s.contains("mail attachments of msg"))
    #expect(s.contains("save att in (POSIX file destPath)"))
    #expect(s.contains(#"/tmp/dest"#))
    #expect(s.contains(#"<msg1@x>"#))
    #expect(s.contains(#"(name of acct) is "Work""#))
    #expect(s.contains("return \"__NOTFOUND__\""))
    #expect(s.contains("character id 30"))
}

@Test func mailScriptsAttachmentsEscapesQuotes() {
    let s = MailScripts.attachments(
        messageID: #"id"mid"#,
        destDir: #"/tmp/a"b"#,
        account: #"Ac"me"#
    )
    #expect(s.contains(#"message id is "id\"mid""#))
    #expect(s.contains(#""/tmp/a\"b""#))
    #expect(s.contains(#"(name of acct) is "Ac\"me""#))
}

@Test func mailAttachmentsParsesSavedNames() throws {
    let rs = AppleScript.recordSeparator
    let out = "foto.jpg\(rs)doc.pdf\(rs)"
    let r = try Mail.attachments(
        messageID: "msg1",
        destDir: "/tmp/dest",
        runner: MockScriptRunner(stdout: out)
    )
    #expect(
        r
            == MailAttachmentsResult(
                messageID: "msg1",
                destDir: "/tmp/dest",
                saved: ["foto.jpg", "doc.pdf"]
            )
    )
}

@Test func mailAttachmentsEmptySaved() throws {
    let r = try Mail.attachments(
        messageID: "msg1",
        destDir: "/tmp/dest",
        runner: MockScriptRunner(stdout: "")
    )
    #expect(r.saved.isEmpty)
    #expect(r.messageID == "msg1")
    #expect(r.destDir == "/tmp/dest")
}

@Test func mailAttachmentsNotFoundIsDomainError() {
    do {
        _ = try Mail.attachments(
            messageID: "ghost",
            destDir: "/tmp/dest",
            runner: MockScriptRunner(stdout: "__NOTFOUND__\n")
        )
        Issue.record("expected domain error for missing message")
    } catch let error as MacverbsError {
        #expect(error == .domain("message ghost not found"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func mailAttachmentsPassesAccountAndDestToRunner() throws {
    let recorder = RecordingOsascriptProcess()
    recorder.result = OsascriptProcessResult(exitStatus: 0, stdout: "", stderr: "")
    let runner = OSAScriptRunner(process: recorder)
    _ = try Mail.attachments(
        messageID: "mid",
        destDir: "/tmp/out",
        account: "Acme",
        runner: runner
    )
    #expect(recorder.scripts.count == 1)
    let s = recorder.scripts[0]
    #expect(s.contains(#"(name of acct) is "Acme""#))
    #expect(s.contains(#"/tmp/out"#))
    #expect(s.contains(#"message id is "mid""#))
}

@Test func mailFormatAttachmentsText() {
    #expect(
        Mail.formatAttachments(
            MailAttachmentsResult(messageID: "m", destDir: "/tmp", saved: [])
        ) == "no attachments."
    )
    let text = Mail.formatAttachments(
        MailAttachmentsResult(
            messageID: "m",
            destDir: "/tmp/dest",
            saved: ["foto.jpg", "doc.pdf"]
        )
    )
    #expect(text == "saved to /tmp/dest:\n- foto.jpg\n- doc.pdf")
}

@Test func mailAttachmentsCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        let rs = AppleScript.recordSeparator
        BackendClients.scriptRunner = MockScriptRunner(
            stdout: "foto.jpg\(rs)doc.pdf\(rs)"
        )
        defer { BackendClients.resetDefaults() }
        let code = MacverbsApp.run(
            arguments: [
                "--json", "mail", "attachments", "<msg1@x>",
                "--dest", "/tmp/dest", "--account", "Work",
            ]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(obj?["message_id"] as? String == "<msg1@x>")
        #expect(obj?["dest_dir"] as? String == "/tmp/dest")
        let saved = obj?["saved"] as? [String]
        #expect(saved == ["foto.jpg", "doc.pdf"])
        // Sorted keys: dest_dir, message_id, saved
        if let destRange = text.range(of: "\"dest_dir\""),
            let midRange = text.range(of: "\"message_id\""),
            let savedRange = text.range(of: "\"saved\"")
        {
            #expect(destRange.lowerBound < midRange.lowerBound)
            #expect(midRange.lowerBound < savedRange.lowerBound)
        } else {
            Issue.record("expected attachments JSON keys")
        }
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailAttachmentsCommandTextOnStdout() throws {
    try withRedirectedStdio { pipes in
        let rs = AppleScript.recordSeparator
        BackendClients.scriptRunner = MockScriptRunner(stdout: "a.pdf\(rs)")
        defer { BackendClients.resetDefaults() }
        let code = MacverbsApp.run(
            arguments: ["mail", "attachments", "mid-1", "--dest", "/tmp/out"]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("saved to /tmp/out:"))
        #expect(text.contains("- a.pdf"))
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailAttachmentsCommandEmptyText() throws {
    try withRedirectedStdio { pipes in
        BackendClients.scriptRunner = MockScriptRunner(stdout: "")
        defer { BackendClients.resetDefaults() }
        let code = MacverbsApp.run(
            arguments: ["mail", "attachments", "mid", "--dest", "/tmp/x"]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("no attachments."))
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailAttachmentsNotFoundExit1() throws {
    try withRedirectedStdio { pipes in
        BackendClients.scriptRunner = MockScriptRunner(stdout: "__NOTFOUND__")
        defer { BackendClients.resetDefaults() }
        let code = MacverbsApp.run(
            arguments: ["mail", "attachments", "ghost", "--dest", "/tmp/x"]
        )
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("error: message ghost not found"))
        let _outEmpty = try pipes.readOutput()
        #expect(_outEmpty.isEmpty)
    }
}

@Test func mailAttachmentsRequiresDestUsageExit64() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.run(arguments: ["mail", "attachments", "mid"])
        #expect(code == ExitCodes.usage)
        let _outEmpty = try pipes.readOutput()
        #expect(_outEmpty.isEmpty)
    }
}

// MARK: - Mail draft + compose (T18)

@Test func mailScriptsAsMultilineAndAddressList() {
    #expect(MailScripts.asMultiline("linha1\nlinha2") == #""linha1" & return & "linha2""#)
    #expect(MailScripts.asMultiline(#"a"b"#) == #""a\"b""#)
    #expect(MailScripts.addressList([]) == "{}")
    #expect(MailScripts.addressList(["a@x", #"b"c"#]) == #"{"a@x", "b\"c"}"#)
}

@Test func mailScriptsDraftReplyWithoutOpeningWindow() {
    let s = MailScripts.draftReply(
        messageID: "abc@x",
        body: "linha1\nlinha2",
        account: "Work"
    )
    #expect(s.contains("tell application \"Mail\""))
    #expect(s.contains("reply msg without opening window"))
    #expect(s.contains(#""linha1" & return & "linha2""#))
    #expect(s.contains(#"message id is "abc@x""#))
    #expect(s.contains(#"(name of acct) is "Work""#))
    #expect(s.contains("INBOX"))
    #expect(s.contains("[Gmail]/All Mail"))
    #expect(s.contains("return \"__NOTFOUND__\""))
    #expect(s.contains("save newMsg"))
    #expect(!s.contains("make new attachment"))
    #expect(!s.contains("send "))
    #expect(!s.contains(" with opening window"))
}

@Test func mailScriptsDraftReplyWithAttachmentsDelays() {
    let s = MailScripts.draftReply(
        messageID: "abc@x",
        body: "oi",
        account: "",
        attachments: ["/tmp/a.pdf", "/tmp/b.txt"]
    )
    #expect(s.components(separatedBy: "make new attachment").count - 1 == 2)
    #expect(s.contains(#"POSIX file "/tmp/a.pdf""#))
    #expect(s.contains(#"POSIX file "/tmp/b.txt""#))
    #expect(s.contains("at after the last paragraph"))
    #expect(s.components(separatedBy: "delay 1").count - 1 == 2)
    #expect(s.contains("tell content of newMsg"))
    #expect(s.contains("reply msg without opening window"))
}

@Test func mailScriptsComposeNewDraftNeverSends() {
    let s = MailScripts.compose(
        subject: "Assunto",
        body: "linha1\nlinha2",
        to: ["a@x"],
        cc: ["b@x"],
        account: "Work"
    )
    #expect(s.contains(#"subject:"Assunto""#))
    #expect(s.contains(#""linha1" & return & "linha2""#))
    #expect(s.contains(#"name of acct is "Work""#))
    #expect(s.contains(#"{"a@x"}"#))
    #expect(s.contains(#"{"b@x"}"#))
    #expect(s.contains("visible:true"))
    #expect(s.contains("save newMsg"))
    #expect(s.contains("return \"OK\""))
    #expect(!s.contains("send "))
}

@Test func mailScriptsComposeNoRecipientsNoAccount() {
    let s = MailScripts.compose(subject: "S", body: "b", to: [])
    #expect(s.contains(#"if "" is not """#))
    #expect(s.contains("to recipients"))
    #expect(s.contains("cc recipients"))
}

@Test func mailDraftParsesOkStatus() throws {
    let r = try Mail.draft(
        messageID: "msg1",
        body: "oi",
        runner: MockScriptRunner(stdout: "OK\n")
    )
    #expect(
        r
            == MailDraftResult(
                messageID: "msg1",
                status: "OK",
                attachments: []
            )
    )
}

@Test func mailDraftWithAttachmentsReturnsPaths() throws {
    let r = try Mail.draft(
        messageID: "msg1",
        body: "oi",
        attachments: ["/tmp/a.pdf"],
        runner: MockScriptRunner(stdout: "OK")
    )
    #expect(r.attachments == ["/tmp/a.pdf"])
    #expect(r.status == "OK")
}

@Test func mailDraftNotFoundIsDomainError() {
    do {
        _ = try Mail.draft(
            messageID: "ghost",
            body: "oi",
            runner: MockScriptRunner(stdout: "__NOTFOUND__")
        )
        Issue.record("expected domain error for missing message")
    } catch let error as MacverbsError {
        #expect(error == .domain("message ghost not found"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func mailComposeReturnsSubjectAndRecipients() throws {
    let r = try Mail.compose(
        subject: "S",
        body: "b",
        to: ["a@x"],
        cc: ["c@x"],
        account: "Work",
        runner: MockScriptRunner(stdout: "OK")
    )
    #expect(r == MailComposeResult(subject: "S", to: ["a@x"], cc: ["c@x"]))
}

@Test func mailComposeWithoutCc() throws {
    let r = try Mail.compose(
        subject: "S",
        body: "b",
        to: ["a@x"],
        runner: MockScriptRunner(stdout: "OK")
    )
    #expect(r.cc.isEmpty)
    #expect(r.to == ["a@x"])
}

@Test func mailFormatDraftAndComposeText() {
    #expect(
        Mail.formatDraft(
            MailDraftResult(messageID: "abc", status: "OK", attachments: [])
        ) == "draft created (reply to abc), not sent."
    )
    #expect(
        Mail.formatCompose(
            MailComposeResult(subject: "Assunto", to: ["a@x"], cc: ["c@x"])
        ) == "new draft created, not sent. Subject: Assunto | To: a@x, cc: c@x"
    )
    #expect(
        Mail.formatCompose(
            MailComposeResult(subject: "S", to: ["a@x"], cc: [])
        ) == "new draft created, not sent. Subject: S | To: a@x"
    )
}

@Test func mailDraftCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macverbs-draft-body-\(UUID().uuidString).txt")
        try "hello body".write(to: bodyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        BackendClients.scriptRunner = MockScriptRunner(stdout: "OK")
        defer { BackendClients.resetDefaults() }
        let code = MacverbsApp.run(
            arguments: [
                "--json", "mail", "draft", "<msg1@x>",
                "--body-file", bodyURL.path,
            ]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(obj?["message_id"] as? String == "<msg1@x>")
        #expect(obj?["status"] as? String == "OK")
        let atts = obj?["attachments"] as? [String]
        #expect(atts == [])
        // Sorted keys: attachments, message_id, status
        if let aRange = text.range(of: "\"attachments\""),
            let mRange = text.range(of: "\"message_id\""),
            let sRange = text.range(of: "\"status\"")
        {
            #expect(aRange.lowerBound < mRange.lowerBound)
            #expect(mRange.lowerBound < sRange.lowerBound)
        } else {
            Issue.record("expected draft JSON keys")
        }
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailDraftCommandTextWithAttach() throws {
    try withRedirectedStdio { pipes in
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macverbs-draft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bodyURL = tmp.appendingPathComponent("body.txt")
        let attURL = tmp.appendingPathComponent("anexo.pdf")
        try "oi".write(to: bodyURL, atomically: true, encoding: .utf8)
        try Data("x".utf8).write(to: attURL)

        let recorder = RecordingOsascriptProcess()
        recorder.result = OsascriptProcessResult(exitStatus: 0, stdout: "OK", stderr: "")
        BackendClients.scriptRunner = OSAScriptRunner(process: recorder)
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: [
                "mail", "draft", "abc",
                "--body-file", bodyURL.path,
                "--attach", attURL.path,
            ]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(text.contains("draft created (reply to abc), not sent."))
        #expect(recorder.scripts.count == 1)
        let s = recorder.scripts[0]
        #expect(s.contains("make new attachment"))
        #expect(s.contains("delay 1"))
        #expect(s.contains("reply msg without opening window"))
        #expect(s.contains(#"POSIX file "\(attURL.path)""#) || s.contains(attURL.path))
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailDraftAttachNotFoundExit1() throws {
    try withRedirectedStdio { pipes in
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macverbs-draft-body-\(UUID().uuidString).txt")
        try "oi".write(to: bodyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let code = MacverbsApp.run(
            arguments: [
                "mail", "draft", "abc",
                "--body-file", bodyURL.path,
                "--attach", "/tmp/nao-existe-macverbs-xyz.pdf",
            ]
        )
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("attachment(s) not found"))
        let _outEmpty = try pipes.readOutput()
        #expect(_outEmpty.isEmpty)
    }
}

@Test func mailDraftMissingBodyFileExit1() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.run(
            arguments: [
                "mail", "draft", "abc",
                "--body-file", "/tmp/does-not-exist-macverbs-xyz.txt",
            ]
        )
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("could not read --body-file"))
        let _outEmpty = try pipes.readOutput()
        #expect(_outEmpty.isEmpty)
    }
}

@Test func mailDraftRequiresBodyFileUsageExit64() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.run(arguments: ["mail", "draft", "abc"])
        #expect(code == ExitCodes.usage)
        let _outEmpty = try pipes.readOutput()
        #expect(_outEmpty.isEmpty)
    }
}

@Test func mailDraftNotFoundExit1() throws {
    try withRedirectedStdio { pipes in
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macverbs-draft-body-\(UUID().uuidString).txt")
        try "oi".write(to: bodyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        BackendClients.scriptRunner = MockScriptRunner(stdout: "__NOTFOUND__")
        defer { BackendClients.resetDefaults() }
        let code = MacverbsApp.run(
            arguments: ["mail", "draft", "ghost", "--body-file", bodyURL.path]
        )
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("error: message ghost not found"))
        let _outEmpty = try pipes.readOutput()
        #expect(_outEmpty.isEmpty)
    }
}

@Test func mailComposeCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macverbs-compose-body-\(UUID().uuidString).txt")
        try "oi".write(to: bodyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        BackendClients.scriptRunner = MockScriptRunner(stdout: "OK")
        defer { BackendClients.resetDefaults() }
        let code = MacverbsApp.run(
            arguments: [
                "--json", "mail", "compose",
                "--subject", "Assunto",
                "--body-file", bodyURL.path,
                "--to", "a@x",
                "--cc", "c@x",
            ]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(obj?["subject"] as? String == "Assunto")
        #expect(obj?["to"] as? [String] == ["a@x"])
        #expect(obj?["cc"] as? [String] == ["c@x"])
        // Sorted keys: cc, subject, to
        if let ccRange = text.range(of: "\"cc\""),
            let subRange = text.range(of: "\"subject\""),
            let toRange = text.range(of: "\"to\"")
        {
            #expect(ccRange.lowerBound < subRange.lowerBound)
            #expect(subRange.lowerBound < toRange.lowerBound)
        } else {
            Issue.record("expected compose JSON keys")
        }
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailComposeCommandTextOnStdout() throws {
    try withRedirectedStdio { pipes in
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macverbs-compose-body-\(UUID().uuidString).txt")
        try "oi".write(to: bodyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let recorder = RecordingOsascriptProcess()
        recorder.result = OsascriptProcessResult(exitStatus: 0, stdout: "OK", stderr: "")
        BackendClients.scriptRunner = OSAScriptRunner(process: recorder)
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: [
                "mail", "compose",
                "--subject", "Assunto",
                "--body-file", bodyURL.path,
                "--to", "a@x",
                "--cc", "c@x",
            ]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        #expect(
            text.contains("Assunto: Assunto | To: a@x, cc: c@x")
                || text.contains("Subject: Assunto | To: a@x, cc: c@x")
        )
        #expect(recorder.scripts.count == 1)
        let s = recorder.scripts[0]
        #expect(s.contains("save newMsg"))
        #expect(!s.contains("send "))
        let _errEmpty = try pipes.readError()
        #expect(_errEmpty.isEmpty)
    }
}

@Test func mailComposeMissingBodyFileExit1() throws {
    try withRedirectedStdio { pipes in
        let code = MacverbsApp.run(
            arguments: [
                "mail", "compose",
                "--subject", "S",
                "--body-file", "/tmp/does-not-exist-macverbs-xyz.txt",
            ]
        )
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("could not read --body-file"))
        let _outEmpty = try pipes.readOutput()
        #expect(_outEmpty.isEmpty)
    }
}

@Test func mailComposeRequiresSubjectAndBodyFileUsageExit64() throws {
    try withRedirectedStdio { pipes in
        let code1 = MacverbsApp.run(
            arguments: ["mail", "compose", "--body-file", "x"]
        )
        #expect(code1 == ExitCodes.usage)
        let code2 = MacverbsApp.run(
            arguments: ["mail", "compose", "--subject", "S"]
        )
        #expect(code2 == ExitCodes.usage)
        let _ = try pipes.readOutput()
        let _ = try pipes.readError()
    }
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
    let mock = MockEventStoreClient(calendar: .fullAccess, reminders: .fullAccess)
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
        let mock = MockEventStoreClient(calendar: .fullAccess, reminders: .fullAccess)
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
        let mock = MockEventStoreClient(calendar: .fullAccess, reminders: .fullAccess)
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
        let mock = MockEventStoreClient(calendar: .fullAccess, reminders: .fullAccess)
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
        let mock = MockEventStoreClient(calendar: .fullAccess, reminders: .fullAccess)
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
    #expect(remHelp.contains("add"))
    #expect(remHelp.contains("done"))
    #expect(remHelp.contains("move"))
    #expect(remHelp.contains("edit"))
    #expect(remHelp.contains("mklist"))
    #expect(remHelp.contains("delete"))
}

// MARK: - Reminders add / done / delete (T10)

@Test func reminderPriorityValueMapping() throws {
    #expect(try ReminderFields.priorityValue("") == 0)
    #expect(try ReminderFields.priorityValue("none") == 0)
    #expect(try ReminderFields.priorityValue("high") == 1)
    #expect(try ReminderFields.priorityValue("medium") == 5)
    #expect(try ReminderFields.priorityValue("low") == 9)
    do {
        _ = try ReminderFields.priorityValue("urgent")
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error.message.contains("invalid priority"))
        #expect(error.processExitCode == ExitCodes.domain)
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Test func reminderParseDueFormats() throws {
    #expect(try ReminderFields.parseDue("") == nil)
    let dateOnly = try ReminderFields.parseDue("2026-07-06")
    #expect(dateOnly?.year == 2026)
    #expect(dateOnly?.month == 7)
    #expect(dateOnly?.day == 6)
    #expect(dateOnly?.hour == 9)
    #expect(dateOnly?.minute == 0)
    let withTime = try ReminderFields.parseDue("2026-07-06 14:30")
    #expect(withTime?.hour == 14)
    #expect(withTime?.minute == 30)
    do {
        _ = try ReminderFields.parseDue("07/06/2026")
        Issue.record("expected throw")
    } catch let error as MacverbsError {
        #expect(error.message.contains("invalid due"))
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Test func remindersFormatMutationResults() {
    #expect(
        RemindersFormat.created(ReminderCreated(created: "Ship", list: "Work"))
            == "created: Ship"
    )
    #expect(RemindersFormat.done(ReminderDoneResult(done: "Ship")) == "done: Ship")
    #expect(
        RemindersFormat.deleted(ReminderDeleted(deleted: "Ship")) == "deleted: Ship"
    )
}

@Test func mockReminderAddDoneCycleByTitleAndList() throws {
    let mock = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        reminderListInfos: [
            ReminderListInfo(name: "Work", pending: 0),
            ReminderListInfo(name: "Personal", pending: 0),
        ]
    )
    let created = try mock.addReminder(
        title: "Standup prep",
        listName: "Work",
        due: "2026-07-06 14:30",
        notes: "bring laptop",
        priority: "high"
    )
    #expect(created == ReminderCreated(created: "Standup prep", list: "Work"))
    #expect(try mock.incompleteReminders(listName: "Work").count == 1)
    #expect(try mock.incompleteReminders(listName: "Personal").isEmpty)

    _ = try mock.addReminder(
        title: "Standup prep",
        listName: "Personal",
        due: "",
        notes: "",
        priority: ""
    )
    let done = try mock.completeReminder(title: "Standup prep", listName: "Work")
    #expect(done == ReminderDoneResult(done: "Standup prep"))
    #expect(try mock.incompleteReminders(listName: "Work").isEmpty)
    #expect(try mock.incompleteReminders(listName: "Personal").count == 1)
}

@Test func mockReminderAddDeleteCycleByTitleAndList() throws {
    let mock = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        reminderListInfos: [ReminderListInfo(name: "Work", pending: 0)]
    )
    _ = try mock.addReminder(
        title: "Temp task",
        listName: "Work",
        due: "2026-07-06",
        notes: "x",
        priority: "low"
    )
    #expect(try mock.incompleteReminders(listName: "Work").count == 1)
    let deleted = try mock.deleteReminder(title: "Temp task", listName: "Work")
    #expect(deleted == ReminderDeleted(deleted: "Temp task"))
    #expect(try mock.incompleteReminders(listName: "Work").isEmpty)
}

@Test func mockReminderMatchRequiresExactTitleInList() throws {
    let mock = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        reminderListInfos: [ReminderListInfo(name: "Work", pending: 1)],
        reminderItems: [
            ReminderItem(
                title: "Buy milk",
                due: "",
                priority: "",
                list: "Work",
                notes: ""
            )
        ]
    )
    do {
        _ = try mock.completeReminder(title: "buy milk", listName: "Work")
        Issue.record("expected throw for case mismatch")
    } catch let error as MacverbsError {
        #expect(error == .domain("reminder buy milk not found"))
    } catch {
        Issue.record("unexpected \(error)")
    }
    do {
        _ = try mock.deleteReminder(title: "Buy milk", listName: "Acme")
        Issue.record("expected throw for missing list")
    } catch let error as MacverbsError {
        #expect(error == .domain("list Acme not found"))
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Test func mockReminderAddDefaultListLabel() throws {
    let mock = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        reminderListInfos: [ReminderListInfo(name: "Work", pending: 0)],
        defaultListName: "Work"
    )
    let created = try mock.addReminder(
        title: "No list flag",
        listName: nil,
        due: "",
        notes: "",
        priority: ""
    )
    #expect(created.list == ReminderFields.defaultListLabel)
    #expect(mock.reminderItems[0].list == "Work")
}

@Test func stubReminderMutationsThrowSystem() {
    let stub = StubEventStoreClient()
    #expect(throws: MacverbsError.self) {
        try stub.addReminder(
            title: "T",
            listName: nil,
            due: "",
            notes: "",
            priority: ""
        )
    }
    #expect(throws: MacverbsError.self) {
        try stub.completeReminder(title: "T", listName: nil)
    }
    #expect(throws: MacverbsError.self) {
        try stub.deleteReminder(title: "T", listName: nil)
    }
    #expect(throws: MacverbsError.self) {
        try stub.moveReminder(title: "T", fromList: "A", toList: "B")
    }
    #expect(throws: MacverbsError.self) {
        try stub.editReminder(
            title: "T",
            listName: nil,
            due: "2026-07-06",
            priority: "",
            notes: ""
        )
    }
    #expect(throws: MacverbsError.self) {
        try stub.ensureReminderList(name: "Work")
    }
}

@Test func remindersAddCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: [ReminderListInfo(name: "Work", pending: 0)]
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: [
                "--json", "reminders", "add", "Ship",
                "--list", "Work",
                "--due", "2026-07-06 14:30",
                "--notes", "tag:release",
                "--priority", "high",
            ]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["created"] as? String == "Ship")
        #expect(obj?["list"] as? String == "Work")
        let err = try pipes.readError()
        #expect(err.isEmpty)
        #expect(mock.reminderItems.count == 1)
        #expect(mock.reminderItems[0].priority == "high")
        #expect(mock.reminderItems[0].notes == "tag:release")
    }
}

@Test func remindersDoneCommandJsonAndRemovesItem() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: [ReminderListInfo(name: "Work", pending: 1)],
            reminderItems: [
                ReminderItem(
                    title: "Ship",
                    due: "",
                    priority: "",
                    list: "Work",
                    notes: ""
                )
            ]
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: ["--json", "reminders", "done", "Ship", "--list", "Work"]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["done"] as? String == "Ship")
        #expect(mock.reminderItems.isEmpty)
        let err = try pipes.readError()
        #expect(err.isEmpty)
    }
}

@Test func remindersDeleteCommandTextAndRemovesItem() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: [ReminderListInfo(name: "Personal", pending: 1)],
            reminderItems: [
                ReminderItem(
                    title: "Temp",
                    due: "",
                    priority: "",
                    list: "Personal",
                    notes: ""
                )
            ]
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: ["reminders", "delete", "Temp", "--list", "Personal"]
        )
        #expect(code == ExitCodes.success)
        let out = try pipes.readOutput()
        #expect(out.contains("deleted: Temp"))
        #expect(mock.reminderItems.isEmpty)
        let err = try pipes.readError()
        #expect(err.isEmpty)
    }
}

@Test func remindersDoneNotFoundExit1() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: [ReminderListInfo(name: "Work", pending: 0)]
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: ["reminders", "done", "Missing", "--list", "Work"]
        )
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("error: reminder Missing not found"))
        let out = try pipes.readOutput()
        #expect(out.isEmpty)
    }
}

@Test func remindersAddMissingListExit1() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: [ReminderListInfo(name: "Work", pending: 0)]
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: ["reminders", "add", "X", "--list", "Acme"]
        )
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("error: list Acme not found"))
        let out = try pipes.readOutput()
        #expect(out.isEmpty)
    }
}

@Test func remindersAddInvalidDueExit1() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: [ReminderListInfo(name: "Work", pending: 0)]
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: ["reminders", "add", "X", "--list", "Work", "--due", "soon"]
        )
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("invalid due"))
        let out = try pipes.readOutput()
        #expect(out.isEmpty)
    }
}

@Test func remindersAddInvalidPriorityExit1() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: [ReminderListInfo(name: "Work", pending: 0)]
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: [
                "reminders", "add", "X", "--list", "Work", "--priority", "urgent",
            ]
        )
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("invalid priority"))
        let out = try pipes.readOutput()
        #expect(out.isEmpty)
    }
}

@Test func remindersCliAddDoneCycle() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: [ReminderListInfo(name: "Work", pending: 0)]
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let addCode = MacverbsApp.run(
            arguments: ["--json", "reminders", "add", "Cycle", "--list", "Work"]
        )
        #expect(addCode == ExitCodes.success)
        #expect(mock.reminderItems.count == 1)

        let doneCode = MacverbsApp.run(
            arguments: ["--json", "reminders", "done", "Cycle", "--list", "Work"]
        )
        #expect(doneCode == ExitCodes.success)
        #expect(mock.reminderItems.isEmpty)
        let out = try pipes.readOutput()
        #expect(out.contains("\"created\""))
        #expect(out.contains("\"done\""))
    }
}

@Test func remindersCliAddDeleteCycle() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: [ReminderListInfo(name: "Work", pending: 0)]
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let addCode = MacverbsApp.run(
            arguments: ["reminders", "add", "CycleDel", "--list", "Work"]
        )
        #expect(addCode == ExitCodes.success)
        #expect(mock.reminderItems.count == 1)
        let deleteCode = MacverbsApp.run(
            arguments: ["reminders", "delete", "CycleDel", "--list", "Work"]
        )
        #expect(deleteCode == ExitCodes.success)
        #expect(mock.reminderItems.isEmpty)
        let out = try pipes.readOutput()
        #expect(out.contains("created: CycleDel"))
        #expect(out.contains("deleted: CycleDel"))
    }
}

// MARK: - Reminders move / edit / mklist (T11)

@Test func remindersFormatMoveEditMklistResults() {
    #expect(
        RemindersFormat.moved(
            ReminderMoved(moved: "Ship", from: "Work", to: "Personal")
        ) == "moved: Ship (Work → Personal)"
    )
    #expect(RemindersFormat.edited(ReminderEdited(edited: "Ship")) == "edited: Ship")
    #expect(
        RemindersFormat.listEnsured(ReminderListEnsured(list: "Acme"))
            == "list ensured: Acme"
    )
}

@Test func mockReminderMoveBetweenLists() throws {
    let mock = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        reminderListInfos: [
            ReminderListInfo(name: "Work", pending: 1),
            ReminderListInfo(name: "Personal", pending: 0),
        ],
        reminderItems: [
            ReminderItem(
                title: "Standup prep",
                due: "2026-07-06 14:30",
                priority: "high",
                list: "Work",
                notes: "bring laptop"
            )
        ]
    )
    let moved = try mock.moveReminder(
        title: "Standup prep",
        fromList: "Work",
        toList: "Personal"
    )
    #expect(moved == ReminderMoved(moved: "Standup prep", from: "Work", to: "Personal"))
    #expect(try mock.incompleteReminders(listName: "Work").isEmpty)
    let personal = try mock.incompleteReminders(listName: "Personal")
    #expect(personal.count == 1)
    #expect(personal[0].title == "Standup prep")
    #expect(personal[0].priority == "high")
}

@Test func mockReminderMoveMissingReminderOrList() throws {
    let mock = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        reminderListInfos: [
            ReminderListInfo(name: "Work", pending: 0),
            ReminderListInfo(name: "Personal", pending: 0),
        ]
    )
    do {
        _ = try mock.moveReminder(title: "Missing", fromList: "Work", toList: "Personal")
        Issue.record("expected throw for missing reminder")
    } catch let error as MacverbsError {
        #expect(error == .domain("reminder Missing not found"))
    } catch {
        Issue.record("unexpected \(error)")
    }
    do {
        _ = try mock.moveReminder(title: "X", fromList: "Acme", toList: "Work")
        Issue.record("expected throw for missing source list")
    } catch let error as MacverbsError {
        #expect(error == .domain("list Acme not found"))
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Test func mockReminderEditDuePriorityNotes() throws {
    let mock = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        reminderListInfos: [ReminderListInfo(name: "Work", pending: 1)],
        reminderItems: [
            ReminderItem(
                title: "Standup prep",
                due: "",
                priority: "high",
                list: "Work",
                notes: "old"
            )
        ]
    )
    let edited = try mock.editReminder(
        title: "Standup prep",
        listName: "Work",
        due: "2026-07-20 09:00",
        priority: "medium",
        notes: "updated context"
    )
    #expect(edited == ReminderEdited(edited: "Standup prep"))
    let item = mock.reminderItems[0]
    #expect(item.due == "2026-07-20 09:00")
    #expect(item.priority == "medium")
    #expect(item.notes == "updated context")

    _ = try mock.editReminder(
        title: "Standup prep",
        listName: "Work",
        due: "",
        priority: "none",
        notes: ""
    )
    #expect(mock.reminderItems[0].priority == "")
}

@Test func mockReminderEditRequiresChange() throws {
    let mock = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        reminderListInfos: [ReminderListInfo(name: "Work", pending: 1)],
        reminderItems: [
            ReminderItem(
                title: "Ship",
                due: "",
                priority: "",
                list: "Work",
                notes: ""
            )
        ]
    )
    do {
        _ = try mock.editReminder(
            title: "Ship",
            listName: "Work",
            due: "",
            priority: "",
            notes: ""
        )
        Issue.record("expected throw when nothing to edit")
    } catch let error as MacverbsError {
        #expect(error.message.contains("nothing to edit"))
        #expect(error.processExitCode == ExitCodes.domain)
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Test func mockReminderMklistIdempotent() throws {
    let mock = MockEventStoreClient(
        calendar: .fullAccess,
        reminders: .fullAccess,
        reminderListInfos: [ReminderListInfo(name: "Work", pending: 0)]
    )
    let first = try mock.ensureReminderList(name: "Acme")
    #expect(first == ReminderListEnsured(list: "Acme"))
    #expect(mock.reminderListInfos.map(\.name).contains("Acme"))
    let countAfterCreate = mock.reminderListInfos.count
    let second = try mock.ensureReminderList(name: "Acme")
    #expect(second == ReminderListEnsured(list: "Acme"))
    #expect(mock.reminderListInfos.count == countAfterCreate)
    let existing = try mock.ensureReminderList(name: "Work")
    #expect(existing == ReminderListEnsured(list: "Work"))
}

@Test func remindersMoveCommandJsonOnStdout() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: [
                ReminderListInfo(name: "Work", pending: 1),
                ReminderListInfo(name: "Personal", pending: 0),
            ],
            reminderItems: [
                ReminderItem(
                    title: "Ship",
                    due: "",
                    priority: "",
                    list: "Work",
                    notes: ""
                )
            ]
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: [
                "--json", "reminders", "move", "Ship",
                "--from", "Work",
                "--to", "Personal",
            ]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["moved"] as? String == "Ship")
        #expect(obj?["from"] as? String == "Work")
        #expect(obj?["to"] as? String == "Personal")
        #expect(mock.reminderItems[0].list == "Personal")
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func remindersEditCommandJsonAndUpdatesItem() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: [ReminderListInfo(name: "Work", pending: 1)],
            reminderItems: [
                ReminderItem(
                    title: "Ship",
                    due: "",
                    priority: "high",
                    list: "Work",
                    notes: ""
                )
            ]
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: [
                "--json", "reminders", "edit", "Ship",
                "--list", "Work",
                "--due", "2026-07-20 09:00",
                "--priority", "low",
                "--notes", "ship notes",
            ]
        )
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["edited"] as? String == "Ship")
        #expect(mock.reminderItems[0].due == "2026-07-20 09:00")
        #expect(mock.reminderItems[0].priority == "low")
        #expect(mock.reminderItems[0].notes == "ship notes")
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func remindersEditCommandNothingToEditExit1() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: [ReminderListInfo(name: "Work", pending: 1)],
            reminderItems: [
                ReminderItem(
                    title: "Ship",
                    due: "",
                    priority: "",
                    list: "Work",
                    notes: ""
                )
            ]
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: ["reminders", "edit", "Ship", "--list", "Work"]
        )
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("nothing to edit"))
        #expect(try pipes.readOutput().isEmpty)
    }
}

@Test func remindersMklistCommandJsonIdempotent() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: [ReminderListInfo(name: "Work", pending: 0)]
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code1 = MacverbsApp.run(
            arguments: ["--json", "reminders", "mklist", "Acme"]
        )
        #expect(code1 == ExitCodes.success)
        let code2 = MacverbsApp.run(
            arguments: ["--json", "reminders", "mklist", "Acme"]
        )
        #expect(code2 == ExitCodes.success)
        #expect(mock.reminderListInfos.filter { $0.name == "Acme" }.count == 1)
        let text = try pipes.readOutput()
        #expect(text.contains("\"list\""))
        #expect(text.contains("Acme"))
        #expect(try pipes.readError().isEmpty)
    }
}

@Test func remindersMklistCommandText() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: []
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["reminders", "mklist", "Personal"])
        #expect(code == ExitCodes.success)
        let out = try pipes.readOutput()
        #expect(out.contains("list ensured: Personal"))
        let err = try pipes.readError()
        #expect(err.isEmpty)
    }
}

@Test func remindersMoveCommandMissingExit1() throws {
    try withRedirectedStdio { pipes in
        let mock = MockEventStoreClient(
            calendar: .fullAccess,
            reminders: .fullAccess,
            reminderListInfos: [
                ReminderListInfo(name: "Work", pending: 0),
                ReminderListInfo(name: "Personal", pending: 0),
            ]
        )
        BackendClients.eventStore = mock
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(
            arguments: [
                "reminders", "move", "Missing",
                "--from", "Work",
                "--to", "Personal",
            ]
        )
        #expect(code == ExitCodes.domain)
        let err = try pipes.readError()
        #expect(err.contains("reminder Missing not found"))
        let out = try pipes.readOutput()
        #expect(out.isEmpty)
    }
}

@Test func ekClientDelegatesMoveEditMklistToFakeBacking() throws {
    let fake = FakeEventKitBacking(
        calendar: .fullAccess,
        reminders: .fullAccess,
        reminderListInfos: [
            ReminderListInfo(name: "Work", pending: 1),
            ReminderListInfo(name: "Personal", pending: 0),
        ],
        reminderItems: [
            ReminderItem(
                title: "Ship",
                due: "",
                priority: "",
                list: "Work",
                notes: ""
            )
        ]
    )
    let client = EKEventStoreClient(backing: fake)
    let moved = try client.moveReminder(
        title: "Ship",
        fromList: "Work",
        toList: "Personal"
    )
    #expect(moved.moved == "Ship")
    let edited = try client.editReminder(
        title: "Ship",
        listName: "Work",
        due: "2026-07-06",
        priority: "",
        notes: ""
    )
    #expect(edited.edited == "Ship")
    let ensured = try client.ensureReminderList(name: "Acme")
    #expect(ensured.list == "Acme")
    #expect(fake.reminderListInfos.map(\.name).contains("Acme"))
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
