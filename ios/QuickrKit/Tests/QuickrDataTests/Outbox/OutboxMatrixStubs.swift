import Testing

/// outbox.md §13 cases that need the real backend (INT, `make ios-integration`). Each has a
/// fake-server simulation already (named in the reason); these stubs mark the real runs still
/// owed. The multi-process cases run in `MultiProcess/OutboxMultiProcessTests`.
@Suite struct OutboxMatrixStubs {
    @Test(
        "12 · INT: a late POST after the DELETE",
        .disabled("INT (make ios-integration); simulated in OutboxUndoTests 12"))
    func case12INT() {}

    @Test(
        "17 · INT: PATCH 404 after a web delete",
        .disabled("INT (make ios-integration); simulated in OutboxServerStateTests 17"))
    func case17INT() {}

    @Test(
        "32 · INT: stale rebasing by a superseded sender, against the real backend",
        .disabled("INT (make ios-integration); MP half in MultiProcess/OutboxMultiProcessTests 32"))
    func case32INT() {}

    @Test(
        "38 · INT: epoch rotation with pending and failed items",
        .disabled("INT (make ios-integration); simulated in OutboxServerStateTests 38"))
    func case38INT() {}

    @Test(
        "49 · INT: two stacks, server_mismatch",
        .disabled("INT (make ios-integration); simulated in OutboxServerStateTests 49"))
    func case49INT() {}

    @Test(
        "51 · INT: a delayed POST after the undo DELETE",
        .disabled("INT (make ios-integration); simulated in OutboxUndoTests 51"))
    func case51INT() {}

    @Test(
        "59 · INT: a fault-injecting proxy garbles the 201",
        .disabled("INT (make ios-integration); simulated in OutboxUndoTests 59"))
    func case59INT() {}
}
