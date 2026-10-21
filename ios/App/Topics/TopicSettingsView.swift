import QuickrCore
import QuickrUI
import SwiftUI

/// Topic settings (the PWA's `SettingsPage`): Details, Schedule and Lifecycle sections, each saving
/// on its own. Leaving with unsaved edits asks first.
struct TopicSettingsView: View {
    @Bindable var model: TopicSettingsModel
    @State private var confirmingLeave = false
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss

    private let text = TopicText()

    var body: some View {
        List {
            detailsSection
            scheduleSection
            lifecycleSection
        }
        .listStyle(.insetGrouped)
        .tint(.qr.accentStrong)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .qrPaperBackground()
        .navigationTitle("Topic settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .toolbar {
            if hasUnsavedChanges {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        confirmingLeave = true
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .accessibilityIdentifier("topicSettings.back")
                }
            }
        }
        .alert("Discard unsaved changes?", isPresented: $confirmingLeave) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("You have changes that haven’t been saved. Leave and lose them?")
        }
        .sheet(isPresented: $deleting) {
            DeleteTopicSheet(model: model, entries: text.count(model.topic.entryCount, "entry", "entries"))
        }
    }

    private var hasUnsavedChanges: Bool { model.detailsDirty || model.scheduleDirty }

    // MARK: Details

    private var detailsSection: some View {
        Section {
            if let banner = model.detailsBanner {
                TopicBanner(text: banner, trigger: model.detailsAttempts)
                    .accessibilityIdentifier("topicSettings.details.banner")
            }
            TopicLabeledField("Name", error: model.detailErrors[.name]) {
                TextField("Name", text: $model.name)
                    .accessibilityIdentifier("topicSettings.name")
            }
            TopicLabeledField(
                "URL slug", hint: "Changing it breaks old links to this topic", error: model.detailErrors[.slug]
            ) {
                TextField("URL slug", text: $model.slug)
                    .font(.qr(.mono))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("topicSettings.slug")
            }
            TopicLabeledField("Description", optional: true, error: model.detailErrors[.description]) {
                TextField("Description", text: $model.description, axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("topicSettings.description")
            }
            TopicSaveButton(
                "Save details", isSaving: model.isSavingDetails, isEnabled: model.detailsDirty,
                id: "topicSettings.saveDetails"
            ) {
                Task { await model.saveDetails() }
            }
        } header: {
            Text("Details")
        } footer: {
            Text("Questions are edited by publishing a new version.")
        }
        .disabled(model.isSavingDetails)
    }

    // MARK: Schedule

    private var scheduleSection: some View {
        Section {
            if let banner = model.scheduleBanner {
                TopicBanner(text: banner, trigger: model.scheduleAttempts)
                    .accessibilityIdentifier("topicSettings.schedule.banner")
            }
            if model.isArchived {
                Text("Archived topics are never due.").font(.qr(.subheadline)).foregroundStyle(.qr.muted)
            }
            ScheduleEditorRows(
                draft: $model.schedule, errors: model.scheduleErrors, limits: model.limits,
                preview: model.schedulePreview, id: "topicSettings.schedule")
            HStack {
                if model.scheduleDirty {
                    Button("Reset") { model.resetSchedule() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("topicSettings.resetSchedule")
                }
                Spacer()
                TopicSaveButton(
                    "Save schedule", isSaving: model.isSavingSchedule, isEnabled: model.scheduleDirty,
                    id: "topicSettings.saveSchedule"
                ) {
                    Task { await model.saveSchedule() }
                }
            }
        } header: {
            Text("Schedule")
        }
        .disabled(model.isSavingSchedule)
    }

    // MARK: Lifecycle

    private var lifecycleSection: some View {
        Section {
            Text(lifecycleSummary)
                .font(.qr(.subheadline))
                .foregroundStyle(.qr.muted)
                .accessibilityIdentifier("topicSettings.lifecycle")
            if model.isArchived {
                Button {
                    Task { await model.unarchive() }
                } label: {
                    Label("Unarchive", systemImage: "arrow.uturn.backward")
                }
                .accessibilityIdentifier("topicSettings.unarchive")
                Button(role: .destructive) {
                    deleting = true
                } label: {
                    Label("Delete permanently", systemImage: "trash")
                }
                .accessibilityIdentifier("topicSettings.delete")
            } else {
                Button {
                    Task { await model.archive() }
                } label: {
                    Label("Archive topic", systemImage: "archivebox")
                }
                .accessibilityIdentifier("topicSettings.archive")
            }
        } header: {
            Text("Lifecycle")
        } footer: {
            if !model.isArchived {
                Text("Archived topics are hidden and stop accepting entries. Only archived topics can be deleted.")
            }
        }
        .disabled(model.isChangingArchive)
    }

    /// "Created 4 Mar 2026 at 12:00 · 12 entries · archived 5 Mar 2026 at 09:30".
    private var lifecycleSummary: String {
        let topic = model.topic
        var parts = "Created \(Self.dateTime(topic.createdAt)) · \(text.count(topic.entryCount, "entry", "entries"))"
        if let archived = topic.archivedAt { parts += " · archived \(Self.dateTime(archived))" }
        return parts
    }

    static func dateTime(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}

/// "Delete forever?": type the slug, then "Delete topic" (the PWA's `ConfirmSheet`).
struct DeleteTopicSheet: View {
    @Bindable var model: TopicSettingsModel
    let entries: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.deleteText(entries: entries))
                        .font(.qr(.body))
                        .foregroundStyle(.qr.inkSoft)
                    if let warning = model.unsyncedWarning {
                        TopicBanner(text: warning, tone: .warn).accessibilityIdentifier("deleteTopic.unsynced")
                    }
                }
                Section {
                    TextField(model.topic.slug, text: $model.deleteConfirmation)
                        .font(.qr(.mono))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .accessibilityLabel("Type \(model.topic.slug) to confirm")
                        .accessibilityIdentifier("deleteTopic.confirmation")
                } header: {
                    Text("Type \(Text(model.topic.slug).font(.qr(.monoCaption))) to confirm")
                }
                Section {
                    Button(role: .destructive) {
                        Task { if await model.delete() { dismiss() } }
                    } label: {
                        HStack {
                            Text("Delete topic")
                            Spacer()
                            if model.isDeleting { ProgressView() }
                        }
                    }
                    .disabled(!model.canConfirmDelete)
                    .accessibilityIdentifier("deleteTopic.confirm")
                }
            }
            .scrollContentBackground(.hidden)
            .qrPaperBackground()
            .navigationTitle("Delete forever?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("deleteTopic.cancel")
                }
            }
            .interactiveDismissDisabled(model.isDeleting)
            .task {
                await model.prepareDelete()
                focused = true
            }
        }
    }
}

