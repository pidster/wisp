import Foundation

/// Replaces secrets and personal data with numbered markers, `[REDACTED:email#1]`, so a reader can
/// still tell that two places hold the same value without seeing it. Numbers are per kind, in order of
/// first appearance, and stay stable across both passes of one redaction.
public struct Redactor: Sendable {
    /// Per kind, the number given to each value.
    private var numbers: [String: [String: Int]] = [:]
    /// Occurrences replaced, per kind.
    public private(set) var counts: [String: Int] = [:]

    /// Creates a redactor with no values seen.
    public init() {}

    /// The marker that stands for the `number`th value of `kind`.
    public static func marker(kind: String, number: Int) -> String {
        "[REDACTED:\(kind)#\(number)]"
    }

    /// Markers already in a text, so a later pass never rewrites inside one.
    static let markerPattern = #"\[REDACTED:[a-z\-]+#\d+\]"#

    /// The marker for `value`, numbering it on first sight, and the count of replacements.
    private mutating func marker(for value: String, kind: String) -> String {
        let number: Int
        if let known = numbers[kind]?[value] {
            number = known
        } else {
            number = (numbers[kind]?.count ?? 0) + 1
            numbers[kind, default: [:]][value] = number
        }
        counts[kind, default: 0] += 1
        return Self.marker(kind: kind, number: number)
    }

    /// Replaces each rule match in `text`, which must be the text the matches were found in.
    ///
    /// - Parameters:
    ///   - matches: From `SecretScanner.scan(text)`, in order and without overlaps.
    ///   - text: The scanned text.
    /// - Returns: The text with every match replaced by its marker.
    public mutating func apply(_ matches: [SecretScanner.Match], to text: String) -> String {
        var output = ""
        var cursor = text.startIndex
        for match in matches where match.range.lowerBound >= cursor {
            output += text[cursor..<match.range.lowerBound]
            output += marker(for: match.value, kind: match.kind)
            cursor = match.range.upperBound
        }
        output += text[cursor...]
        return output
    }

    /// Replaces every occurrence of each literal value outside the markers already present, longest value
    /// first so a value inside another is not split.
    ///
    /// - Parameters:
    ///   - literals: Values and their kinds, as the model pass reported them.
    ///   - text: A text, typically already redacted by rule.
    /// - Returns: The text with each occurrence replaced.
    public mutating func apply(literals: [(value: String, kind: String)], to text: String) -> String {
        var text = text
        for literal in literals.sorted(by: { $0.value.count > $1.value.count }) {
            let protected = Self.markerRanges(in: text)
            var output = ""
            var cursor = text.startIndex
            var search = text.startIndex
            while let found = text.range(of: literal.value, range: search..<text.endIndex) {
                search = found.upperBound
                if protected.contains(where: { $0.overlaps(found) }) { continue }
                output += text[cursor..<found.lowerBound]
                output += marker(for: literal.value, kind: literal.kind)
                cursor = found.upperBound
            }
            output += text[cursor...]
            text = output
        }
        return text
    }

    /// Where the markers are in `text`.
    static func markerRanges(in text: String) -> [Range<String.Index>] {
        guard let regex = try? RegexCache.regex(markerPattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text)
        }
    }
}

/// The model's pass over text the rules have already redacted: it names what rules cannot recognise, a
/// person's name, a street address, a customer number, a private hostname, a credential with no known
/// shape. It sees each chunk in a fresh tool-less turn with a schema, like `Triage`, and only values
/// that occur exactly in the chunk are kept, so it cannot invent or alter text; replacing them is the
/// `Redactor`'s job, never the model's.
public struct ModelSweep: Sendable {
    /// What the model may call a value, and the category each belongs to.
    public static let kinds: [String: SecretScanner.Category] = [
        "credential": .secret, "name": .personal, "email": .personal, "phone": .personal, "address": .personal,
        "identifier": .personal, "hostname": .personal,
    ]

    /// Shortest value kept: shorter ones are common words or fragments more often than data.
    static let minimumLength = 4

