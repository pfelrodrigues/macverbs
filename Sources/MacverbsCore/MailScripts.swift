import ArgumentParser
import Foundation

// MARK: - AppleScript builders

/// Pure AppleScript source for Mail verbs. Testable without osascript.
enum MailScripts {
    /// Header defining US/RS field/record separators (US/RS header).
    private static let separatorsHeader = """
        set fs to (character id 31)
        set rs to (character id 30)

        """

    /// Inbox name candidates (IMAP `INBOX` vs localized Exchange names).
    ///
    /// Oracle `_INBOX_NAMES`. Order: try each until one resolves.
    static let inboxNames =
        #"{"INBOX", "Caixa de Entrada", "Inbox", "Bandeja de entrada"}"#

    /// Archive / All Mail name candidates (Gmail All Mail first — Gmail notes).
    ///
    /// Oracle `_ARCHIVE_NAMES`.
    static let archiveNames =
        #"{"[Gmail]/Todos os e-mails", "[Gmail]/All Mail", "Archive", "Arquivo Morto", "Arquivo"}"#

    /// Trash / Deleted name candidates (Gmail + Exchange + generic).
    ///
    /// Oracle `_TRASH_NAMES`.
    static let trashNames =
        #"{"[Gmail]/Lixeira", "[Gmail]/Trash", "Deleted Messages", "Itens Excluídos", "Deleted Items", "Lixeira", "Trash"}"#

    /// Sentinela when archive target resolves to Gmail All Mail .
    ///
    /// Moving to All Mail does not remove INBOX; refuse instead of reporting a false move.
    static let archiveUnsupportedSentinel = "__ARCHIVE_UNSUPPORTED__"

    /// Account filter expression: empty `account` → all accounts; else name match.
    ///
    /// Oracle `_acct_filter`.
    static func accountFilter(_ account: String) -> String {
        let a = AppleScript.escape(account)
        return #"("\#(a)" is "" or (name of acct) is "\#(a)")"#
    }

    /// Box-names AppleScript list literal for the given mailbox.
    static func boxNames(for mailbox: MailMailbox) -> String {
        switch mailbox {
        case .inbox:
            return inboxNames
        case .archive:
            return archiveNames
        }
    }

    /// Destination box-names for archive vs delete .
    static func destinationBoxNames(for target: MailMoveTarget) -> String {
        switch target {
        case .archive:
            return archiveNames
        case .delete:
            return trashNames
        }
    }

    /// AppleScript block: resolve `varName` to the first existing mailbox in `candidatesExpr`.
    ///
    /// Oracle `_resolve_box`. Indentation matches the body of `mail_move`.
    static func resolveBox(varName: String, candidatesExpr: String) -> String {
        """
                    set \(varName) to missing value
                    repeat with c in \(candidatesExpr)
                        try
                            set \(varName) to mailbox c of acct
                            exit repeat
                        end try
                    end repeat
        """
    }

    /// Gmail All Mail guard (archive only). Returns empty for delete.
    ///
    /// Oracle `_gmail_allmail_guard`.
    static func gmailAllMailGuard(for target: MailMoveTarget) -> String {
        guard target == .archive else {
            return ""
        }
        let sentinel = archiveUnsupportedSentinel
        return """
                            set tbName to (name of tb)
                            if tbName contains "Todos os e-mails" or tbName contains "All Mail" then
                                return "\(sentinel)" & fs & tbName
                            end if
            """
    }

    /// AppleScript list literal of escaped message ids: `{"a", "b"}`.
    static func idListLiteral(_ ids: [String]) -> String {
        let items = ids.map { "\"\(AppleScript.escape($0))\"" }.joined(separator: ", ")
        return "{\(items)}"
    }

    /// AppleScript list literal of addresses: `{"a@x", "b@x"}` .
    static func addressList(_ addresses: [String]) -> String {
        let items = addresses.map { "\"\(AppleScript.escape($0))\"" }.joined(separator: ", ")
        return "{\(items)}"
    }

    /// Multi-line body as AppleScript expression joined with `return`
    /// (AppleScript has no multi-line string literal; AppleScript has no multi-line string literal).
    static func asMultiline(_ body: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.map { "\"\(AppleScript.escape($0))\"" }.joined(separator: " & return & ")
    }

