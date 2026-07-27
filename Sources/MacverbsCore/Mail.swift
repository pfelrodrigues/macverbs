import ArgumentParser
import Foundation

// MARK: - Commands

enum Mail {
    /// Default osascript timeout (same as production ScriptRunner).
    static let defaultTimeout: TimeInterval = OSAScriptRunner.defaultTimeout

    /// Sentinel when `mail read` cannot find the message (contract).
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

    /// Save attachments for a message into `destDir` (searches inbox + archive).
    ///
    /// Missing message → domain error (`message <id> not found`). Empty `saved`
    /// means the message was found but has no attachments.
    static func attachments(
        messageID: String,
        destDir: String,
        account: String = "",
        runner: any ScriptRunner = BackendClients.scriptRunner,
        timeout: TimeInterval = defaultTimeout
    ) throws -> MailAttachmentsResult {
        let raw = try runner.run(
            script: MailScripts.attachments(
                messageID: messageID,
                destDir: destDir,
                account: account
            ),
            timeout: timeout
        )
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == notFoundSentinel {
            throw MacverbsError.domain("message \(messageID) not found")
        }
        // Oracle: split on RS and drop blank names (not parseRecords field maps).
        let saved =
            raw.split(
                separator: Character(AppleScript.recordSeparator),
                omittingEmptySubsequences: false
            )
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != notFoundSentinel }
        return MailAttachmentsResult(
            messageID: messageID,
            destDir: destDir,
            saved: saved
        )
    }

    /// Create a reply draft (never sends). Body is the message content;
    /// attachments are absolute paths that must already exist.
    ///
    /// Missing message → domain error (`message <id> not found`).
    static func draft(
        messageID: String,
        body: String,
        account: String = "",
        attachments: [String] = [],
        runner: any ScriptRunner = BackendClients.scriptRunner,
        timeout: TimeInterval = defaultTimeout
    ) throws -> MailDraftResult {
        let raw = try runner.run(
            script: MailScripts.draftReply(
                messageID: messageID,
                body: body,
                account: account,
                attachments: attachments
            ),
            timeout: timeout
        )
        let status = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == notFoundSentinel {
            throw MacverbsError.domain("message \(messageID) not found")
        }
        return MailDraftResult(
            messageID: messageID,
            status: status,
            attachments: attachments
        )
    }

    /// Create a new compose draft (never sends).
    static func compose(
        subject: String,
        body: String,
        to: [String] = [],
        cc: [String] = [],
        account: String = "",
        runner: any ScriptRunner = BackendClients.scriptRunner,
        timeout: TimeInterval = defaultTimeout
    ) throws -> MailComposeResult {
        _ = try runner.run(
            script: MailScripts.compose(
                subject: subject,
                body: body,
                to: to,
                cc: cc,
                account: account
            ),
            timeout: timeout
        )
        return MailComposeResult(subject: subject, to: to, cc: cc)
    }

    /// Read UTF-8 body from `--body-file` .
    static func readBodyFile(_ path: String) throws -> String {
        let expanded = expandPath(path)
        do {
            return try String(contentsOfFile: expanded, encoding: .utf8)
        } catch {
            throw MacverbsError.domain("could not read --body-file: \(error.localizedDescription)")
        }
    }

    /// Expand `~`, make absolute, and require each attach path exists.
    static func resolveAttachmentPaths(_ paths: [String]) throws -> [String] {
        var resolved: [String] = []
        var missing: [String] = []
        for path in paths {
            let abs = expandPath(path)
            if FileManager.default.fileExists(atPath: abs) {
                resolved.append(abs)
            } else {
                missing.append(abs)
            }
        }
        if !missing.isEmpty {
            let list = missing.joined(separator: ", ")
            throw MacverbsError.domain("attachment(s) not found: \(list)")
        }
        return resolved
    }

    /// Absolute path: tilde expansion + CWD-relative resolution .
    static func expandPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    // MARK: Text formatters

    /// Human lines for `mail accounts` (English).
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

    /// Human lines for `mail list` (English empty message).
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

    /// Human text for `mail attachments` (English).
    static func formatAttachments(_ result: MailAttachmentsResult) -> String {
        if result.saved.isEmpty {
            return "no attachments."
        }
        let lines = result.saved.map { "- \($0)" }.joined(separator: "\n")
        return "saved to \(result.destDir):\n\(lines)"
    }

    /// Human text for `mail draft` (English).
    static func formatDraft(_ result: MailDraftResult) -> String {
        "draft created (reply to \(result.messageID)), not sent."
    }

    /// Human text for `mail compose` (English).
    static func formatCompose(_ result: MailComposeResult) -> String {
        let toPart = result.to.joined(separator: ", ")
        let ccPart =
            result.cc.isEmpty
            ? ""
            : ", cc: \(result.cc.joined(separator: ", "))"
        return "new draft created, not sent. Subject: \(result.subject) | To: \(toPart)\(ccPart)"
    }
}

