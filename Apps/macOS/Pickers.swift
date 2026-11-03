import DabbleKit
import SwiftUI

/// Shows the right picker for a request and applies the result to the store.
struct PickerPopover: View {
    let request: PopoverRequest
    @Environment(WindowState.self) private var state
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let ids = request.ids
        let first = ids.first!
        let todo = store.todo(first)
        let project = store.project(first)
        Group {
            switch request.kind {
            case .when:
                WhenPicker(
                    current: todo.flatMap { When(of: $0, today: model.today) } ?? project.flatMap { When(of: $0, today: model.today) },
                    reminder: todo?.reminder ?? project?.reminder,
                    showsReminder: ids.count == 1,
                    onSelect: { when in
                        state.schedule(when ?? .anytime, ids)
                        dismiss()
                    },
                    onReminder: { minutes in
                        store.setReminder(first, minutes: minutes, today: model.today)
                        dismiss()
                    }
                )
            case .deadline:
                DeadlinePicker(current: todo?.deadline ?? project?.deadline) { day in
                    store.setDeadline(ids, day)
                    dismiss()
                }
            case .tags:
                TagPicker(selected: Set(todo?.tagIDs ?? project?.tagIDs ?? store.area(first)?.tagIDs ?? [])) { tag in
                    store.toggleTag(tag, on: ids)
                }
            case .move:
                MovePicker(movingProjects: ids.allSatisfy { store.project($0) != nil }) { destination in
                    withAnimation(.snappy) { store.move(ids, to: destination) }
                    dismiss()
                }
            case .repeatRule:
                RepeatPicker(current: todo?.repeatRule) { rule in
                    for id in ids where store.todo(id) != nil { store.setRepeat(id, rule, today: model.today) }
                    dismiss()
                }
            case .reminder:
                ReminderPicker(current: todo?.reminder ?? project?.reminder) { minutes in
                    store.setReminder(first, minutes: minutes, today: model.today)
                    dismiss()
                }
            }
        }
    }

    private func dismiss() {
        state.popover = nil
    }
}

// MARK: - When

struct WhenPicker: View {
    var current: When?
    var reminder: Int?
    var showsReminder = true
    var onSelect: (When?) -> Void
    var onReminder: ((Int?) -> Void)?

    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var addingReminder = false
    @State private var reminderTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()

