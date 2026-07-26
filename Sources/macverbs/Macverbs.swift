import ArgumentParser

/// Agent-first CLI for macOS Mail, Reminders, Notes, and Calendar.
@main
struct Macverbs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macverbs",
        abstract: "Agent-first CLI for macOS Mail, Reminders, Notes, and Calendar.",
        version: Version.current,
        subcommands: []
    )

    func run() throws {
        // No domain verbs yet (T01 scaffold). Print help when invoked bare.
        print(Self.helpMessage())
    }
}

enum Version {
    /// Semantic version of the macverbs binary.
    static let current = "0.1.0"
}
