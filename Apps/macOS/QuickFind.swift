import AppKit
import DabbleKit
import SwiftUI

/// ⌘F (or just typing in a list): a floating search over lists, areas,
/// projects, tags and to-dos.
struct QuickFindView: View {
    @Environment(WindowState.self) private var state
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var highlighted = 0
    @State private var focusToken = 0

    private struct Result: Identifiable {
        enum Target {
            case list(ListID)
            case item(UUID)
        }
        var id: String
        var title: String
        var subtitle: String?
        var icon: AnyView
        var target: Target
    }

    var body: some View {
        let results = self.results
        ZStack(alignment: .top) {
            Color.black.opacity(0.06)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                    PlainTextField(text: $query, placeholder: "Quick Find", font: .systemFont(ofSize: 19), focusToken: focusToken) { command in
                        switch command {
                        case .up:
                            highlighted = max(0, highlighted - 1)
                        case .down:
                            highlighted = min(max(0, results.count - 1), highlighted + 1)
                        case .submit:
                            if results.indices.contains(highlighted) { activate(results[highlighted]) }
                        case .escape:
                            close()
                        case .deleteWhenEmpty, .tab, .backtab:
                            return false
                        }
                        return true
                    }
                    .frame(height: 26)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                if !results.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                    row(result, highlighted: index == highlighted)
                                        .id(index)
                                        .onTapGesture { activate(result) }
                                        .onHover { if $0 { highlighted = index } }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 380)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
                    }
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Divider()
                    Text("No results")
                        .foregroundStyle(.secondary)
                        .padding(18)
                }
            }
            .frame(width: 540)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(.top, 70)
        }
        .onAppear {
            query = state.quickFindQuery ?? ""
            focusToken += 1
        }
        .onChange(of: query) { highlighted = 0 }
    }

    private func row(_ result: Result, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            result.icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title).lineLimit(1)
                    .foregroundStyle(highlighted ? .white : .primary)
                if let subtitle = result.subtitle {
                    Text(subtitle).font(.caption).lineLimit(1)
                        .foregroundStyle(highlighted ? .white.opacity(0.8) : .secondary)
                }
            }
            Spacer()
            if highlighted {
                Image(systemName: "return").font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(highlighted ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

    private var results: [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let store = model.store
        let lists = model.lists
        var results: [Result] = ListID.builtIn
            .filter { $0.title(in: store).localizedCaseInsensitiveContains(trimmed) }
            .map { list in
                Result(id: "list-\(list.title(in: store))", title: list.title(in: store), subtitle: nil,
                       icon: AnyView(Image(systemName: list.systemImage).foregroundStyle(list.tint)), target: .list(list))
            }
        for item in lists.search(trimmed).prefix(80) {
            switch item {
            case .area(let area):
                results.append(Result(id: area.id.uuidString, title: area.title.nonEmpty ?? "New Area", subtitle: "Area",
                                      icon: AnyView(Image(systemName: "shippingbox.fill").foregroundStyle(Theme.area)), target: .list(.area(area.id))))
            case .project(let project):
                let progress = lists.snapshot.progress(of: project.id)
                results.append(Result(id: project.id.uuidString, title: project.title.nonEmpty ?? "New Project",
                                      subtitle: lists.subtitle(for: item) ?? (project.isOpen ? "Project" : "Completed project"),
                                      icon: AnyView(ProgressPie(progress: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total), size: 14,
                                                                completed: project.status == .completed)),
                                      target: .list(.project(project.id))))
            case .tag(let tag):
                results.append(Result(id: tag.id.uuidString, title: tag.title, subtitle: "Tag",
                                      icon: AnyView(Image(systemName: "tag.fill").foregroundStyle(.secondary)), target: .list(.tag(tag.id))))
            case .todo(let todo):
                let home = lists.home(of: todo)
                var subtitle = lists.subtitle(for: item) ?? home.title(in: store)
                if !todo.isOpen { subtitle += " · Logged" }
                results.append(Result(id: todo.id.uuidString, title: todo.title.nonEmpty ?? "New To-Do", subtitle: subtitle,
                                      icon: AnyView(Image(systemName: todo.isOpen ? "square" : "checkmark.square.fill")
                                        .foregroundStyle(todo.isOpen ? Color.secondary : Color.accentColor)),
                                      target: .item(todo.id)))
            case .heading:
                break
            }
        }
        return results
    }

    private func activate(_ result: Result) {
        state.quickFindQuery = nil
        switch result.target {
        case .list(let list): state.navigate(to: list)
        case .item(let id): state.reveal(id)
        }
        if case .list = result.target { state.listFocusRequest += 1 }
    }

    private func close() {
        state.quickFindQuery = nil
        state.listFocusRequest += 1
    }
}
