import ArgumentParser
import Foundation

// MARK: - Models (docs/behavior.md)

/// One note row from `notes list` / `notes search`.
///
/// Keys match the oracle: `title`, `modified`.
struct NoteItem: Codable, Equatable, Sendable {
    var title: String
    /// Modification date as Notes reports it (locale text from AppleScript).
    var modified: String
}

/// Body payload from `notes read`.
///
/// JSON keys: `title`, `body`.
struct NoteBody: Codable, Equatable, Sendable {
    var title: String
    var body: String
}

/// Result of `notes create`.
///
/// JSON keys: `created`, `folder`.
struct NoteCreateResult: Codable, Equatable, Sendable {
    var created: String
    var folder: String
}

// MARK: - AppleScript builders (oracle: apple.scripts)

/// Pure AppleScript source for Notes verbs. Testable without osascript.
enum NotesScripts {
    /// Header defining US/RS field/record separators (oracle `_H`).
    private static let separatorsHeader = """
        set fs to (character id 31)
        set rs to (character id 30)

        """

    /// List notes in a folder: title, modification date (RS/FS delimited).
    ///
    /// Default folder is `"Notes"` (oracle parity).
    static func list(folder: String = "Notes") -> String {
        let f = AppleScript.escape(folder)
        return separatorsHeader
            + """
            tell application "Notes"
                set output to ""
                repeat with n in notes of folder "\(f)"
                    set output to output & (name of n) & fs & ((modification date of n) as text) & rs
                end repeat
                return output
            end tell
            """
    }

    /// Read plaintext of the first note whose name matches `title` exactly.
    static func read(title: String) -> String {
        let t = AppleScript.escape(title)
        return """
            tell application "Notes"
                return plaintext of (first note whose name is "\(t)")
            end tell
            """
    }

    /// Create a note with name and body in the given folder.
    static func create(title: String, body: String, folder: String = "Notes") -> String {
        let t = AppleScript.escape(title)
        let b = AppleScript.escape(body)
        let f = AppleScript.escape(folder)
        return """
            tell application "Notes"
                tell folder "\(f)"
                    make new note with properties {name:"\(t)", body:"\(b)"}
                end tell
                return "ok"
            end tell
            """
    }

    /// Search notes whose name or plaintext contains `query`.
    ///
    /// Emits title + modification date (same shape as list).
    static func search(query: String) -> String {
        let q = AppleScript.escape(query)
        return separatorsHeader
            + """
            tell application "Notes"
                set output to ""
                repeat with n in (every note whose name contains "\(q)" or plaintext contains "\(q)")
                    set output to output & (name of n) & fs & ((modification date of n) as text) & rs
                end repeat
                return output
            end tell
            """
    }
}

// MARK: - Commands (oracle: apple.commands)

enum Notes {
    /// Default osascript timeout (same as production ScriptRunner).
    static let defaultTimeout: TimeInterval = OSAScriptRunner.defaultTimeout

    /// Default Notes folder name (oracle).
    static let defaultFolder = "Notes"

    /// List notes in a folder via Apple Events.
    static func list(
        folder: String = defaultFolder,
        runner: any ScriptRunner = BackendClients.scriptRunner,
        timeout: TimeInterval = defaultTimeout
    ) throws -> [NoteItem] {
        let raw = try runner.run(script: NotesScripts.list(folder: folder), timeout: timeout)
        return parseNoteItems(raw)
    }

    /// Read a note by exact title (first match).
    static func read(
        title: String,
        runner: any ScriptRunner = BackendClients.scriptRunner,
        timeout: TimeInterval = defaultTimeout
    ) throws -> NoteBody {
        let raw = try runner.run(script: NotesScripts.read(title: title), timeout: timeout)
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return NoteBody(title: title, body: body)
    }

    /// Create a note in `folder` (default `"Notes"`).
    static func create(
        title: String,
        body: String,
        folder: String = defaultFolder,
        runner: any ScriptRunner = BackendClients.scriptRunner,
        timeout: TimeInterval = defaultTimeout
    ) throws -> NoteCreateResult {
        _ = try runner.run(
            script: NotesScripts.create(title: title, body: body, folder: folder),
            timeout: timeout
        )
        return NoteCreateResult(created: title, folder: folder)
    }

    /// Search notes by name or plaintext contains `query`.
    static func search(
        query: String,
        runner: any ScriptRunner = BackendClients.scriptRunner,
        timeout: TimeInterval = defaultTimeout
    ) throws -> [NoteItem] {
        let raw = try runner.run(script: NotesScripts.search(query: query), timeout: timeout)
        return parseNoteItems(raw)
    }

    private static func parseNoteItems(_ raw: String) -> [NoteItem] {
        AppleScript.parseRecords(raw, fields: ["title", "modified"])
            .map { row in
                NoteItem(
                    title: row["title"] ?? "",
                    modified: row["modified"] ?? ""
                )
            }
    }

    // MARK: Text formatters

    /// Human lines for `notes list` / `notes search` (English empty message).
    static func formatList(_ items: [NoteItem]) -> String {
        if items.isEmpty {
            return "no notes."
        }
        return items.map { "- \($0.title) | \($0.modified)" }.joined(separator: "\n")
    }

    /// Human text for `notes read` (body only; oracle `fmt.body`).
    static func formatBody(_ result: NoteBody) -> String {
        if result.body.isEmpty {
            return "(empty)"
        }
        return result.body
    }

    /// Human text for `notes create` (English; oracle shape).
    static func formatCreate(_ result: NoteCreateResult) -> String {
        "created: \(result.created)"
    }
}

// MARK: - CLI

/// Notes domain: Apple Events via ScriptRunner.
struct NotesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Notes folders and notes (Apple Events).",
        discussion: """
            Examples:
              macverbs --json notes list --folder Notes
              macverbs notes search "meeting"
              macverbs notes create "Title" --body-file ./note.txt

            """,
        subcommands: [
            NotesListCommand.self,
            NotesReadCommand.self,
            NotesCreateCommand.self,
            NotesSearchCommand.self,
        ]
    )
}

/// `macverbs notes list [--folder Notes]`.
struct NotesListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List notes in a folder (default: Notes)."
    )

    @Option(
        name: .long,
        help: "Notes folder name (default: Notes)."
    )
    var folder: String = Notes.defaultFolder

    func run() throws {
        let items = try Notes.list(folder: folder)
        try CLIOutput.emit(items, text: Notes.formatList)
    }
}

/// `macverbs notes read <title>`.
struct NotesReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read a note by exact title (first match)."
    )

    @Argument(help: "Note title (exact name match).")
    var title: String

    func run() throws {
        let result = try Notes.read(title: title)
        try CLIOutput.emit(result, text: Notes.formatBody)
    }
}

/// `macverbs notes create <title> <body> [--folder Notes]`.
struct NotesCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a note in a folder (default: Notes)."
    )

    @Argument(help: "Note title.")
    var title: String

    @Argument(help: "Note body.")
    var body: String

    @Option(
        name: .long,
        help: "Notes folder name (default: Notes)."
    )
    var folder: String = Notes.defaultFolder

    func run() throws {
        let result = try Notes.create(title: title, body: body, folder: folder)
        try CLIOutput.emit(result, text: Notes.formatCreate)
    }
}

/// `macverbs notes search <query>`.
struct NotesSearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search notes by title or body contains query."
    )

    @Argument(help: "Search string (title or plaintext contains).")
    var query: String

    func run() throws {
        let items = try Notes.search(query: query)
        try CLIOutput.emit(items, text: Notes.formatList)
    }
}
