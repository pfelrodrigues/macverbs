import ArgumentParser
import EventKit
import Foundation
import Testing

@testable import MacverbsCore

// MARK: - Calendar list

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

@Test func calendarFormatWhenAllDaySingleExclusiveEnd() {
    // Classic EventKit: end is midnight of the day after the event.
    let when = CalendarService.formatWhen(
        start: utcDate(2026, 7, 26),
        end: utcDate(2026, 7, 27),
        isAllDay: true,
        calendar: utcCalendar()
    )
    #expect(when == "2026-07-26")
}

@Test func calendarFormatWhenAllDaySingleSameDayEnd() {
    // Some EventKit stores report end on the same calendar day as start.
    // Subtracting one day would invert; clamp to start.
    let when = CalendarService.formatWhen(
        start: utcDate(2026, 7, 26),
        end: utcDate(2026, 7, 26),
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

// MARK: - Calendar add

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
