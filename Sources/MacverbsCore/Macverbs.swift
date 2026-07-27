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

            Examples:
              macverbs doctor
              macverbs --json calendar list --days 7
              macverbs reminders list --list Inbox
              macverbs --json mail list --account Work --limit 20

            First run: macverbs doctor, then optionally config calendars init.
            See docs/usage.md in the repository for more recipes.
            """,
        version: Version.current,
        subcommands: [
            CalendarCommand.self,
            ConfigCommand.self,
            DoctorCommand.self,
            MailCommand.self,
            NotesCommand.self,
            RemindersCommand.self,
        ]
    )

    /// Declared so `--json` appears in root help. Leading peel in `MacverbsApp`
    /// also accepts it before the subcommand.
    @Flag(name: .long, help: "Emit one JSON value on stdout (place before the subcommand).")
    var json: Bool = false

    func run() throws {
        // Bare root (or only global flags): print help.
        print(Self.helpMessage())
    }
}

enum Version {
    /// Semantic version of the macverbs binary.
    static let current = "0.1.1"
}

// MARK: - Entry

/// Runnable CLI entry that returns an exit code (testable; does not call `exit`).
public enum MacverbsApp {
    /// Parse and run with the given argv (no process name). Returns contract exit code.
    public static func run(arguments: [String]) -> Int32 {
        var argv = arguments
        // Leading `--json` is peeled here; root `Macverbs.json` is only for help text.
        let json = GlobalFlags.peelLeading(&argv)

        do {
            var command = try Macverbs.parseAsRoot(argv)
            return try CLIContext.$jsonOutput.withValue(json) {
                try command.run()
                return ExitCodes.success
            }
        } catch let error as MacverbsError {
            return report(error)
        } catch {
            return handleArgumentParserError(error)
        }
    }

    /// Run an arbitrary throwing body under the same error/exit contract as verbs.
    /// Used by tests (and future internal commands) to prove exit 1/2 + stderr.
    public static func runCatching(_ body: () throws -> Void) -> Int32 {
        do {
            try body()
            return ExitCodes.success
        } catch let error as MacverbsError {
            return report(error)
        } catch {
            CLIOutput.writeError(String(describing: error))
            return ExitCodes.system
        }
    }

    private static func report(_ error: MacverbsError) -> Int32 {
        CLIOutput.writeError(error.message)
        return error.processExitCode
    }

    private static func handleArgumentParserError(_ error: Error) -> Int32 {
        let code = Macverbs.exitCode(for: error)
        let text = Macverbs.fullMessage(for: error)
        if !text.isEmpty {
            if code.isSuccess {
                // Help / version / completion scripts → stdout (CLIOutput so tests
                // can redirect; same as process stdout in production).
                CLIOutput.writeText(text)
            } else {
                // Usage and other parser failures → stderr.
                let line = text.hasSuffix("\n") ? text : text + "\n"
                if let data = line.data(using: .utf8) {
                    try? CLIOutput.errFile.write(contentsOf: data)
                }
            }
        }
        return code.rawValue
    }
}
