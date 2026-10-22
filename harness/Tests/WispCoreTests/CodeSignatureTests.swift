import Foundation
import Security
import Testing

@testable import WispCore

/// Reading who signed an executable, for `wisp doctor`'s `signature` finding.
@Suite struct CodeSignatureTests {
    /// A system binary is signed by Apple's certificate, read from the file.
    @Test func readsTheCertificateThatSignedASystemBinary() {
        guard case .signed(let authority) = CodeSignature.of(URL(fileURLWithPath: "/usr/bin/true")) else {
            Issue.record("/usr/bin/true read as \(CodeSignature.of(URL(fileURLWithPath: "/usr/bin/true")))")
            return
        }
        #expect(authority.hasSuffix("Software Signing"))
    }

    /// The test runner itself is a build from source, which the linker signs ad hoc.
    @Test func readsABuildFromSourceAsAdHoc() throws {
        let runner = try #require(ExecutablePath.current)
        #expect(CodeSignature.of(runner) == .adHoc)
    }

    /// A missing file is no signature at all, and says why.
    @Test func aMissingFileIsUnreadable() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "wisp-missing-\(UUID().uuidString)")
        guard case .unreadable(let reason) = CodeSignature.of(missing) else {
            Issue.record("\(CodeSignature.of(missing))")
            return
        }
        #expect(!reason.isEmpty)
    }

    /// Signing information without an identifier is code that is not signed; with the ad hoc flag, ad hoc.
    @Test func classifiesTheSigningInformation() {
        #expect(CodeSignature.classify([:]) == .unsigned)
        let adHoc: [String: Any] = [
            kSecCodeInfoIdentifier as String: "wisp",
            kSecCodeInfoFlags as String: NSNumber(value: SecCodeSignatureFlags.adhoc.rawValue),
        ]
        #expect(CodeSignature.classify(adHoc) == .adHoc)
        #expect(CodeSignature.classify([kSecCodeInfoIdentifier as String: "wisp"]) == .adHoc)
    }
}
