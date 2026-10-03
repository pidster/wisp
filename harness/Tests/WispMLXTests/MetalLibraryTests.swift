import Foundation
import Testing
import WispCore

@testable import WispMLX

/// The doctor's search for MLX's Metal library, over scratch directories, without MLX or a GPU.
@Suite struct MetalLibraryTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-metallib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("metallib".utf8).write(to: url)
    }

    @Test func searchesInMLXsOrder() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let search = MetalLibrary.Search(imageDirectory: root, mainBundleDirectory: root)
        #expect(
            search.candidates.map { String($0.path.dropFirst(root.path.count + 1)) } == [
                "mlx.metallib", "Resources/mlx.metallib",
                "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib", "mlx-swift_Cmlx.bundle/default.metallib",
                "Resources/default.metallib",
            ])
        #expect(search.found == nil)
        try touch(root.appending(path: "Resources/default.metallib"))
        #expect(search.found?.lastPathComponent == "default.metallib")
        try touch(root.appending(path: "mlx-swift_Cmlx.bundle/default.metallib"))
        #expect(search.found?.path.contains("mlx-swift_Cmlx.bundle") == true)
        try touch(root.appending(path: "mlx.metallib"))
        #expect(search.found?.path == root.appending(path: "mlx.metallib").path)
        let unknownImage = MetalLibrary.Search(imageDirectory: nil, mainBundleDirectory: root)
        #expect(unknownImage.candidates.count == 2)
    }

    @Test func findingsForEachState() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = MetalLibrary.finding(compiledIn: false, search: nil)
        #expect(absent.ok && absent.name == "MLX" && absent.detail.contains("without the MLX trait"))
        let search = MetalLibrary.Search(imageDirectory: root, mainBundleDirectory: root)
        let missing = MetalLibrary.finding(compiledIn: true, search: search)
        #expect(!missing.ok && missing.detail.contains("mlx.metallib in \(root.path)"))
        #expect(missing.detail.contains("beside wisp as mlx.metallib"))
        let blind = MetalLibrary.finding(
            compiledIn: true, search: .init(imageDirectory: nil, mainBundleDirectory: root))
        #expect(!blind.ok && blind.detail.contains("the binary's directory"))
        try touch(root.appending(path: "mlx.metallib"))
        let loads = MetalLibrary.finding(compiledIn: true, search: search)
        #expect(loads.ok && loads.detail == "Metal library \(root.path)/mlx.metallib loads")
        let corrupt = MetalLibrary.finding(compiledIn: true, search: search) { _ in "invalid library" }
        #expect(!corrupt.ok && corrupt.detail.hasSuffix("does not load: invalid library"))
    }

    @Test func theBackendReportsItsBuild() throws {
        let finding = try #require(MLXBackend().doctorFinding())
        #expect(finding.name == "MLX")
        if !MLXBackend.isCompiledIn { #expect(finding.ok) }
        #expect(MetalLibrary.imageDirectory() != nil)
    }
}
