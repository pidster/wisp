import Darwin
import Foundation

/// Where the running `wisp` is, by the path the kernel started it from, never by `argv[0]`
/// ([ADR 0061](../../../../docs/decisions/0061-process-names-set-at-spawn.md)). A parent may name its child at
/// spawn (`scripts/wisp-mcp` starts the server as `wisp mcp (claude-code)`, `wisp-tui` its child as
/// `wisp chat (tui)`), and a shell launching through `PATH` passes a bare name, so `argv[0]` says nothing reliable
/// about where the executable is.
public enum ExecutablePath {
    /// The path the kernel recorded when it started this process (`_NSGetExecutablePath`), or nil when it cannot
    /// be read. It is the path given to `execve`, which may hold links; `resolve` resolves them.
    static func kernelPath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    /// The running executable from the sources given, links resolved: the kernel's path when it is absolute;
    /// otherwise the main bundle's executable, which Foundation takes from the kernel too and makes absolute
    /// early, before anything changes the working directory; and only then the kernel's relative path, against
    /// the working directory. None of them is `argv[0]`.
    ///
    /// - Parameters:
    ///   - kernel: The kernel's path, as `kernelPath()` reads it: the path given to `execve`, possibly relative.
    ///   - bundle: `Bundle.main.executableURL`.
    /// - Returns: The real path, or nil when neither source has one.
    static func resolve(kernel: String?, bundle: URL?) -> URL? {
        if let kernel, kernel.hasPrefix("/") { return URL(fileURLWithPath: kernel).resolvingSymlinksInPath() }
        if let bundle { return bundle.resolvingSymlinksInPath() }
        guard let kernel, !kernel.isEmpty else { return nil }
        return URL(fileURLWithPath: kernel).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The running executable's real path, or nil in the unlikely case that neither the kernel nor Foundation
    /// can say.
    public static var current: URL? { resolve(kernel: kernelPath(), bundle: Bundle.main.executableURL) }
}
