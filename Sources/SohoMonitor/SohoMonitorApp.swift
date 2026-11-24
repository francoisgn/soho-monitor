import SohoMonitorCore
import SwiftUI

/// Bootstrap entry point: a menu bar extra only. The disk module and the desktop panel come with the
/// migration of the diskwidget (see the issues).
@main
struct SohoMonitorApp: App {
    var body: some Scene {
        MenuBarExtra("soho-monitor", systemImage: "gauge.with.dots.needle.33percent") {
            Text("soho-monitor \(SohoMonitorCore.version)")
                .font(.system(.body, design: .rounded))
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
