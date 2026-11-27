import CoreGraphics
import Testing

@testable import SohoMonitorCore

@Suite struct PanelPlacementTests {
    let screen = CGRect(x: 0, y: 80, width: 1700, height: 1000)  // visible frame above a Dock

    @Test func aPanelThatGrewBelowTheScreenMovesBackUp() {
        // Saved at the bottom when it was short; it is taller now and its frame starts under the Dock.
        let origin = PanelPlacement.origin(of: CGRect(x: 24, y: -200, width: 444, height: 700), within: screen)
        #expect(origin == CGPoint(x: 24, y: 80))
    }

    @Test func aPanelPastTheTopOrTheRightComesBackInside() {
        let origin = PanelPlacement.origin(of: CGRect(x: 1600, y: 900, width: 444, height: 300), within: screen)
        #expect(origin == CGPoint(x: 1256, y: 780))
    }

    @Test func aPanelInsideStaysWhereItIs() {
        let frame = CGRect(x: 300, y: 200, width: 444, height: 600)
        #expect(PanelPlacement.origin(of: frame, within: screen) == frame.origin)
    }

    @Test func theDefaultCornerIsTheTopLeftUnderTheMenuBar() {
        #expect(PanelPlacement.defaultTopLeft(in: screen, margin: 24) == CGPoint(x: 24, y: 1056))
    }

    @Test func anchoredAtTheTopLeftThePanelGrowsDownward() {
        let topLeft = CGPoint(x: 24, y: 1056)
        let short = PanelPlacement.origin(topLeft: topLeft, size: CGSize(width: 444, height: 300), within: screen)
        let tall = PanelPlacement.origin(topLeft: topLeft, size: CGSize(width: 444, height: 700), within: screen)
        #expect(short == CGPoint(x: 24, y: 756))
        #expect(tall == CGPoint(x: 24, y: 356))  // same top edge: only the bottom moved
    }

    @Test func aTopLeftTooLowForTheContentIsPushedUpToKeepTheBottomOnScreen() {
        let origin = PanelPlacement.origin(
            topLeft: CGPoint(x: 24, y: 400), size: CGSize(width: 444, height: 700), within: screen)
        #expect(origin == CGPoint(x: 24, y: 80))
    }

    @Test func contentTallerThanTheScreenKeepsItsTopUnderTheMenuBar() {
        let origin = PanelPlacement.origin(
            topLeft: CGPoint(x: 24, y: 1056), size: CGSize(width: 444, height: 1400), within: screen)
        #expect(origin.y + 1400 == screen.maxY)
    }

    @Test func theTopLeftOfAFrame() {
        #expect(PanelPlacement.topLeft(of: CGRect(x: 24, y: 356, width: 444, height: 700)) == CGPoint(x: 24, y: 1056))
    }

    @Test func aPanelTallerThanTheScreenKeepsItsTopVisible() {
        let origin = PanelPlacement.origin(of: CGRect(x: 24, y: 0, width: 444, height: 1400), within: screen)
        #expect(origin == CGPoint(x: 24, y: 80 + 1000 - 1400))
    }
}