// MARK: - CLI

/// Mail domain: Apple Events via ScriptRunner.
struct MailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Mail accounts and messages (Apple Events).",
        discussion: """
            Examples:
              macverbs --json mail accounts
              macverbs --json mail list --account Work --limit 20
              macverbs --json mail archive --account Work -- "message-id"
            Use id from mail list as-is. Prefer --json for agents. Gmail archive is unsupported.

            """,
        subcommands: [
            MailAccountsCommand.self,
            MailUnreadCommand.self,
            MailListCommand.self,
            MailReadCommand.self,
            MailArchiveCommand.self,
            MailDeleteCommand.self,
            MailAttachmentsCommand.self,
            MailDraftCommand.self,
            MailComposeCommand.self,
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

/// `macverbs mail attachments <message-id> --dest DIR [--account]`.
struct MailAttachmentsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attachments",
        abstract: "Save attachments from a message (searches inbox and archive)."
    )

    @Argument(help: "Message-ID header value (from mail list).")
    var messageId: String

    @Option(
        name: .long,
        help: "Destination directory for saved files (required).",
        completion: .directory
    )
    var dest: String

    @Option(name: .long, help: "Filter by account name (empty = all accounts).")
    var account: String = ""

    func run() throws {
        let result = try Mail.attachments(
            messageID: messageId,
            destDir: dest,
            account: account
        )
        try CLIOutput.emit(result, text: Mail.formatAttachments)
    }
}

/// `macverbs mail draft <message-id> --body-file FILE [--attach]… [--account]`.
///
/// Creates a reply draft only; never sends.
struct MailDraftCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "draft",
        abstract: "Create a reply draft to a message (never sends)."
    )

    @Argument(help: "Message-ID header value (from mail list).")
    var messageId: String

    @Option(
        name: .long,
        help: "File with the draft body (required).",
        completion: .file()
    )
    var bodyFile: String

    @Option(name: .long, help: "Filter by account name (empty = all accounts).")
    var account: String = ""

    @Option(
        name: .long,
        parsing: .singleValue,
        help: "File path to attach (repeatable).",
        completion: .file()
    )
    var attach: [String] = []

    func run() throws {
        let body = try Mail.readBodyFile(bodyFile)
        let attachments = try Mail.resolveAttachmentPaths(attach)
        let result = try Mail.draft(
            messageID: messageId,
            body: body,
            account: account,
            attachments: attachments
        )
        try CLIOutput.emit(result, text: Mail.formatDraft)
    }
}

/// `macverbs mail compose --subject S --body-file FILE [--to]… [--cc]… [--account]`.
///
/// Creates a new message draft only; never sends.
struct MailComposeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Create a new email draft (never sends)."
    )

    @Option(name: .long, help: "Subject line (required).")
    var subject: String

    @Option(
        name: .long,
        help: "File with the draft body (required).",
        completion: .file()
    )
    var bodyFile: String

    @Option(
        name: .long,
        parsing: .singleValue,
        help: "To recipient (repeatable; empty = fill later in Mail)."
    )
    var to: [String] = []

    @Option(
        name: .long,
        parsing: .singleValue,
        help: "Cc recipient (repeatable)."
    )
    var cc: [String] = []

    @Option(name: .long, help: "Sender account name (empty = Mail default).")
    var account: String = ""

    func run() throws {
        let body = try Mail.readBodyFile(bodyFile)
        let result = try Mail.compose(
            subject: subject,
            body: body,
            to: to,
            cc: cc,
            account: account
        )
        try CLIOutput.emit(result, text: Mail.formatCompose)
    }
}
