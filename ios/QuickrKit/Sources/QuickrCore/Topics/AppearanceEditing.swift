import Foundation

// MARK: - Limits

/// The appearance limits of appearance.md §1.3 (`MAX_TAGS`, `MAX_TAG_LENGTH`, `MAX_ICON_LENGTH`).
///
/// T2-M3 seam: replaced by the `Limits` fields `maxTags`, `maxTagLength`, `maxIconLength` (from
/// `GET /limits`) when M3-DB lands; until then the server's defaults.
public struct AppearanceLimits: Sendable, Hashable {
    public var maxTags: Int
    public var maxTagLength: Int
    public var maxIconLength: Int

    public init(maxTags: Int, maxTagLength: Int, maxIconLength: Int) {
        self.maxTags = maxTags
        self.maxTagLength = maxTagLength
        self.maxIconLength = maxIconLength
    }

    public static let serverDefaults = AppearanceLimits(maxTags: 10, maxTagLength: 24, maxIconLength: 16)
}

// MARK: - Validation (appearance.md §2, §1.3, §5)

/// What is wrong with an icon or the tags, and where: `index` is the offending tag (the server's
/// `appearance.tags.{i}`), nil for the icon or for too many tags (`appearance.tags`).
public struct AppearanceIssue: Error, Sendable, Hashable {
    public var index: Int?
    public var message: String

    public init(index: Int? = nil, message: String) {
        self.index = index
        self.message = message
    }
}

public enum AppearanceMessage {
    public static let iconEmpty = "Enter an emoji"
    public static let iconNotOne = "Enter a single emoji"
    public static let iconText = "Enter an emoji, not text"
    public static let tagEmpty = "A tag can’t be empty"
    public static let tagControl = "Tags can’t hold control characters"
    public static func tagTooLong(_ max: Int) -> String { "At most \(max) characters" }
    public static func tagDuplicate(_ tag: String) -> String { "“\(tag)” is already a tag" }
    public static func tooManyTags(_ max: Int) -> String { "At most \(max) tags" }
}

extension TopicAppearance {
    private static let vs16: Unicode.Scalar = "\u{FE0F}"
    private static let keycap: Unicode.Scalar = "\u{20E3}"
    private static let regionalIndicators: ClosedRange<Unicode.Scalar> = "\u{1F1E6}"..."\u{1F1FF}"

    /// One emoji, in its stored form (appearance.md §2, the iOS row of the predicate table):
    ///
    /// 1. NFC; refused when empty or longer than `maxIconLength` code points.
    /// 2. A text-presentation pictograph not followed by U+FE0F gets one ("☺" → "☺️"). Swift has no
    ///    `Extended_Pictographic`: `isEmoji && !isEmojiPresentation && !isASCII` stands in, which
    ///    leaves the keycap bases `0–9 # *` (ASCII) alone.
    /// 3. Exactly one `Character`.
    /// 4. It starts as an emoji: `s0.isEmojiPresentation`; or `s0.isEmoji && !s0.isASCII` and
    ///    `s1 == U+FE0F` (the `!isASCII` refuses a digit + VS16); or two regional indicators (a flag);
    ///    or a keycap `[0-9#*] U+FE0F U+20E3`. The first two exclude a regional indicator and a skin
    ///    tone modifier as `s0`: both are `Emoji_Presentation` but not `Extended_Pictographic`, so the
    ///    server (and the PWA) refuse a lone "🇮" or "🏽", and so does this.
    public static func checkIcon(_ value: String, limits: AppearanceLimits = .serverDefaults)
        -> Result<String, AppearanceIssue>
    {
        var scalars = Array(value.precomposedStringWithCanonicalMapping.unicodeScalars)
        if scalars.isEmpty { return .failure(AppearanceIssue(message: AppearanceMessage.iconEmpty)) }
        if scalars.count > limits.maxIconLength {
            return .failure(AppearanceIssue(message: AppearanceMessage.iconNotOne))
        }
        let first = scalars[0]
        if first.properties.isEmoji && !first.properties.isEmojiPresentation && !first.isASCII
            && scalars.dropFirst().first != vs16
        {
            scalars.insert(vs16, at: 1)
        }
        var stored = ""
        stored.unicodeScalars.append(contentsOf: scalars)
        guard stored.count == 1 else { return .failure(AppearanceIssue(message: AppearanceMessage.iconNotOne)) }
        guard startsAsEmoji(scalars) else { return .failure(AppearanceIssue(message: AppearanceMessage.iconText)) }
        return .success(stored)
    }

