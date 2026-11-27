import AppKit
import SohoMonitorCore
import SwiftUI

/// Borderless panel at desktop level: above the wallpaper and the desktop icons, below every normal window, on all
/// Spaces. Moved by dragging the card (position saved), double-click puts it back in its default place.
@MainActor
final class DesktopPanelController {
    private let panel: NSPanel
    private var dragOffset: CGPoint?

    static let originKey = "panel.origin"
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
            rootView: PanelView(
                model: model, system: system,
                onDrag: { [weak self] phase in self?.drag(phase) },
                onResetPosition: { [weak self] in self?.resetPosition() }))
        host.sizingOptions = [.preferredContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        panel.contentViewController = host
        placeAtSavedOrDefaultPosition()
        keepOnScreen()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen() }
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
            panel.setFrameOrigin(clamped(CGPoint(x: mouse.x - offset.x, y: mouse.y - offset.y)))
        case .ended:
            dragOffset = nil
            UserDefaults.standard.set(
                [Double(panel.frame.minX), Double(panel.frame.minY)], forKey: Self.originKey)
        }
    }

    private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.originKey)
        panel.setFrameOrigin(defaultOrigin())
    }

    private func placeAtSavedOrDefaultPosition() {
        if let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], saved.count == 2 {
            let origin = CGPoint(x: saved[0], y: saved[1])
            // A saved position on a screen that is gone (external display unplugged) falls back to the default.
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(origin) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        panel.setFrameOrigin(defaultOrigin())
    }

    /// Bottom-left corner of the main screen.
    private func defaultOrigin() -> CGPoint {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return CGPoint(x: frame.minX + Self.margin, y: frame.minY + Self.margin)
    }

    /// Keeps the panel fully on the screen under the mouse.
    private func clamped(_ origin: CGPoint) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            return origin
        }
        return PanelPlacement.origin(of: CGRect(origin: origin, size: panel.frame.size), within: screen.visibleFrame)
    }

    /// After a resize (cards added, a group's top folders opened): back inside its screen's visible frame. The saved
    /// position is not overwritten: the next launch starts from it (and is clamped again if needed).
    private func keepOnScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let origin = PanelPlacement.origin(of: panel.frame, within: screen.visibleFrame)
        if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
    }
}
