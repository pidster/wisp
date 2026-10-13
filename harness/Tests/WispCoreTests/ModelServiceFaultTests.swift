import Foundation
import Testing

@testable import WispCore

@Suite struct ModelServiceFaultTests {
    /// The error `wisp` printed on 2026-10-13 while `modelmanagerd` had run out of open files, shortened.
    static let outOfFiles =
        "Model Catalog error: Error Domain=com.apple.MobileAssetError.AutoAsset Code=6583 \"[[AUTO-SHORT-TERM]"
        + "[FRAMEWORK][RAPID-LOCK]{acquireShortTermLockSync}:FailedSharedLockPreparation(6583)] Failed to open lock "
        + "file for ClientDomain:com.apple.UnifiedAssetFramework | Error: Too many open files\""

    @Test func recognisesTheServiceRunningOutOfFiles() {
        let fault = ModelServiceFault.recognise(Self.outOfFiles)
        #expect(fault == ModelServiceFault(kind: .outOfFiles))
        #expect(fault?.description.contains(ModelServiceFault.restart) == true)
    }

    @Test func recognisesOtherRefusalsOfTheService() {
        let fm = "The operation couldn’t be completed. (ModelManagerServices.ModelManagerError error 1026.)"
        #expect(ModelServiceFault.recognise(fm) == ModelServiceFault(kind: .refused))
        #expect(ModelServiceFault.recognise(fm)?.description.contains(ModelServiceFault.restart) == true)
    }

    @Test func leavesOtherErrorsAlone() {
        // An open-file error that is not the service's is not taken for it.
        #expect(ModelServiceFault.recognise("Too many open files") == nil)
        #expect(ModelServiceFault.recognise(CommandRunner.Failure.launchFailed("no such file")) == nil)
    }
}
