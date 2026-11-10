import Foundation

/// Files under ~/Library/Application Support/AQIBar (folder is 0700).
enum AppFiles {
    static var directory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AQIBar", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        return dir
    }
    static var keyURL: URL { directory.appendingPathComponent("openaq.key") }
    static var stationPlanURL: URL { directory.appendingPathComponent("stations.json") }
    static var lastLocationURL: URL { directory.appendingPathComponent("last-location.json") }

    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The OpenAQ API key, kept in a 0600 file rather than the Keychain: this app is ad-hoc
/// signed and every rebuild changes its signature, so a Keychain item would prompt for
/// your login password after each rebuild. The key is never logged or printed.
enum KeyStore {
    static func load() -> String? {
        guard let data = try? Data(contentsOf: AppFiles.keyURL),
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = AppFiles.keyURL
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(trimmed.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // A new key may see different stations; search again.
        try? FileManager.default.removeItem(at: AppFiles.stationPlanURL)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: AppFiles.keyURL)
        try? FileManager.default.removeItem(at: AppFiles.stationPlanURL)
    }
}

/// The last coordinate the app located, so `--print-once` can run without Location Services.
struct LastLocation: Codable {
    let latitude: Double
    let longitude: Double
    let placeName: String?
}
