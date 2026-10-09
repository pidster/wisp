import Foundation

@testable import WispCore

/// What a test that lists or resolves models gives wisp so it never reaches a real server or the real home: every
/// HTTP backend (Ollama, llama.cpp, LM Studio) pointed at port 1 of the loopback address, which refuses at once
/// without a lookup, and a home in a temporary directory that is never created.
enum OfflineBackends {
    /// Where every HTTP backend is pointed: nothing listens on port 1.
    static let baseURL = "http://127.0.0.1:1"

    /// A home under the temporary directory, never `~/.wisp`; nothing is created there unless a test does.
    static let home = Home(
        root: FileManager.default.temporaryDirectory.appending(path: "wisp-offline-home-\(UUID().uuidString)"))

    /// The three backends' sections, as `config.json` spells them.
    static var sections: [String: Any] {
        [
            "ollama": ["baseURL": baseURL, "timeoutSeconds": 1],
            "llamacpp": ["baseURL": baseURL, "timeoutSeconds": 1],
            "lmstudio": ["baseURL": baseURL, "timeoutSeconds": 1],
        ]
    }

    /// A configuration with only the three backends offline.
    static var config: Config {
        Config(
            ollama: .init(baseURL: baseURL, timeoutSeconds: 1), llamacpp: .init(baseURL: baseURL, timeoutSeconds: 1),
            lmstudio: .init(baseURL: baseURL, timeoutSeconds: 1))
    }

    /// `json`, a `config.json`'s text, with the three backends offline wherever it does not set them itself.
    ///
    /// - Parameter json: The file's text; nil for an otherwise empty file.
    /// - Returns: The text to write.
    static func file(_ json: String? = nil) -> String {
        var object =
            json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        for (key, value) in sections where object[key] == nil { object[key] = value }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
