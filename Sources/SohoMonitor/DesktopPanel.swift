import AppKit
import SohoMonitorCore
import SwiftUI

/// Borderless panel at desktop level: above the wallpaper and the desktop icons, below every normal window, on all
/// Spaces. Anchored by its top-left corner (top-left of the main screen by default), so it grows downward as cards
/// are added or expand; moved by dragging a card (corner saved), double-click puts it back in its default place.
@MainActor
final class DesktopPanelController {
    private let panel: NSPanel
    private var dragOffset: CGPoint?
    /// Top-left corner the panel hangs from, in screen coordinates.
    private var anchor: CGPoint = .zero

    static let topLeftKey = "panel.topLeft"
    /// Bottom-left origin saved by earlier versions: meaningless once the panel's height changes, so dropped.
    static let legacyOriginKey = "panel.origin"
    static let margin: CGFloat = 24

    /// Called with true while some part of the panel is on screen (shown and not fully covered), false otherwise.
    var onScreenChanged: ((Bool) -> Void)?

    init(model: AppModel, system: SystemModel) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: DiskCard.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // kCGDesktopIconWindowLevel + 1: over the desktop icons, under normal windows (as Übersicht widgets are).
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false  // moved by the drag gesture below, which also saves the position

        let host = NSHostingController(
            rootView: PanelStack(
                model: model, system: system,
                onDrag: { [weak self] phase in self?.drag(phase) },
                onResetPosition: { [weak self] in self?.resetPosition() }))
        host.sizingOptions = [.preferredContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        panel.contentViewController = host
        UserDefaults.standard.removeObject(forKey: Self.legacyOriginKey)
        anchor = savedAnchor() ?? defaultAnchor()
        hangFromAnchor()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hangFromAnchor() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportOnScreen() }
        }
    }

    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        reportOnScreen()
    }

    /// Fades the whole window: AppKit composites the panel (Liquid Glass included) as at full opacity, then the
    /// window server applies the alpha, so the glass keeps its look. A SwiftUI `.opacity` on the root view would
    /// instead fade each layer on its own, glass backdrops included.
    func setAlpha(_ alpha: Double) {
        let value = CGFloat(alpha)
        if panel.alphaValue != value { panel.alphaValue = value }
    }

    /// Live sampling runs only while this is true: a hidden panel, or one AppKit reports as fully occluded (covered
    /// by other windows), costs nothing.
    var isOnScreen: Bool { panel.isVisible && panel.occlusionState.contains(.visible) }

    private func reportOnScreen() {
        onScreenChanged?(isOnScreen)
    }

    // MARK: Position

    enum DragPhase { case changed, ended }

    /// Follows the mouse in screen coordinates: independent of the window that moves under the gesture.
    private func drag(_ phase: DragPhase) {
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .changed:
            let offset = dragOffset ?? CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
            dragOffset = offset
            let frame = CGRect(origin: CGPoint(x: mouse.x - offset.x, y: mouse.y - offset.y), size: panel.frame.size)
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
            let origin = screen.map { PanelPlacement.origin(of: frame, within: $0.visibleFrame) } ?? frame.origin
            panel.setFrameOrigin(origin)
            anchor = PanelPlacement.topLeft(of: panel.frame)
        case .ended:
            dragOffset = nil
            anchor = PanelPlacement.topLeft(of: panel.frame)
            UserDefaults.standard.set([Double(anchor.x), Double(anchor.y)], forKey: Self.topLeftKey)
        }
    }

    private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.topLeftKey)
        anchor = defaultAnchor()
        hangFromAnchor()
    }

    /// The saved corner, unless no screen shows it any more (external display unplugged).
    private func savedAnchor() -> CGPoint? {
        guard let saved = UserDefaults.standard.array(forKey: Self.topLeftKey) as? [Double], saved.count == 2 else {
            return nil
        }
        let corner = CGPoint(x: saved[0], y: saved[1])
        // The corner itself sits on the visible frame's edge: test a point just inside the panel.
        let inside = CGPoint(x: corner.x + 1, y: corner.y - 1)
        return NSScreen.screens.contains(where: { $0.visibleFrame.contains(inside) }) ? corner : nil
    }

    /// Top-left of the main screen, under the menu bar.
    private func defaultAnchor() -> CGPoint {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return PanelPlacement.defaultTopLeft(in: visible, margin: Self.margin)
    }

    /// Places the panel so its top-left corner is the anchor, whatever its current height (it grows downward), kept
    /// inside the visible frame of the anchor's screen. Called at launch, on reset and after every resize.
    private func hangFromAnchor() {
        let inside = CGPoint(x: anchor.x + 1, y: anchor.y - 1)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(inside) }) ?? NSScreen.main
        else { return }
        let origin = PanelPlacement.origin(topLeft: anchor, size: panel.frame.size, within: screen.visibleFrame)
        if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
    }
}
