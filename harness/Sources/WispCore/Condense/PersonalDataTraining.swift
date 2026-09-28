import CreateML
import CryptoKit
import Foundation

/// Trains the personal-data classifier (`PersonalDataClassifier`) with Create ML from the secrets
/// training set: `personal` lines against everything else, by transfer learning on contextual
/// embeddings, which measured best on dev ([ADR 0042](../../../../docs/decisions/0042-personal-data-classifier.md)).
/// This algorithm holds back a random tenth of the examples to decide when to stop, even when told not to
/// validate, unless it is given a validation set; the dev set is that set, so every training example
/// trains. What is left is the network's random start, which Create ML does not let wisp seed: two
/// trainings still differ on a few lines, so the trained file, not the training, is what ships.
public enum PersonalDataTraining {
    /// Why training refused to run.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// No `personal` lines, or nothing else.
        case oneSided

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .oneSided: "the examples and the validation set each need both personal lines and other lines"
            }
        }
    }

    /// The label each training line gets: `personal`, or `other` for `secret` and `none`.
    public static func label(_ label: String) -> String {
        label == PersonalDataClassifier.Contract.flagged ? label : "other"
    }

    /// Trains on `examples` (labelled `secret`, `personal`, or `none`) and writes the `.mlmodel` to `url`.
    ///
    /// - Parameters:
    ///   - examples: The labelled lines.
    ///   - validation: Labelled lines that decide when training stops: the dev set, never the test set.
    ///   - source: Where they came from, for the manifest.
    ///   - url: Where to write the model; replaced if present.
    ///   - version: The classifier's version.
    /// - Returns: The manifest.
    /// - Throws: `Failure`, or a Create ML or file error.
    public static func train(
        _ examples: [TrainingSplit.Example], validation: [TrainingSplit.Example], source: String, writingTo url: URL,
        version: String
    ) throws -> PersonalDataClassifier.Manifest {
        let texts = examples.map { PersonalDataClassifier.Contract.preprocess($0.text) }
        let labels = examples.map { label($0.label) }
        let byLabel = Dictionary(grouping: zip(labels, texts), by: \.0).mapValues { $0.map(\.1) }
        let held = Dictionary(grouping: validation, by: { label($0.label) }).mapValues {
            $0.map { PersonalDataClassifier.Contract.preprocess($0.text) }
        }
        guard byLabel.count == 2, held.count == 2 else { throw Failure.oneSided }
        let model = try MLTextClassifier(
            trainingData: byLabel,
            parameters: .init(
                validation: .dictionary(held), algorithm: .transferLearning(.elmoEmbedding, revision: 1)))
        let metadata = MLModelMetadata(
            author: "wisp classifier ship", shortDescription: "wisp personal-data classifier",
            version: version,
            additional: [
                CoreMLRiskClassifier.Contract.versionKey: PersonalDataClassifier.Contract.version,
                CoreMLRiskClassifier.Contract.labelsKey: PersonalDataClassifier.Contract.labels,
            ])
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try model.write(to: url, metadata: metadata)
        let lines = examples.map { "\($0.label)\t\($0.text)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
        return PersonalDataClassifier.Manifest(
            task: "personal", version: version, created: Date().formatted(.iso8601), examplesSource: source,
            examples: examples.count, examplesDigest: digest,
            perLabel: byLabel.mapValues(\.count))
    }
}
