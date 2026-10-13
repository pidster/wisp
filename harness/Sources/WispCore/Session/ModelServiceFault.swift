import Foundation

/// A failure of Apple's model service, `modelmanagerd`, rather than of the model or of wisp: the on-device model
/// reports itself available, yet every request fails before it reaches the model. Seen on 2026-10-13, after
/// `modelmanagerd` had run for 26 days: it could no longer open the model's lock file ("Too many open files"),
/// `wisp` and Apple's own `fm` failed alike, and restarting the service cleared it. `wisp doctor` and the model
/// evaluations recognise it from the error's text, so a person is told to restart the service rather than left
/// with a framework message, and an eval run is not taken for a measurement of the model.
public struct ModelServiceFault: Equatable, Sendable, CustomStringConvertible {
    /// What the service did.
    public enum Kind: Equatable, Sendable {
        /// It ran out of open files, so it cannot open the model's assets.
        case outOfFiles
        /// It refused the request for another reason.
        case refused
    }

    /// What the service did.
    public let kind: Kind

    /// The command that restarts the service; launchd starts it again on the next request.
    public static let restart = "sudo killall modelmanagerd"

    /// Creates a fault.
    ///
    /// - Parameter kind: What the service did.
    public init(kind: Kind) {
        self.kind = kind
    }

    /// The fault an error's text describes, or nil when it is not one of the service's. The text is matched rather
    /// than the error's type because the framework passes the service's error along as an `NSError` of Mobile
    /// Asset's domain inside its own, and `fm` reports it only as `ModelManagerError`.
    ///
    /// - Parameter text: The error, as wisp prints it.
    /// - Returns: The fault, or nil.
    public static func recognise(_ text: String) -> ModelServiceFault? {
        let service = ["Model Catalog error", "MobileAssetError", "ModelManagerError"].contains {
            text.contains($0)
        }
        guard service else { return nil }
        return ModelServiceFault(kind: text.contains("Too many open files") ? .outOfFiles : .refused)
    }

    /// The fault recognised in `error`, or nil.
    ///
    /// - Parameter error: The error a request threw.
    /// - Returns: The fault, or nil.
    public static func recognise(_ error: any Error) -> ModelServiceFault? {
        recognise("\(error)")
    }

    /// What happened and what to do.
    public var description: String {
        switch kind {
        case .outOfFiles:
            "Apple's model service (modelmanagerd) has run out of open files and cannot open the model; restart it "
                + "with `\(Self.restart)` (launchd starts it again), or restart the Mac"
        case .refused:
            "Apple's model service (modelmanagerd) refused the request; restarting it (`\(Self.restart)`) or the "
                + "Mac may clear it"
        }
    }
}