// MARK: - Shared pieces

/// A field with its label above, an optional hint and its error below.
struct TopicLabeledField<Content: View>: View {
    let label: String
    var hint: String?
    var optional = false
    let error: String?
    @ViewBuilder let content: Content

    init(
        _ label: String, hint: String? = nil, optional: Bool = false, error: String?,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.hint = hint
        self.optional = optional
        self.error = error
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label).font(.qr(.label)).foregroundStyle(.qr.inkSoft)
                if optional { Text("optional").font(.qr(.caption)).foregroundStyle(.qr.muted) }
            }
            // Read as the field's heading: visible text stays in the accessibility tree.
            .accessibilityElement(children: .combine)
            content.font(.qr(.body))
            if let hint { Text(hint).font(.qr(.footnote)).foregroundStyle(.qr.muted) }
            TopicFieldError(error)
        }
        .padding(.vertical, 2)
    }
}

/// A section's Save: disabled until there is something to save, a spinner while it saves.
struct TopicSaveButton: View {
    let title: String
    let isSaving: Bool
    let isEnabled: Bool
    let id: String
    let action: () -> Void

    init(_ title: String, isSaving: Bool, isEnabled: Bool, id: String, action: @escaping () -> Void) {
        self.title = title
        self.isSaving = isSaving
        self.isEnabled = isEnabled
        self.id = id
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSaving { ProgressView() }
                Text(title).font(.qr(.callout))
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isEnabled || isSaving)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier(id)
    }
}

/// A message over a section: what went wrong, or a warning.
struct TopicBanner: View {
    enum Tone { case danger, warn }

    let text: String
    var tone: Tone = .danger
    /// Changes per attempt (a save counter), so a repeated identical error is read again.
    var trigger = 0

    var body: some View {
        Label {
            Text(text).font(.qr(.subheadline)).foregroundStyle(.qr.ink)
        } icon: {
            Image(systemName: tone == .danger ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tone == .danger ? Color.qr.danger : .qr.warn)
        }
        .padding(.vertical, 4)
        .listRowBackground(tone == .danger ? Color.qr.dangerSoft : .qr.warnSoft)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        // VoiceOver goes to an error as it appears (TP6, X2); a warning is only read in turn.
        .qrAnnouncesError(tone == .danger ? text : nil, trigger: trigger)
    }
}
