import QuickrCore
import QuickrUI
import SwiftUI
import UIKit

/// The record screen (the PWA's `RecordPage`): the answers, Details (captured at, notes, source),
/// Log another, and a sticky Save. In fix mode it says the entry wasn't saved and saves again.
/// Leaving with unsaved changes asks first. At accessibility text sizes the Save bar steps aside
/// while the keyboard is up, so the field being typed in stays visible.
struct RecordView: View {
    @Bindable var model: RecordModel
    let settings: AppSettings
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var keyboardUp = false
    @State private var confirmingLeave = false

    var body: some View {
        FormView(
            model: model.form,
            onAutoSave: { body in
                let saved = await model.autoSave(body)
                if saved { dismiss() }
                return saved
            }
        ) {
            EntryDetailsSection(model: model, idPrefix: "record")
            if !model.isFixing && model.form.autoSaveKey == nil {
                Toggle(isOn: logAnother) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Log another").font(.qr(.callout))
                        Text("Stay here after saving").font(.qr(.subheadline)).foregroundStyle(.qr.muted)
                    }
                }
                .tint(.qr.accent)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("record.logAnother")
            }
        }
        // A fresh form (Log another) starts with fresh field state: no focus or touch carried over.
        .id(ObjectIdentifier(model.form))
        // Nothing can change while it saves: an edit made meanwhile would be lost when the screen
        // closes or Log another starts afresh.
        .disabled(model.isSaving)
        .safeAreaInset(edge: .top) {
            if model.isFixing {
                fixBanner
            } else if let message = model.rejectionMessage {
                rejectionBanner(message)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !(keyboardUp && typeSize.isAccessibilitySize) { saveBar }
        }
        .qrPaperBackground()
        .navigationTitle(model.isFixing ? "Fix entry · \(model.topic.name)" : model.topic.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.hasUnsavedChanges)
        .toolbar {
            if model.hasUnsavedChanges {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        confirmingLeave = true
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .accessibilityIdentifier("record.back")
                }
            }
            if model.loggedCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    QuickrBadge("+\(model.loggedCount)", tone: .ok)
                        .accessibilityLabel("\(model.loggedCount) logged")
                        .accessibilityIdentifier("record.loggedCount")
                }
            }
        }
        .alert("Discard this entry?", isPresented: $confirmingLeave) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("What you’ve entered hasn’t been saved.")
        }
        .onDisappear { environment.toastBottomInset = 8 }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardUp = false
        }
    }

    private var logAnother: Binding<Bool> {
        Binding(
            get: { model.logAnother },
            set: { value in
                model.logAnother = value
                settings.logAnother = value
            })
    }

    private var saveBar: some View {
        PrimaryButton(model.isFixing ? "Save again" : "Save", icon: .check, isLoading: model.isSaving) {
            Task {
                if await model.save() == .leave { dismiss() }
            }
        }
        .accessibilityIdentifier("record.save")
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Toasts sit above the bar (measured: it grows with the text size). Only the screen leaving
        // puts them back down: Log another's fresh form rebuilds the bar, and its old copy going
        // must not undo the new one's measure.
        .onGeometryChange(
            for: CGFloat.self, of: { $0.size.height },
            action: { height in environment.toastBottomInset = height + 8 })
    }

    /// A refusal the form can't show on a field (no `Problem` came back).
    private func rejectionBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not saved").font(.qr(.callout))
            Text("The server said: \(message)").font(.qr(.subheadline))
        }
        .foregroundStyle(QuickrTone.danger.foreground)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QuickrTone.danger.background)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("record.rejection")
    }

    private var fixBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This entry was not saved").font(.qr(.callout))
            Text(
                (model.rejectionMessage ?? model.fixMessage).map {
                    "The server said: \($0). Correct it and save again, or discard it from the sync list."
                }
                    ?? "The server rejected it. Correct it and save again, or discard it from the sync list."
            )
            .font(.qr(.subheadline))
        }
        .foregroundStyle(QuickrTone.info.foreground)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QuickrTone.info.background)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("record.fixBanner")
    }
}
