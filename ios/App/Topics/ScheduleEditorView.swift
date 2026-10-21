import QuickrCore
import QuickrUI
import SwiftUI

/// The schedule editor (the PWA's `ScheduleEditor`): None / Daily (times, weekdays) / Every N
/// units, the time zone and the per-topic notification toggle, with a line saying what it would
/// save. Rows for a `List` section; errors (the form's or the server's) show under their field.
struct ScheduleEditorRows: View {
    @Binding var draft: ScheduleDraft
    let errors: [ScheduleField: String]
    let limits: Limits
    let preview: String
    /// Accessibility identifier prefix ("topicSettings.schedule", "newTopic.schedule").
    let id: String
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let kinds: [(ScheduleDraft.Kind, String)] = [
        (.none, "None"), (.daily, "Daily"), (.interval, "Every…"),
    ]

    var body: some View {
        // A menu at accessibility sizes (TP4, X5).
        QuickrSegmentedPicker("Schedule", selection: $draft.kind) {
            ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden()
        .accessibilityLabel("Schedule")
        .accessibilityIdentifier("\(id).kind")

        switch draft.kind {
        case .none:
            Text(ScheduleDraft.noScheduleText)
                .font(.qr(.subheadline))
                .foregroundStyle(.qr.muted)
        case .daily:
            times
            days
        case .interval:
            interval
        }

        if draft.kind != .none {
            zone
            Toggle(isOn: $draft.notify) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ScheduleDraft.notifyTitle).font(.qr(.body))
                    Text(ScheduleDraft.notifyHint).font(.qr(.footnote)).foregroundStyle(.qr.muted)
                }
            }
            .accessibilityIdentifier("\(id).notify")
            Text(preview)
                .font(.qr(.subheadline))
                .foregroundStyle(.qr.inkSoft)
                .accessibilityIdentifier("\(id).preview")
        }
    }

    // MARK: Daily

    @ViewBuilder
    private var times: some View {
        ForEach(draft.times.indices, id: \.self) { i in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("At")
                        .font(.qr(.label))
                        .foregroundStyle(.qr.inkSoft)
                        .opacity(i == 0 ? 1 : 0)
                        // Visible text is read (the audit flags hidden text); only the first shows.
                        .accessibilityHidden(i != 0)
                    Spacer()
                    DatePicker("Time \(i + 1)", selection: timeBinding(i), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .environment(\.timeZone, Self.utc)
                        .accessibilityLabel("Time \(i + 1)")
                        .accessibilityIdentifier("\(id).time.\(i)")
                    if draft.canRemoveTime {
                        Button {
                            draft.removeTime(at: i)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.qr.muted)
                                // A 44 pt target, not the 22 pt symbol (TP3).
                                .frame(minWidth: QuickrMetrics.tapTarget, minHeight: QuickrMetrics.tapTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove time \(i + 1)")
                        .accessibilityIdentifier("\(id).removeTime.\(i)")
                    }
                }
                TopicFieldError(errors[.time(i)])
            }
        }
        if draft.canAddTime(limits: limits) {
            Button {
                draft.addTime(limits: limits)
            } label: {
                // Our text, which grows fully (a Label here was capped at accessibility sizes).
                HStack(spacing: 8) {
                    Image(systemName: "plus").accessibilityHidden(true)
                    Text("Time").font(.qr(.label)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityLabel("Add a time")
            .accessibilityIdentifier("\(id).addTime")
        }
        if let error = errors[.times] { TopicFieldError(error) }
    }

    private var days: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On").font(.qr(.label)).foregroundStyle(.qr.inkSoft)
            // Seven in a row; a grid at accessibility sizes, where a row of seven clips (TP1).
            LazyVGrid(columns: dayColumns, spacing: 6) {
                ForEach(1...7, id: \.self) { day in
                    let on = draft.days.contains(day)
                    Button {
                        draft.toggleDay(day)
                    } label: {
                        Text(ScheduleText.dayShort[day - 1])
                            .font(.qr(.callout))
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(on ? Color.qr.onAccent : .qr.inkSoft)
                            .background(
                                on ? Color.qr.accent : .qr.surface,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        errors[.days] != nil ? Color.qr.danger : on ? .qr.accent : .qr.lineStrong,
                                        lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.weekdayNames[day - 1])
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("\(id).day.\(day)")
                }
            }
            // The presets wrap onto lines of their own when they don't fit (TP2).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { presets }
                VStack(alignment: .leading, spacing: 6) { presets }
            }
            TopicFieldError(errors[.days])
        }
        .padding(.vertical, 4)
    }

    private var dayColumns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
            : Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    }

    private var presets: some View {
        ForEach(ScheduleDraft.dayPresets) { preset in
            let active = draft.isSelected(preset)
            Button(preset.label) { draft.days = preset.days }
                .font(.qr(.footnote))
                .padding(.horizontal, 12)
                .frame(minHeight: QuickrMetrics.tapTarget)
                .foregroundStyle(active ? Color.qr.paper : .qr.inkSoft)
                .background(active ? Color.qr.ink : .qr.sunken, in: Capsule())
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
                .accessibilityIdentifier("\(id).preset.\(preset.label)")
        }
    }

    // MARK: Interval

    private var interval: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Stacked at accessibility sizes, where a 90 pt field clips the number (TP5).
            if typeSize.isAccessibilitySize {
                Text("Every").font(.qr(.label)).foregroundStyle(.qr.inkSoft)
                everyField
                unitPicker
            } else {
                HStack {
                    Text("Every").font(.qr(.label)).foregroundStyle(.qr.inkSoft)
                    everyField.multilineTextAlignment(.trailing).frame(maxWidth: 90)
                    unitPicker
                }
            }
            Text(ScheduleDraft.intervalHint).font(.qr(.footnote)).foregroundStyle(.qr.muted)
            TopicFieldError(errors[.every])
        }
    }

    private var everyField: some View {
        TextField("Every", text: $draft.every)
            .keyboardType(.numberPad)
            .font(.qr(.body))
            .accessibilityLabel("Every")
            .accessibilityIdentifier("\(id).every")
    }

    private var unitPicker: some View {
        Picker("Unit", selection: $draft.unit) {
            ForEach(ScheduleDraft.Unit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .accessibilityIdentifier("\(id).unit")
    }

    // MARK: Zone

    private var zone: some View {
        VStack(alignment: .leading, spacing: 4) {
            NavigationLink {
                ZonePicker(selection: $draft.timezone)
            } label: {
                LabeledContent("Time zone", value: ScheduleDraft.zoneLabel(draft.timezone))
            }
            .accessibilityIdentifier("\(id).timezone")
            TopicFieldError(errors[.timezone])
        }
    }

    // MARK: Helpers

    static let utc = TimeZone(identifier: "UTC")!
    private static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    /// `HH:MM` as a date on a fixed day in UTC, for the picker (which is told it is in UTC too).
    private func timeBinding(_ i: Int) -> Binding<Date> {
        Binding(
            get: {
                let time = draft.times.indices.contains(i) ? TimeOfDay(draft.times[i]) : nil
                return Self.date(time ?? TimeOfDay(hour: 8, minute: 0))
            },
            set: { date in
                guard draft.times.indices.contains(i) else { return }
                draft.times[i] = Self.time(date).description
            })
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    static func date(_ time: TimeOfDay) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: time.hour, minute: time.minute)) ?? .now
    }

    static func time(_ date: Date) -> TimeOfDay {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }
}

