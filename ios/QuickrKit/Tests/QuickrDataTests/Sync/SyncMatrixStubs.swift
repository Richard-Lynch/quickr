import Testing

/// The sync-protocol.md §13.1 cases that need real subprocesses (MP, gate G5), the APNs work, or
/// the backend alone. Each has a single-process simulation in SyncLiveTests, SyncRebuildTests or
/// SyncResetTests; these stubs hold their numbers until those work packages implement them. S1,
/// S8 and S9 (INT, gate G4) run against the real backend in QuickrDataIntegrationTests.
@Suite struct SyncMatrixStubs {
    @Test(.disabled("MP WP (simulated in SyncRebuildTests)"))
    func s3SuspendedCoordinatorProcess() {}

    @Test(.disabled("MP WP (simulated in SyncRebuildTests)"))
    func s4KilledStagingCoordinatorProcess() {}

    @Test(.disabled("MP WP (simulated in SyncResetTests)"))
    func s7ResetWithExtensionProcessPools() {}

    @Test(.disabled("INT and APNs WPs (coordinator side: S20)"))
    func s10ApnsRegisterAcrossAnEpochRotation() {}

    @Test(.disabled("MP WP (simulated in SyncResetTests)"))
    func s11WallClockChangesAcrossProcesses() {}

    @Test(.disabled("MP WP (simulated in SyncResetTests)"))
    func s13RebuildAndResetInTwoProcesses() {}

    @Test(.disabled("MP WP (simulated in SyncRebuildTests)"))
    func s16FlusherProcessEpochMismatch() {}

    @Test(.disabled("MP WP (simulated in SyncResetTests)"))
    func s17KilledBeforeTheRetire() {}

    @Test(.disabled("MP WP (simulated in SyncResetTests)"))
    func s18KilledBeforeTheAdvance() {}

    @Test(.disabled("MP WP (simulated in SyncResetTests)"))
    func s19WidgetProcessEnqueuesDuringAReset() {}

    @Test(.disabled("Backend M0-feed: header provenance is a server test"))
    func s21HeaderEpochIsNeverOlderThanTheData() {}
}
