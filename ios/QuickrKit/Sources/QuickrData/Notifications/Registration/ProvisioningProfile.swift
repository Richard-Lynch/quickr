import Foundation
import QuickrCore

/// The APNs environment of this build (notifications.md §9.1), explicit and never guessed:
///
/// 1. No `embedded.mobileprovision`: an App Store or TestFlight build, which Apple strips of its
///    profile. `production` (the only inferred case, and documented behaviour).
/// 2. A profile: the XML plist inside its CMS envelope (from `<?xml` through the first
///    `</plist>`), whose `Entitlements["aps-environment"]` is `development` (sandbox) or
///    `production`. Anything else is an explicit error, and nothing is registered.
/// 3. The simulator is `sandbox`; the app decides that at compile time
///    (`targetEnvironment(simulator)`), before calling this.
public enum ProvisioningProfile {
    public enum Failure: Error, Sendable, Hashable, CustomStringConvertible {
        /// No `<?xml` … `</plist>` in the file.
        case noPlist
        /// The bytes between the markers aren't a property list (a dictionary).
        case invalidPlist
        case noEntitlements
        case noApsEnvironment
        /// `aps-environment` is neither `development` nor `production`.
        case unknownEnvironment(String)

        public var description: String {
            switch self {
            case .noPlist: "the provisioning profile has no property list"
            case .invalidPlist: "the provisioning profile's property list doesn't parse"
            case .noEntitlements: "the provisioning profile has no Entitlements"
            case .noApsEnvironment: "the provisioning profile has no aps-environment"
            case .unknownEnvironment(let value): "the provisioning profile's aps-environment is \"\(value)\""
            }
        }
    }

    /// What Settings ▸ Notifications shows for any failure.
    public static let failureMessage = "Push setup error: the provisioning profile has no valid APNs environment"

    /// The environment for a build with this profile (`nil`: no profile in the bundle).
    public static func apnsEnvironment(profile: Data?) -> Result<ApnsEnvironment, Failure> {
        guard let profile else { return .success(.production) }
        guard let plist = plistBytes(in: profile) else { return .failure(.noPlist) }
        guard
            let object = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil),
            let root = object as? [String: Any]
        else { return .failure(.invalidPlist) }
        guard let entitlements = root["Entitlements"] as? [String: Any] else { return .failure(.noEntitlements) }
        guard let value = entitlements["aps-environment"] else { return .failure(.noApsEnvironment) }
        switch value as? String {
        case "development": return .success(.sandbox)
        case "production": return .success(.production)
        default: return .failure(.unknownEnvironment(value as? String ?? String(describing: type(of: value))))
        }
    }

    /// The bytes from the first `<?xml` through the first `</plist>` after it.
    static func plistBytes(in data: Data) -> Data? {
        guard let start = data.firstRange(of: Data("<?xml".utf8)),
            let end = data[start.lowerBound...].firstRange(of: Data("</plist>".utf8))
        else { return nil }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }
}
