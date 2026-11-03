import AppKit
import SwiftUI

/// Keys the editor fields report instead of handling themselves.
enum FieldCommand {
    case submit
    case deleteWhenEmpty
    case up
    case down
    case escape
    case tab
    case backtab
}

/// Makes `view` first responder once it's in a window (picker panels attach
/// their window a moment after SwiftUI creates the view).
func focusWhenInWindow(_ view: NSView, attempts: Int = 8, then: @escaping () -> Void = {}) {
    DispatchQueue.main.async {
        guard let window = view.window else {
            if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { focusWhenInWindow(view, attempts: attempts - 1, then: then) }
            }
            return
        }
        if window.makeFirstResponder(view) { then() }
    }
}

/// A rounded search-style field for picker popovers that grabs focus on appear.
struct PickerSearchField: View {
    @Binding var text: String
    var placeholder: String
    var onCommand: (FieldCommand) -> Bool = { _ in false }
    @State private var token = 1

    var body: some View {
        PlainTextField(text: $text, placeholder: placeholder, font: .systemFont(ofSize: 13), focusToken: token, onCommand: onCommand)
            .frame(height: 18)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.hairline))
    }
}

/// A borderless single-line field that reports Return, Backspace-when-empty,
/// arrows and Esc — things SwiftUI's TextField doesn't expose reliably on macOS.
struct PlainTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont = .systemFont(ofSize: 13)
    var textColor: NSColor = .labelColor
    /// Focuses the field whenever this changes to a new non-nil value.
    var focusToken: Int?
    var onCommand: (FieldCommand) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isBezeled = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.font = font
        field.textColor = textColor
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font, .foregroundColor: NSColor.placeholderTextColor,
        ])
        if let focusToken, focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            focusWhenInWindow(field) {
                field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PlainTextField
        var lastFocusToken: Int?

        init(_ parent: PlainTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): return parent.onCommand(.submit)
            case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty: return parent.onCommand(.deleteWhenEmpty)
            case #selector(NSResponder.moveUp(_:)): return parent.onCommand(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onCommand(.down)
            case #selector(NSResponder.cancelOperation(_:)): return parent.onCommand(.escape)
            case #selector(NSResponder.insertTab(_:)): return parent.onCommand(.tab)
            case #selector(NSResponder.insertBacktab(_:)): return parent.onCommand(.backtab)
            default: return false
            }
        }
    }
}

/// A plain-text editor that grows with its content, for notes.
struct NotesTextView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 12.5)
    var textColor: NSColor = .secondaryLabelColor
    var focusToken: Int?
    var onCommand: (FieldCommand) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> GrowingTextView {
        let view = GrowingTextView(usingTextLayoutManager: false)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.string = text
        return view
    }

    func updateNSView(_ view: GrowingTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text {
            view.string = text
            view.invalidateIntrinsicContentSize()
        }
        if view.font != font {
            view.font = font
            view.invalidateIntrinsicContentSize()
        }
        view.textColor = textColor
        view.typingAttributes = [.font: font, .foregroundColor: textColor]
        if let focusToken, focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            focusWhenInWindow(view) {
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesTextView
        var lastFocusToken: Int?

        init(_ parent: NotesTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)): return parent.onCommand(.escape)
            case #selector(NSResponder.insertBacktab(_:)): return parent.onCommand(.backtab)
            case #selector(NSResponder.insertTab(_:)): return parent.onCommand(.tab)
            case #selector(NSResponder.moveUp(_:)) where textView.selectedRange().location == 0: return parent.onCommand(.up)
            case #selector(NSResponder.moveDown(_:)) where textView.selectedRange().location >= (textView.string as NSString).length:
                return parent.onCommand(.down)
            default: return false
            }
        }
    }
}

/// An NSTextView whose height follows its text, so SwiftUI can size it.
final class GrowingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let layout = layoutManager else { return super.intrinsicContentSize }
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: font ?? .systemFont(ofSize: 13))
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(max(lineHeight, layout.usedRect(for: container).height)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}
