import DabbleKit
import SwiftUI

/// The pickers that can be opened on one or more items.
enum ItemSheet: Identifiable, Hashable {
    case when([UUID])
    case deadline([UUID])
    case tags([UUID])
    case move([UUID])
    case repeatRule(UUID)
    case reminder(UUID)

    var id: Self { self }
}

extension View {
    /// Presents the picker for `sheet` from this view.
    func itemSheet(_ sheet: Binding<ItemSheet?>, onDismiss: (() -> Void)? = nil) -> some View {
        modifier(ItemSheetModifier(sheet: sheet, onDismiss: onDismiss))
    }
}

private struct ItemSheetModifier: ViewModifier {
    @Binding var sheet: ItemSheet?
    var onDismiss: (() -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    func body(content: Content) -> some View {
        content.sheet(item: $sheet, onDismiss: onDismiss) { sheet in
            Group {
                switch sheet {
                case .when(let ids): WhenPicker(ids: ids)
                case .deadline(let ids): DeadlinePicker(ids: ids)
                case .tags(let ids): TagPicker(ids: ids)
                case .move(let ids): MovePicker(ids: ids)
                case .repeatRule(let id): RepeatPicker(id: id)
                case .reminder(let id): ReminderPicker(id: id)
                }
            }
            .environment(model)
            .environment(router)
        }
    }
}

/// A row in a picker: icon, title, optional checkmark.
struct PickerRow: View {
    var title: String
    var systemImage: String
    var tint: Color
    var isSelected = false
    var indent: CGFloat = 0
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.leading, indent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