/// An error under a field, or nothing.
struct TopicFieldError: View {
    let message: String?

    init(_ message: String?) { self.message = message }

    var body: some View {
        if let message {
            Text(message)
                .font(.qr(.footnote))
                .foregroundStyle(.qr.danger)
                .accessibilityLabel("Error: \(message)")
        }
    }
}

/// The time zone list, searchable (the PWA's select of every IANA zone).
struct ZonePicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var options: [String] {
        let all = ScheduleDraft.timeZoneOptions(
            current: selection, device: TimeZone.current.identifier, known: TimeZone.knownTimeZoneIdentifiers)
        guard !query.isEmpty else { return all }
        return all.filter { ScheduleDraft.zoneLabel($0).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(options, id: \.self) { zone in
            Button {
                selection = zone
                dismiss()
            } label: {
                HStack {
                    Text(ScheduleDraft.zoneLabel(zone)).foregroundStyle(.qr.ink)
                    Spacer()
                    if zone == selection { Image(systemName: "checkmark").foregroundStyle(.qr.accentStrong) }
                }
            }
            .accessibilityAddTraits(zone == selection ? .isSelected : [])
        }
        .searchable(text: $query, prompt: "Search time zones")
        .navigationTitle("Time zone")
        .navigationBarTitleDisplayMode(.inline)
    }
}
