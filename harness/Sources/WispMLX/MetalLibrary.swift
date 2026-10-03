import Foundation
import WispCore

/// Where MLX finds its Metal library at run time, for `wisp doctor`
/// ([ADR 0047](../../../docs/decisions/0047-mlx-in-the-release.md)).
///
/// MLX compiles its kernels into one `.metallib` at build time and loads it when the GPU is first used,
/// from the first of these that exists (`mlx/backend/metal/device.cpp`, `load_default_library`):
/// `mlx.metallib` in the directory of the image holding MLX's code, `Resources/mlx.metallib` there,
/// `default.metallib` in a `mlx-swift_Cmlx.bundle` beside the main bundle (what `swift build` leaves),
/// and `Resources/default.metallib` in the image's directory. MLX is linked statically, so the image is
/// the `wisp` executable (or the test bundle's binary under `swift test`), and the release carries the
/// library as `mlx.metallib` beside `wisp`. This type repeats that search; it does not load MLX.
enum MetalLibrary {
    /// The bundle SwiftPM builds for mlx-swift's `Cmlx` target, holding `default.metallib`.
    static let swiftPMBundle = "mlx-swift_Cmlx.bundle"

    /// The directories MLX searches from.
    struct Search: Equatable {
        /// The directory of the image holding MLX's code (`dladdr`'s `dli_fname`); nil when unknown.
        var imageDirectory: URL?
        /// `Bundle.main.bundleURL`: for a command-line tool, the executable's directory.
        var mainBundleDirectory: URL

        /// Every path MLX tries, in its order.
        var candidates: [URL] {
            var paths: [URL] = []
            if let imageDirectory {
                paths.append(imageDirectory.appending(path: "mlx.metallib"))
                paths.append(imageDirectory.appending(path: "Resources/mlx.metallib"))
            }
            let bundle = mainBundleDirectory.appending(path: MetalLibrary.swiftPMBundle)
            // A bundle's resources are at its top level or under Contents/Resources; NSBundle accepts both.
            paths.append(bundle.appending(path: "Contents/Resources/default.metallib"))
            paths.append(bundle.appending(path: "default.metallib"))
            if let imageDirectory {
                paths.append(imageDirectory.appending(path: "Resources/default.metallib"))
            }
            return paths
        }

        /// The first candidate that exists, or nil.
        var found: URL? {
            candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    /// The directory of the image this code is linked into, as `dladdr` reports it; MLX asks the same
    /// question about its own code, which is linked into the same image.
    static func imageDirectory() -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else { return nil }
        return URL(filePath: String(cString: name)).deletingLastPathComponent()
    }

    /// The doctor's `MLX` finding.
    ///
    /// - Parameters:
    ///   - compiledIn: Whether this build carries MLX.
    ///   - search: Where to look; nil when not compiled in.
    ///   - load: Loads a found library, returning nil on success or the failure.
    /// - Returns: Passing when MLX is not in the build or its library loads; failing when it is in the build
    ///   and the library is missing or does not load.
    static func finding(
        compiledIn: Bool, search: Search?, load: (URL) -> String? = { _ in nil }
    ) -> Doctor.Finding {
        guard compiledIn, let search else {
            return Doctor.Finding(
                name: "MLX", ok: true,
                detail: "not in this build (built without the MLX trait); mlx: models are refused")
        }
        guard let library = search.found else {
            let looked = search.imageDirectory.map { "mlx.metallib in \($0.path)" } ?? "the binary's directory"
            return Doctor.Finding(
                name: "MLX", ok: false,
                detail: "this build has MLX but not its Metal library (looked for \(looked) and for "
                    + "\(swiftPMBundle) in \(search.mainBundleDirectory.path)); mlx: models cannot load. "
                    + "Copy default.metallib from the build's \(swiftPMBundle) beside wisp as mlx.metallib")
        }
        if let problem = load(library) {
            return Doctor.Finding(
                name: "MLX", ok: false, detail: "Metal library \(library.path) does not load: \(problem)")
        }
        return Doctor.Finding(name: "MLX", ok: true, detail: "Metal library \(library.path) loads")
    }
}
