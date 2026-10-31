import Foundation
import FoundationModels

/// Reports the current date and time. The on-device model has no clock, so
/// this is the smallest useful example of a tool the harness can offer.
public struct CurrentDateTool: WispTool {
    /// The identifier the model uses to request this tool.
    public let name = "current_date"
    /// What the model is told this tool does.
    public let description = "Returns the current local date and time."
    /// One line of output.
    public let limits = "One line of output."
    /// How to ask for it.
    public let examplePrompt =
        "Use current_date to find today's date in Asia/Tokyo and reply with just the date."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// Optional IANA zone identifier; nil means the process-local zone.
        @Guide(description: "IANA time zone identifier such as Europe/London. Defaults to the local zone.")
        public var timeZone: String?
    }

    /// Creates the tool.
    public init() {}

    /// Formats the current instant in the requested zone. An identifier the system does not know falls back to the
    /// local zone rather than failing; the zone named in the result shows the model which it got.
    ///
    /// - Parameter arguments: The zone to report in.
    /// - Returns: An ISO 8601 timestamp with offset, followed by the zone identifier.
    public func call(arguments: Arguments) async -> String {
        let zone = arguments.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        return Self.format(Date(), in: zone)
    }

    /// ISO 8601 with offset, then the zone identifier in parentheses. Pure, for tests. A formatter per call, since
    /// `DateFormatter` is not `Sendable`.
    ///
    /// - Parameters:
    ///   - date: The instant.
    ///   - zone: The zone to write it in.
    /// - Returns: Such as `2026-10-31T18:15:00+09:00 (Asia/Tokyo)`.
    static func format(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return "\(formatter.string(from: date)) (\(zone.identifier))"
    }
}
