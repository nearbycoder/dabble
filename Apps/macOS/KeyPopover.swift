import AppKit
import SwiftUI

extension View {
    /// A popover-style picker panel that becomes the key window when shown, so
    /// pickers opened from the keyboard (⌘S, ⇧⌘T…) can be typed into at once.
    /// (`NSPopover` windows won't take key status programmatically.)
    func keyPopover<Content: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .bottom,
                                   @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(KeyPopoverModifier(isPresented: isPresented, popoverContent: content))
    }
}

private struct KeyPopoverModifier<PopoverContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    var popoverContent: () -> PopoverContent
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state: WindowState?

    func body(content: Content) -> some View {
        content.background(
            PanelAnchor(isPresented: $isPresented) {
                AnyView(
                    popoverContent()
                        .environment(model)
                        .environment(state)
                )
            }
        )
    }
}

private struct PanelAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    var content: () -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onClose = { [binding = $isPresented] in
            if binding.wrappedValue { binding.wrappedValue = false }
        }
        if isPresented {
            if let panel = coordinator.panel {
                panel.update(content())
            } else {
                coordinator.show(content(), from: view)
            }
        } else {
            coordinator.close()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    final class Coordinator {
        var panel: PickerPanel?
        var onClose: () -> Void = {}

        func show(_ content: AnyView, from view: NSView) {
            let panel = PickerPanel(content: content)
            self.panel = panel
            panel.onClose = { [weak self, weak panel] in
                guard let self, self.panel === panel else { return }
                self.panel = nil
                self.onClose()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel === panel else { return }
                guard view.window != nil else {
                    self.panel = nil
                    self.onClose()
                    return
                }
                panel.present(from: view)
            }
        }

        func close() {
            guard let panel else { return }
            self.panel = nil
            panel.dismiss(notify: false)
        }
    }
}

/// A borderless, blurred, rounded panel positioned under an anchor view.
final class PickerPanel: NSPanel {
    private let host: NSHostingView<AnyView>
    var onClose: () -> Void = {}
    private var anchorTop: CGFloat?
    private var isDismissing = false

    init(content: AnyView) {
        host = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .utilityWindow
        contentView = host
        update(content)
    }

    func update(_ content: AnyView) {
        host.rootView = AnyView(
            content
                .background(VisualEffectBackground(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in self?.fit(size) }
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keeps the top edge pinned under the anchor as the content grows or shrinks.
    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let top = anchorTop ?? frame.maxY
        let newFrame = NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height)
        if newFrame != frame { setFrame(newFrame, display: true) }
    }

    func present(from view: NSView) {
        guard let parentWindow = view.window else { return }
        let anchor = parentWindow.convertToScreen(view.convert(view.bounds, to: nil))
        let size = host.fittingSize
        let screen = parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.minX - 8
        // Stay inside the parent window when it's wide enough, then on screen.
        if x + size.width > parentWindow.frame.maxX - 6 { x = max(parentWindow.frame.minX + 6, anchor.maxX + 8 - size.width) }
        x = min(max(screen.minX + 6, x), screen.maxX - size.width - 6)
        var top = anchor.minY - 4
        if top - size.height < screen.minY + 6 {
            top = min(screen.maxY - 6, anchor.maxY + 4 + size.height)
        }
        anchorTop = top
        setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: false)
        level = parentWindow.level
        parentWindow.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    override func resignKey() {
        super.resignKey()
        // Clicking anywhere else closes the picker, like a transient popover.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, NSApp.keyWindow !== self else { return }
            if let key = NSApp.keyWindow, key.parent === self { return }
            self.dismiss()
        }
    }

    func dismiss(notify: Bool = true) {
        guard !isDismissing else { return }
        isDismissing = true
        let parentWindow = parent
        let wasKey = NSApp.keyWindow === self
        parentWindow?.removeChildWindow(self)
        orderOut(nil)
        if wasKey { parentWindow?.makeKey() }
        if notify { onClose() }
    }
}

/// Behind-window blur with rounded corners for picker panels.
struct VisualEffectBackground: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private static func mask(_ radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

