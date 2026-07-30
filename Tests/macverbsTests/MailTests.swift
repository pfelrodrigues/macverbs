import ArgumentParser
import EventKit
import Foundation
import Testing

@testable import MacverbsCore

// MARK: - Mail accounts + unread

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
    #expect(s.contains("set output to output & (name of acct) & fs & (u as text) & rs"))
}

/// Regression #17: fully-read accounts must appear as `unread: 0`, not be dropped.
/// Empty JSON must mean "no accounts", never "all inboxes are clean".
@Test func mailScriptsUnreadNeverFiltersZeroAccounts() {
    let s = MailScripts.unread()
    #expect(!s.contains("if u > 0 then"))
    #expect(!s.contains("if u > 0"))
    // Row is appended unconditionally after summing mailboxes.
    #expect(s.contains("set output to output & (name of acct) & fs & (u as text) & rs"))
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

/// Regression #17: mixed zero / non-zero rows stay in the parse result.
@Test func mailUnreadParsesZeroAlongsidePositive() throws {
    let fs = AppleScript.fieldSeparator
    let rs = AppleScript.recordSeparator
    let out = "Work\(fs)0\(rs)Personal\(fs)3\(rs)Acme\(fs)0\(rs)"
    let items = try Mail.unread(runner: MockScriptRunner(stdout: out))
    #expect(
        items == [
            MailUnreadCount(account: "Work", unread: 0),
            MailUnreadCount(account: "Personal", unread: 3),
            MailUnreadCount(account: "Acme", unread: 0),
        ]
    )
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
    let withZero = Mail.formatUnread([
        MailUnreadCount(account: "Work", unread: 0),
        MailUnreadCount(account: "Personal", unread: 2),
    ])
    #expect(withZero.contains("Work: 0 unread"))
    #expect(withZero.contains("Personal: 2 unread"))
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

/// Regression #17: CLI JSON keeps accounts with unread 0 (agents size inboxes from this).
@Test func mailUnreadCommandJsonIncludesZeroAccounts() throws {
    try withRedirectedStdio { pipes in
        let fs = AppleScript.fieldSeparator
        let rs = AppleScript.recordSeparator
        BackendClients.scriptRunner = MockScriptRunner(
            stdout: "Work\(fs)0\(rs)Personal\(fs)2\(rs)"
        )
        defer { BackendClients.resetDefaults() }

        let code = MacverbsApp.run(arguments: ["--json", "mail", "unread"])
        #expect(code == ExitCodes.success)
        let text = try pipes.readOutput()
        let arr = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]
        #expect(arr?.count == 2)
        #expect(arr?[0]["account"] as? String == "Work")
        #expect(arr?[0]["unread"] as? Int == 0)
        #expect(arr?[1]["account"] as? String == "Personal")
        #expect(arr?[1]["unread"] as? Int == 2)
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

// MARK: - Mail list + read

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

// MARK: - Mail archive + delete

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

/// Regression #16: post-move verify must be one inbox walk, not one full scan per id.
/// The old loop timed out after a successful move on large inboxes (exit 2, messages gone).
@Test func mailScriptsMoveVerifyIsSinglePassNotPerIdScan() {
    let archive = MailScripts.move(
        account: "Work",
        ids: ["<a@x>", "<b@x>", "<c@x>"],
        target: .archive
    )
    let delete = MailScripts.move(
        account: "Personal",
        ids: ["<d@x>"],
        target: .delete
    )
    for s in [archive, delete] {
        #expect(s.contains("set allMsgs to every message of ib"))
        #expect(s.contains("if mid is (contents of rid) then"))
        #expect(s.contains("set remaining to remaining + 1"))
        // Old O(ids × inbox) pattern must not return.
        #expect(!s.contains("count of (messages of ib whose message id is ms)"))
        // Move phase may still use whose-by-id; verify block must not reintroduce per-id count.
        let afterDelay = s.components(separatedBy: "delay 1").last ?? ""
        #expect(afterDelay.contains("set allMsgs to every message of ib"))
        #expect(!afterDelay.contains("whose message id is ms"))
    }
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

// MARK: - Mail attachments

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

// MARK: - Mail draft + compose

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
