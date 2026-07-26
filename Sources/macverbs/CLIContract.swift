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
            return message
        }
    }

    var description: String { message }

    var processExitCode: Int32 {
        switch self {
        case .domain:
            return ExitCodes.domain
        case .system:
            return ExitCodes.system
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
    /// Write a domain/system error line to stderr (`error: …`).
    static func writeError(_ message: String) {
        let line = "error: \(message)\n"
        if let data = line.data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }

    /// Write human text to stdout.
    static func writeText(_ text: String) {
        print(text)
    }

    /// Write one JSON value to stdout (pretty-printed, stable key order).
    static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try FileHandle.standardOutput.write(contentsOf: data)
        if let newline = "\n".data(using: .utf8) {
            try FileHandle.standardOutput.write(contentsOf: newline)
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
}
