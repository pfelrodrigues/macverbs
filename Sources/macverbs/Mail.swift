import ArgumentParser
import Foundation

// MARK: - Models (docs/behavior.md)

/// One Mail account as reported by `mail accounts`.
struct MailAccount: Codable, Equatable, Sendable {
    var name: String
    /// Account type as Mail reports it (e.g. `imap`, `exchange`).
    var type: String
    var email: String
}

/// Unread total for one account (`mail unread`). Only accounts with unread > 0.
struct MailUnreadCount: Codable, Equatable, Sendable {
    var account: String
    var unread: Int
}

/// One message row from `mail list`.
///
/// Keys match the oracle: `account`, `subject`, `sender`, `date`, `read`, `id`.
/// `read` is the string `"read"` or `"unread"` (not a boolean).
struct MailMessageItem: Codable, Equatable, Sendable {
    var account: String
    var subject: String
    var sender: String
    var date: String
    /// `"read"` or `"unread"`.
    var read: String
    /// Message-ID header value (use with `mail read` / archive / delete).
    var id: String
}

/// Body payload from `mail read`.
struct MailMessageBody: Codable, Equatable, Sendable {
    var body: String
}

/// Result of `mail archive` / `mail delete` (verified move counts).
///
/// Keys match the oracle: `account`, `action`, `moved`, `requested`, `remaining`;
/// optional `unsupported` when Gmail archive is refused honestly.
struct MailMoveResult: Equatable, Sendable {
    var account: String
    /// `"archive"` or `"delete"`.
    var action: String
    var moved: Int
    var requested: Int
    var remaining: Int
    /// Present only when the operation is refused (e.g. Gmail archive).
    var unsupported: String?
}

extension MailMoveResult: Encodable {
    enum CodingKeys: String, CodingKey {
        case account, action, moved, requested, remaining, unsupported
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(account, forKey: .account)
        try container.encode(action, forKey: .action)
        try container.encode(moved, forKey: .moved)
        try container.encode(requested, forKey: .requested)
        try container.encode(remaining, forKey: .remaining)
        try container.encodeIfPresent(unsupported, forKey: .unsupported)
    }
}

/// Mailbox target for `mail list` (`inbox` or `archive`).
enum MailMailbox: String, CaseIterable, ExpressibleByArgument, Sendable {
    case inbox
    case archive
}

/// Move destination for `mail archive` / `mail delete`.
enum MailMoveTarget: String, Sendable {
    case archive
    case delete
}

// MARK: - AppleScript builders (oracle: apple.scripts)

/// Pure AppleScript source for Mail verbs. Testable without osascript.
enum MailScripts {
    /// Header defining US/RS field/record separators (oracle `_H`).
    private static let separatorsHeader = """
        set fs to (character id 31)
        set rs to (character id 30)

        """

    /// Inbox name candidates (IMAP `INBOX` vs localized Exchange names).
    ///
    /// Oracle `_INBOX_NAMES`. Order: try each until one resolves.
    static let inboxNames =
        #"{"INBOX", "Caixa de Entrada", "Inbox", "Bandeja de entrada"}"#

    /// Archive / All Mail name candidates (Gmail All Mail first — see T16 notes).
    ///
    /// Oracle `_ARCHIVE_NAMES`.
    static let archiveNames =
        #"{"[Gmail]/Todos os e-mails", "[Gmail]/All Mail", "Archive", "Arquivo Morto", "Arquivo"}"#

    /// Trash / Deleted name candidates (Gmail + Exchange + generic).
    ///
    /// Oracle `_TRASH_NAMES`.
    static let trashNames =
        #"{"[Gmail]/Lixeira", "[Gmail]/Trash", "Deleted Messages", "Itens Excluídos", "Deleted Items", "Lixeira", "Trash"}"#

    /// Sentinela when archive target resolves to Gmail All Mail (oracle `ARCHIVE_UNSUPPORTED`).
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

