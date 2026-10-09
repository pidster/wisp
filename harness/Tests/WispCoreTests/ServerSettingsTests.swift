import Foundation
import Testing

@testable import WispCore

/// A local server's settings refused on load when they are out of range or do not parse, rather than replaced by the
/// defaults without a word.
@Suite struct ServerSettingsTests {
    /// Loads `json` as `config.json`, returning the refusal's text, or nil when it loads.
    private func refusal(_ json: String) throws -> String? {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-servers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        try Data(json.utf8).write(to: file)
        do {
            _ = try Config.load(from: file)
            return nil
        } catch let DecodingError.dataCorrupted(context) {
            return context.debugDescription
        }
    }

    @Test func anUnparsableURLOrAnOutOfRangeTimeoutOrWindowIsRefused() throws {
        #expect(try refusal(#"{"ollama":{"baseURL":"not a url"}}"#)?.hasPrefix("ollama: baseURL 'not a url'") == true)
        #expect(try refusal(#"{"llamacpp":{"baseURL":"ftp://host:21"}}"#)?.contains("http or https") == true)
        #expect(try refusal(#"{"lmstudio":{"baseURL":"http://"}}"#)?.hasPrefix("lmstudio: baseURL") == true)
        #expect(try refusal(#"{"ollama":{"timeoutSeconds":0}}"#)?.contains("timeoutSeconds must be between 1") == true)
        #expect(try refusal(#"{"lmstudio":{"timeoutSeconds":100000}}"#)?.contains("(it was 100000)") == true)
        #expect(try refusal(#"{"ollama":{"contextLength":10}}"#)?.contains("contextLength must be between 512") == true)
        #expect(
            try refusal(#"{"ollama":{"models":{"q:8b":{"contextLength":-1}}}}"#)?.contains("models.q:8b.contextLength")
                == true)
        #expect(
            try refusal(#"{"llamacpp":{"models":{"m":{"contextLength":99999999}}}}"#)?.hasPrefix("llamacpp: models.m")
                == true)
        // What is in range loads, as do the absent settings.
        #expect(
            try refusal(
                #"{"ollama":{"baseURL":"http://127.0.0.1:11434","timeoutSeconds":120,"contextLength":16384},"#
                    + #""llamacpp":{"baseURL":"https://box.local:8080","timeoutSeconds":1}}"#) == nil)
        #expect(try refusal("{}") == nil)
    }

    /// The facts settings' shares are refused when outside 0 to 0.5, the summary's as well as the facts'.
    @Test func aFactsShareOrSummaryShareOutOfRangeIsRefused() throws {
        #expect(
            try refusal(#"{"facts":{"summaryShare":0.9}}"#)?.contains("summaryShare must be between 0 and 0.5") == true)
        #expect(try refusal(#"{"facts":{"summaryShare":-0.1}}"#)?.contains("summaryShare") == true)
        #expect(try refusal(#"{"facts":{"share":0.7}}"#)?.contains("share must be between 0 and 0.5") == true)
        #expect(try refusal(#"{"facts":{"share":0.2,"summaryShare":0.5}}"#) == nil)
    }
}
