import Foundation

// MARK: - Exit codes (docs/behavior.md)

/// Process exit codes for the macverbs CLI contract.
enum ExitCodes {
    /// Success.
    static let success: Int32 = 0
    /// Domain / user error (not found, unsupported, denied).
    static let domain: Int32 = 1
    /// System / backend failure.
    static let system: Int32 = 2
    /// Usage / parse error (`EX_USAGE`).
    static let usage: Int32 = 64
}

// MARK: - Errors

/// Typed failures that map to the global exit-code contract.
///
/// Messages go to **stderr** only; never to JSON stdout.
enum MacverbsError: Error, CustomStringConvertible, Equatable {
    /// Domain / user error → exit 1.
    case domain(String)
    /// System / backend failure → exit 2.
    case system(String)

    var message: String {
        switch self {
        case .domain(let message), .system(let message):
            message
        }
    }

    var description: String { message }

    var processExitCode: Int32 {
        switch self {
        case .domain:
            ExitCodes.domain
        case .system:
            ExitCodes.system
        }
    }
}

// MARK: - Output mode

/// Process-local output mode. Set from leading `--json` before dispatch.
enum CLIContext {
    /// When true, successful command results are one JSON value on stdout.
    @TaskLocal static var jsonOutput: Bool = false
}

// MARK: - Global flags

enum GlobalFlags {
    /// Peel leading global flags so `--json` works **before** the subcommand
    /// (parity with `apple --json calendar list`).
    ///
    /// Stops at the first positional token or unknown option so ArgumentParser
    /// can handle `--help`, `--version`, and domain options.
    static func peelLeading(_ argv: inout [String]) -> Bool {
        var json = false
        while let first = argv.first {
            switch first {
            case "--json":
                json = true
                argv.removeFirst()
            default:
                return json
            }
        }
        return json
    }
}

// MARK: - Stdio helpers

enum CLIOutput {
    /// Injectable for tests; defaults to process stdio.
    /// CLI is single-threaded at the entrypoint; tests redirect serially.
    nonisolated(unsafe) static var standardOutput: FileHandle = .standardOutput
    nonisolated(unsafe) static var standardError: FileHandle = .standardError

    /// Write a domain/system error line to stderr (`error: …`).
    static func writeError(_ message: String) {
        let line = "error: \(message)\n"
        write(line, to: standardError)
    }

    /// Write human text to stdout.
    static func writeText(_ text: String) {
        let line = text.hasSuffix("\n") ? text : text + "\n"
        write(line, to: standardOutput)
    }

    /// Write one JSON value to stdout (pretty-printed, stable key order).
    static func writeJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try standardOutput.write(contentsOf: data)
        if let newline = "\n".data(using: .utf8) {
            try standardOutput.write(contentsOf: newline)
        }
    }

    /// Emit a successful result as JSON or human text depending on `CLIContext.jsonOutput`.
    static func emit<T: Encodable>(_ value: T, text: (T) -> String) throws {
        if CLIContext.jsonOutput {
            try writeJSON(value)
        } else {
            writeText(text(value))
        }
    }

    private static func write(_ string: String, to handle: FileHandle) {
        if let data = string.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}