    private static func startsAsEmoji(_ scalars: [Unicode.Scalar]) -> Bool {
        let s0 = scalars[0]
        let s1 = scalars.count > 1 ? scalars[1] : nil
        let s2 = scalars.count > 2 ? scalars[2] : nil
        if regionalIndicators.contains(s0) { return s1.map(regionalIndicators.contains) ?? false }
        if s0.properties.isEmojiModifier { return false }
        if s0.properties.isEmojiPresentation { return true }
        if s0.properties.isEmoji && !s0.isASCII && s1 == vs16 { return true }
        return "0123456789#*".unicodeScalars.contains(s0) && s1 == vs16 && s2 == keycap
    }

    /// Tags in their stored form (appearance.md §1.3, §5): each trimmed with its inner whitespace
    /// runs collapsed to one space, non-empty, no control characters, at most `maxTagLength` code
    /// points, unique by case folding (a duplicate is an error, not dropped: the later one is
    /// refused); then at most `maxTags`. Order kept. The same order of checks as the PWA's
    /// `checkTags`.
    public static func checkTags(_ tags: [String], limits: AppearanceLimits = .serverDefaults)
        -> Result<[String], AppearanceIssue>
    {
        var out: [String] = []
        var seen: Set<TextKey> = []
        for (index, raw) in tags.enumerated() {
            let tag = normalizedTag(raw)
            if tag.isEmpty { return .failure(AppearanceIssue(index: index, message: AppearanceMessage.tagEmpty)) }
            if tag.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                return .failure(AppearanceIssue(index: index, message: AppearanceMessage.tagControl))
            }
            if tag.unicodeScalars.count > limits.maxTagLength {
                return .failure(
                    AppearanceIssue(index: index, message: AppearanceMessage.tagTooLong(limits.maxTagLength)))
            }
            // Python's `str.casefold()` ("Straße" and "STRASSE" are one tag).
            let key = BuilderText.casefold(tag)
            if !seen.insert(key).inserted {
                return .failure(AppearanceIssue(index: index, message: AppearanceMessage.tagDuplicate(tag)))
            }
            out.append(tag)
        }
        if out.count > limits.maxTags {
            return .failure(AppearanceIssue(message: AppearanceMessage.tooManyTags(limits.maxTags)))
        }
        return .success(out)
    }

    /// Python's `str.strip()` and inner whitespace runs collapsed to one space, by Python's
    /// `str.isspace()` (``ServerText``), so U+001C–U+001F count as spaces as on the server.
    static func normalizedTag(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            if ServerText.isWhitespace(scalar) {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" ") }
            pendingSpace = false
            out.append(scalar)
        }
        return String(out)
    }
}

// MARK: - The PATCH (appearance.md §1.1)

/// An appearance PATCH (`AppearanceUpdate`): an omitted field is unchanged. For `color` and
/// `icon`, `nil` is omitted and `.some(nil)` clears (`"icon": null`); `tags: []` clears the tags.
public struct AppearanceUpdate: Sendable, Hashable {
    public var color: ColorName??
    public var icon: TopicIcon??
    public var tags: [String]?

    public init(color: ColorName?? = nil, icon: TopicIcon?? = nil, tags: [String]? = nil) {
        self.color = color
        self.icon = icon
        self.tags = tags
    }

    /// The fields of `appearance` that differ from `saved`; nil when none do ("Nothing to save").
    public init?(_ appearance: TopicAppearance, from saved: TopicAppearance) {
        self.init(
            color: appearance.color == saved.color ? nil : .some(appearance.color),
            icon: appearance.icon == saved.icon ? nil : .some(appearance.icon),
            tags: appearance.tags == saved.tags ? nil : appearance.tags)
        if color == nil && icon == nil && tags == nil { return nil }
    }
}

