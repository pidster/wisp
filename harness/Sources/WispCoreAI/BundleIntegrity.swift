import CryptoKit
import Foundation
import WispCore

/// Checks a Core AI bundle's weights against the hash exported beside them, before Core AI reads them.
///
/// An `.aimodel` holds its weights as `main.mlirb` and their SHA-256, as 32 raw bytes, as `main.hash` (checked
/// against Qwen3, Nemotron, and Muse Glimmer bundles on 2026-10-08). Core AI does not refuse weights that do not
/// match: a truncated `main.mlirb` it has not compiled before aborts the whole process inside its compiler ("LLVM
/// ERROR: cannot unwrap empty `odiec_module_t`", exit 134) on the first request, which nothing in wisp can catch,
/// and one it has compiled before runs from Core AI's cache as if whole. So wisp hashes each weights file once and
/// refuses the model when the hash differs, with the path and both hashes.
///
/// Hashing reads the whole file, about 2 s a gigabyte, so a match is remembered by path, size, and modification
/// time in `<home>/cache/coreai-verified.json`, and a file is hashed again only when one of them changes. A bundle
/// without a `.hash` beside its `.mlirb` (a compiled `.aimodelc`, or an older exporter's) is not checked.
enum BundleIntegrity {
    /// A weights file whose hash differs from the one exported beside it.
    struct Mismatch: Error, CustomStringConvertible, Equatable {
        /// The weights file.
        var path: String
        /// Its size in bytes.
        var bytes: Int64
        /// The SHA-256 the bundle states, in hex.
        var expected: String
        /// The SHA-256 of the file as it is, in hex.
        var actual: String

        /// Says which file, that it does not match, and the likely cause.
        var description: String {
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "\(path) (\(size)) does not match the SHA-256 beside it (expected \(expected), found \(actual)); "
                + "the bundle is truncated or corrupt, perhaps an unfinished download: fetch or export it again"
        }
    }

    /// What is remembered of a weights file that matched its hash.
    struct Record: Codable, Equatable, Sendable {
        /// Its size in bytes.
        var bytes: Int64
        /// Its modification time.
        var modified: Date
        /// Its SHA-256, in hex.
        var sha256: String
    }

    /// What a check did.
    enum Outcome: Equatable, Sendable {
        /// The files were hashed and matched; the paths checked.
        case verified([String])
        /// Every file had matched before and is unchanged; nothing was hashed.
        case remembered
        /// No weights file has a hash beside it.
        case unchecked
    }

    /// The pairs of weights and hash files in a bundle: each `X.mlirb` in an `.aimodel` directory with an `X.hash`.
    ///
    /// - Parameter bundle: The bundle directory, holding `metadata.json` and the `.aimodel`.
    /// - Returns: The weights files and their hash files, sorted by path.
    static func pairs(in bundle: URL) -> [(weights: URL, hash: URL)] {
        let manager = FileManager.default
        let models = ((try? manager.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "aimodel" }
        return models.flatMap { model in
            ((try? manager.contentsOfDirectory(at: model, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "mlirb" }
                .map { ($0, $0.deletingPathExtension().appendingPathExtension("hash")) }
                .filter { manager.fileExists(atPath: $0.1.path) }
        }
        .sorted { $0.0.path < $1.0.path }
    }

    /// Checks every weights file in a bundle against its hash, hashing only files not remembered as matching.
    ///
    /// - Parameters:
    ///   - bundle: The bundle directory.
    ///   - records: The file remembering matches; read when present, rewritten after a new match.
    /// - Returns: What was done.
    /// - Throws: `Mismatch` for the first file that differs; file errors when one cannot be read.
    static func check(bundle: URL, records: URL) throws -> Outcome {
        let pairs = pairs(in: bundle)
        guard !pairs.isEmpty else { return .unchecked }
        var remembered = load(records)
        var hashed: [String] = []
        for (weights, hashFile) in pairs {
            let path = weights.resolvingSymlinksInPath().path
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
            let expected = try Data(contentsOf: hashFile).map { String(format: "%02x", $0) }.joined()
            if let record = remembered[path], record.bytes == bytes, record.modified == modified,
                record.sha256 == expected
            {
                continue
            }
            Diagnostics.agent.info(
                "hashing Core AI weights \(path) to check them against \(hashFile.lastPathComponent)")
            let actual = try sha256(of: weights)
            guard actual == expected else {
                remembered[path] = nil
                save(remembered, to: records)
                throw Mismatch(path: path, bytes: bytes, expected: expected, actual: actual)
            }
            remembered[path] = Record(bytes: bytes, modified: modified, sha256: actual)
            hashed.append(path)
        }
        if hashed.isEmpty { return .remembered }
        save(remembered, to: records)
        return .verified(hashed)
    }

    /// A file's SHA-256, read in 8 MiB pieces so a large file is never held whole.
    ///
    /// - Parameter file: The file.
    /// - Returns: The hash, in lower-case hex.
    /// - Throws: When the file cannot be read.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let piece = try handle.read(upToCount: 8 << 20), !piece.isEmpty {
            hasher.update(data: piece)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The remembered matches, by real path; empty when the file is missing or unreadable.
    ///
    /// - Parameter records: The records file.
    /// - Returns: The records.
    static func load(_ records: URL) -> [String: Record] {
        guard let data = try? Data(contentsOf: records) else { return [:] }
        return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }

    /// Writes the remembered matches atomically; a failure only costs a later check its shortcut.
    ///
    /// - Parameters:
    ///   - remembered: The records.
    ///   - records: The records file.
    static func save(_ remembered: [String: Record], to records: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(remembered) else { return }
        try? FileManager.default.createDirectory(
            at: records.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: records, options: .atomic)
    }
}
