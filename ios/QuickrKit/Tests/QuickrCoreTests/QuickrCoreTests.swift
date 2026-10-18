import QuickrCore
import Testing

@Test(.timeLimit(.minutes(2))) func versionIsSet() {
    #expect(!QuickrCore.version.isEmpty)
}