    var body: some View {
        let today = model.today
        VStack(alignment: .leading, spacing: 2) {
            Text("When")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)
            PickerSearchField(text: $text, placeholder: "Type: tomorrow, fri, in 3 days…") { command in
                switch command {
                case .submit:
                    if let when = When.parse(text, today: today) { onSelect(when) }
                    return true
                default:
                    return false
                }
            }
            if !text.isEmpty {
                Group {
                    if let when = When.parse(text, today: today) {
                        Label(label(for: when, today: today), systemImage: "return")
                    } else {
                        Text("Not a date I understand")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }

            PickerRow(icon: "star.fill", tint: Theme.today, title: "Today", checked: current == .today) { onSelect(.today) }
                .padding(.top, 6)
            PickerRow(icon: "moon.fill", tint: Theme.evening, title: "This Evening", checked: current == .evening) { onSelect(.evening) }

            CalendarGrid(selected: currentDay, today: today, allowsPast: false) { day in
                onSelect(day == today ? .today : .date(day))
            }
            .padding(.vertical, 6)

            PickerRow(icon: "archivebox.fill", tint: Theme.someday, title: "Someday", checked: current == .someday) { onSelect(.someday) }

            if showsReminder, let onReminder {
                Divider().padding(.vertical, 4)
                if addingReminder || reminder != nil {
                    HStack {
                        Image(systemName: "bell.fill").foregroundStyle(.secondary)
                        DatePicker("", selection: $reminderTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.stepperField)
                        Spacer()
                        Button("Set") { onReminder(minutes(of: reminderTime)) }
                        if reminder != nil {
                            Button { onReminder(nil) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Remove reminder")
                        }
                    }
                    .padding(.horizontal, 6)
                } else {
                    PickerRow(icon: "plus", tint: .secondary, title: "Add Reminder") { addingReminder = true }
                }
            }

            if current != nil {
                Divider().padding(.vertical, 4)
                Button { onSelect(nil) } label: {
                    Text("Clear").frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
            }
        }
        .padding(12)
        .frame(width: 252)
        .onAppear {
            if let reminder {
                reminderTime = Calendar.current.date(bySettingHour: reminder / 60, minute: reminder % 60, second: 0, of: Date()) ?? reminderTime
            }
        }
    }

    private var currentDay: Day? {
        switch current {
        case .date(let day): day
        case .today, .evening: model.today
        default: nil
        }
    }

    private func label(for when: When, today: Day) -> String {
        if case .date(let day) = when {
            return day.date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return when.label
    }
}

func minutes(of date: Date) -> Int {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
}

/// A full-width row button in a picker popover.
struct PickerRow: View {
    var icon: String
    var tint: Color
    var title: String
    var checked = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                Spacer()
                if checked {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).font(.caption.weight(.bold))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Things-style month grid. Today shows a star.
struct CalendarGrid: View {
    var selected: Day?
    var today: Day
    var allowsPast = true
    var onPick: (Day) -> Void

    @State private var month: Day?

    private var calendar: Calendar { .current }

    var body: some View {
        let shown = month ?? firstOfMonth(selected ?? today)
        let days = gridDays(for: shown)
        VStack(spacing: 4) {
            HStack {
                Text(shown.date().formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { month = shown.adding(.month, -1) } label: { Image(systemName: "chevron.left") }
                    .disabled(!allowsPast && shown <= firstOfMonth(today))
                Button { month = firstOfMonth(today) } label: { Image(systemName: "circle.fill").font(.system(size: 5)) }
                    .help("This month")
                Button { month = shown.adding(.month, 1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 4)

            let symbols = weekdaySymbols
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(height: 16)
                }
                ForEach(days, id: \.self) { day in
                    dayCell(day, inMonth: day.month == shown.month)
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Day, inMonth: Bool) -> some View {
        let isSelected = day == selected
        let disabled = !allowsPast && day < today
        Button { onPick(day) } label: {
            ZStack {
                if isSelected {
                    Circle().fill(Color.accentColor)
                }
                if day == today && !isSelected {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.today)
                } else {
                    Text("\(day.day)")
                        .font(.system(size: 11.5, weight: day == today || isSelected ? .bold : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : (inMonth && !disabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)))
                }
            }
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func firstOfMonth(_ day: Day) -> Day {
        Day(year: day.year, month: day.month, day: 1)
    }

    private func gridDays(for first: Day) -> [Day] {
        let offset = (first.weekday(calendar: calendar) - calendar.firstWeekday + 7) % 7
        let start = first.adding(days: -offset)
        let daysInMonth = calendar.range(of: .day, in: .month, for: first.date())?.count ?? 30
        let cells = Int(ceil(Double(offset + daysInMonth) / 7)) * 7
        return (0..<cells).map { start.adding(days: $0) }
    }
}

// MARK: - Deadline

struct DeadlinePicker: View {
    var current: Day?
    var onSelect: (Day?) -> Void
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        VStack(spacing: 6) {
            Label("Deadline", systemImage: "flag.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.deadline)
            PickerSearchField(text: $text, placeholder: "Type a date: fri, dec 24…") { command in
                guard command == .submit else { return false }
                switch When.parse(text, today: model.today) {
                case .date(let day)?: onSelect(day)
                case .today?, .evening?: onSelect(model.today)
                default: break
                }
                return true
            }
            CalendarGrid(selected: current, today: model.today) { onSelect($0) }
            if current != nil {
                Divider()
                Button { onSelect(nil) } label: { Text("Clear").frame(maxWidth: .infinity) }
            }
        }
        .padding(12)
        .frame(width: 252)
    }
}

// MARK: - Reminder

struct ReminderPicker: View {
    var current: Int?
    var onSave: (Int?) -> Void
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()

    var body: some View {
        VStack(spacing: 10) {
            Label("Reminder", systemImage: "bell.fill")
                .font(.system(size: 12, weight: .semibold))
            DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.stepperField)
            Text("Reminds you on the to-do's When date.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if current != nil {
                    Button("Remove", role: .destructive) { onSave(nil) }
                }
                Spacer()
                Button("Set Reminder") { onSave(minutes(of: time)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 240)
        .onAppear {
            if let current {
                time = Calendar.current.date(bySettingHour: current / 60, minute: current % 60, second: 0, of: Date()) ?? time
            }
        }
    }
}

// MARK: - Tags

struct TagPicker: View {
    var selected: Set<UUID>
    var onToggle: (UUID) -> Void
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        let snapshot = model.store.snapshot
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let tags = snapshot.tagList.filter { trimmed.isEmpty || $0.title.localizedCaseInsensitiveContains(trimmed) }
        let exact = snapshot.tags.values.contains { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
        VStack(alignment: .leading, spacing: 6) {
            PickerSearchField(text: $query, placeholder: "Search or create tag") { command in
                guard command == .submit else { return false }
                if let tag = tags.first(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) ?? (trimmed.isEmpty ? nil : tags.first) {
                    onToggle(tag.id)
                } else if !trimmed.isEmpty {
                    onToggle(model.store.addTag(trimmed).id)
                }
                query = ""
                return true
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tags) { tag in
                        let depth = trimmed.isEmpty ? snapshot.tagDepth(tag) : 0
                        Button { onToggle(tag.id) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: selected.contains(tag.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selected.contains(tag.id) ? Color.accentColor : .secondary)
                                Text(tag.title)
                                Spacer()
                                if let shortcut = tag.shortcut {
                                    Text("⌃\(shortcut.uppercased())").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.leading, CGFloat(depth) * 14)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if !trimmed.isEmpty && !exact {
                        Button {
                            onToggle(model.store.addTag(trimmed).id)
                            query = ""
                        } label: {
                            Label("New Tag “\(trimmed)”", systemImage: "plus.circle.fill")
                                .padding(.vertical, 4)
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    if tags.isEmpty && trimmed.isEmpty {
                        Text("No tags yet. Type a name to create one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(4)
                    }
                }
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 240)
    }
}

// MARK: - Move

struct MovePicker: View {
    var movingProjects: Bool
    var onSelect: (Destination) -> Void
    @Environment(AppModel.self) private var model
    @State private var query = ""

    private struct Entry: Identifiable {
        var id: String
        var title: String
        var icon: AnyView
        var depth: Int
        var destination: Destination
    }

    var body: some View {
        let entries = filteredEntries
        VStack(alignment: .leading, spacing: 6) {
            PickerSearchField(text: $query, placeholder: "Move to…") { command in
                guard command == .submit else { return false }
                if let first = entries.first { onSelect(first.destination) }
                return true
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        Button { onSelect(entry.destination) } label: {
                            HStack(spacing: 7) {
                                entry.icon.frame(width: 16)
                                Text(entry.title).lineLimit(1)
                                Spacer()
                            }
                            .padding(.leading, CGFloat(entry.depth) * 16)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 260)
    }

    private var filteredEntries: [Entry] {
        let all = entries
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }.map { var e = $0; e.depth = 0; return e }
    }

    private var entries: [Entry] {
        let snapshot = model.store.snapshot
        var result: [Entry] = []
        func icon(_ name: String, _ tint: Color) -> AnyView {
            AnyView(Image(systemName: name).foregroundStyle(tint))
        }
        func addProject(_ project: Project, depth: Int) {
            let progress = snapshot.progress(of: project.id)
            result.append(Entry(id: project.id.uuidString, title: project.title.nonEmpty ?? "New Project",
                                icon: AnyView(ProgressPie(progress: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total), size: 13)),
                                depth: depth, destination: .project(project.id)))
            for heading in snapshot.headings(in: project.id) where !heading.isArchived {
                result.append(Entry(id: heading.id.uuidString, title: heading.title.nonEmpty ?? "Untitled Heading",
                                    icon: icon("line.3.horizontal", .secondary), depth: depth + 1,
                                    destination: .project(project.id, heading: heading.id)))
            }
        }
        if movingProjects {
            result.append(Entry(id: "none", title: "No Area", icon: icon("xmark.circle", .secondary), depth: 0, destination: .none))
            for area in snapshot.areaList {
                result.append(Entry(id: area.id.uuidString, title: area.title.nonEmpty ?? "New Area", icon: icon("shippingbox.fill", Theme.area), depth: 0, destination: .area(area.id)))
            }
            return result
        }
        result.append(Entry(id: "inbox", title: "Inbox", icon: icon("tray.fill", Theme.inbox), depth: 0, destination: .inbox))
        for project in snapshot.openProjects(in: nil) { addProject(project, depth: 0) }
        for area in snapshot.areaList {
            result.append(Entry(id: area.id.uuidString, title: area.title.nonEmpty ?? "New Area", icon: icon("shippingbox.fill", Theme.area), depth: 0, destination: .area(area.id)))
            for project in snapshot.openProjects(in: area.id) { addProject(project, depth: 1) }
        }
        return result
    }
}

// MARK: - Repeat

struct RepeatPicker: View {
    var current: RepeatRule?
    var onSave: (RepeatRule?) -> Void

    @State private var unit: RepeatRule.Unit = .week
    @State private var interval = 1
    @State private var mode: RepeatRule.Mode = .schedule
    @State private var weekdays: Set<Int> = []
    @State private var hasEnd = false
    @State private var until = Date().addingTimeInterval(60 * 60 * 24 * 90)

    private var rule: RepeatRule {
        RepeatRule(unit: unit, interval: interval, mode: mode, weekdays: unit == .week && mode == .schedule ? Array(weekdays) : [],
                   until: hasEnd ? Day(until) : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Repeat", systemImage: "repeat")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
            Picker("", selection: $mode) {
                Text("On a schedule").tag(RepeatRule.Mode.schedule)
                Text("After completion").tag(RepeatRule.Mode.afterCompletion)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Picker("", selection: $unit) {
                Text("Daily").tag(RepeatRule.Unit.day)
                Text("Weekly").tag(RepeatRule.Unit.week)
                Text("Monthly").tag(RepeatRule.Unit.month)
                Text("Yearly").tag(RepeatRule.Unit.year)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Stepper(value: $interval, in: 1...99) {
                Text(mode == .afterCompletion ? "\(interval) \(unitName) after completion" : "Every \(interval == 1 ? "" : "\(interval) ")\(unitName)")
            }
            if unit == .week && mode == .schedule {
                HStack(spacing: 4) {
                    let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
                    ForEach(1...7, id: \.self) { weekday in
                        let on = weekdays.contains(weekday)
                        Button {
                            if on { weekdays.remove(weekday) } else { weekdays.insert(weekday) }
                        } label: {
                            Text(symbols[weekday - 1])
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(on ? Color.accentColor : Color.primary.opacity(0.08)))
                                .foregroundStyle(on ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Toggle("Ends", isOn: $hasEnd)
            if hasEnd {
                DatePicker("Until", selection: $until, displayedComponents: .date)
            }
            Text(rule.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if current != nil {
                    Button("Stop Repeating", role: .destructive) { onSave(nil) }
                }
                Spacer()
                Button("OK") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            guard let current else { return }
            unit = current.unit
            interval = current.interval
            mode = current.mode
            weekdays = Set(current.weekdays)
            if let end = current.until {
                hasEnd = true
                until = end.date()
            }
        }
    }

    private var unitName: String {
        let name = switch unit {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .year: "year"
        }
        return interval == 1 ? name : name + "s"
    }
}
