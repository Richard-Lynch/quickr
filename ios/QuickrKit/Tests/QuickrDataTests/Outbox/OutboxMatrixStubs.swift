import Testing

/// outbox.md §13 cases that need several OS processes (MP, `ProcessHelper`). Each has a
/// single-process simulation already (named in the reason); these stubs mark the real runs still
/// owed. The INT cases (12, 17, 18, 32's INT half, 38, 49, 51, 59) run against the real backend in
/// QuickrDataIntegrationTests (`make ios-integration`).
@Suite struct OutboxMatrixStubs {
    @Test("8 · MP: SIGSTOP past the TTL, B takes over", .disabled("MP WP; simulated in OutboxConcurrencyTests 8, 9"))
    func case08MP() {}

    @Test("9 · MP: SIGCONT, A's late 201 writes nothing", .disabled("MP WP; simulated in OutboxConcurrencyTests 8, 9"))
    func case09MP() {}

    @Test("10 · MP: SIGKILL while holding the lease", .disabled("MP WP; simulated in OutboxConcurrencyTests 10"))
    func case10MP() {}

    @Test(
        "23 · MP: update while the create is in flight in another process",
        .disabled("MP WP; simulated in OutboxConcurrencyTests 23"))
    func case23MP() {}

    @Test(
        "24 · MP: two processes interleave across a topic barrier",
        .disabled("MP WP; simulated in OutboxCoalescingTests 24"))
    func case24MP() {}

    @Test(
        "32 · MP: stale rebasing by a superseded sender process",
        .disabled("MP WP; simulated in OutboxConcurrencyTests 32; INT half in QuickrDataIntegrationTests 32"))
    func case32MPINT() {}

    @Test(
        "34 · MP: takeover between the refetch and the rebase",
        .disabled("MP WP; simulated in OutboxConcurrencyTests 34"))
    func case34MP() {}

    @Test(
        "39 · MP: app and widget write the same entity at once",
        .disabled("MP WP; simulated in OutboxConcurrencyTests 39"))
    func case39MP() {}

    @Test(
        "40 · MP: the widget logs while the app holds the lease",
        .disabled("MP WP; simulated in OutboxConcurrencyTests 40"))
    func case40MP() {}

    @Test("45 · MP: wall clock back 3 h, the holder dies", .disabled("MP WP; simulated in OutboxConcurrencyTests 45"))
    func case45MP() {}

    @Test(
        "46 · MP: wall clock forward 3 h, the holder lives", .disabled("MP WP; simulated in OutboxConcurrencyTests 46"))
    func case46MP() {}
}
