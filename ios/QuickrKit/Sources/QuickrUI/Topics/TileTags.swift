/// A tile's tag chips (appearance.md §5): at most three, in the stored order, then "+N" for the
/// rest. Pure, so QuickrDesignTests checks it on the host.
public struct TileTags: Sendable, Hashable {
    /// The chips shown, one per tag.
    public let shown: [String]
    /// How many more there are ("+2"); 0 for none.
    public let more: Int

    public static let limit = 3

    public init(_ tags: [String]) {
        shown = Array(tags.prefix(Self.limit))
        more = max(0, tags.count - Self.limit)
    }

    /// The "+N" chip's text, or nil when every tag is shown.
    public var moreLabel: String? { more > 0 ? "+\(more)" : nil }

    /// What VoiceOver reads for the chips: "Tags: Health, Daily, Home, and 2 more".
    public var spokenLabel: String {
        let list = shown.joined(separator: ", ")
        return more > 0 ? "Tags: \(list), and \(more) more" : "Tags: \(list)"
    }
}

#if os(iOS)
import SwiftUI

/// The tile footer's tag chips (appearance.md §5): neutral badges, three then "+N", wrapping.
/// Display only: the home filter panel's chips filter.
public struct TileTagChips: View {
    let tags: TileTags

    public init(_ tags: [String]) {
        self.tags = TileTags(tags)
    }

    public var body: some View {
        if !tags.shown.isEmpty {
            FlowRow {
                ForEach(Array(tags.shown.enumerated()), id: \.offset) { _, tag in QuickrBadge(tag) }
                if let more = tags.moreLabel { QuickrBadge(more) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tags.spokenLabel)
        }
    }
}

/// The home filter panel's "Tag" row (appearance.md §5): one chip per tag in the store; a tap
/// filters by it (`HomeModel.tagFilter`), a tap on the selected one or ✕ clears it. A selected
/// tag no topic holds any more stays, so it can be cleared.
///
/// Accessibility identifiers: `home.tags` on the row, `home.tag.<tag>` on a chip, `home.tag.clear`.
public struct TagFilterRow: View {
    let tags: [String]
    @Binding var selection: String?

    public init(tags: [String], selection: Binding<String?>) {
        self.tags = tags
        self._selection = selection
    }

    public var body: some View {
        let shown = selection.map { tags.contains($0) ? tags : [$0] + tags } ?? tags
        VStack(alignment: .leading, spacing: 6) {
            Text("Tag").font(.qr(.label)).foregroundStyle(.qr.inkSoft).accessibilityAddTraits(.isHeader)
            FlowRow {
                ForEach(shown, id: \.self) { tag in chip(tag) }
                if selection != nil {
                    Button {
                        selection = nil
                    } label: {
                        QIcon.x.view(size: 14, weight: .bold)
                            .foregroundStyle(.qr.inkSoft)
                            .frame(width: QuickrMetrics.tapTarget, height: QuickrMetrics.tapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(QuickrPressStyle())
                    .accessibilityLabel("Clear the tag filter")
                    .accessibilityIdentifier("home.tag.clear")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.tags")
    }

    private func chip(_ tag: String) -> some View {
        let selected = selection == tag
        return Button {
            selection = selected ? nil : tag
        } label: {
            Text(tag)
                .font(.qr(.sansSemiBold, size: 14, relativeTo: .subheadline))
                .foregroundStyle(selected ? Color.qr.accentStrong : .qr.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(selected ? Color.qr.accentSoft : .qr.surface, in: Capsule())
                .overlay { Capsule().strokeBorder(selected ? Color.qr.accentStrong : .qr.lineStrong, lineWidth: 1) }
                .frame(minHeight: QuickrMetrics.tapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuickrPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("home.tag.\(tag)")
    }
}
#endif
