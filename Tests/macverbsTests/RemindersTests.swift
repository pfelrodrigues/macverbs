import ArgumentParser
import EventKit
import Foundation
import Testing

@testable import MacverbsCore

// MARK: - Reminders lists + list

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

// MARK: - Reminders add / done / delete

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

// MARK: - Reminders move / edit / mklist

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
