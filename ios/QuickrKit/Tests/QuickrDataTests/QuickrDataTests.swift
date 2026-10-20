import QuickrCore
import QuickrData
import Testing

@Test(.timeLimit(.minutes(2))) func dataSeesCore() {
    #expect(QuickrData.coreVersion == QuickrCore.version)
}