    /// The shape each chunk's answer must take.
    public static let schemaJSON: JSONValue = [
        "type": "object",
        "properties": [
            "items": [
                "type": "array", "maxItems": 20,
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "The value, copied exactly as it appears"],
                        "kind": [
                            "type": "string",
                            "enum": ["credential", "name", "email", "phone", "address", "identifier", "hostname"],
                            "description": "What the value is",
                        ],
                    ],
                    "required": ["text", "kind"],
                ],
            ]
        ],
        "required": ["items"],
    ]

    /// Bytes per chunk.
    public var chunkBytes: Int
    /// Turns per chunk at most. The small model names a couple of values per answer, so the chunk is
    /// asked again with what it found hidden, until an answer adds nothing or this many turns have run.
    public var passes: Int
    /// Answers one chunk's prompt with JSON of `schemaJSON`'s shape.
    private let judge: Triage.Judge

    /// Creates a sweep.
    ///
    /// - Parameters:
    ///   - chunkBytes: Bytes per chunk shown to the model; cut at line ends.
    ///   - passes: Turns per chunk at most; at least one.
    ///   - judge: A fresh model turn each time.
    public init(chunkBytes: Int = 4096, passes: Int = 3, judge: @escaping Triage.Judge) {
        self.chunkBytes = chunkBytes
        self.passes = max(1, passes)
        self.judge = judge
    }

    /// The prompt for one chunk.
    public static func prompt(chunk: String, index: Int, count: Int, label: String) -> String {
        """
        Below is part \(index) of \(count) of \(label). Known secrets are already replaced by [REDACTED:...] \
        markers. List every remaining value that is a credential (password, key, token) or personal data about \
        a person: their name, email address, phone number, street address, an account or customer number, or a \
        private hostname. Copy each value exactly as it appears, without surrounding text. Do not list code \
        identifiers, file paths, version numbers, dates, or the markers. An empty list is the right answer when \
        there is nothing.

        TEXT:
        \(chunk)
        """
    }

    /// The values in one chunk's answer that occur in the chunk, with their kinds; anything malformed,
    /// too short, not in the chunk, or overlapping a marker is dropped.
    public static func values(in json: String, chunk: String) -> [(value: String, kind: String)] {
        guard let data = json.data(using: .utf8), let answer = try? JSONDecoder().decode(JSONValue.self, from: data),
            let items = answer.objectValue?["items"]?.arrayValue
        else { return [] }
        return items.compactMap { item in
            guard let fields = item.objectValue, let raw = fields["text"]?.stringValue,
                let kind = fields["kind"]?.stringValue, kinds[kind] != nil
            else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= minimumLength, !value.contains("REDACTED"), chunk.contains(value) else { return nil }
            return (value, kind)
        }
    }

    /// Judges every chunk of `text`, each up to `passes` times, and returns the distinct values found, in
    /// order. A turn that fails, a guardrail refusal or a runtime error, is asked once more; if it fails
    /// again the chunk keeps what earlier turns found and is reported failed, and the sweep goes on, so
    /// one refused chunk never costs the rest of the text or the rules' findings.
    ///
    /// - Parameters:
    ///   - text: Text already redacted by rule.
    ///   - label: What it is, for the prompt.
    /// - Returns: The values, the number of chunks, and the 1-based numbers of the chunks that failed.
    /// - Throws: `CancellationError` when the task is cancelled; nothing else.
    public func run(
        _ text: String, label: String
    ) async throws -> (values: [(value: String, kind: String)], chunks: Int, failed: [Int]) {
        let pieces = Triage.chunks(text, maxBytes: chunkBytes)
        var seen: Set<String> = []
        var values: [(value: String, kind: String)] = []
        var failed: [Int] = []
        for (index, piece) in pieces.enumerated() {
            var shown = piece
            for _ in 0..<passes {
                let prompt = Self.prompt(chunk: shown, index: index + 1, count: pieces.count, label: label)
                guard let answer = try await answer(prompt) else {
                    failed.append(index + 1)
                    break
                }
                let new = Self.values(in: answer, chunk: shown).filter { seen.insert($0.value).inserted }
                guard !new.isEmpty else { break }
                values += new
                // Hide what was found so the next turn looks past it; the numbers do not matter here.
                for found in new {
                    shown = shown.replacingOccurrences(
                        of: found.value, with: Redactor.marker(kind: found.kind, number: 0))
                }
            }
        }
        return (values, pieces.count, failed)
    }

    /// The judge's answer to `prompt`, asked a second time if the first attempt fails; nil when both do.
    ///
    /// - Throws: `CancellationError` when the task is cancelled.
    private func answer(_ prompt: String) async throws -> String? {
        for _ in 0..<2 {
            try Task.checkCancellation()
            do {
                return try await judge(prompt)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return nil
    }
}
