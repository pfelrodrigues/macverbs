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

// MARK: - AppleScript builders (oracle: apple.scripts)

/// Pure AppleScript source for Mail verbs. Testable without osascript.
enum MailScripts {
    /// Header defining US/RS field/record separators (oracle `_H`).
    private static let separatorsHeader = """
        set fs to (character id 31)
        set rs to (character id 30)

        """

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
}

// MARK: - Commands (oracle: apple.commands)

enum Mail {
    /// Default osascript timeout (same as production ScriptRunner).
    static let defaultTimeout: TimeInterval = OSAScriptRunner.defaultTimeout

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
