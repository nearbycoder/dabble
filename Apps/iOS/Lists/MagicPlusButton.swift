import SwiftUI

/// Things' floating "+" button. Tap for a new to-do; long-press for more.
struct MagicPlusButton<MenuItems: View>: View {
    var action: () -> Void
    var menu: MenuItems?

    init(action: @escaping () -> Void, @ViewBuilder menu: () -> MenuItems) {
        self.action = action
        self.menu = menu()
    }

    var body: some View {
        if let menu {
            Menu {
                menu
            } label: {
                PlusCircle()
            } primaryAction: {
                action()
            }
            .menuStyle(.button)
            .buttonStyle(PlusButtonStyle())
            .accessibilityLabel("New To-Do")
            .accessibilityHint("Touch and hold for more options")
        } else {
            Button(action: action) {
                PlusCircle()
            }
            .buttonStyle(PlusButtonStyle())
            .accessibilityLabel("New To-Do")
        }
    }
}

extension MagicPlusButton where MenuItems == EmptyView {
    init(action: @escaping () -> Void) {
        self.action = action
        self.menu = nil
    }
}

private struct PlusCircle: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 58, height: 58)
            .background(Circle().fill(Color.accentColor.gradient))
            .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
            .contentShape(Circle())
    }
}

private struct PlusButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}
