import ArgumentParser
import EventKit
import Foundation
import Testing

@testable import MacverbsCore

// MARK: - Test doubles

/// One recorded `saveEvent` call for mock verification.
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

/// Captures scripts passed to `run` for CLI flag checks (never runs osascript).
final class RecordingScriptRunner: ScriptRunner, @unchecked Sendable {
    var stdout: String = ""
    var error: Error?
    private(set) var scripts: [String] = []

    init(stdout: String = "", error: Error? = nil) {
        self.stdout = stdout
        self.error = error
    }

    func run(script: String, timeout: TimeInterval) throws -> String {
        scripts.append(script)
        if let error {
            throw error
        }
        return stdout
    }
}
