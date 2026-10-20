import Observation

/// Typed destinations for the root `NavigationStack`. Empty in SKEL; LINKS adds the cases (topic,
/// record, entries, settings, …) and the `quickr://` and PWA-path parser.
enum Route: Hashable {}

/// Owns the navigation path. LINKS adds `handle(url:)`.
@MainActor @Observable
final class Router {
    var path: [Route] = []
}
