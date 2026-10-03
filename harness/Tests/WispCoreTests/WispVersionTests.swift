import Testing

@testable import WispCore

@Suite struct WispVersionTests {
    @Test func aReleaseBuildPrintsTheBareVersionWhateverElseIsKnown() {
        #expect(WispVersion.format(version: "1.2.3", commit: "abc1234", modified: true, release: true) == "1.2.3")
        #expect(WispVersion.format(version: "1.2.3", commit: nil, modified: false, release: true) == "1.2.3")
    }

    @Test func aCleanDevelopmentBuildNamesItsCommit() {
        #expect(
            WispVersion.format(version: "1.2.3", commit: "abc1234", modified: false, release: false)
                == "1.2.3-dev+abc1234")
    }

    @Test func aModifiedDevelopmentBuildSaysSo() {
        #expect(
            WispVersion.format(version: "1.2.3", commit: "abc1234", modified: true, release: false)
                == "1.2.3-dev+abc1234 (modified)")
    }

    @Test func anUnknownCommitIsStillNotARelease() {
        #expect(WispVersion.format(version: "1.2.3", commit: nil, modified: false, release: false) == "1.2.3-dev")
        #expect(WispVersion.format(version: "1.2.3", commit: nil, modified: true, release: false) == "1.2.3-dev")
    }

    @Test func theAuditVersionStaysBare() {
        #expect(!WispVersion.current.contains("-dev") && !WispVersion.current.contains("+"))
    }
}