    /// Destination box-names for archive vs delete (oracle `mail_move`).
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

    /// Move messages from inbox to archive or trash, then re-count remaining in inbox.
    ///
    /// Emits `requested{FS}moved{FS}remaining`. On Gmail archive (All Mail), emits
    /// `__ARCHIVE_UNSUPPORTED__{FS}{boxName}` without moving.
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
                        repeat with mid in idList
                            set ms to (contents of mid)
                            try
                                set remaining to remaining + (count of (messages of ib whose message id is ms))
                            end try
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

    /// Unread count per account (sum of mailbox unread counts); only u > 0.
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
                    if u > 0 then set output to output & (name of acct) & fs & (u as text) & rs
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
        // Concatenate inbox + archive candidate lists (oracle: _INBOX_NAMES & _ARCHIVE_NAMES).
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
}

// MARK: - Commands (oracle: apple.commands)

enum Mail {
    /// Default osascript timeout (same as production ScriptRunner).
    static let defaultTimeout: TimeInterval = OSAScriptRunner.defaultTimeout

    /// Sentinel when `mail read` cannot find the message (oracle parity).
    static let notFoundSentinel = "__NOTFOUND__"

    /// List Mail accounts via Apple Events.
    static func accounts(
        runner: any ScriptRunner = BackendClients.scriptRunner,
        timeout: TimeInterval = defaultTimeout
    ) throws -> [MailAccount] {
        let raw = try runner.run(script: MailScripts.accounts(), timeout: timeout)
        return AppleScript.parseRecords(raw, fields: ["name", "type", "email"])
            .map { row in
                MailAccount(
                    name: row["name"] ?? "",
                    type: row["type"] ?? "",
                    email: row["email"] ?? ""
                )
            }
    }

    /// Unread totals per account (accounts with zero unread are omitted by script).
    static func unread(
        runner: any ScriptRunner = BackendClients.scriptRunner,
        timeout: TimeInterval = defaultTimeout
    ) throws -> [MailUnreadCount] {
        let raw = try runner.run(script: MailScripts.unread(), timeout: timeout)
        return AppleScript.parseRecords(raw, fields: ["account", "unread"])
            .map { row in
                let n = Int(row["unread"] ?? "") ?? 0
                return MailUnreadCount(account: row["account"] ?? "", unread: n)
            }
    }

    /// List recent messages (`--account` empty = all accounts).
    static func list(
        account: String = "",
        limit: Int = 20,
        mailbox: MailMailbox = .inbox,
        runner: any ScriptRunner = BackendClients.scriptRunner,
        timeout: TimeInterval = defaultTimeout
    ) throws -> [MailMessageItem] {
        guard limit >= 0 else {
            throw MacverbsError.domain("--limit must be >= 0")
        }
        let raw = try runner.run(
            script: MailScripts.list(account: account, limit: limit, mailbox: mailbox),
            timeout: timeout
        )
        return
            AppleScript.parseRecords(
                raw,
                fields: ["account", "subject", "sender", "date", "read", "id"]
            )
            .map { row in
                MailMessageItem(
                    account: row["account"] ?? "",
                    subject: row["subject"] ?? "",
                    sender: row["sender"] ?? "",
                    date: row["date"] ?? "",
                    read: row["read"] ?? "",
                    id: row["id"] ?? ""
                )
            }
    }

    /// Read a message body by message-id (searches inbox + archive).
    static func read(
        messageID: String,
        account: String = "",
        runner: any ScriptRunner = BackendClients.scriptRunner,
        timeout: TimeInterval = defaultTimeout
    ) throws -> MailMessageBody {
        let raw = try runner.run(
            script: MailScripts.read(messageID: messageID, account: account),
            timeout: timeout
        )
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body == notFoundSentinel {
            throw MacverbsError.domain("message \(messageID) not found")
        }
        return MailMessageBody(body: body)
    }

