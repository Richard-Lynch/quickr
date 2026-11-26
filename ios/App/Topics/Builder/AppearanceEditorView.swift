import QuickrCore
import QuickrUI
import SwiftUI

/// The Appearance row of the new-topic and topic-settings forms (appearance.md §7): the glyph and a
/// summary, opening ``AppearanceEditorView``. Nothing when the model has nowhere to send it.
struct AppearanceRow<Model: AppearanceEditingModel>: View {
    @Bindable var model: Model
    /// The topic's name, for the fallback initial.
    let name: String
    let id: String

    var body: some View {
        if model.editsAppearance {
            NavigationLink {
                AppearanceEditorView(model: model)
            } label: {
                HStack(spacing: 12) {
                    TopicGlyphView(theme: TopicTheme(appearance: model.appearance.preview, name: name), size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Appearance").font(.qr(.label)).foregroundStyle(.qr.ink)
                        Text(summary).font(.qr(.subheadline)).foregroundStyle(.qr.muted)
                    }
                    if hasError {
                        Spacer()
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.qr.danger)
                            .accessibilityLabel("Needs attention")
                    }
                }
            }
            .accessibilityIdentifier("\(id).appearance")
        }
    }

    /// "Teal · 🚬 · 2 tags", or "Colour, emoji and tags" when there is none.
    private var summary: String {
        let appearance = model.appearance.preview
        var parts: [String] = []
        if let color = appearance.color { parts.append(color.label) }
        if case .emoji(let value)? = appearance.icon { parts.append(value) }
        switch appearance.tags.count {
        case 0: break
        case 1: parts.append("1 tag")
        case let n: parts.append("\(n) tags")
        }
        return parts.isEmpty ? "Colour, emoji and tags" : parts.joined(separator: " · ")
    }

    private var hasError: Bool { model.appearanceErrors.keys.contains { $0 != .newTag } }
}

/// The colour swatches, the emoji field and the tags (appearance.md §7). Edits go straight into the
/// form's draft; the form's own Create or Save sends them. Accessibility ids per §7: `topic.color.<name>`,
/// `topic.icon`, `topic.tags`, `topic.tags.add`, `topic.tags.<i>`.
struct AppearanceEditorView<Model: AppearanceEditingModel>: View {
    @Bindable var model: Model
    @FocusState private var addingTag: Bool
    @ScaledMetric(relativeTo: .body) private var swatchSize: CGFloat = 44

    var body: some View {
        List {
            colorSection
            iconSection
            tagsSection
        }
        .listStyle(.insetGrouped)
        .tint(.qr.accentStrong)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .qrPaperBackground()
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Colour

    private var colorSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: swatchSize), spacing: 12)], spacing: 12) {
                swatch(nil)
                ForEach(ColorName.allCases, id: \.self) { swatch($0) }
            }
            .padding(.vertical, 6)
            TopicFieldError(model.appearanceErrors[.color])
        } header: {
            Text("Colour")
        } footer: {
            Text("Tints the topic’s tile, buttons and Live Activity.")
        }
    }

    private func swatch(_ color: ColorName?) -> some View {
        let theme = TopicTheme(appearance: TopicAppearance(color: color), name: "")
        let selected = model.appearance.color == color
        return Button {
            model.appearance.color = color
        } label: {
            ZStack {
                if color == nil {
                    Circle().strokeBorder(Color.qr.muted, lineWidth: 1.5)
                    Image(systemName: "slash.circle").foregroundStyle(.qr.muted)
                } else {
                    Circle().fill(theme.tint)
                }
                if selected {
                    Circle().strokeBorder(Color.qr.ink, lineWidth: 2).padding(-4)
                    if color != nil { Image(systemName: "checkmark").font(.qr(.label)).foregroundStyle(theme.onTint) }
                }
            }
            .frame(width: swatchSize, height: swatchSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color?.label ?? "No colour")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("topic.color.\(color?.rawValue ?? "none")")
    }

    // MARK: Emoji

    private var iconSection: some View {
        Section {
            FieldRow(alignment: .center) {
                TopicGlyphView(
                    theme: TopicTheme(appearance: model.appearance.preview, name: ""), size: 32, fallbackInitial: false)
                // iOS has no emoji-only keyboard: the globe key switches to it (§7).
                TextField("Emoji", text: $model.appearance.icon)
                    .keyboardType(.default)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.qr(.title))
                    .accessibilityLabel("Emoji")
                    .accessibilityIdentifier("topic.icon")
                if !model.appearance.icon.isEmpty {
                    Button("Remove") { model.appearance.icon = "" }
                        .buttonStyle(.borderless)
                        .frame(minHeight: QuickrMetrics.tapTarget)
                        .accessibilityLabel("Remove emoji")
                        .accessibilityIdentifier("topic.icon.clear")
                }
            }
            TopicFieldError(model.appearance.iconError(limits: model.appearanceLimits) ?? model.appearanceErrors[.icon])
        } header: {
            Text("Emoji · optional")
        } footer: {
            Text("One emoji. Shown before the topic’s name everywhere.")
        }
    }

    // MARK: Tags

    private var tagsSection: some View {
        Section {
            Group {
                if model.appearance.tags.isEmpty {
                    Text("No tags yet.").font(.qr(.subheadline)).foregroundStyle(.qr.muted)
                } else {
                    FlowLayout {
                        ForEach(Array(model.appearance.tags.enumerated()), id: \.offset) { index, tag in
                            chip(index, tag)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("topic.tags")
            ForEach(Array(model.appearance.tags.indices), id: \.self) { index in
                if let message = model.appearanceErrors[.tag(index)] {
                    TopicFieldError("\(model.appearance.tags[index]): \(message)")
                }
            }
            TopicFieldError(model.appearanceErrors[.tags])
            VStack(alignment: .leading, spacing: 4) {
                FieldRow(alignment: .center) {
                    TextField("Add a tag", text: $model.appearance.newTag)
                        .focused($addingTag)
                        .submitLabel(.done)
                        .onSubmit {
                            model.addTag()
                            // Stay in the field for the next one.
                            addingTag = true
                        }
                        .accessibilityLabel("Add a tag")
                        .accessibilityIdentifier("topic.tags.add")
                    Button("Add") { model.addTag() }
                        .buttonStyle(.borderless)
                        .frame(minHeight: QuickrMetrics.tapTarget)
                        .disabled(model.appearance.newTag.allSatisfy(\.isWhitespace))
                        .accessibilityIdentifier("topic.tags.addButton")
                }
                TopicFieldError(model.appearanceErrors[.newTag])
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Tags")
                Text("\(model.appearance.tags.count)/\(model.appearanceLimits.maxTags)").font(.qr(.monoCaption))
            }
        } footer: {
            Text("Filter the topic list by tag.")
        }
    }

    private func chip(_ index: Int, _ tag: String) -> some View {
        Button {
            model.removeTag(at: index)
        } label: {
            HStack(spacing: 4) {
                Text(tag)
                Image(systemName: "xmark").font(.qr(.caption))
            }
            .font(.qr(.callout))
            .foregroundStyle(.qr.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: QuickrMetrics.tapTarget)
            .background(Color.qr.sunken, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.qr.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove tag \(tag)")
        .accessibilityIdentifier("topic.tags.\(index)")
    }
}

extension ColorName {
    /// "Teal": the swatch's spoken name and the row's summary.
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}
