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
    /// How far the keyboard, with its Next/Done bar, reaches up from the bottom of the screen.
    @State private var keyboardHeight: CGFloat = 0
    @State private var bottomSafeArea: CGFloat = 0
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
            DetailsSection(model: model)
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
        // The Save bar sits on the keyboard as UIKit reports it, not on SwiftUI's keyboard safe
        // area: that one lost the keyboard's Next/Done bar when the form changed (the first
        // keystroke), and the Save bar slid under it until the next layout.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !(keyboardUp && typeSize.isAccessibilitySize) { saveBar }
                Color.clear.frame(height: max(0, keyboardHeight - bottomSafeArea))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }, action: { bottomSafeArea = $0 })
        .qrPaperBackground()
        .navigationTitle(model.isFixing ? "Fix entry · \(model.topic.name)" : model.topic.name)
        .navigationBarTitleDisplayMode(.inline)
        // One back button the whole time: swapping the system's for a guarded one on the first edit
        // changed the navigation bar while the keyboard was up, and the Save bar then dropped under
        // the keyboard's Next/Done until the screen was laid out again. The edge swipe goes back
        // only while there is nothing to lose.
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
            guard let end = $0.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                let screen = $0.object as? UIScreen
            else { return }
            let height = max(0, screen.bounds.maxY - end.minY)
            withAnimation(.smooth(duration: 0.25)) { keyboardHeight = height }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.smooth(duration: 0.25)) { keyboardHeight = 0 }
        }
    }

    /// Back: straight away when nothing changed, else asks first.
    private func leave() {
        if model.hasUnsavedChanges { confirmingLeave = true } else { dismiss() }
    }

    private var keyboardUp: Bool { keyboardHeight > 0 }

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

/// Captured at, notes and source: collapsed to a summary line, opened by an error in it.
private struct DetailsSection: View {
    @Bindable var model: RecordModel

    var body: some View {
        DisclosureGroup(isExpanded: $model.showsDetails) {
            VStack(alignment: .leading, spacing: 14) {
                field(error: model.metaErrors[.capturedAt]) {
                    DatePicker(
                        "Captured at", selection: $model.capturedAt, displayedComponents: [.date, .hourAndMinute]
                    )
                    .font(.qr(.body))
                    .accessibilityIdentifier("record.capturedAt")
                }
                field(error: model.metaErrors[.notes]) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("Notes").font(.qr(.label))
                            Text("optional").font(.qr(.sansMedium, size: 12, relativeTo: .caption))
                                .foregroundStyle(.qr.muted)
                        }
                        TextField("", text: $model.notes, axis: .vertical)
                            .lineLimit(2...6)
                            .font(.qr(.body))
                            .padding(12)
                            .background(
                                Color.qr.surface,
                                in: RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: QuickrMetrics.controlRadius, style: .continuous)
                                    .strokeBorder(Color.qr.lineStrong, lineWidth: 1)
                            )
                            .accessibilityLabel("Notes")
                            .accessibilityIdentifier("record.notes")
                    }
                }
                field(error: model.metaErrors[.source]) {
                    LabeledContent("Source", value: model.source)
                        .font(.qr(.body))
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                QIcon.clock.view(size: 16).foregroundStyle(.qr.muted)
                Text("Details").font(.qr(.callout))
                Text(summary).font(.qr(.subheadline)).foregroundStyle(.qr.muted).lineLimit(1)
                if !model.metaErrors.isEmpty {
                    QIcon.alert.view(size: 14).foregroundStyle(.qr.danger)
                }
            }
        }
        .tint(.qr.inkSoft)
        .padding(16)
        .qrCard()
        .accessibilityIdentifier("record.details")
    }

    private var summary: String {
        let when = model.capturedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(when) · \(model.source)"
    }

    @ViewBuilder
    private func field(error: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            if let error {
                Text(error)
                    .font(.qr(.sansMedium, size: 14, relativeTo: .subheadline))
                    .foregroundStyle(.qr.danger)
            }
        }
    }
}

/// The navigation controller's swipes back (the edge swipe, and iOS 26's swipe from anywhere in
/// the content), which hiding the system back button turns off: on while `isEnabled`, and their
/// previous delegates back when the screen goes.
private struct SwipeBack: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isEnabled = isEnabled
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var isEnabled = true
        private var previousDelegates: [(UIGestureRecognizer, UIGestureRecognizerDelegate?)] = []

        private var swipes: [UIGestureRecognizer] {
            [
                navigationController?.interactivePopGestureRecognizer,
                navigationController?.interactiveContentPopGestureRecognizer,
            ].compactMap { $0 }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            for swipe in swipes where swipe.delegate !== self {
                previousDelegates.append((swipe, swipe.delegate))
                swipe.delegate = self
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            for (swipe, delegate) in previousDelegates where swipe.delegate === self { swipe.delegate = delegate }
            previousDelegates = []
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            isEnabled && (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