    /// Move messages from inbox to archive or trash, then re-count remaining in inbox.
    ///
    /// Emits `requested{FS}moved{FS}remaining`. On Gmail archive (All Mail), emits
    /// `__ARCHIVE_UNSUPPORTED__{FS}{boxName}` without moving.
    ///
    /// Verification is a **single pass** over inbox messages (intersect with the
    /// requested id set), not one full mailbox scan per id. The old O(ids × inbox)
    /// recount could exceed the 30s osascript timeout after a successful move
    /// (issue #16), reporting exit 2 even though messages had already left the inbox.
    static func move(account: String, ids: [String], target: MailMoveTarget) -> String {
        let a = AppleScript.escape(account)
        let boxes = destinationBoxNames(for: target)
        let idList = idListLiteral(ids)
        let resolveInbox = resolveBox(varName: "ib", candidatesExpr: "inboxNames")
        let resolveTarget = resolveBox(varName: "tb", candidatesExpr: "boxNames")
        let guardBlock = gmailAllMailGuard(for: target)
        return separatorsHeader
            + """
            set inboxNames to \(inboxNames)
            set boxNames to \(boxes)
            set idList to \(idList)
            tell application "Mail"
                repeat with acct in accounts
                    if (name of acct) is "\(a)" then
            \(resolveInbox)
            \(resolveTarget)
                        if ib is missing value then error "inbox not found for \(a)"
                        if tb is missing value then error "destination mailbox not found for \(a)"
            \(guardBlock)
                        repeat with mid in idList
                            set ms to (contents of mid)
                            try
                                set matches to (messages of ib whose message id is ms)
                                repeat with m in matches
                                    move m to tb
                                end repeat
                            end try
                        end repeat
                        delay 1
                        set remaining to 0
                        set allMsgs to every message of ib
                        repeat with m in allMsgs
                            set mid to message id of m
                            repeat with rid in idList
                                if mid is (contents of rid) then
                                    set remaining to remaining + 1
                                    exit repeat
                                end if
                            end repeat
                        end repeat
                        set reqCount to (count of idList)
                        return (reqCount as text) & fs & ((reqCount - remaining) as text) & fs & (remaining as text)
                    end if
                end repeat
                error "account \(a) not found"
            end tell
            """
    }

    /// List configured accounts: name, type, email (RS/FS delimited).
    static func accounts() -> String {
        separatorsHeader
            + """
            tell application "Mail"
                set output to ""
                repeat with acct in accounts
                    set em to ""
                    try
                        set em to (email addresses of acct) as text
                    end try
                    set output to output & (name of acct) & fs & ((account type of acct) as text) & fs & em & rs
                end repeat
                return output
            end tell
            """
    }

    /// Unread count per account (sum of mailbox unread counts), including zero.
    ///
    /// Every configured account is emitted so callers can distinguish "0 unread"
    /// from "account missing" or an empty result (issue #17).
    static func unread() -> String {
        separatorsHeader
            + """
            tell application "Mail"
                set output to ""
                repeat with acct in accounts
                    set u to 0
                    repeat with mb in mailboxes of acct
                        set u to u + (unread count of mb)
                    end repeat
                    set output to output & (name of acct) & fs & (u as text) & rs
                end repeat
                return output
            end tell
            """
    }

    /// Recent messages from inbox or archive, multi-account by default.
    ///
    /// Resolves mailbox by name candidates (INBOX / Caixa de Entrada / …).
    /// Emits: account, subject, sender, date, read|unread, message-id.
    static func list(
        account: String = "",
        limit: Int = 20,
        mailbox: MailMailbox = .inbox
    ) -> String {
        let n = max(0, limit)
        let boxes = boxNames(for: mailbox)
        let filter = accountFilter(account)
        return separatorsHeader
            + """
            set boxNames to \(boxes)
            set output to ""
            tell application "Mail"
                repeat with acct in accounts
                    if \(filter) then
                        set mb to missing value
                        repeat with c in boxNames
                            try
                                set mb to mailbox c of acct
                                exit repeat
                            end try
                        end repeat
                        if mb is not missing value then
                            set n to count of messages of mb
                            if n > \(n) then set n to \(n)
                            repeat with i from 1 to n
                                set msg to message i of mb
                                if (msg's read status) then
                                    set rdFlag to "read"
                                else
                                    set rdFlag to "unread"
                                end if
                                set output to output & (name of acct) & fs & (subject of msg) & fs & (sender of msg) & fs & ((date received of msg) as text) & fs & rdFlag & fs & (message id of msg) & rs
                            end repeat
                        end if
                    end if
                end repeat
                return output
            end tell
            """
    }

    /// Read one message by message-id (searches inbox + archive candidates).
    ///
    /// Returns a multi-line body with From/Subject/Date headers, or `__NOTFOUND__`.
    static func read(messageID: String, account: String = "") -> String {
        let mid = AppleScript.escape(messageID)
        let filter = accountFilter(account)
        // Concatenate inbox + archive candidate lists (inbox + archive name candidates).
        return """
            set boxNames to \(inboxNames) & \(archiveNames)
            tell application "Mail"
                repeat with acct in accounts
                    if \(filter) then
                        repeat with c in boxNames
                            try
                                set mb to mailbox c of acct
                                set msgs to (messages of mb whose message id is "\(mid)")
                                if (count of msgs) > 0 then
                                    set msg to item 1 of msgs
                                    return "De: " & (sender of msg) & linefeed & "Assunto: " & (subject of msg) & linefeed & "Data: " & ((date received of msg) as text) & linefeed & linefeed & (content of msg)
                                end if
                            end try
                        end repeat
                    end if
                end repeat
                return "__NOTFOUND__"
            end tell
            """
    }

