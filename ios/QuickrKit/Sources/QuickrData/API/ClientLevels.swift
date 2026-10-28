import Foundation
import QuickrCore

/// `X-QuickR-Client` (client-versions.md §3.1): the platform, this build's API level and its
/// build number. The server only logs the build.
public enum ClientHeader {
    public static func value(level: String, build: String) -> String { "ios; level=\(level); build=\(build)" }

    /// This build's: `APILevel.current` and `CFBundleVersion` (the app's and every extension's are
    /// the same).
    public static let current = value(
        level: String(APILevel.current),
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")

    /// What the request goldens carry (client-versions.md §6), so a bump or a new build number
    /// doesn't change them; the replay fills both in.
    public static let placeholder = value(level: "<level>", build: "<build>")
}

/// What one response says about API levels (client-versions.md §3.2): its
/// `X-QuickR-Api-Level`, and the `ios` entry of `X-QuickR-Min-Client-Level`. Either is nil when
/// the header is missing or doesn't parse.
public struct ServerLevels: Sendable, Hashable {
    public var apiLevel: Int?
    public var minClientLevelIOS: Int?

    public init(apiLevel: Int?, minClientLevelIOS: Int?) {
        self.apiLevel = apiLevel
        self.minClientLevelIOS = minClientLevelIOS
    }

    public init(headers: HTTPHeaders) {
        self.init(
            apiLevel: headers[QuickrHeader.apiLevel].flatMap(Self.level),
            minClientLevelIOS: headers[QuickrHeader.minClientLevel].flatMap { Self.minimums($0)["ios"] })
    }

    /// Neither header.
    public var isEmpty: Bool { apiLevel == nil && minClientLevelIOS == nil }

    /// `ios=2, web=2` by platform; entries that don't parse are left out.
    public static func minimums(_ value: String) -> [String: Int] {
        var minimums: [String: Int] = [:]
        for part in value.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let level = level(String(pair[1])) else { continue }
            minimums[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = level
        }
        return minimums
    }

    private static func level(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), let level = Int(trimmed), level >= 0 else {
            return nil
        }
        return level
    }
}

/// The outdated state, for `APIClient` (client-versions.md §4.1): it asks before every request
/// whether this build is known to be too old, and hands it the levels of every response from the
/// expected server and epoch. `StoreClientLevels` keeps both in the store's `sync_state`.
public protocol ClientLevelGate: Sendable {
    /// The minimum the server demanded, while it is above `APILevel.current`: nothing is sent.
    /// Nil sends.
    func outdatedMinimum() async -> Int?
    /// One response's levels. `outdatedMinimum`, when set, is a 426 `client_outdated`'s minimum.
    func record(_ levels: ServerLevels, outdatedMinimum: Int?) async
}

/// What the parts that only enqueue say while this build is outdated (client-versions.md §4.1).
public enum ClientOutdated {
    /// Widgets, Controls, App Intents, the Action button, Live Activity buttons and notification
    /// actions: the tap is kept, and goes once quickR is updated.
    public static let savedMessage = "Saved on this iPhone. Update quickR to sync."
    /// A request refused (or not sent) because this build is too old.
    public static let updateMessage = "Update quickR to keep syncing with your server."

    /// Whether `minimum` (a stored `client_outdated_min`) still refuses this build.
    public static func refuses(_ minimum: Int?) -> Bool { minimum.map { $0 > APILevel.current } ?? false }

    /// Whether `store` is known to be outdated (best effort: a store that can't be read isn't).
    public static func isOutdated(_ store: LocalStore) async -> Bool {
        await StoreClientLevels(store: store).outdatedMinimum() != nil
    }

    /// `text`, followed by `savedMessage` when outdated.
    public static func saying(_ text: String, outdated: Bool) -> String {
        outdated ? "\(text) \(savedMessage)" : text
    }
}
