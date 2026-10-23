import Foundation

extension Doctor {
    /// The `package` finding: whether every part the package declares is where it says
    /// ([ADR 0072](../../../../docs/decisions/0072-a-dmg-and-a-declared-layout.md)). A missing part fails, which would
    /// have caught 0.17.0's `wisp-tui`, moved where `wisp chat` did not look, before release; a build directory, which
    /// declares nothing, passes, its parts searched for.
    ///
    /// - Parameter exists: Whether a path exists.
    /// - Returns: The finding.
    func package(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Finding {
        let name = "package"
        switch probes.layout() {
        case .none:
            return Finding(
                name: name, ok: true,
                detail:
                    "no declared layout (a build directory, or a tarball unpacked by hand); wisp searches beside itself"
            )
        case .malformed(let source, let reason):
            return Finding(name: name, ok: false, detail: "\(source.path) cannot be read: \(reason)")
        case .declared(let layout):
            let declared = PackageLayout.Part.allCases.compactMap { part in layout.parts[part].map { (part, $0) } }
            let missing = declared.filter { !exists($0.1.path) }
            let source = layout.declaration.source.path
            guard missing.isEmpty else {
                let list = missing.map { "\($0.0.label) at \($0.1.path)" }.joined(separator: ", ")
                return Finding(name: name, ok: false, detail: "\(source) declares parts that are missing: \(list)")
            }
            let list = declared.map(\.0.label).joined(separator: ", ")
            return Finding(
                name: name, ok: true,
                detail: declared.isEmpty ? "\(source) declares no parts" : "\(source) declares \(list); all present")
        }
    }
}
