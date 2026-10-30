import Foundation

extension ModelActions {
    /// Links a GGUF file into wisp's llama.cpp models folder, so wisp's own server serves it as `llamacpp:<name>`
    /// ([ADR 0082](../../../../docs/decisions/0082-a-llama-cpp-server-wisp-starts.md), decision 2): only under
    /// `llamacpp.server wisp`, the file never copied or moved (`LlamaCppModels.add`). Recorded as `model.add`, a
    /// refusal too. The person's alone: the model's `models` tool does not offer it.
    ///
    /// - Parameters:
    ///   - path: The file, as typed: absolute, `~/…`, or relative to `workingDirectory`.
    ///   - workingDirectory: Where a relative path starts.
    /// - Returns: The lines for the person: what was linked, and how to use it.
    /// - Throws: `Failure.notForTheModel` from the tool; `LlamaCppModels.Failure` for another server's setting or a
    ///   file that cannot be added; the file system's error when the link cannot be made.
    public func add(_ path: String, workingDirectory: URL) throws -> [String] {
        guard face != .tool else { throw Failure.notForTheModel(Action.add.rawValue) }
        let models = LlamaCppModels(home: session.home)
        func record(_ outcome: String, link: LlamaCppModels.Link?, reason: String?) {
            audit.record(
                .modelAdd,
                details: [
                    "model": link.map { .string("llamacpp:\($0.name)") } ?? .null, "path": .string(path),
                    "file": link.map { .string($0.target.path) } ?? .null,
                    "link": link.map { .string($0.link.path) } ?? .null,
                    "bytes": link?.bytes.map { .int($0) } ?? .null, "outcome": .string(outcome),
                    "reason": reason.map { .string($0) } ?? .null, "source": .string(face.rawValue),
                ])
        }
        let added: LlamaCppModels.Added
        do {
            let server = session.config.llamacpp.server
            guard server == .wisp else { throw LlamaCppModels.Failure.notWispsServer(server) }
            added = try models.add(path, workingDirectory: workingDirectory)
        } catch {
            record("refused", link: nil, reason: "\(error)")
            throw error
        }
        let link = added.link
        record(added.unchanged ? "unchanged" : "added", link: link, reason: nil)
        let model = "llamacpp:\(link.name)"
        if added.unchanged {
            return ["\(model) is linked already, to \(link.target.path); nothing changed"]
        }
        let size = ModelRemoval.formatted(Int64(link.bytes ?? 0))
        return [
            "added \(model): \(link.link.path) links to \(link.target.path) (\(size)), which stays where it is",
            "wisp's llama.cpp server serves it as \(model) once the server is built; wisp models uninstall \(model) "
                + "removes the link, never the file",
        ]
    }
}
