import Foundation
import Security

/// Who signed an executable, read from its code signature, for `wisp doctor`'s `signature` finding: a release made
/// with a signing identity is signed with a Developer ID and notarised, and an unsigned release or a build from
/// source is signed ad hoc by the linker
/// ([ADR 0069](../../../../docs/decisions/0069-signed-and-notarised-releases.md)).
public enum CodeSignature: Equatable, Sendable {
    /// Signed by a certificate; `authority` is its leaf's name, `Developer ID Application: Name (TEAMID)` for a
    /// release.
    case signed(authority: String)
    /// Signed ad hoc, with no certificate: what the linker gives a build from source.
    case adHoc
    /// Not signed at all.
    case unsigned
    /// The signature could not be read; the text says why.
    case unreadable(String)

    /// The signature of the executable at `url`, read statically from the file; nothing is run.
    ///
    /// - Parameter url: The executable.
    /// - Returns: What signs it.
    public static func of(_ url: URL) -> CodeSignature {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard created == errSecSuccess, let code else { return .unreadable(describe(created)) }
        var information: CFDictionary?
        let read = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard read == errSecSuccess, let info = information as? [String: Any] else {
            return .unreadable(describe(read))
        }
        return classify(info)
    }

    /// The signature a signing-information dictionary describes.
    ///
    /// - Parameter info: `SecCodeCopySigningInformation`'s dictionary, keyed by the `kSecCodeInfo…` names.
    /// - Returns: What signs the code.
    static func classify(_ info: [String: Any]) -> CodeSignature {
        guard info[kSecCodeInfoIdentifier as String] != nil else { return .unsigned }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return .adHoc }
        guard let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first,
            let name = SecCertificateCopySubjectSummary(leaf) as String?
        else { return .adHoc }
        return .signed(authority: name)
    }

    /// A Security status as a sentence.
    ///
    /// - Parameter status: The status a call returned.
    /// - Returns: Its message, or its number when the system has none.
    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
    }
}
