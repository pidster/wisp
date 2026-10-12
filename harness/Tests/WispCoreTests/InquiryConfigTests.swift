import Foundation
import Testing

@testable import WispCore

/// The settings the inquiry verb and its neighbours add to the config file (ADR 0062, ADR 0046): what they resolve
/// to in range and out of it, and the refusals on load.
@Suite struct InquiryConfigTests {
    /// Loads `json` as `config.json`, returning the refusal's text, or nil when it loads.
    private func refusal(_ json: String) throws -> String? {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-inquiry-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        try Data(json.utf8).write(to: file)
        do {
            _ = try Config.load(from: file)
            return nil
        } catch let DecodingError.dataCorrupted(context) {
            return context.debugDescription
        }
    }

    @Test func theQuestionDeadlineIsClampedAndZeroOrAbsentWaitsUntilAnswered() {
        func timeout(_ seconds: Int?) -> Duration? {
            Config(inquiry: Config.InquiryConfig(timeoutSeconds: seconds)).resolved.inquiryTimeout
        }
        #expect(timeout(nil) == nil && timeout(0) == nil, "no deadline: the harness waits for the person's return")
        #expect(timeout(300) == .seconds(300))
        #expect(timeout(-5) == .seconds(10), "a negative deadline is the 10 s floor, never an instant refusal")
        #expect(timeout(1_000_000) == .seconds(86_400), "a deadline above a day is a day")
        #expect(Config().resolved.inquiryElicitation == false)
        #expect(Config(inquiry: Config.InquiryConfig(elicitation: true)).resolved.inquiryElicitation)
    }

    @Test func theWatchSettleIsRefusedOutsideItsRangeAndResolvedInsideIt() throws {
        #expect(try refusal(#"{"watch":{"settle":61}}"#) == "watch: settle must be between 0 and 60")
        #expect(try refusal(#"{"watch":{"settle":-1}}"#) == "watch: settle must be between 0 and 60")
        #expect(try refusal(#"{"watch":{"settle":0}}"#) == nil && refusal(#"{"watch":{"settle":60}}"#) == nil)
        #expect(Config(watch: Config.WatchConfig(settle: 2.5)).resolved.watchSettle == 2.5)
        #expect(Config().resolved.watchSettle == Config.WatchConfig.defaultSettle)
    }

    @Test func theAssessmentSettingsResolveFromTheirFields() {
        var config = Config()
        #expect(config.resolved.assessmentEnabled == false, "off until the eval decides")
        config.assessment = Config.AssessmentConfig(enabled: true, tools: .all, taskChanges: .any)
        let resolved = config.resolved
        #expect(
            resolved.assessmentEnabled && resolved.assessmentTools == .all && resolved.assessmentTaskChanges == .any)
    }

    @Test func theApprovalBannerDelayIsRefusedWhenItCouldNeverBePostedAndResolvedOtherwise() throws {
        #expect(
            try refusal(#"{"approval":{"bannerDelaySeconds":10,"timeoutSeconds":10}}"#)?.contains(
                "must be shorter than timeoutSeconds") == true)
        // An unbounded wait (timeoutSeconds 0) has no deadline for the banner to beat.
        #expect(try refusal(#"{"approval":{"bannerDelaySeconds":3600,"timeoutSeconds":0}}"#) == nil)
        #expect(Config().resolved.approvalBannerDelay == .seconds(10))
        let delayed = Config(approval: Config.ApprovalConfig(timeoutSeconds: 120, bannerDelaySeconds: 30))
        #expect(delayed.resolved.approvalBannerDelay == .seconds(30))
        #expect(Config().resolved.approvalOutOfBand, "out-of-band approval is on by default")
        #expect(Config(approval: Config.ApprovalConfig(outOfBand: false)).resolved.approvalOutOfBand == false)
    }
}
