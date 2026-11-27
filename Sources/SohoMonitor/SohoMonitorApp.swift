import AppKit
import SohoMonitorCore
import SwiftUI

/// Entry point: `SohoMonitor --scan` runs one scan without UI (writes the cache, prints a summary); otherwise the
/// menu bar app starts.
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.dropFirst().contains("--scan") {
            exit(HeadlessScan.run())
        }
        SohoMonitorApp.main()
    }
}

struct SohoMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("soho-monitor", systemImage: "internaldrive") {
            MenuContent(model: delegate.model)
        }
    }
}

/// Owns the model and the desktop panel for the whole life of the app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let system = SystemModel()
    private var panel: DesktopPanelController?
    private let credentialWindow = CredentialWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let synology = model.synology
        synology.presentSetup = { [weak self] in self?.credentialWindow.show(model: synology) }
        model.start()
        system.start()
        let panel = DesktopPanelController(model: model, system: system)
        self.panel = panel
        panel.onScreenChanged = { [weak self] onScreen in self?.system.setDemand(onScreen) }
        panel.setVisible(model.panelVisible)
        observePanelVisibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A `du` still running would otherwise go on after the app has quit.
        ProcessRunner.terminateRunning()
    }

    private func observePanelVisibility() {
        withObservationTracking {
            _ = model.panelVisible
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.panel?.setVisible(self.model.panelVisible)
                self.observePanelVisibility()
            }
        }
    }
}

private struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Text(model.menuSummary)
        if model.isScanning {
            Text("Scanning…")
        } else if let snapshot = model.snapshot {
            Text("Updated \(RelativeAge.string(from: snapshot.updated, now: .now))")
        }
        if !model.configState.errors.isEmpty {
            Text("⚠︎ Config error: \(model.configState.errors[0].description)")
        }
        if let error = model.lastScanError {
            Text("⚠︎ Scan failed: \(error)")
        }
        Divider()
        Button(model.panelVisible ? "Hide Panel" : "Show Panel") { model.panelVisible.toggle() }
            .keyboardShortcut("p")
        Button("Rescan Now") { model.rescanNow() }
            .keyboardShortcut("r")
            .disabled(model.isScanning || !model.configState.hasValidConfig)
        if model.synology.isEnabled {
            Button("Synology Credentials…") { model.synology.presentSetup() }
        }
        Divider()
        Text("soho-monitor \(SohoMonitorCore.version)")
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// `--scan`: one scan with the current configuration, cache written, summary on stdout. Useful to fill the cache
/// from a shell, or to check the figures without the UI.
enum HeadlessScan {
    static func run() -> Int32 {
        let url = ConfigFile.defaultURL(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
        let config: DiskConfig
        switch ConfigFile.load(url) {
        case .success(let loaded):
            for warning in loaded.warnings { print("warn  \(warning)") }
            config = loaded.config.disk
        case .failure(let error):
            for issue in error.issues { fputs("ko    \(issue)\n", stderr) }
            return 1
        }
        let box = OutcomeBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .background) {
            let scanner = DiskScanner(runner: ProcessRunner(), paths: GlobPathResolver(home: NSHomeDirectory()))
            let coordinator = ScanCoordinator(scanner: scanner, lockURL: SnapshotStore.defaultLockURL)
            box.outcome = await coordinator.scanIfIdle(config)
            done.signal()
        }
        done.wait()
        if box.outcome == .alreadyRunning {
            fputs("ko    another scan is running (the app or another --scan): try again when it ends\n", stderr)
            return 1
        }
        guard case .completed(let snapshot) = box.outcome else {
            fputs("ko    scan failed: \(String(describing: box.outcome))\n", stderr)
            return 1
        }
        let store = SnapshotStore(directory: SnapshotStore.defaultDirectory)
        do {
            try store.save(snapshot)
        } catch {
            fputs("ko    cannot write \(store.url.path): \(error)\n", stderr)
            return 1
        }
        for group in DiskSummary.groups(of: snapshot) {
            print(group.detail + (group.partial ? "  (partial)" : ""))
        }
        print("ok    \(DiskSummary.menuLine(of: snapshot)), scan \(Int(snapshot.duration)) s → \(store.url.path)")
        return 0
    }

    /// Written by the scan task before the semaphore is signalled, read after `wait()`: ordered, never concurrent.
    private final class OutcomeBox: @unchecked Sendable {
        var outcome: ScanOutcome?
    }
}
