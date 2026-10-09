import CryptoKit
import Foundation

/// The risk classifiers on this Mac, one directory per version under `<home>/classifiers/risk`: the
/// default that ships with each release, never changed, and the versions trained here, never
/// overwritten ([ADR 0038](../../../../docs/decisions/0038-fast-specialised-classifiers.md), amendment).
///
/// A version is named `<wisp version>-default` for the shipped one and `<wisp version>-local.<n>` for
/// those trained here, and referred to as `risk@<version>`. Each directory holds `model.mlmodel`,
/// read-only, and `manifest.json`: what it was trained from and every measurement taken of it.
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
    public init(home: Home) {
        root = home.root.appending(path: "classifiers").appending(path: Self.task)
    }

    /// The version name of the default that ships with `wispVersion`.
    public static func defaultVersion(_ wispVersion: String = WispVersion.current) -> String {
        "\(wispVersion)-default"
    }

    /// The version a `risk@<version>` reference names, or nil for anything else (a path, a file name).
    /// A malformed version (`risk@../../x`, one with a `/`) is not a reference: it would name a directory
    /// outside the store.
    public static func version(of reference: String) -> String? {
        let prefix = "\(task)@"
        guard reference.hasPrefix(prefix), reference.count > prefix.count else { return nil }
        let version = String(reference.dropFirst(prefix.count))
        return isValidVersion(version) ? version : nil
    }

    /// Whether `version` can name a directory in the store and nothing outside it: letters, digits, `.`, `_`,
    /// `+`, and `-`, not starting with `.`, and without `..` or `/`.
    public static func isValidVersion(_ version: String) -> Bool {
        !version.isEmpty && version.count <= 128 && !version.hasPrefix(".") && !version.contains("..")
            && version.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) }
    }

    /// The reference for `version`, as config names it.
    public static func reference(_ version: String) -> String { "\(task)@\(version)" }

    /// Labelled commands kept out of every training run on this Mac: a test set of commands actually run
    /// here, which `--from-audit` would otherwise learn from. `train` always leaves out anything that
    /// overlaps it.
    public var heldOut: URL { root.appending(path: "held-out.tsv") }

    /// `examples` without any that overlap `heldOut` (exactly, after normalising, by family, or by near
    /// match), and how many were left out.
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
    public func directory(_ version: String) -> URL { root.appending(path: version) }

    /// The model file of `version`.
    public func model(_ version: String) -> URL { directory(version).appending(path: "model.mlmodel") }

    /// Every version with a manifest, the default first, then newest last.
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
    public func manifest(_ version: String) -> Manifest? {
        guard Self.isValidVersion(version) else { return nil }
        let url = directory(version).appending(path: "manifest.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    }

    /// The name the next version trained by `wispVersion` gets: `<wisp version>-local.<n>`, one past
    /// the highest `n` any version has.
    public func nextLocalVersion(_ wispVersion: String = WispVersion.current) -> String {
        let highest =
            versions().compactMap { manifest in
                manifest.version.split(separator: ".").last.flatMap { Int($0) }
                    .flatMap { manifest.version.contains("-local.") ? $0 : nil }
            }.max() ?? 0
        return "\(wispVersion)-local.\(highest + 1)"
    }

    /// SHA-256 of examples, as `Manifest.examplesDigest` records it.
    public static func digest(_ examples: [RiskExample]) -> String {
        let text = examples.map { "\($0.level.rawValue)\t\($0.command)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Adds a version: moves the trained model into its directory, makes it read-only, and writes the
    /// manifest, which later gains only measurements. An existing version is never replaced.
    ///
    /// - Throws: A file-system error, including when the version exists.
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
    func write(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: directory(manifest.version).appending(path: "manifest.json"), options: .atomic)
    }

    /// Records a measurement in `version`'s manifest.
    ///
    /// - Throws: `Failure.unknownVersion`, or a file-system error.
    public func record(_ measured: Manifest.Measured, for version: String) throws {
        guard var manifest = manifest(version) else { throw Failure.unknownVersion(version) }
        manifest.measurements.append(measured)
        try write(manifest)
    }

    /// Removes a local version.
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
    /// `ShippedClassifier`; nothing is written when the build carries none.
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
public struct ShippedClassifier: Sendable {
    /// What it records about itself.
    public var manifest: ClassifierStore.Manifest
    /// The `.mlmodel` bytes.
    public var model: Data

    /// The embedded default, or nil when the resource is empty or not for this build's version.
    public static let current: ShippedClassifier? = decode(RiskDefaultText.text)

    /// The resource's shape.
    struct Resource: Codable {
        var manifest: ClassifierStore.Manifest
        var model: String
    }

    /// Reads the resource; nil when it is empty or malformed.
    static func decode(_ text: String) -> ShippedClassifier? {
        guard let resource = try? JSONDecoder().decode(Resource.self, from: Data(text.utf8)),
            let model = Data(base64Encoded: resource.model)
        else { return nil }
        return ShippedClassifier(manifest: resource.manifest, model: model)
    }

    /// The resource text for a trained model and its manifest, as `wisp classifier ship` writes it.
    public static func resource(manifest: ClassifierStore.Manifest, model: Data) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Resource(manifest: manifest, model: model.base64EncodedString()))
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
