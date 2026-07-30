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

/// Unread total for one account (`mail unread`), including zero.
struct MailUnreadCount: Codable, Equatable, Sendable {
    var account: String
    var unread: Int
}

/// One message row from `mail list`.
///
/// Keys: `account`, `subject`, `sender`, `date`, `read`, `id`.
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
/// Keys: `account`, `action`, `moved`, `requested`, `remaining`;
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

/// Result of `mail attachments` (saved file names under `--dest`).
///
/// JSON keys: `message_id`, `dest_dir`, `saved`.
struct MailAttachmentsResult: Equatable, Sendable {
    var messageID: String
    var destDir: String
    /// Base names of attachments saved into `destDir` (may be empty).
    var saved: [String]
}

extension MailAttachmentsResult: Encodable {
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case destDir = "dest_dir"
        case saved
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(destDir, forKey: .destDir)
        try container.encode(saved, forKey: .saved)
    }
}

/// Result of `mail draft` (reply draft; never sends).
///
/// JSON keys: `message_id`, `status`, `attachments`.
struct MailDraftResult: Equatable, Sendable {
    var messageID: String
    /// Script status string (typically `"OK"`).
    var status: String
    /// Absolute paths of attachments that were requested (may be empty).
    var attachments: [String]
}

extension MailDraftResult: Encodable {
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case status
        case attachments
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(status, forKey: .status)
        try container.encode(attachments, forKey: .attachments)
    }
}

/// Result of `mail compose` (new draft; never sends).
///
/// JSON keys: `subject`, `to`, `cc`.
struct MailComposeResult: Codable, Equatable, Sendable {
    var subject: String
    var to: [String]
    var cc: [String]
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
