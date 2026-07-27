import ArgumentParser
import EventKit
import Foundation
import Testing

@testable import MacverbsCore

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
        #expect(error == .system("EventKit client not wired (Calendar, Reminders)"))
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
        automation: MockAutomationPermissionClient(),
        version: "0.1.0"
    )
    #expect(report.backends.eventKit.kind == EKEventStoreClient.kind)
    #expect(report.backends.eventKit.calendar == .fullAccess)
    #expect(report.backends.eventKit.reminders == .fullAccess)
    #expect(report.backends.appleEvents.mail == .authorized)
    #expect(report.backends.appleEvents.notes == .authorized)
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
