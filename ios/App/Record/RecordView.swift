import QuickrCore
import QuickrUI
import SwiftUI
import UIKit

/// The record screen (the PWA's `RecordPage`): the answers, Details (captured at, notes, source),
/// Log another, and a sticky Save. In fix mode it says the entry wasn't saved and saves again.
/// Leaving with unsaved changes asks first. While the keyboard is up, Save moves into the
/// keyboard's toolbar, so nothing sits between the keyboard and the field being typed in.
struct RecordView: View {
    @Bindable var model: RecordModel
    let settings: AppSettings
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
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
        // Toasts sit above the bar (measured: it grows with the text size). Only the screen leaving
        // puts them back down: Log another's fresh form rebuilds the bar, and its old copy going
        // must not undo the new one's measure.
        .formSaveBar(
            saveTitle, identifier: "record.save", isSaving: model.isSaving,
            onBarHeight: { environment.toastBottomInset = $0 + 8 }, save: save
        )
        .qrPaperBackground()
        .navigationTitle(model.isFixing ? "Fix entry · \(model.topic.name)" : model.topic.name)
        .navigationBarTitleDisplayMode(.inline)
        // One back button the whole time, guarded (the navigation bar doesn't change on the first
        // edit); the swipes back go back only while there is nothing to lose, and so does
        // VoiceOver's escape.
        .navigationBarBackButtonHidden()
        .background(SwipeBack(isEnabled: !model.hasUnsavedChanges))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: leave) {
                    Label("Back", systemImage: "chevron.left")
                }
                .accessibilityIdentifier("record.back")
            }
            if model.loggedCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    QuickrBadge("+\(model.loggedCount)", tone: .ok)
                        .accessibilityLabel("\(model.loggedCount) logged")
                        .accessibilityIdentifier("record.loggedCount")
                }
            }
        }
        // VoiceOver's escape (two-finger scrub) is a back too, guarded the same way.
        .accessibilityAction(.escape, leave)
        .alert("Discard this entry?", isPresented: $confirmingLeave) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("What you’ve entered hasn’t been saved.")
        }
        .onDisappear { environment.toastBottomInset = 8 }
    }

    private var saveTitle: String { model.isFixing ? "Save again" : "Save" }

    private func save() {
        Task {
            if await model.save() == .leave { dismiss() }
        }
    }

    /// Back: straight away when nothing changed, else asks first.
    private func leave() {
        if model.hasUnsavedChanges { confirmingLeave = true } else { dismiss() }
    }

    private var logAnother: Binding<Bool> {
        Binding(
            get: { model.logAnother },
            set: { value in
                model.logAnother = value
                settings.logAnother = value
            })
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

/// The navigation controller's swipes back (the edge swipe, and iOS 26's swipe from anywhere in
/// the content), which hiding the system back button turns off: on while `isEnabled`, and their
/// previous delegates back when the screen goes. The record and edit screens.
struct SwipeBack: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isEnabled = isEnabled
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var isEnabled = true
        /// Each swipe taken over, with what to put back: its delegate, and whether it was enabled
        /// (UIKit turns the content swipe off while the back button is hidden).
        private var previous: [(swipe: UIGestureRecognizer, delegate: UIGestureRecognizerDelegate?, enabled: Bool)] =
            []

        private var swipes: [UIGestureRecognizer] {
            [
                navigationController?.interactivePopGestureRecognizer,
                navigationController?.interactiveContentPopGestureRecognizer,
            ].compactMap { $0 }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            for swipe in swipes where swipe.delegate !== self {
                previous.append((swipe, swipe.delegate, swipe.isEnabled))
                swipe.delegate = self
                swipe.isEnabled = true  // whether it may start is gestureRecognizerShouldBegin's call
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            for (swipe, delegate, enabled) in previous where swipe.delegate === self {
                swipe.delegate = delegate
                swipe.isEnabled = enabled
            }
            previous = []
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            isEnabled && (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
