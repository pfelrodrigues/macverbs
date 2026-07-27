import ArgumentParser
import Foundation

// MARK: - Models

/// Path report for `config path`.
struct ConfigPathReport: Codable, Equatable, Sendable {
    /// Resolved config directory.
    var directory: String
    /// Full path to `calendars.json`.
    var calendarsFile: String
    /// Whether `calendars.json` exists on disk.
    var calendarsFileExists: Bool
}

/// Result of `config calendars init`.
struct ConfigCalendarsInitResult: Codable, Equatable, Sendable {
    var path: String
    var count: Int
    var force: Bool
}

/// One entry for `config calendars show`.
struct ConfigCalendarAliasEntry: Codable, Equatable, Sendable {
    var uid: String
    var label: String
}

// MARK: - Format

enum ConfigFormat {
    static func path(_ report: ConfigPathReport) -> String {
        var lines = [
            "config directory: \(report.directory)",
            "calendars.json: \(report.calendarsFile)",
        ]
        if report.calendarsFileExists {
            lines.append("calendars.json: exists")
        } else {
            lines.append("calendars.json: missing (optional; run config calendars init)")
        }
        return lines.joined(separator: "\n")
    }

    static func aliases(_ entries: [ConfigCalendarAliasEntry]) -> String {
        if entries.isEmpty {
            return "no calendar aliases configured."
        }
        return entries.map { "- \($0.uid) → \($0.label)" }.joined(separator: "\n")
    }

    static func initResult(_ result: ConfigCalendarsInitResult) -> String {
        let mode = result.force ? "overwrote" : "wrote"
        return "\(mode) \(result.count) alias(es) → \(result.path)"
    }
}

// MARK: - CLI

/// `macverbs config` — user configuration (paths + calendars.json).
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show and initialize macverbs config (calendars.json).",
        subcommands: [
            ConfigPathCommand.self,
            ConfigCalendarsCommand.self,
        ]
    )
}

/// `macverbs config path`
struct ConfigPathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Print the resolved config directory and calendars.json path."
    )

    func run() throws {
        let dir = ConfigPaths.configDirectory()
        let file = ConfigPaths.calendarsURL()
        let report = ConfigPathReport(
            directory: dir.path,
            calendarsFile: file.path,
            calendarsFileExists: FileManager.default.fileExists(atPath: file.path)
        )
        try CLIOutput.emit(report, text: ConfigFormat.path)
    }
}

/// `macverbs config calendars …`
struct ConfigCalendarsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendars",
        abstract: "Manage calendars.json (UID → label map).",
        subcommands: [
            ConfigCalendarsShowCommand.self,
            ConfigCalendarsInitCommand.self,
        ]
    )
}

/// `macverbs config calendars show`
struct ConfigCalendarsShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show the current calendars.json alias map."
    )

    func run() throws {
        let aliases = Config.loadCalendarAliases()
        let entries =
            aliases.labelsByUID
            .map { ConfigCalendarAliasEntry(uid: $0.key, label: $0.value) }
            .sorted { $0.uid < $1.uid }
        try CLIOutput.emit(entries, text: ConfigFormat.aliases)
    }
}

/// `macverbs config calendars init [--force]`
struct ConfigCalendarsInitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract:
            "Create calendars.json from EventKit calendars (edit labels afterward)."
    )

    @Flag(name: .long, help: "Overwrite an existing calendars.json.")
    var force: Bool = false

    func run() throws {
        let client = BackendClients.eventStore
        try client.ensureAccess(for: .event)
        let calendars = try client.eventCalendars()
        let url = ConfigPaths.calendarsURL()
        let aliases = try Config.initCalendarAliases(
            calendars: calendars,
            force: force,
            url: url
        )
        let result = ConfigCalendarsInitResult(
            path: url.path,
            count: aliases.labelsByUID.count,
            force: force
        )
        try CLIOutput.emit(result, text: ConfigFormat.initResult)
    }
}
