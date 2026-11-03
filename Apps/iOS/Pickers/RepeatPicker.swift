import DabbleKit
import SwiftUI

/// Edit a to-do's repeat rule: daily/weekly/monthly/yearly, an interval,
/// weekdays, and whether it follows a schedule or repeats after completion.
struct RepeatPicker: View {
    let id: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var unit: RepeatRule.Unit = .week
    @State private var interval = 1
    @State private var mode: RepeatRule.Mode = .schedule
    @State private var weekdays: Set<Int> = []
    @State private var hasEnd = false
    @State private var endDate = Date().addingTimeInterval(60 * 60 * 24 * 90)
    @State private var loaded = false

    private var rule: RepeatRule {
        RepeatRule(unit: unit, interval: interval, mode: mode,
                   weekdays: unit == .week && mode == .schedule ? Array(weekdays) : [],
                   until: hasEnd ? Day(endDate) : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Repeat", selection: $mode) {
                        Text("On a Schedule").tag(RepeatRule.Mode.schedule)
                        Text("After Completion").tag(RepeatRule.Mode.afterCompletion)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    Picker("Frequency", selection: $unit) {
                        Text("Daily").tag(RepeatRule.Unit.day)
                        Text("Weekly").tag(RepeatRule.Unit.week)
                        Text("Monthly").tag(RepeatRule.Unit.month)
                        Text("Yearly").tag(RepeatRule.Unit.year)
                    }
                    Stepper(value: $interval, in: 1...99) {
                        Text(interval == 1 ? "Every \(unitName(1))" : "Every \(interval) \(unitName(interval))")
                    }
                }

                if unit == .week && mode == .schedule {
                    Section("On") {
                        WeekdayChooser(selection: $weekdays)
                            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                    }
                }

                Section {
                    Toggle("End Date", isOn: $hasEnd.animation())
                    if hasEnd {
                        DatePicker("Ends", selection: $endDate, displayedComponents: .date)
                    }
                } footer: {
                    Text(mode == .schedule
                         ? "\(rule.summary). Completing one schedules the next."
                         : "\(rule.summary). The next one appears once you complete this one.")
                }

                if model.store.todo(id)?.repeatRule != nil {
                    Section {
                        Button("Don't Repeat", role: .destructive) {
                            model.store.setRepeat(id, nil, today: model.today)
                            dismiss()
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Repeat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.store.setRepeat(id, rule, today: model.today)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func unitName(_ count: Int) -> String {
        let name: String
        switch unit {
        case .day: name = "day"
        case .week: name = "week"
        case .month: name = "month"
        case .year: name = "year"
        }
        return count == 1 ? name : name + "s"
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let todo = model.store.todo(id) else { return }
        if let existing = todo.repeatRule {
            unit = existing.unit
            interval = existing.interval
            mode = existing.mode
            weekdays = Set(existing.weekdays)
            if let until = existing.until {
                hasEnd = true
                endDate = until.date()
            }
        } else {
            weekdays = [(todo.startDate ?? model.today).weekday()]
        }
    }
}

/// Seven round toggles, S M T W T F S.
struct WeekdayChooser: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let first = Calendar.current.firstWeekday
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { offset in
                let weekday = (first - 1 + offset) % 7 + 1
                let isOn = selection.contains(weekday)
                Button {
                    if isOn { selection.remove(weekday) } else { selection.insert(weekday) }
                } label: {
                    Text(symbols[weekday - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(Circle().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.12)))
                        .foregroundStyle(isOn ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}
