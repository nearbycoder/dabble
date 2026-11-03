import DabbleKit
import SwiftUI

/// Things' "When" popover: Today, This Evening, a calendar, Someday, a
/// reminder time, and a field that understands "fri" or "in 3 days".
struct WhenPicker: View {
    let ids: [UUID]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var date = Date()
    @State private var hasReminder = false
    @State private var reminderTime = Date()
    @State private var loaded = false
    @FocusState private var queryFocused: Bool

    private var store: DabbleStore { model.store }
    private var single: (any Schedulable)? {
        guard ids.count == 1 else { return nil }
        return store.todo(ids[0]) ?? store.project(ids[0])
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "text.cursor")
                            .foregroundStyle(.secondary)
                        TextField("Type a date: tomorrow, fri, in 3 days…", text: $query)
                            .focused($queryFocused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { if let parsed { apply(parsed) } }
                    }
                    if let parsed {
                        PickerRow(title: parsed.label, systemImage: icon(for: parsed), tint: tint(for: parsed)) { apply(parsed) }
                    }
                }

                Section {
                    PickerRow(title: "Today", systemImage: "star.fill", tint: Theme.today, isSelected: current == .today) { apply(.today) }
                    PickerRow(title: "This Evening", systemImage: "moon.fill", tint: Theme.evening, isSelected: current == .evening) { apply(.evening) }
                }

                Section {
                    DatePicker("Date", selection: $date, in: model.today.date()..., displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .onChange(of: date) { _, newValue in
                            guard loaded else { return }
                            let day = Day(newValue)
                            if hasReminder {
                                store.schedule(ids, .date(day), today: model.today)
                            } else {
                                apply(day == model.today ? .today : .date(day))
                            }
                        }
                }

                Section {
                    PickerRow(title: "Someday", systemImage: "archivebox.fill", tint: Theme.someday, isSelected: current == .someday) { apply(.someday) }
                    if single != nil {
                        Toggle(isOn: $hasReminder.animation()) {
                            Label {
                                Text(hasReminder ? "Reminder" : "Add Reminder")
                            } icon: {
                                Image(systemName: "bell.fill").foregroundStyle(.secondary)
                            }
                        }
                        if hasReminder {
                            DatePicker("Time", selection: $reminderTime, displayedComponents: .hourAndMinute)
                        }
                    }
                    Button(role: .destructive) {
                        clear()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("When")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var parsed: When? { When.parse(query, today: model.today) }

    private var current: When? {
        guard let single else { return nil }
        if let date = single.startDate {
            if date <= model.today { return single.isEvening ? .evening : .today }
            return .date(date)
        }
        return single.start == .someday ? .someday : nil
    }

    private func load() {
        guard !loaded else { return }
        if let single {
            if let start = single.startDate { date = start.date() }
            if let minutes = single.reminder {
                hasReminder = true
                reminderTime = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            } else {
                reminderTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
            }
        }
        DispatchQueue.main.async { loaded = true }
    }

    private func apply(_ when: When) {
        store.schedule(ids, when, today: model.today)
        finish()
    }

    /// Saves the reminder (if the item has a date now) and closes.
    private func finish() {
        if let single {
            let refreshed = store.todo(single.id).map { $0 as any Schedulable } ?? store.project(single.id)
            if hasReminder, refreshed?.startDate != nil {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
                store.setReminder(single.id, minutes: (parts.hour ?? 9) * 60 + (parts.minute ?? 0), today: model.today)
            } else if !hasReminder, refreshed?.reminder != nil {
                store.setReminder(single.id, minutes: nil, today: model.today)
            }
        }
        dismiss()
    }

    private func clear() {
        store.batch {
            for id in ids {
                // Inbox items stay in the Inbox; everything else becomes Anytime.
                if let todo = store.todo(id), todo.start == .inbox { continue }
                store.schedule([id], .anytime, today: model.today)
                store.setReminder(id, minutes: nil, today: model.today)
            }
        }
        dismiss()
    }

    private func icon(for when: When) -> String {
        switch when {
        case .today: "star.fill"
        case .evening: "moon.fill"
        case .someday: "archivebox.fill"
        case .inbox: "tray.fill"
        case .anytime: "square.stack.3d.up.fill"
        case .date: "calendar"
        }
    }

    private func tint(for when: When) -> Color {
        switch when {
        case .today: Theme.today
        case .evening: Theme.evening
        case .someday: Theme.someday
        case .inbox: Theme.inbox
        case .anytime: Theme.anytime
        case .date: Theme.upcoming
        }
    }
}

/// Deadline picker: quick choices plus a calendar.
struct DeadlinePicker: View {
    let ids: [UUID]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var loaded = false

    private var existing: Day? {
        ids.count == 1 ? (model.store.todo(ids[0])?.deadline ?? model.store.project(ids[0])?.deadline) : nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PickerRow(title: "Today", systemImage: "flag.fill", tint: Theme.deadline) { set(model.today) }
                    PickerRow(title: "Tomorrow", systemImage: "flag", tint: Theme.deadline) { set(model.today.adding(days: 1)) }
                    PickerRow(title: "In a Week", systemImage: "flag", tint: Theme.deadline) { set(model.today.adding(days: 7)) }
                }
                Section {
                    DatePicker("Deadline", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .tint(Theme.deadline)
                        .onChange(of: date) { _, newValue in
                            if loaded { set(Day(newValue)) }
                        }
                }
                if existing != nil {
                    Section {
                        Button(role: .destructive) { set(nil) } label: {
                            Label("Remove Deadline", systemImage: "xmark.circle")
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Deadline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let existing { date = existing.date() }
                DispatchQueue.main.async { loaded = true }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func set(_ day: Day?) {
        model.store.setDeadline(ids, day)
        dismiss()
    }
}

/// A time-of-day reminder on the item's "when" day.
struct ReminderPicker: View {
    let id: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()

    private var item: (any Schedulable)? { model.store.todo(id) ?? model.store.project(id) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                if let day = item?.startDate {
                    Text("Reminds you \(day.relativeLabel(today: model.today)) at \(time.formatted(date: .omitted, time: .shortened)).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("This will also schedule it for Today.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if item?.reminder != nil {
                    Button("Remove Reminder", role: .destructive) {
                        model.store.setReminder(id, minutes: nil, today: model.today)
                        dismiss()
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                        model.store.setReminder(id, minutes: (parts.hour ?? 9) * 60 + (parts.minute ?? 0), today: model.today)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let minutes = item?.reminder {
                    time = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? time
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
