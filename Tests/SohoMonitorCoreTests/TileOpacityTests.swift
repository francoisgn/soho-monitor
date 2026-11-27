import Foundation
import Testing

@testable import SohoMonitorCore

@Suite struct TileOpacityTests {
    @Test func nothingSavedKeepsTheCurrentLook() {
        #expect(TileOpacity(stored: nil) == .glass)
        #expect(TileOpacity.standard == .glass)
        // The look the cards had before the setting: regular glass, no fill.
        #expect(TileOpacity.glass.style(reduceTransparency: false) == TileStyle(glass: true, backing: 0))
    }

    @Test func aSavedStepIsReadBack() {
        for step in TileOpacity.allCases {
            #expect(TileOpacity(stored: step.rawValue) == step)
            // UserDefaults hands numbers back as NSNumber.
            #expect(TileOpacity(stored: NSNumber(value: step.rawValue)) == step)
        }
    }

    @Test func anOutOfRangeValueIsClamped() {
        #expect(TileOpacity(stored: -40) == .glass)
        #expect(TileOpacity(stored: 250) == .opaque)
        #expect(TileOpacity(stored: Int.min) == .glass)
        #expect(TileOpacity(stored: Int.max) == .opaque)
        #expect(TileOpacity(stored: 1e300) == .opaque)
        // Unclamped, every step is 1e300 away in floating point and the tie rule would pick `opaque`.
        #expect(TileOpacity(stored: -1e300) == .glass)
        #expect(TileOpacity(stored: -Double.infinity) == .glass)
        #expect(TileOpacity(stored: Double.infinity) == .opaque)
    }

    @Test func anInBetweenValueSnapsToTheNearestStep() {
        #expect(TileOpacity(stored: 10) == .glass)
        #expect(TileOpacity(stored: 30) == .light)
        #expect(TileOpacity(stored: 61.9) == .frosted)
        #expect(TileOpacity(stored: 90) == .opaque)
        // Halfway: the more opaque step, legibility first.
        #expect(TileOpacity(stored: 12.5) == .light)
        #expect(TileOpacity(stored: 87.5) == .opaque)
    }

    @Test func aValueOfTheWrongTypeFallsBackToTheDefault() {
        #expect(TileOpacity(stored: "opaque") == .standard)
        #expect(TileOpacity(stored: "50") == .standard)
        #expect(TileOpacity(stored: [50]) == .standard)
        #expect(TileOpacity(stored: Double.nan) == .standard)
        // A Boolean is an NSNumber too, but no percent: the default.
        #expect(TileOpacity(stored: true) == .glass)
        #expect(TileOpacity(stored: false) == .glass)
    }

    @Test func stepsGoFromGlassToOpaque() {
        let styles = TileOpacity.allCases.map { $0.style(reduceTransparency: false) }
        #expect(TileOpacity.allCases.first == .standard)
        #expect(styles.first == TileStyle(glass: true, backing: 0))
        #expect(styles.last == TileStyle(glass: false, backing: 1))
        #expect(zip(styles, styles.dropFirst()).allSatisfy { $0.backing < $1.backing })
    }

    @Test func onlyAnOpaqueTileGoesWithoutTheGlassBlur() {
        // Legibility floor: without the blur, a busy wallpaper shows sharp through any partial fill.
        for step in TileOpacity.allCases {
            let style = step.style(reduceTransparency: false)
            #expect(style.glass || style.backing == 1, "\(step)")
            #expect((0...1).contains(style.backing), "\(step)")
        }
    }

    @Test func reduceTransparencyMakesEveryStepOpaque() {
        for step in TileOpacity.allCases {
            #expect(step.style(reduceTransparency: true) == TileStyle(glass: false, backing: 1))
        }
    }

    @Test func everyStepHasItsOwnName() {
        let names = TileOpacity.allCases.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(!names.contains(""))
    }
}
