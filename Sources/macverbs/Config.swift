import Foundation

// MARK: - Paths

/// Resolution of the macverbs config directory and known files.
///
/// Default: `~/.config/macverbs`. Override with env `MACVERBS_CONFIG_DIR`
/// (tilde is expanded). Never hardcodes personal account labels.
enum ConfigPaths {
    /// Environment variable that overrides the config directory.
    static let envConfigDir = "MACVERBS_CONFIG_DIR"

    /// Calendar UID → label map filename under the config directory.
    static let calendarsFileName = "calendars.json"

    /// Resolve the config directory from environment (or default under home).
    ///
    /// - Parameters:
    ///   - environment: Process environment; injectable for tests.
    ///   - homeDirectory: User home; injectable for tests.
    static func configDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let raw = environment[envConfigDir]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        {
            return expandTilde(raw, home: homeDirectory)
        }
        return
            homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("macverbs", isDirectory: true)
    }

    /// Full path to `calendars.json` under the resolved config directory.
    static func calendarsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        configDirectory(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent(calendarsFileName, isDirectory: false)
    }

    /// Expand a leading `~` or `~/…` against `home`. Absolute paths pass through.
    static func expandTilde(_ path: String, home: URL) -> URL {
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            // Join path segments explicitly so multi-level paths keep their slashes
            // (avoid treating "a/b" as a single path component name).
            var url = home
            for segment in rest.split(separator: "/") where !segment.isEmpty {
                url = url.appendingPathComponent(String(segment), isDirectory: true)
            }
            return url
        }
        // Absolute or relative path as given (FileManager-compatible string URL).
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

// MARK: - Calendar aliases

/// Map of calendar EventKit/UID → short human label (e.g. account name).
///
/// Used by calendar listing to disambiguate same-named calendars across accounts.
/// Oracle shape: `{"UID": "Label", ...}`.
struct CalendarAliases: Equatable, Sendable {
    /// UID → label. Empty when config is missing or unreadable.
    var labelsByUID: [String: String]

    /// Empty map (config absent / invalid).
    static let empty = CalendarAliases(labelsByUID: [:])

    /// Label for a calendar UID, or `fallback` when unmapped.
    func label(forUID uid: String, fallback: String) -> String {
        labelsByUID[uid] ?? fallback
    }
}

// MARK: - Load

/// Load user config files. Missing or invalid input yields empty defaults (no crash).
enum Config {
    /// Load calendar UID→label aliases from `calendars.json`.
    ///
    /// - Parameters:
    ///   - url: File to read. Default resolves via `ConfigPaths.calendarsURL()`.
    ///   - fileManager: Injectable for tests.
    /// - Returns: Parsed aliases, or `.empty` if the file is absent, unreadable, or not a string map.
    static func loadCalendarAliases(
        from url: URL = ConfigPaths.calendarsURL(),
        fileManager: FileManager = .default
    ) -> CalendarAliases {
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }
        guard let data = try? Data(contentsOf: url) else {
            return .empty
        }
        return decodeCalendarAliases(from: data)
    }

    /// Decode alias map from JSON data (UID → label). Invalid → empty.
    static func decodeCalendarAliases(from data: Data) -> CalendarAliases {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return .empty
        }
        guard let dict = object as? [String: Any] else {
            return .empty
        }
        var labels: [String: String] = [:]
        labels.reserveCapacity(dict.count)
        for (uid, value) in dict {
            guard let label = value as? String else {
                // Non-string values: skip entry rather than fail the whole file.
                continue
            }
            labels[uid] = label
        }
        // If the root was an object but every value was non-string, still return
        // whatever string entries we got (possibly empty) — never throw.
        return CalendarAliases(labelsByUID: labels)
    }
}
