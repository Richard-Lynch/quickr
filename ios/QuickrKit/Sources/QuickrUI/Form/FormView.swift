#if os(iOS)
import QuickrCore
import SwiftUI

/// The answer form of the record and edit screens: the error banner, "Same as last time", the
/// questions in a card, and the caller's `footer` (details, …). Scrolls itself; put the Save
/// bar on it with `.safeAreaInset(edge: .bottom)` and call ``FormModel/submit()`` from there.
///
/// Focus: each question's field mirrors ``FormModel/focus`` into its own `FocusState` and
/// reports the user's focus changes back, so the model's rules (first empty field, next after a
/// pick, Next/Return) decide where the keyboard goes. Number pads have no Return key, so a
/// keyboard toolbar offers Next/Done while a number field has focus.
public struct FormView<Footer: View>: View {
    let model: FormModel
    let onAutoSave: AutoSave?
    let footer: Footer
    @QuickrReduceMotion private var reduceMotion
    @Environment(\.formSave) private var formSave

    /// - Parameter onAutoSave: called with the entry when a pick on ``FormModel/autoSaveKey``
    ///   completes a valid form (single-chip topics). Save it, show the Undo toast, and return
    ///   whether it was saved or queued; chips stay disabled until it returns.
    public init(
        model: FormModel, onAutoSave: AutoSave? = nil, @ViewBuilder footer: () -> Footer
    ) {
        self.model = model
        self.onAutoSave = onAutoSave
        self.footer = footer()
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let banner = model.banner {
                        FormBannerView(banner: banner).id(FormScrollTarget.banner)
                            .qrAnnouncesError(
                                model.voiceOverRequest?.target == .banner ? banner.message : nil,
                                trigger: model.voiceOverRequest?.serial)
                    }
                    if model.showsSameAsLast, let prefill = model.prefill {
                        SameAsLastButton(prefill: prefill, isApplied: model.isSameAsLastApplied) {
                            model.toggleSameAsLast()
                        }
                    }
                    questions
                    if model.autoSaveKey != nil {
                        Text("Tap an answer to log it right away.")
                            .font(.qr(.subheadline))
                            .foregroundStyle(.qr.muted)
                            .padding(.horizontal, 4)
                            .padding(.top, -4)
                    }
                    footer
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.scrollRequest) { _, request in
                guard let request else { return }
                withQRAnimation(QuickrMotion.rise, reduceMotion: reduceMotion) {
                    proxy.scrollTo(request.target, anchor: .center)
                }
            }
            .task {
                // FocusState only takes once the fields are on screen (after a push animation).
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                model.appear()
            }
            // The keyboard's toolbar, right-aligned: Next/Done for a number (the pad has no Return),
            // then the screen's Save (`formSaveBar`), for any field, the footer's included.
            .toolbar {
                if numberFocus != nil || formSave != nil {
                    ToolbarSpacer(.flexible, placement: .keyboard)
                }
                if let key = numberFocus {
                    ToolbarItem(placement: .keyboard) {
                        Button(model.nextField(after: key) == nil ? "Done" : "Next") { model.advance(from: key) }
                            .font(.qr(.callout))
                            .accessibilityIdentifier("form.keyboard.advance")
                    }
                }
                if let save = formSave {
                    ToolbarSpacer(.fixed, placement: .keyboard)
                    ToolbarItem(placement: .keyboard) {
                        Button(save.title, action: save.action)
                            .font(.qr(.callout))
                            .fontWeight(.semibold)
                            .buttonStyle(.glassProminent)
                            .tint(.qr.accent)
                            .disabled(save.isSaving)
                            .accessibilityIdentifier(save.identifier)
                    }
                }
            }
        }
    }

    /// The focused question's key when it takes a number.
    private var numberFocus: String? {
        guard let key = model.focus, model.questions.first(where: { $0.key == key })?.numericRules != nil
        else { return nil }
        return key
    }

    private var questions: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.questions.enumerated()), id: \.element.key) { index, question in
                if index > 0 { DashedDivider() }
                FormRow(model: model, question: question, onAutoSave: onAutoSave)
                    .padding(16)
                    .id(FormScrollTarget.question(question.key))
            }
        }
        .qrCard()
        // While an auto-save is in flight no chip can start another.
        .disabled(model.isAutoSaving)
    }
}

/// Saves an auto-saved entry (``FormModel/autoSaveKey``) and returns whether it was saved or
/// queued; false lets the user tap the answer again to retry.
public typealias AutoSave = @MainActor (AnswersBody) async -> Bool

