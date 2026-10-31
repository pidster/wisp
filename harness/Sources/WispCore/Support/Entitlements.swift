import Foundation
import Security

/// The code-signing entitlements of this process, for capabilities macOS grants only to signed
/// binaries that carry them.
///
/// Private Cloud Compute is the case that matters: the framework reports it available on any
/// eligible Mac, but a request from a binary without the managed entitlement fails deep inside
/// `ModelManagerServices` with an opaque error. Checking up front turns that into a sentence.
public struct Entitlements: Sendable {
    /// The managed entitlement Apple grants for Private Cloud Compute
    /// (`docs/backends.md`, "Private Cloud Compute").
    public static let privateCloudCompute = "com.apple.developer.private-cloud-compute"

    /// Whether this process holds the named entitlement.
    private let lookup: @Sendable (String) -> Bool

    /// Creates a set backed by `lookup`.
    ///
    /// - Parameter lookup: Answers whether the named entitlement is held.
    public init(lookup: @escaping @Sendable (String) -> Bool) {
        self.lookup = lookup
    }

    /// The running process's own entitlements, read from its code signature (`SecTaskCopyValueForEntitlement`); an
    /// entitlement whose value is not a Boolean `true` counts as not held.
    public static let process = Entitlements { key in
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return false }
        return (value as? Bool) ?? false
    }

    /// A set that holds exactly `keys`, so a test can show what an entitled build would do without being one.
    ///
    /// - Parameter keys: The entitlements held.
    /// - Returns: The set.
    public static func granting(_ keys: Set<String>) -> Entitlements {
        Entitlements { keys.contains($0) }
    }

    /// A set that holds nothing.
    public static let none = Entitlements { _ in false }

    /// Whether `key` is held.
    ///
    /// - Parameter key: The entitlement's name, such as ``privateCloudCompute``.
    /// - Returns: Whether this set holds it.
    public func has(_ key: String) -> Bool { lookup(key) }
}
