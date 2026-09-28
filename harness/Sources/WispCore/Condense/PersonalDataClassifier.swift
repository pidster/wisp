import CoreML
import Foundation
import NaturalLanguage
import Synchronization

/// Flags lines that hold personal data the rules cannot recognise, such as a name, an address outside the
/// "number, name, Street" form, or an account holder, for `scan_secrets` and `wisp scan` with personal
/// data requested ([ADR 0042](../../../../docs/decisions/0042-personal-data-classifier.md)).
///
/// A Core ML text classifier over one line, trained by Create ML's transfer learning on contextual
/// embeddings from `training/secrets/train.tsv`, with two labels, `personal` and `other`. It judges
/// lines, not values, so it reports where personal data is and never what it is, and `redact` does not
/// use it. Training it again gives a slightly different model, so the file this build embeds is the
/// classifier: it is trained when its training set changes, measured, and committed, never retrained at a
/// release.
public final class PersonalDataClassifier: Sendable {
    /// What a model asset must satisfy, and the preprocessing it can expect.
    public enum Contract {
        /// The contract `wisp classifier ship --task personal` writes.
        public static let version = "1"
        /// The labels, comma-separated: the flagged one first.
        public static let labels = "personal,other"
        /// The label that flags a line.
        public static let flagged = "personal"
        /// The string input the model takes: the preprocessed line.
        public static let input = "text"
        /// Lines longer than this are judged by their first this-many characters; the training lines
        /// are a line of a log, a ticket, or a file, rarely longer.
        public static let maxCharacters = 500

        /// What the model is given: the line without the U+200B the training files put inside
        /// secret-looking values, trimmed, runs of whitespace collapsed, cut to `maxCharacters`.
        ///
        /// - Parameter line: One line of text.
        /// - Returns: The model's input text.
        public static func preprocess(_ line: String) -> String {
            String(
                line.replacingOccurrences(of: "\u{200B}", with: "").split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ").prefix(maxCharacters))
        }
    }

    /// Why the classifier could not be used. The scan goes on without it and says so.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// This build embeds no classifier, or the resource does not decode.
        case notEmbedded
        /// Core ML could not compile or load the model.
        case unreadable(String)
        /// The model declares another contract or other labels.
        case wrongContract(found: String?)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .notEmbedded: "this build embeds no personal-data classifier"
            case .unreadable(let detail): "cannot load the personal-data classifier: \(detail)"
            case .wrongContract(let found):
                "the personal-data classifier declares \(found ?? "no contract"); this build reads contract "
                    + "\(Contract.version) with labels \(Contract.labels)"
            }
        }
    }

    /// What the embedded classifier records about itself.
    public struct Manifest: Codable, Equatable, Sendable {
        /// Always `personal`.
        public var task: String
        /// The classifier's version, `personal@<version>` in reports.
        public var version: String
        /// When it was trained, ISO 8601.
        public var created: String
        /// The training set it was trained from.
        public var examplesSource: String
        /// Examples trained on.
        public var examples: Int
        /// SHA-256 of the training set's labelled lines, so a changed set is noticed.
        public var examplesDigest: String
        /// Examples per label.
        public var perLabel: [String: Int]
    }

    /// The embedded resource's shape: the manifest and the `.mlmodel` bytes in base64.
    struct Resource: Codable {
        var manifest: Manifest
        var model: String
    }

    /// What the classifier calls itself in reports, `personal@<version>`.
    public let reference: String
    /// The loaded model; `NLModel` is not `Sendable`, so it is only touched under the lock.
    private let model: Mutex<NLModel>

    /// Loads the compiled model at `compiledURL` and checks its contract.
    ///
    /// - Parameters:
    ///   - compiledURL: A compiled `.mlmodelc` directory.
    ///   - version: The version to report.
    /// - Throws: `Failure`.
    public init(compiledURL: URL, version: String) throws {
        let loaded: MLModel
        do {
            loaded = try MLModel(contentsOf: compiledURL)
        } catch {
            throw Failure.unreadable("\(error)")
        }
        let metadata = loaded.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        let declared = metadata[CoreMLRiskClassifier.Contract.versionKey]
        guard declared == Contract.version, metadata[CoreMLRiskClassifier.Contract.labelsKey] == Contract.labels,
            loaded.modelDescription.inputDescriptionsByName.keys.contains(Contract.input)
        else { throw Failure.wrongContract(found: declared.map { "contract \($0)" }) }
        do {
            model = Mutex(try NLModel(mlModel: loaded))
        } catch {
            throw Failure.unreadable("\(error)")
        }
        reference = "personal@\(version)"
    }

    /// The classifier this build embeds, compiled and loaded on first use, or why it cannot be used.
    public static let shipped: Result<PersonalDataClassifier, Failure> = load(PersonalDefaultText.text)

    /// Decodes a resource, compiles its model, and loads it.
    static func load(_ text: String) -> Result<PersonalDataClassifier, Failure> {
        guard let resource = try? JSONDecoder().decode(Resource.self, from: Data(text.utf8)),
            let data = Data(base64Encoded: resource.model)
        else { return .failure(.notEmbedded) }
        let staging = FileManager.default.temporaryDirectory.appending(path: "wisp-personal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let source = staging.appending(path: "personal.mlmodel")
            try data.write(to: source)
            let compiled = try Blocking.run { try await MLModel.compileModel(at: source) }
            defer { try? FileManager.default.removeItem(at: compiled) }
            return .success(try PersonalDataClassifier(compiledURL: compiled, version: resource.manifest.version))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.unreadable("\(error)"))
        }
    }

    /// The embedded classifier's manifest, or nil when none is embedded.
    public static var shippedManifest: Manifest? {
        try? JSONDecoder().decode(Resource.self, from: Data(PersonalDefaultText.text.utf8)).manifest
    }

    /// Whether `line` holds personal data: the model's top label is `personal`. A blank line never does.
    public func flags(_ line: String) -> Bool {
        let text = Contract.preprocess(line)
        guard !text.isEmpty else { return false }
        return model.withLock { $0.predictedLabel(for: text) } == Contract.flagged
    }

    /// The resource text for a trained model, as `wisp classifier ship --task personal` writes it.
    ///
    /// - Parameters:
    ///   - manifest: What the model records about itself.
    ///   - model: The `.mlmodel` bytes.
    /// - Returns: The JSON text.
    /// - Throws: An encoding error.
    public static func resource(manifest: Manifest, model: Data) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Resource(manifest: manifest, model: model.base64EncodedString()))
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
