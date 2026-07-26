import ArgumentParser
import Foundation

/// Agent-first CLI for macOS Mail, Reminders, Notes, and Calendar.
struct Macverbs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macverbs",
        abstract: "Agent-first CLI for macOS Mail, Reminders, Notes, and Calendar.",
        discussion: """
            Global flags (before the subcommand):
              --json    One JSON value on stdout; errors still go to stderr.

            Exit codes: 0 ok, 1 domain, 2 system, 64 usage.
            """,
        version: Version.current,
        subcommands: []
    )

    /// Declared so `--json` appears in root help. Leading peel in `MacverbsApp`
    /// also accepts it before future domain subcommands (parity with `apple`).
    @Flag(name: .long, help: "Emit one JSON value on stdout (place before the subcommand).")
    var json: Bool = false

    func run() throws {
        // No domain verbs yet. Print help when invoked bare (or with only --json).
        print(Self.helpMessage())
    }
}

enum Version {
    /// Semantic version of the macverbs binary.
    static let current = "0.1.0"
}

// MARK: - Entry

/// Runnable CLI entry that returns an exit code (testable; does not call `exit`).
enum MacverbsApp {
    /// Parse and run with the given argv (no process name). Returns contract exit code.
    static func run(arguments: [String]) -> Int32 {
        var argv = arguments
        var json = GlobalFlags.peelLeading(&argv)

        do {
            var command = try Macverbs.parseAsRoot(argv)
            if let root = command as? Macverbs, root.json {
                json = true
            }
            return try CLIContext.$jsonOutput.withValue(json) {
                try command.run()
                return ExitCodes.success
            }
        } catch let error as MacverbsError {
            CLIOutput.writeError(error.message)
            return error.processExitCode
        } catch {
            return handleArgumentParserError(error)
        }
    }

    private static func handleArgumentParserError(_ error: Error) -> Int32 {
        let code = Macverbs.exitCode(for: error)
        let text = Macverbs.fullMessage(for: error)
        if !text.isEmpty {
            if code.isSuccess {
                // Help / version / clean messages → stdout.
                print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
            } else {
                // Usage and other parser failures → stderr.
                let line = text.hasSuffix("\n") ? text : text + "\n"
                if let data = line.data(using: .utf8) {
                    try? FileHandle.standardError.write(contentsOf: data)
                }
            }
        }
        return code.rawValue
    }
}

@main
enum Main {
    static func main() {
        let code = MacverbsApp.run(
            arguments: Array(CommandLine.arguments.dropFirst())
        )
        Foundation.exit(code)
    }
}