    /// Save mail attachments for a message into `destDir` (inbox + archive search).
    ///
    /// Emits one attachment file name per RS-delimited record; empty output means
    /// the message was found but has no attachments. Returns `__NOTFOUND__` when
    /// the message is missing.
    static func attachments(
        messageID: String,
        destDir: String,
        account: String = ""
    ) -> String {
        let mid = AppleScript.escape(messageID)
        let dest = AppleScript.escape(destDir)
        let filter = accountFilter(account)
        return separatorsHeader
            + """
            set boxNames to \(inboxNames) & \(archiveNames)
            tell application "Mail"
                repeat with acct in accounts
                    if \(filter) then
                        repeat with c in boxNames
                            try
                                set mb to mailbox c of acct
                                set msgs to (messages of mb whose message id is "\(mid)")
                                if (count of msgs) > 0 then
                                    set msg to item 1 of msgs
                                    set output to ""
                                    repeat with att in mail attachments of msg
                                        set attName to (name of att)
                                        set destPath to "\(dest)" & "/" & attName
                                        save att in (POSIX file destPath)
                                        set output to output & attName & rs
                                    end repeat
                                    return output
                                end if
                            end try
                        end repeat
                    end if
                end repeat
                return "__NOTFOUND__"
            end tell
            """
    }

    /// Create a reply draft for a message (inbox + archive search); never sends.
    ///
    /// Uses `reply … without opening window` so `set content` is not a silent
    /// no-op. Attachments go on `content of newMsg` with `delay 1` after each
    /// `make new attachment` so Mail materializes them before `save` (
    /// Mail.app armadilhas). Returns `"OK"` or `"__NOTFOUND__"`.
    static func draftReply(
        messageID: String,
        body: String,
        account: String = "",
        attachments: [String] = []
    ) -> String {
        let mid = AppleScript.escape(messageID)
        let filter = accountFilter(account)
        let bodyExpr = asMultiline(body)
        let attachBlock: String
        if attachments.isEmpty {
            attachBlock = ""
        } else {
            let attachLines =
                attachments.map { path in
                    let p = AppleScript.escape(path)
                    return """

                                                    make new attachment with properties {file name:(POSIX file "\(p)")} at after the last paragraph
                                                    delay 1
                        """
                }
                .joined()
            attachBlock = """

                                    tell content of newMsg\(attachLines)
                                    end tell
                """
        }
        return """
            set boxNames to \(inboxNames) & \(archiveNames)
            tell application "Mail"
                repeat with acct in accounts
                    if \(filter) then
                        repeat with c in boxNames
                            try
                                set mb to mailbox c of acct
                                set msgs to (messages of mb whose message id is "\(mid)")
                                if (count of msgs) > 0 then
                                    set msg to item 1 of msgs
                                    set newMsg to reply msg without opening window
                                    tell newMsg
                                        set content to (\(bodyExpr))
                                    end tell\(attachBlock)
                                    save newMsg
                                    return "OK"
                                end if
                            end try
                        end repeat
                    end if
                end repeat
                return "__NOTFOUND__"
            end tell
            """
    }

    /// Create a new outgoing message draft (not a reply); never sends.
    ///
    /// Optional `account` selects the sender by account name. Empty recipients
    /// are allowed (fill later in Mail). Saves with `save`; never calls `send`.
    static func compose(
        subject: String,
        body: String,
        to: [String],
        cc: [String] = [],
        account: String = ""
    ) -> String {
        let subj = AppleScript.escape(subject)
        let acct = AppleScript.escape(account)
        let bodyExpr = asMultiline(body)
        let toList = addressList(to)
        let ccList = addressList(cc)
        return """
            tell application "Mail"
                set senderAddr to ""
                if "\(acct)" is not "" then
                    repeat with acct in accounts
                        if name of acct is "\(acct)" then
                            try
                                set senderAddr to item 1 of (email addresses of acct)
                            end try
                            exit repeat
                        end if
                    end repeat
                end if
                set newMsg to make new outgoing message with properties {subject:"\(subj)", content:(\(bodyExpr)), visible:true}
                tell newMsg
                    if senderAddr is not "" then set sender to senderAddr
                    repeat with a in \(toList)
                        make new to recipient at end of to recipients with properties {address:a}
                    end repeat
                    repeat with a in \(ccList)
                        make new cc recipient at end of cc recipients with properties {address:a}
                    end repeat
                end tell
                save newMsg
                return "OK"
            end tell
            """
    }
}
