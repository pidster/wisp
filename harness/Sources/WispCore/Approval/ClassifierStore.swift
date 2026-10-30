import CryptoKit
import Foundation

/// The risk classifiers on this Mac, one directory per version under `<home>/classifiers/risk`: the
/// default that ships with each release, never changed, and the versions trained here, never
/// overwritten ([ADR 0038](../../../../docs/decisions/0038-fast-specialised-classifiers.md), amendment).
///
/// A version is named `<wisp version>-default` for the shipped one and `<wisp version>-local.<n>` for
/// those trained here, and referred to as `risk@<version>`. Each directory holds `model.mlmodel`,
/// read-only, and `manifest.json`: what it was trained from and every measurement taken of it.
///
/// Versions are kept rather than replaced because retraining once overwrote the model the gate used, silently,
/// with no history and no way back, and Create ML's training was not then repeatable. The configuration names a
/// version as `risk@<version>` in `approval.coremlModel`; `wisp classifier` is the CLI over the store, and
/// ``CoreMLRiskClassifier`` loads the version a session uses.
public struct ClassifierStore: Sendable {
    /// The task every version here serves.
    public static let task = "risk"

    /// What a version records about itself.
    public struct Manifest: Codable, Equatable, Sendable {
        /// The task, `risk`.
        public var task: String
        /// The version, such as `0.12.0-local.1`.
        public var version: String
        /// The wisp that trained it.
        public var wispVersion: String
        /// When, ISO 8601.
        public var created: String
        /// What it learned from: `bundled`, a file's path, and `+ audit` when the audit log was added.
        public var examplesSource: String
        /// Examples trained on.
        public var examples: Int
        /// Examples per level.
        public var perLevel: [String: Int]
        /// SHA-256 of the examples, one `level<TAB>command` line each in order, so two versions trained
        /// on the same examples can be told apart from two that were not.
        public var examplesDigest: String
        /// The version in use when this one was trained, if any.
        public var parent: String?
        /// Measurements taken since, oldest first.
        public var measurements: [Measured]

        /// One `wisp classifier measure` of the version, beside the rules.
        public struct Measured: Codable, Equatable, Sendable {
            /// When, ISO 8601.
            public var date: String
            /// The labelled commands it was measured on.
            public var examplesSource: String
            /// Rated exactly.
            public var correct: Int
            /// Commands measured.
            public var total: Int
            /// Rated below their level.
            public var under: Int
            /// Rated above their level.
            public var over: Int
            /// Median milliseconds per verdict.
            public var p50Milliseconds: Double
            /// 95th-percentile milliseconds per verdict.
            public var p95Milliseconds: Double
            /// Whether no dangerous command was rated safe.
            public var holdsTheHardRequirement: Bool

            /// A measurement from a report taken now.
            ///
            /// - Parameters:
            ///   - report: What ``RiskMeasurement`` found.
            ///   - examplesSource: The labelled commands it was measured on.
            public init(_ report: RiskMeasurement.Report, examplesSource: String) {
                date = Date().ISO8601Format()
                self.examplesSource = examplesSource
                correct = report.correct
                total = report.total
                under = report.under
                over = report.over
                p50Milliseconds = report.p50Milliseconds
                p95Milliseconds = report.p95Milliseconds
                holdsTheHardRequirement = report.holdsTheHardRequirement
            }
        }
    }