extension FormView where Footer == EmptyView {
    public init(model: FormModel, onAutoSave: AutoSave? = nil) {
        self.init(model: model, onAutoSave: onAutoSave) { EmptyView() }
    }
}

/// One question bound to the model, with its own `FocusState` kept in step with the model's.
private struct FormRow: View {
    let model: FormModel
    let question: Question
    let onAutoSave: AutoSave?
    @FocusState private var isFocused: Bool

    var body: some View {
        let key = question.key
        let voiceOver = model.voiceOverRequest.flatMap { $0.target == .question(key) ? $0.serial : nil }
        AnswerField(
            question: question,
            input: Binding(
                get: { model.input(for: key) },
                set: { input in
                    guard let body = model.change(key, to: input) else { return }
                    Task {
                        let saved = await onAutoSave?(body) ?? false
                        model.autoSaveFinished(succeeded: saved)
                    }
                }),
            options: model.options(for: question), error: model.errors[key],
            characterCount: model.characterCount(for: key), focus: $isFocused,
            submitLabel: model.nextField(after: key) == nil ? .done : .next,
            onSubmit: { model.advance(from: key) },
            voiceOverRequest: voiceOver
        )
        .onChange(of: model.focus == key, initial: true) { _, wanted in
            if isFocused != wanted { isFocused = wanted }
        }
        .onChange(of: isFocused) { _, focused in model.focusChanged(key, isFocused: focused) }
    }
}

private struct DashedDivider: View {
    var body: some View {
        Line()
            .stroke(Color.qr.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

/// The server's message over the form, with any issues no field shows listed under it.
struct FormBannerView: View {
    let banner: FormBanner

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            QIcon.alert.view(size: 16, weight: .bold)
            VStack(alignment: .leading, spacing: 4) {
                Text(banner.message)
                    .font(.qr(.callout))
                ForEach(Array(banner.unplaced.enumerated()), id: \.offset) { _, issue in
                    let path = ProblemMapping.path(issue.location)
                    (path.isEmpty ? Text("") : Text("\(path) ").font(.qr(.monoCaption))) + Text(issue.message)
                }
                .font(.qr(.subheadline))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(QuickrTone.danger.foreground)
        .padding(14)
        .background(
            QuickrTone.danger.background,
            in: RoundedRectangle(cornerRadius: QuickrMetrics.chipRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("form.banner")
    }
}

/// One tap fills every answer from the last entry; tapping again undoes it.
struct SameAsLastButton: View {
    let prefill: FormPrefill
    let isApplied: Bool
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .callout) private var iconSide: CGFloat = 36
    @ScaledMetric(relativeTo: .callout) private var iconSize: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: QuickrMetrics.cardRadius, style: .continuous)
        Button(action: action) {
            // At accessibility sizes the summary takes the full width, with Fill/Undo under it.
            let layout =
                typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                HStack(spacing: 12) {
                    (isApplied ? QIcon.check : QIcon.restore).view(size: iconSize, weight: .bold)
                        .frame(width: iconSide, height: iconSide)
                        .foregroundStyle(isApplied ? Color.qr.onAccent : .qr.inkSoft)
                        .background(isApplied ? Color.qr.accent : .qr.sunken, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isApplied ? "Filled in from last time" : "Same as last time")
                            .font(.qr(.callout))
                            .foregroundStyle(.qr.ink)
                        (Text(prefill.summary) + Text(" · ")
                            + Text(prefill.capturedAt, format: .relative(presentation: .named)))
                            .font(.qr(.subheadline))
                            .foregroundStyle(.qr.muted)
                            .lineLimit(typeSize.isAccessibilitySize ? 4 : 1)
                    }
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(isApplied ? "Undo" : "Fill")
                    .font(.qr(.sansSemiBold, size: 14, relativeTo: .subheadline))
                    .foregroundStyle(.qr.accentStrong)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(isApplied ? Color.qr.accentSoft : .qr.surface.opacity(0.7), in: shape)
            .overlay(
                shape.strokeBorder(
                    isApplied ? Color.qr.accent.opacity(0.5) : .qr.lineStrong,
                    style: StrokeStyle(lineWidth: 1, dash: isApplied ? [] : [5, 3]))
            )
            .contentShape(shape)
        }
        .buttonStyle(QuickrPressStyle(scale: 0.99))
        .accessibilityAddTraits(isApplied ? .isSelected : [])
        .accessibilityHint(isApplied ? "Puts back the answers you had." : "Fills in the answers from last time.")
        .accessibilityIdentifier("form.sameAsLast")
    }
}
#endif
