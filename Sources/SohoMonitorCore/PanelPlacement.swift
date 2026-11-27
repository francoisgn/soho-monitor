import CoreGraphics

/// Where the desktop panel may sit on a screen.
public enum PanelPlacement {
    /// Origin that keeps `frame` inside `visible` (the screen's visible frame, in AppKit's bottom-up coordinates).
    /// The panel grows when cards are added or expanded, so a position saved when it was short can push it under the
    /// Dock. Too wide: aligned left; too tall: its top stays visible (the header is what one grabs to move it).
    public static func origin(of frame: CGRect, within visible: CGRect) -> CGPoint {
        CGPoint(
            x: max(visible.minX, min(frame.minX, visible.maxX - frame.width)),
            y: min(max(frame.minY, visible.minY), visible.maxY - frame.height))
    }
}