    /// Why the store refused.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// No such version.
        case unknownVersion(String)
        /// The version is the one configured, or the shipped default.
        case protected(String, reason: String)
        /// A reference that is not `risk@<version>`.
        case notAReference(String)
        /// A version name that could reach outside the store (`..`, `/`) or holds other characters.
        case invalidVersion(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .invalidVersion(let version):
                "'\(version)' is not a classifier version: use letters, digits, '.', '_', '+', and '-', without '..'"
            case .unknownVersion(let version): "no classifier version \(version); 'wisp classifier list' shows them"
            case .protected(let version, let reason): "\(version) cannot be removed: \(reason)"
            case .notAReference(let text): "'\(text)' is not a classifier version; use risk@<version>"
            }
        }
    }

    /// `<home>/classifiers/risk`.
    public let root: URL

    /// A store under `home`.
    ///
    /// - Parameter home: wisp's home; the store is its `classifiers/risk`.
    public init(home: Home) {
        root = home.root.appending(path: "classifiers").appending(path: Self.task)
    }

    /// The version name of the default that ships with `wispVersion`.
    ///
    /// - Parameter wispVersion: A wisp version; this build's by default.
    /// - Returns: `<wispVersion>-default`.
    public static func defaultVersion(_ wispVersion: String = WispVersion.current) -> String {
        "\(wispVersion)-default"
    }

    /// The version a `risk@<version>` reference names, or nil for anything else (a path, a file name).
    /// A malformed version (`risk@../../x`, one with a `/`) is not a reference: it would name a directory
    /// outside the store.
    ///
    /// - Parameter reference: A configuration value, such as `risk@0.12.0-local.1`.
    /// - Returns: The version, or nil.
    public static func version(of reference: String) -> String? {
        let prefix = "\(task)@"
        guard reference.hasPrefix(prefix), reference.count > prefix.count else { return nil }
        let version = String(reference.dropFirst(prefix.count))
        return isValidVersion(version) ? version : nil
    }

    /// Whether `version` can name a directory in the store and nothing outside it: letters, digits, `.`, `_`,
    /// `+`, and `-`, not starting with `.`, and without `..` or `/`, at most 128 characters.
    ///
    /// - Parameter version: The name to check.
    /// - Returns: True when it is safe to use as a directory name in the store.
    public static func isValidVersion(_ version: String) -> Bool {
        !version.isEmpty && version.count <= 128 && !version.hasPrefix(".") && !version.contains("..")
            && version.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) }
    }

    /// The reference for `version`, as config names it.
    ///
    /// - Parameter version: The version.
    /// - Returns: `risk@<version>`.
    public static func reference(_ version: String) -> String { "\(task)@\(version)" }

    /// Labelled commands kept out of every training run on this Mac: a test set of commands actually run
    /// here, which `--from-audit` would otherwise learn from. `train` always leaves out anything that
    /// overlaps it.
    public var heldOut: URL { root.appending(path: "held-out.tsv") }

    /// `examples` without any that overlap `heldOut` (exactly, after normalising, by family, or by near
    /// match), and how many were left out.
    ///
    /// The comparison is ``TrainingSplit/overlaps(_:_:)``'s, so a near copy of a held-out command cannot leak
    /// into training and inflate the held-out measurement.
    ///
    /// - Parameters:
    ///   - examples: The training examples.
    ///   - extra: Other held-out files to keep out as well; missing ones are skipped.
    /// - Returns: The examples kept, and the number removed.
    public func withoutHeldOut(_ examples: [RiskExample], also extra: [URL] = []) -> (kept: [RiskExample], removed: Int)
    {
        let files = ([heldOut] + extra).filter { FileManager.default.fileExists(atPath: $0.path) }
        let held = files.flatMap { url in (try? String(contentsOf: url, encoding: .utf8)).map(TrainingSplit.parse) ?? []
        }
        guard !held.isEmpty else { return (examples, 0) }
        let asExamples = examples.map { TrainingSplit.Example(label: $0.level.rawValue, text: $0.command) }
        let clashing = Set(TrainingSplit.overlaps(held, asExamples).map(\.second))
        let kept = examples.filter { !clashing.contains($0.command) }
        return (kept, examples.count - kept.count)
    }

    /// The directory of `version`.
    ///
    /// - Parameter version: A valid version name.
    /// - Returns: `<root>/<version>`.
    public func directory(_ version: String) -> URL { root.appending(path: version) }

    /// The model file of `version`.
    ///
    /// - Parameter version: A valid version name.
    /// - Returns: The version's `model.mlmodel`.
    public func model(_ version: String) -> URL { directory(version).appending(path: "model.mlmodel") }

    /// Every version with a manifest, the default first, then newest last.
    ///
    /// - Returns: The manifests, ordered by creation then name after any default.
    public func versions() -> [Manifest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let manifests = names.compactMap { manifest($0) }
        return manifests.sorted { lhs, rhs in
            let l = lhs.version.hasSuffix("-default")
            let r = rhs.version.hasSuffix("-default")
            if l != r { return l }
            return (lhs.created, lhs.version) < (rhs.created, rhs.version)
        }
    }

    /// The manifest of `version`, or nil.
    ///
    /// - Parameter version: The version; an invalid name gives nil without touching the disk.
    /// - Returns: The manifest, or nil when it is missing or unreadable.
    public func manifest(_ version: String) -> Manifest? {
        guard Self.isValidVersion(version) else { return nil }
        let url = directory(version).appending(path: "manifest.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    }

    /// The name the next version trained by `wispVersion` gets: `<wisp version>-local.<n>`, one past
    /// the highest `n` any version has, whichever wisp trained it, so the numbers never repeat.
    ///
    /// - Parameter wispVersion: The training wisp's version; this build's by default.
    /// - Returns: The version name.
    public func nextLocalVersion(_ wispVersion: String = WispVersion.current) -> String {
        let highest =
            versions().compactMap { manifest in
                manifest.version.split(separator: ".").last.flatMap { Int($0) }
                    .flatMap { manifest.version.contains("-local.") ? $0 : nil }
            }.max() ?? 0
        return "\(wispVersion)-local.\(highest + 1)"
    }

    /// SHA-256 of examples, as `Manifest.examplesDigest` records it.
    ///
    /// - Parameter examples: The examples, in training order.
    /// - Returns: The lowercase hex digest.
    public static func digest(_ examples: [RiskExample]) -> String {
        let text = examples.map { "\($0.level.rawValue)\t\($0.command)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Adds a version: moves the trained model into its directory, makes it read-only, and writes the
    /// manifest, which later gains only measurements. An existing version is never replaced: the directory is
    /// created without intermediates, which fails when it is already there.
    ///
    /// - Parameters:
    ///   - model: The trained `.mlmodel`, moved into the store.
    ///   - manifest: Its manifest, which names the version.
    /// - Throws: `Failure.invalidVersion`, or a file-system error, including when the version exists.
    public func add(model: URL, manifest: Manifest) throws {
        guard Self.isValidVersion(manifest.version) else { throw Failure.invalidVersion(manifest.version) }
        let dir = directory(manifest.version)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: model, to: self.model(manifest.version))
        try write(manifest)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: self.model(manifest.version).path)
    }

    /// Writes a manifest, replacing the old one; only measurements are ever added to it afterwards.
    ///
    /// - Parameter manifest: The manifest, written atomically to its version's `manifest.json`.
    /// - Throws: An encoding or file-system error.
    func write(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: directory(manifest.version).appending(path: "manifest.json"), options: .atomic)
    }

    /// Records a measurement in `version`'s manifest.
    ///
    /// - Parameters:
    ///   - measured: The measurement.
    ///   - version: The version measured.
    /// - Throws: `Failure.unknownVersion`, or a file-system error.
    public func record(_ measured: Manifest.Measured, for version: String) throws {
        guard var manifest = manifest(version) else { throw Failure.unknownVersion(version) }
        manifest.measurements.append(measured)
        try write(manifest)
    }

    /// Removes a local version. The shipped default and the version the configuration names are protected, so a
    /// session never loses its classifier.
    ///
    /// - Parameters:
    ///   - version: The version.
    ///   - inUse: The version the configuration names, which cannot go.
    /// - Throws: `Failure`, or a file-system error.
    public func remove(_ version: String, inUse: String?) throws {
        guard manifest(version) != nil else { throw Failure.unknownVersion(version) }
        if version.hasSuffix("-default") { throw Failure.protected(version, reason: "it is the shipped default") }
        if version == inUse { throw Failure.protected(version, reason: "approval.coremlModel names it") }
        try FileManager.default.removeItem(at: directory(version))
    }

    /// Trains a new version from `examples` and adds it, never replacing one.
    ///
    /// The model is trained into a temporary file, then moved into the store with its manifest.
    ///
    /// - Parameters:
    ///   - examples: What to learn from; every level must appear.
    ///   - source: Where they came from, for the manifest.
    ///   - version: The version name; `nextLocalVersion()` when nil.
    ///   - parent: The version in use now, if any.
    /// - Returns: The new version's manifest and the training outcome.
    /// - Throws: `RiskClassifierTraining.Failure`, a Create ML error, or a file-system error.
    public func train(
        _ examples: [RiskExample], source: String, version: String? = nil, parent: String? = nil
    )
        throws -> (manifest: Manifest, outcome: RiskClassifierTraining.Outcome)
    {
        let version = version ?? nextLocalVersion()
        guard Self.isValidVersion(version) else { throw Failure.invalidVersion(version) }
        let staging = FileManager.default.temporaryDirectory.appending(path: "wisp-train-\(UUID().uuidString).mlmodel")
        let outcome = try RiskClassifierTraining.train(examples, writingTo: staging, version: version)
        let manifest = Manifest(
            task: Self.task, version: version, wispVersion: WispVersion.current, created: Date().ISO8601Format(),
            examplesSource: source, examples: outcome.examples,
            perLevel: Dictionary(uniqueKeysWithValues: outcome.perLevel.map { ($0.key.rawValue, $0.value) }),
            examplesDigest: Self.digest(examples), parent: parent, measurements: [])
        try add(model: staging, manifest: manifest)
        return (manifest, outcome)
    }

    /// Writes the default shipped with this build into the store if it is not there yet, from
    /// `ShippedClassifier`; nothing is written when the build carries none. Called when a session or
    /// `wisp classifier` first needs it.
    ///
    /// - Returns: The default's version, or nil when this build ships none.
    /// - Throws: A file-system error.
    @discardableResult
    public func installDefault() throws -> String? {
        guard let shipped = ShippedClassifier.current else { return nil }
        if manifest(shipped.manifest.version) != nil { return shipped.manifest.version }
        let staging = FileManager.default.temporaryDirectory.appending(
            path: "wisp-default-\(UUID().uuidString).mlmodel")
        try shipped.model.write(to: staging)
        try add(model: staging, manifest: shipped.manifest)
        return shipped.manifest.version
    }
}

