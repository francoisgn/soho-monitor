import Foundation
import Testing

@testable import SohoMonitorCore

@Suite struct PanelOpacityTests {
    @Test func nothingSavedKeepsThePanelFullyOpaque() {
        #expect(PanelOpacity(stored: nil) == .full)
        #expect(PanelOpacity.standard == .full)
        #expect(PanelOpacity.full.alpha(increaseContrast: false, reduceTransparency: false) == 1)
    }

    @Test func aSavedStepIsReadBack() {
        for step in PanelOpacity.allCases {
            #expect(PanelOpacity(stored: step.rawValue) == step)
            // UserDefaults hands numbers back as NSNumber.
            #expect(PanelOpacity(stored: NSNumber(value: step.rawValue)) == step)
        }
    }

    @Test func theStepsAreTheOnesOffered() {
        #expect(PanelOpacity.allCases.map(\.rawValue) == [100, 85, 70, 55, 40, 30])
    }

    @Test func anOutOfRangeValueIsClampedToThirtyOrAHundred() {
        #expect(PanelOpacity(stored: 0) == .p30)
        #expect(PanelOpacity(stored: -40) == .p30)
        #expect(PanelOpacity(stored: 250) == .full)
        #expect(PanelOpacity(stored: Int.min) == .p30)
        #expect(PanelOpacity(stored: Int.max) == .full)
        #expect(PanelOpacity(stored: 1e300) == .full)
        // Unclamped, every step is 1e300 away in floating point and the tie rule would pick 100 %.
        #expect(PanelOpacity(stored: -1e300) == .p30)
        #expect(PanelOpacity(stored: -Double.infinity) == .p30)
        #expect(PanelOpacity(stored: Double.infinity) == .full)
    }

    @Test func anInBetweenValueSnapsToTheNearestStep() {
        #expect(PanelOpacity(stored: 95) == .full)
        #expect(PanelOpacity(stored: 80) == .p85)
        #expect(PanelOpacity(stored: 60) == .p55)
        #expect(PanelOpacity(stored: 33.9) == .p30)
        // Halfway: the more opaque step, legibility first.
        #expect(PanelOpacity(stored: 92.5) == .full)
        #expect(PanelOpacity(stored: 35) == .p40)
        #expect(PanelOpacity(stored: 62.5) == .p70)
    }

    @Test func aValueOfTheWrongTypeFallsBackToTheDefault() {
        #expect(PanelOpacity(stored: "55") == .standard)
        #expect(PanelOpacity(stored: "full") == .standard)
        #expect(PanelOpacity(stored: [55]) == .standard)
        #expect(PanelOpacity(stored: Double.nan) == .standard)
        // A Boolean is an NSNumber too, but not a percent: read as 1 % it would give the faintest step.
        #expect(PanelOpacity(stored: true) == .standard)
        #expect(PanelOpacity(stored: false) == .standard)
        #expect(PanelOpacity(stored: NSNumber(value: true)) == .standard)
    }

    @Test func theAlphaIsThePercent() {
        for step in PanelOpacity.allCases {
            #expect(step.alpha(increaseContrast: false, reduceTransparency: false) == Double(step.rawValue) / 100)
        }
    }

    @Test func neverMoreTransparentThanThirtyPercent() {
        for step in PanelOpacity.allCases {
            #expect(step.alpha(increaseContrast: false, reduceTransparency: false) >= 0.3, "\(step)")
        }
    }

    @Test func increaseContrastOrReduceTransparencyShowsThePanelInFull() {
        for step in PanelOpacity.allCases {
            #expect(step.alpha(increaseContrast: true, reduceTransparency: false) == 1, "\(step)")
            #expect(step.alpha(increaseContrast: false, reduceTransparency: true) == 1, "\(step)")
            #expect(step.alpha(increaseContrast: true, reduceTransparency: true) == 1, "\(step)")
        }
    }

    @Test func anOverrideIsReportedOnlyWhenItChangesWhatIsShown() {
        // The menu says so: picking 55 % with Increase Contrast on would otherwise seem to do nothing.
        #expect(PanelOpacity.p55.isOverridden(increaseContrast: true, reduceTransparency: false))
        #expect(PanelOpacity.p30.isOverridden(increaseContrast: false, reduceTransparency: true))
        #expect(!PanelOpacity.p55.isOverridden(increaseContrast: false, reduceTransparency: false))
        // 100 % is shown as picked: nothing to report.
        #expect(!PanelOpacity.full.isOverridden(increaseContrast: true, reduceTransparency: true))
    }

    @Test func everyStepHasItsOwnName() {
        let names = PanelOpacity.allCases.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(PanelOpacity.full.name == "100%")
        #expect(PanelOpacity.p30.name == "30%")
    }

    @Test func theKeyIsNotTheTileOpacityKey() {
        #expect(PanelOpacity.defaultsKey == "panel.opacity")
        #expect(PanelOpacity.defaultsKey != TileOpacity.defaultsKey)
    }
}