// MARK: - The editor's draft

/// Where an appearance error shows: the swatches, the emoji field, the tag list, one chip, or the
/// "Add a tag" field.
public enum AppearanceField: Sendable, Hashable {
    case color
    case icon
    case tags
    case tag(Int)
    case newTag

    /// The field for a server path relative to the topic body (`appearance.icon.value`,
    /// `appearance.tags.2`); nil outside `appearance`.
    public init?(serverPath path: String) {
        let parts = path.split(separator: ".").map(String.init)
        guard parts.first == "appearance", parts.count >= 2 else { return nil }
        switch parts[1] {
        case "color": self = .color
        case "icon": self = .icon
        case "tags":
            if parts.count >= 3, let index = Int(parts[2]) { self = .tag(index) } else { self = .tags }
        default: return nil
        }
    }
}

/// `AppearanceEditorView`'s state: the chosen colour, the emoji as typed, the tags and the
/// "Add a tag" text not added yet.
public struct AppearanceDraft: Sendable, Hashable {
    public var color: ColorName?
    /// The emoji field's text; empty is no icon.
    public var icon: String
    public var tags: [String]
    public var newTag: String

    public init(_ appearance: TopicAppearance = .empty) {
        color = appearance.color
        switch appearance.icon {
        case .emoji(let value)?: icon = value
        case nil: icon = ""
        }
        tags = appearance.tags
        newTag = ""
    }

    /// What the editor shows now: the colour, the emoji once it is valid, the tags.
    public var preview: TopicAppearance {
        let icon = try? TopicAppearance.checkIcon(icon).get()
        return TopicAppearance(color: color, icon: icon.map(TopicIcon.emoji), tags: tags)
    }

    /// The emoji field's error as it is typed: nil when empty (no icon) or valid.
    public func iconError(limits: AppearanceLimits = .serverDefaults) -> String? {
        guard !icon.isEmpty, case .failure(let issue) = TopicAppearance.checkIcon(icon, limits: limits) else {
            return nil
        }
        return issue.message
    }

    /// "Add" (or Return) in the tag field: the tag joins the list in its stored form, or the
    /// field's error comes back and nothing changes (a duplicate, an eleventh tag, too long).
    public mutating func addTag(limits: AppearanceLimits = .serverDefaults) -> String? {
        switch TopicAppearance.checkTags(tags + [newTag], limits: limits) {
        case .success(let value):
            tags = value
            newTag = ""
            return nil
        case .failure(let issue):
            return issue.message
        }
    }

    public mutating func removeTag(at index: Int) {
        guard tags.indices.contains(index) else { return }
        tags.remove(at: index)
    }

    /// The appearance to send, or the errors by field. Tag text not added yet isn't sent (like an
    /// option not added yet); it only counts as an unsaved change.
    public func validated(limits: AppearanceLimits = .serverDefaults)
        -> Result<TopicAppearance, AppearanceErrors>
    {
        var errors: [AppearanceField: String] = [:]
        var icon: TopicIcon?
        if !self.icon.isEmpty {
            switch TopicAppearance.checkIcon(self.icon, limits: limits) {
            case .success(let value): icon = .emoji(value)
            case .failure(let issue): errors[.icon] = issue.message
            }
        }
        var tags = self.tags
        switch TopicAppearance.checkTags(self.tags, limits: limits) {
        case .success(let value): tags = value
        case .failure(let issue): errors[issue.index.map(AppearanceField.tag) ?? .tags] = issue.message
        }
        guard errors.isEmpty else { return .failure(AppearanceErrors(byField: errors)) }
        return .success(TopicAppearance(color: color, icon: icon, tags: tags))
    }
}

public struct AppearanceErrors: Error, Sendable, Hashable {
    public var byField: [AppearanceField: String]

    public init(byField: [AppearanceField: String]) { self.byField = byField }
}
