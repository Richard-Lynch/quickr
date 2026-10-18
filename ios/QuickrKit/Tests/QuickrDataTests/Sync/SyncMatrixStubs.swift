import Testing

/// The sync-protocol.md §13.1 cases that need real subprocesses (MP, gate G5) or the APNs register
/// flow (M3). Each has a single-process simulation in SyncLiveTests, SyncRebuildTests or
/// SyncResetTests; these stubs hold their numbers until those work packages implement them. S1,
/// S8 and S9 (INT, gate G4) run against the real backend in QuickrDataIntegrationTests. S21 is a
/// server property, tested in backend/tests/test_identity.py: a rotation before the lookup
/// (`test_headers_are_read_after_the_handler`) and between the lookup and the response
/// (`test_headers_after_a_rotation_between_lookup_and_response`), each for a 2xx and a 404.
@Suite struct SyncMatrixStubs {
    @Test(.disabled("MP WP (simulated in SyncRebuildTests)"))
    func s3SuspendedCoordinatorProcess() {}

    @Test(.disabled("MP WP (simulated in SyncRebuildTests)"))
    func s4KilledStagingCoordinatorProcess() {}

    @Test(.disabled("MP WP (simulated in SyncResetTests)"))
    func s7ResetWithExtensionProcessPools() {}

    // Owner: M3 APNs registration (REG). Only `APIClient.registerApnsDevice` exists so far; the
    // register flow that turns 409 epoch_mismatch into a rebuild and a retried register is REG's.
    // Its INT test then goes in QuickrDataIntegrationTests (the coordinator side is S20).
    @Test(.disabled("M3 REG: no APNs register flow yet (coordinator side: S20)"))
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
}
