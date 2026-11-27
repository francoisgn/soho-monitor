import Foundation

/// How opaque the whole desktop panel is (glass, text and figures alike), chosen from the menu bar menu and saved in
/// UserDefaults as a percent. Independent from `TileOpacity`, which only changes the tiles' backgrounds: the two
/// combine. Steps rather than a slider, for the same reason as `TileOpacity` (the menu-style menu bar extra turns a
/// picker into a checked submenu). Never below 30 %: fainter, the figures are no longer readable at a glance.
public enum PanelOpacity: Int, CaseIterable, Sendable {
    case full = 100
    case p85 = 85
    case p70 = 70
    case p55 = 55
    case p40 = 40
    case p30 = 30

    /// The panel as it was before the setting existed, so nothing changes for whoever never picks a step.
    public static let standard: PanelOpacity = .full
    /// UserDefaults key of the saved percent.
    public static let defaultsKey = "panel.opacity"

    /// Reads a saved value tolerantly: a number is clamped to 30...100 then snapped to the nearest step (halfway goes
    /// to the more opaque one, legibility first); nothing saved, or anything else (string, Boolean, NaN), gives 100 %.
    public init(stored: Any?) {
        self =
            PercentStep.nearest(to: stored, in: Self.allCases.map(\.rawValue)).flatMap(Self.init(rawValue:))
            ?? .standard
    }

    /// The menu label.
    public var name: String { "\(rawValue)%" }

    /// The window alpha to apply. Increase Contrast or Reduce Transparency (System Settings › Accessibility ›
    /// Display) wins over the choice: whoever needs either wants the panel legible, so it is shown in full.
    public func alpha(increaseContrast: Bool, reduceTransparency: Bool) -> Double {
        if increaseContrast || reduceTransparency { return 1 }
        return Double(rawValue) / 100
    }

    /// True when an accessibility setting shows the panel more opaque than this step, so the menu can say why the
    /// choice has no effect.
    public func isOverridden(increaseContrast: Bool, reduceTransparency: Bool) -> Bool {
        alpha(increaseContrast: increaseContrast, reduceTransparency: reduceTransparency) > Double(rawValue) / 100
    }
}

/// Snapping of a saved percent onto a set of steps, shared by the opacity settings.
enum PercentStep {
    /// The step nearest to `stored` once clamped to the steps' range; on a tie the larger (more opaque) step. Nil
    /// when `stored` is not a number, is a Boolean or is NaN.
    static func nearest(to stored: Any?, in steps: [Int]) -> Int? {
        // A Boolean bridges to NSNumber too (0 or 1), but is no percent: read as 1 % it would pick the faintest step.
        // NaN checked here, not left to `min` / `max`, which would turn it into whichever bound they pick.
        guard let number = stored as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            case let percent = number.doubleValue, !percent.isNaN,
            let lowest = steps.min(), let highest = steps.max()
        else { return nil }
        // Clamped first: at ±1e300 every step is "equally far" in floating point.
        let clamped = min(Double(highest), max(Double(lowest), percent))
        return steps.min { lhs, rhs in
            let left = abs(Double(lhs) - clamped)
            let right = abs(Double(rhs) - clamped)
            return left == right ? lhs > rhs : left < right
        }
    }
}