    /// Move messages from inbox to archive or trash; re-counts remaining in inbox.
    ///
    /// `--account` is required. Gmail archive (All Mail) is refused with
    /// `unsupported` and `moved: 0` (never report a silent no-op as success).
    static func move(
        account: String,
        ids: [String],
        target: MailMoveTarget,
        runner: any ScriptRunner = BackendClients.scriptRunner,
        timeout: TimeInterval = defaultTimeout
    ) throws -> MailMoveResult {
        guard !account.isEmpty else {
            throw MacverbsError.domain("--account is required for archive/delete")
        }
        guard !ids.isEmpty else {
            throw MacverbsError.domain("at least one message id is required")
        }
        let raw = try runner.run(
            script: MailScripts.move(account: account, ids: ids, target: target),
            timeout: timeout
        )
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentinel = MailScripts.archiveUnsupportedSentinel
        if trimmed.hasPrefix(sentinel) {
            // Gmail: moving to All Mail does not remove INBOX. Refuse honestly.
            let box: String = {
                let parts = trimmed.split(
                    separator: Character(AppleScript.fieldSeparator),
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                if parts.count > 1 {
                    return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return ""
            }()
            let boxLabel = box.isEmpty ? "All Mail" : box
            let reason =
                "archive is not supported on this account (Gmail): moving to "
                + "'\(boxLabel)' does not remove the message from the inbox. "
                + "Use delete or archive manually in Mail."
            return MailMoveResult(
                account: account,
                action: target.rawValue,
                moved: 0,
                requested: ids.count,
                remaining: ids.count,
                unsupported: reason
            )
        }
        let recs = AppleScript.parseRecords(raw, fields: ["requested", "moved", "remaining"])
        let row = recs.first ?? ["requested": "0", "moved": "0", "remaining": "0"]
        return MailMoveResult(
            account: account,
            action: target.rawValue,
            moved: Int(row["moved"] ?? "") ?? 0,
            requested: Int(row["requested"] ?? "") ?? 0,
            remaining: Int(row["remaining"] ?? "") ?? 0,
            unsupported: nil
        )
    }

    /// Archive messages (`mail archive`).
    static func archive(
        account: String,
        ids: [String],
        runner: any ScriptRunner = BackendClients.scriptRunner,
        timeout: TimeInterval = defaultTimeout
    ) throws -> MailMoveResult {
        try move(account: account, ids: ids, target: .archive, runner: runner, timeout: timeout)
    }

    /// Delete messages by moving to trash (`mail delete`).
    static func delete(
        account: String,
        ids: [String],
        runner: any ScriptRunner = BackendClients.scriptRunner,
        timeout: TimeInterval = defaultTimeout
    ) throws -> MailMoveResult {
        try move(account: account, ids: ids, target: .delete, runner: runner, timeout: timeout)
    }

    // MARK: Text formatters

    /// Human lines for `mail accounts` (English; verb/flags match oracle).
    static func formatAccounts(_ items: [MailAccount]) -> String {
        if items.isEmpty {
            return "no accounts."
        }
        return items.map { "- \($0.name) | \($0.type) | \($0.email)" }.joined(separator: "\n")
    }

    /// Human lines for `mail unread`.
    static func formatUnread(_ items: [MailUnreadCount]) -> String {
        if items.isEmpty {
            return "no unread."
        }
        return items.map { "- \($0.account): \($0.unread) unread" }.joined(separator: "\n")
    }

    /// Human lines for `mail list` (oracle shape; English empty message).
    static func formatList(_ items: [MailMessageItem]) -> String {
        if items.isEmpty {
            return "no messages."
        }
        return
            items.map { m in
                "[\(m.read)] (\(m.account)) \(m.subject) | \(m.sender) | \(m.date) | id:\(m.id)"
            }
            .joined(separator: "\n")
    }

    /// Human text for `mail read` (body only; empty body still prints nothing special).
    static func formatBody(_ result: MailMessageBody) -> String {
        if result.body.isEmpty {
            return "(empty)"
        }
        return result.body
    }

    /// Human text for `mail archive` / `mail delete` (verified counts).
    static func formatMove(_ result: MailMoveResult) -> String {
        if let unsupported = result.unsupported {
            return "\(result.account): \(unsupported)"
        }
        let verb = result.action == "archive" ? "archived" : "deleted"
        var line = "\(result.account): \(result.moved)/\(result.requested) \(verb)"
        if result.remaining > 0 {
            line += "; \(result.remaining) remaining in inbox"
        }
        return line
    }
}

// MARK: - CLI

/// Mail domain: Apple Events via ScriptRunner.
struct MailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Mail accounts and messages (Apple Events).",
        subcommands: [
            MailAccountsCommand.self,
            MailUnreadCommand.self,
            MailListCommand.self,
            MailReadCommand.self,
            MailArchiveCommand.self,
            MailDeleteCommand.self,
        ]
    )
}

