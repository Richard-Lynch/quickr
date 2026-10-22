import QuickrCore
import QuickrData
import Testing

@Test(.timeLimit(.minutes(5))) func dataSeesCore() {
    #expect(QuickrData.coreVersion == QuickrCore.version)
}
