import CoreGraphics

/// Where the desktop panel sits on a screen. AppKit's coordinates go bottom-up; the panel is anchored by its
/// top-left corner, so it grows downward when cards are added or expand, and its header stays where it was put.
public enum PanelPlacement {
    /// Default anchor: the top-left corner of the visible frame (under the menu bar), `margin` inside.
    public static func defaultTopLeft(in visible: CGRect, margin: CGFloat) -> CGPoint {
        CGPoint(x: visible.minX + margin, y: visible.maxY - margin)
    }

    /// The top-left corner of a frame (the anchor saved when the panel is moved).
    public static func topLeft(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX, y: frame.maxY)
    }

    /// Frame origin for content of `size` hanging from `topLeft`, then kept inside `visible` (see
    /// `origin(of:within:)`).
    public static func origin(topLeft: CGPoint, size: CGSize, within visible: CGRect) -> CGPoint {
        origin(
            of: CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height),
            within: visible)
    }

    /// Origin that keeps `frame` inside `visible` (the screen's visible frame). Too wide: aligned left; too tall: its
    /// top stays visible (the header is what one grabs to move it).
    public static func origin(of frame: CGRect, within visible: CGRect) -> CGPoint {
        CGPoint(
            x: max(visible.minX, min(frame.minX, visible.maxX - frame.width)),
            y: min(max(frame.minY, visible.minY), visible.maxY - frame.height))
    }
}