/// `macverbs mail accounts` — list configured accounts.
struct MailAccountsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "accounts",
        abstract: "List configured Mail accounts."
    )

    func run() throws {
        let items = try Mail.accounts()
        try CLIOutput.emit(items, text: Mail.formatAccounts)
    }
}

/// `macverbs mail unread` — unread totals per account.
struct MailUnreadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unread",
        abstract: "Unread message counts per account."
    )

    func run() throws {
        let items = try Mail.unread()
        try CLIOutput.emit(items, text: Mail.formatUnread)
    }
}

/// `macverbs mail list [--account] [--limit] [--mailbox]`.
struct MailListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List recent messages (all accounts by default)."
    )

    @Option(name: .long, help: "Filter by account name (empty = all accounts).")
    var account: String = ""

    @Option(name: .long, help: "Max messages per account (default: 20).")
    var limit: Int = 20

    @Option(name: .long, help: "Mailbox to list: inbox or archive (default: inbox).")
    var mailbox: MailMailbox = .inbox

    func run() throws {
        let items = try Mail.list(account: account, limit: limit, mailbox: mailbox)
        try CLIOutput.emit(items, text: Mail.formatList)
    }
}

/// `macverbs mail read <message-id> [--account]`.
struct MailReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read a message by message-id (searches inbox and archive)."
    )

    @Argument(help: "Message-ID header value (from mail list).")
    var messageId: String

    @Option(name: .long, help: "Filter by account name (empty = all accounts).")
    var account: String = ""

    func run() throws {
        let result = try Mail.read(messageID: messageId, account: account)
        try CLIOutput.emit(result, text: Mail.formatBody)
    }
}

/// `macverbs mail archive <ids…> --account` (verified; Gmail → unsupported).
struct MailArchiveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive",
        abstract: "Archive messages (move to archive; effect verified)."
    )

    @Argument(help: "Message-ID header value(s) from mail list.")
    var ids: [String]

    @Option(name: .long, help: "Account that owns the messages (required).")
    var account: String

    func validate() throws {
        if ids.isEmpty {
            throw ValidationError("At least one message id is required.")
        }
    }

    func run() throws {
        let result = try Mail.archive(account: account, ids: ids)
        try CLIOutput.emit(result, text: Mail.formatMove)
    }
}

/// `macverbs mail delete <ids…> --account` (move to trash; effect verified).
struct MailDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete messages (move to trash; effect verified)."
    )

    @Argument(help: "Message-ID header value(s) from mail list.")
    var ids: [String]

    @Option(name: .long, help: "Account that owns the messages (required).")
    var account: String

    func validate() throws {
        if ids.isEmpty {
            throw ValidationError("At least one message id is required.")
        }
    }

    func run() throws {
        let result = try Mail.delete(account: account, ids: ids)
        try CLIOutput.emit(result, text: Mail.formatMove)
    }
}
