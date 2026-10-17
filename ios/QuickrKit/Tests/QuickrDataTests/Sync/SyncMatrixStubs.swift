import Testing

/// The sync-protocol.md §13.1 cases that need the integration stack (INT, gate G4) or the
/// backend. Each has a single-process simulation in SyncLiveTests, SyncRebuildTests or
/// SyncResetTests; these stubs hold their numbers until INT implements them. The multi-process
/// cases (G5) run in `MultiProcess/SyncMultiProcessTests`.
@Suite struct SyncMatrixStubs {
    @Test(.disabled("INT WP (simulated in SyncLiveTests)"))
    func s1BootstrapKilledMidwayAgainstTheRealBackend() {}

    @Test(.disabled("INT WP, two stacks (coordinator side in SyncLiveTests)"))
    func s8FlushAgainstADifferentServer() {}

    @Test(.disabled("INT WP (coordinator side in SyncRebuildTests)"))
    func s9FlushAcrossAnEpochRotation() {}

    @Test(.disabled("INT and APNs WPs (coordinator side: S20)"))
    func s10ApnsRegisterAcrossAnEpochRotation() {}

    @Test(.disabled("Backend M0-feed: header provenance is a server test"))
    func s21HeaderEpochIsNeverOlderThanTheData() {}
}