/// The default risk classifier this build ships: trained once when the release is prepared, measured by
/// the eval, and embedded from `Resources/risk-default.json` (the manifest and the model, base64).
///
/// It is the default classifier ([ADR 0041](../../../../docs/decisions/0041-shipped-classifier-is-the-default.md)),
/// installed into the ``ClassifierStore`` as `risk@<version>-default` by ``ClassifierStore/installDefault()``.
public struct ShippedClassifier: Sendable {
    /// What it records about itself.
    public var manifest: ClassifierStore.Manifest
    /// The `.mlmodel` bytes.
    public var model: Data

    /// The embedded default, or nil when the resource is empty or malformed.
    public static let current: ShippedClassifier? = decode(RiskDefaultText.text)

    /// The resource's shape.
    struct Resource: Codable {
        /// The shipped version's manifest.
        var manifest: ClassifierStore.Manifest
        /// The `.mlmodel` bytes, base64.
        var model: String
    }

    /// Reads the resource; nil when it is empty or malformed.
    ///
    /// - Parameter text: The resource's JSON.
    /// - Returns: The classifier, or nil.
    static func decode(_ text: String) -> ShippedClassifier? {
        guard let resource = try? JSONDecoder().decode(Resource.self, from: Data(text.utf8)),
            let model = Data(base64Encoded: resource.model)
        else { return nil }
        return ShippedClassifier(manifest: resource.manifest, model: model)
    }

    /// The resource text for a trained model and its manifest, as `wisp classifier ship` writes it.
    ///
    /// - Parameters:
    ///   - manifest: The version's manifest.
    ///   - model: The `.mlmodel` bytes.
    /// - Returns: The JSON, with a trailing newline.
    /// - Throws: An encoding error.
    public static func resource(manifest: ClassifierStore.Manifest, model: Data) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Resource(manifest: manifest, model: model.base64EncodedString()))
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
