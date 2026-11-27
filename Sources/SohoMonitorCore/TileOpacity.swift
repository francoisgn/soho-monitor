import Foundation

/// How opaque the desktop panel's tiles are, chosen from the menu bar menu and saved in UserDefaults as a percent.
/// A few steps rather than a slider: the menu bar extra is a menu, where a picker becomes a submenu.
/// The steps go from the most transparent (the Liquid Glass look the tiles always had) to opaque. Nothing more
/// transparent than plain glass: its blur is what keeps the text legible over a busy wallpaper (an unblurred 50 %
/// fill was not, and `Glass.clear` looked the same as `.regular` behind the cards).
public enum TileOpacity: Int, CaseIterable, Sendable {
    case glass = 0
    case light = 25
    case frosted = 50
    case solid = 75
    case opaque = 100

    /// The look the tiles had before the setting existed, so nothing changes for whoever never picks a step.
    public static let standard: TileOpacity = .glass
    /// UserDefaults key of the saved percent.
    public static let defaultsKey = "panel.tileOpacity"

    /// Reads a saved value tolerantly: a number is clamped to 0...100 then snapped to the nearest step (halfway goes
    /// to the more opaque one, legibility first); nothing saved, or anything else (string, NaN), gives the default.
    public init(stored: Any?) {
        guard let percent = (stored as? NSNumber)?.doubleValue, !percent.isNaN else {
            // NaN checked here, not left to `min` / `max`, which would turn it into whichever bound they pick.
            self = .standard
            return
        }
        // Clamped first: at ±1e300 every step is "equally far" in floating point.
        let clamped = min(100, max(0, percent))
        var nearest = Self.standard
        var gap = Double.infinity
        // Ascending order and `<=`: on a tie the later, more opaque step wins.
        for step in Self.allCases where abs(Double(step.rawValue) - clamped) <= gap {
            nearest = step
            gap = abs(Double(step.rawValue) - clamped)
        }
        self = nearest
    }

    /// The menu label.
    public var name: String {
        switch self {
        case .glass: "Glass"
        case .light: "Light Frost"
        case .frosted: "Frosted"
        case .solid: "Solid"
        case .opaque: "Opaque"
        }
    }

    /// What the tiles draw for this step. Reduce Transparency (System Settings › Accessibility) wins over the choice:
    /// every step is then opaque.
    public func style(reduceTransparency: Bool) -> TileStyle {
        if reduceTransparency { return TileStyle(glass: false, backing: 1) }
        switch self {
        case .glass: return TileStyle(glass: true, backing: 0)
        case .light: return TileStyle(glass: true, backing: 0.3)
        case .frosted: return TileStyle(glass: true, backing: 0.55)
        case .solid: return TileStyle(glass: true, backing: 0.8)
        case .opaque: return TileStyle(glass: false, backing: 1)
        }
    }
}

/// The resolved look of a tile: Liquid Glass behind it or not, and how opaque the window-coloured fill laid over the
/// glass, under the content, is.
public struct TileStyle: Equatable, Sendable {
    /// Regular Liquid Glass behind the tile; false means a flat, opaque tile with a hairline border.
    public var glass: Bool
    /// Opacity (0...1) of the window-background fill over the glass.
    public var backing: Double

    public init(glass: Bool, backing: Double) {
        self.glass = glass
        self.backing = backing
    }
}
