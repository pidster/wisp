import CreateML
import Foundation

/// Trains a specialised risk classifier on this Mac with Create ML, from labelled commands, into a
/// Core ML text classifier that meets `CoreMLRiskClassifier`'s contract, so `approval.classifier:
/// coreml` loads it as it is. A maximum-entropy model over the command's words: it trains in well
/// under a second and answers in microseconds, which is what a classifier on every command needs
/// ([ADR 0038](../../../../docs/decisions/0038-fast-specialised-classifiers.md)).
///
/// ``ClassifierStore/train(_:source:version:parent:)`` calls it and keeps the result as a new version; the
/// shipped default is trained the same way when a release is prepared (`scripts/check classifier-default`).
public enum RiskClassifierTraining {
    /// What a training run produced.
    public struct Outcome: Equatable, Sendable {
        /// Where the model was written.
        public var url: URL
        /// Examples trained on.
        public var examples: Int
        /// Examples per level, in severity order.
        public var perLevel: [RiskLevel: Int]
        /// The fraction of the training examples the model labels correctly: a sanity check, not a
        /// measurement (use `RiskMeasurement` on examples it did not see).
        public var trainingAccuracy: Double
        /// Seconds spent training and writing.
        public var seconds: Double
    }

    /// Why training refused to run.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// A level has no examples, so the model could never predict it.
        case missingLevel(RiskLevel)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .missingLevel(let level): "no \(level.rawValue) examples; every level needs some"
            }
        }
    }

    /// Trains on `examples` and writes the `.mlmodel` to `url`, replacing any file there.
    ///
    /// - Parameters:
    ///   - examples: Labelled commands; every level must appear.
    ///   - url: Where to write the model; its directory is created.
    ///   - version: The model's version string, shown in each verdict's metadata.
    /// - Returns: What was trained.
    /// - Throws: `Failure`, or a Create ML or file error.
    public static func train(_ examples: [RiskExample], writingTo url: URL, version: String) throws -> Outcome {
        let started = Date()
        var perLevel: [RiskLevel: Int] = [:]
        for example in examples { perLevel[example.level, default: 0] += 1 }
        for level in RiskLevel.allCases where perLevel[level, default: 0] == 0 {
            throw Failure.missingLevel(level)
        }
        let texts = examples.map { CoreMLRiskClassifier.Contract.preprocess($0.command) }
        let labels = examples.map(\.level.rawValue)
        let byLabel = Dictionary(grouping: zip(labels, texts), by: \.0).mapValues { $0.map(\.1) }
        // Create ML holds back a random slice of the training data for its own validation unless told not
        // to, which made two trainings on the same examples disagree on about 4% of predictions and threw
        // examples away; wisp measures on its own held-out sets, so every example trains and the same
        // examples always give the same model.
        let model = try MLTextClassifier(
            trainingData: byLabel, parameters: .init(validation: .none, algorithm: .maxEnt(revision: 1)))
        let correct = zip(texts, labels).filter { text, label in (try? model.prediction(from: text)) == label }.count
        let metadata = MLModelMetadata(
            author: "wisp classifier train", shortDescription: "wisp risk classifier, \(examples.count) examples",
            version: version,
            additional: [
                CoreMLRiskClassifier.Contract.versionKey: CoreMLRiskClassifier.Contract.version,
                CoreMLRiskClassifier.Contract.labelsKey: CoreMLRiskClassifier.Contract.labels,
            ])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try model.write(to: url, metadata: metadata)
        return Outcome(
            url: url, examples: examples.count, perLevel: perLevel,
            trainingAccuracy: examples.isEmpty ? 0 : Double(correct) / Double(examples.count),
            seconds: Date().timeIntervalSince(started))
    }
}
