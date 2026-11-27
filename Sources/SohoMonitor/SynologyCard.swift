import AppKit
import SohoMonitorCore
import SwiftUI

/// The NAS card while the data cards (#23–#27) are not there yet: host, credential state and TLS warning, with the
/// button to the credential window.
struct SynologyCard: View {
    let model: SynologyModel

    var body: some View {
        if let config = model.config {
            SynologyCardContent(
                config: config, credentials: model.credentials, trust: model.lastTrust,
                savedTest: model.savedTest, onSetUp: model.presentSetup,
                onTestSaved: { Task { await model.testSavedPassword() } })
        }
    }
}

struct SynologyCardContent: View {
    var config: SynologyConfig
    var credentials: SynologyModel.Credentials
    var trust: TLSTrustState?
    var savedTest: SavedPasswordTest.Phase = .idle
    var onSetUp: () -> Void
    var onTestSaved: () -> Void = {}

    var body: some View {
        GlassCard(accent: CardColor.nas) {
            MetricHeader(
                symbol: "externaldrive.connected.to.line.below", title: "NAS", subtitle: "\(config.host)",
                figure: "", tint: CardColor.nas)
            HStack(spacing: 8) {
                Text(status).font(.system(size: 12, weight: .medium)).foregroundStyle(statusStyle).lineLimit(2)
                Spacer(minLength: 4)
                if credentials == .saved {
                    Button("Test", action: onTestSaved)
                        .controlSize(.small)
                        .disabled(savedTest == .testing)
                        .help("Test the saved password (macOS may ask to allow Keychain access: Always Allow)")
                }
                Button(credentials == .saved ? "Change…" : "Set Up…", action: onSetUp)
                    .controlSize(.small)
            }
            if let warning = TLSWarning.text(policy: config.tls, trust: trust) {
                Label(warning, systemImage: "exclamationmark.shield")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CardColor.warning)
                    .lineLimit(2)
            }
        }
    }

    private var status: String {
        switch credentials {
        case .unknown: "Checking the Keychain…"
        case .missing: "Needs setup: no password saved for \(config.user)"
        case .saved:
            switch savedTest {
            case .idle: "Credentials saved for \(config.user)"
            case .testing: "Testing the saved password…"
            case .passed: "Saved password works for \(config.user)"
            case .failed(let error): error.message.capitalizedFirst
            }
        case .unavailable(let message): message
        }
    }

    private var statusStyle: AnyShapeStyle {
        if credentials == .saved, case .failed = savedTest { AnyShapeStyle(.red) } else { AnyShapeStyle(.secondary) }
    }
}

/// The permanent warning of a host whose certificate is not fully verified.
enum TLSWarning {
    static func text(policy: TLSPolicy, trust: TLSTrustState?) -> String? {
        if policy == .allowSelfSigned { return TLSTrustState.insecure.warning }
        return trust?.warning
    }
}

/// The credential window: the account comes from the configuration, the password is typed here, tested, then saved
/// in the Keychain. Nothing is saved when the test fails; the password field is cleared after a save.
struct CredentialForm: View {
    enum Status: Equatable {
        case idle
        case busy(String)
        case connected(TLSTrustState)
        case savedWorks(TLSTrustState)
        case saved(TLSTrustState)
        case removed
        case notice(String)
        case failed(DSMError)
        case keychainFailed(SecretStoreError)
    }

    var config: SynologyConfig
    var hasSavedPassword: Bool
    var onTest: (String) async -> Result<TLSTrustState, DSMError>
    var onSave: (String) async -> CredentialSetupOutcome
    var onRemove: () async -> SecretStoreError?
    var onTestSaved: () async -> SavedPasswordTestReply = { .alreadyRunning }
    @State var status: Status = .idle
    @State private var password = ""
    /// Whether a password is saved, once this window has saved, removed or found it missing.
    @State private var savedNow: Bool?

    private var showsSavedActions: Bool { savedNow ?? hasSavedPassword }

    private var isBusy: Bool { if case .busy = status { true } else { false } }

    var body: some View {
        Form {
            Section {
                LabeledContent("NAS", value: "\(config.host):\(String(config.port))")
                LabeledContent("Account", value: config.user)
                SecureField("Password", text: $password)
                    .onSubmit { if CredentialSetup.canSubmit(password: password), !isBusy { save() } }
            } footer: {
                Text(
                    "Use a dedicated DSM account without 2-factor authentication, with read-only access. The "
                        + "password is kept in the macOS Keychain only (item \"\(config.keychainItem)\")."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if config.tls == .allowSelfSigned, let warning = TLSTrustState.insecure.warning {
                Label(warning, systemImage: "exclamationmark.shield").foregroundStyle(.orange)
            }
            StatusRow(status: status)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if showsSavedActions {
                    Button("Remove", role: .destructive) { remove() }.disabled(isBusy)
                }
                Spacer()
                if showsSavedActions {
                    Button("Test Saved Password") { testSaved() }.disabled(isBusy)
                }
                Button("Test Connection") { test() }
                    .disabled(!CredentialSetup.canSubmit(password: password) || isBusy)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!CredentialSetup.canSubmit(password: password) || isBusy)
            }
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))
        }
        // A grouped form has no ideal height of its own: without one the window shrinks to a single row.
        .frame(width: 480, height: 430)
    }

    private func test() {
        let typed = password
        status = .busy("Testing the connection…")
        Task {
            switch await onTest(typed) {
            case .success(let state): status = .connected(state)
            case .failure(let error): status = .failed(error)
            }
        }
    }

    private func save() {
        let typed = password
        status = .busy("Testing, then saving…")
        Task {
            switch await onSave(typed) {
            case .saved(let state):
                password = ""
                savedNow = true
                status = .saved(state)
            case .testFailed(let error): status = .failed(error)
            case .saveFailed(let error): status = .keychainFailed(error)
            }
        }
    }

    private func remove() {
        status = .busy("Removing…")
        Task {
            if let error = await onRemove() {
                status = .keychainFailed(error)
            } else {
                savedNow = false
                status = .removed
            }
        }
    }

    private func testSaved() {
        status = .busy("Reading the saved password, then testing…")
        Task {
            switch await onTestSaved() {
            case .alreadyRunning: status = .notice("A test of the saved password is already running: see the NAS card.")
            case .overtaken: status = .notice("The settings or the password changed during the test: test again.")
            case .done(.success(let state)): status = .savedWorks(state)
            case .done(.failure(.keychain(let error))): status = .keychainFailed(error)
            case .done(.failure(let error)):
                if error == .needsSetup { savedNow = false }
                status = .failed(error)
            }
        }
    }
}

/// The outcome under the fields; for a refused certificate, the fingerprint it presented, to pin after checking it
/// on the NAS.
private struct StatusRow: View {
    var status: CredentialForm.Status

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .busy(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary)
            }
        case .connected(let trust):
            success("Connection works. Not saved yet.", trust: trust)
        case .savedWorks(let trust):
            success("The saved password works.", trust: trust)
        case .saved(let trust):
            success("Saved in the Keychain.", trust: trust)
        case .removed:
            Label("Password removed from the Keychain.", systemImage: "trash").foregroundStyle(.secondary)
        case .notice(let text):
            Label(text, systemImage: "info.circle").foregroundStyle(.secondary)
        case .failed(let error):
            VStack(alignment: .leading, spacing: 6) {
                Label(error.message.capitalizedFirst, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                if case .tls(let failure) = error, let presented = failure.presented {
                    FingerprintRow(fingerprint: presented)
                }
            }
        case .keychainFailed(let error):
            Label(error.message.capitalizedFirst, systemImage: "key.slash").foregroundStyle(.red)
        }
    }

    private func success(_ text: String, trust: TLSTrustState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if let warning = trust.warning {
                Label(warning.capitalizedFirst, systemImage: "exclamationmark.shield").foregroundStyle(.orange)
            }
        }
    }
}

private struct FingerprintRow: View {
    var fingerprint: CertificateFingerprint

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Certificate presented (SHA-256):").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                Text(fingerprint.description)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fingerprint.description, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the fingerprint")
            }
            Text(
                "Compare it with the certificate in DSM (Control Panel › Security › Certificate) before putting it "
                    + "in tls.pin_sha256."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The credential window, created once and brought to the front on demand. The app has no Dock icon: it is
/// activated so that the window takes the keyboard.
@MainActor
final class CredentialWindowController {
    private var window: NSWindow?

    func show(model: SynologyModel) {
        guard let config = model.config else { return }
        let form = CredentialForm(
            config: config, hasSavedPassword: model.credentials == .saved,
            onTest: { await model.test(password: $0) }, onSave: { await model.save(password: $0) },
            onRemove: { await model.remove() }, onTestSaved: { await model.testSavedPassword() })
        let host = NSHostingController(rootView: form)
        if let window {
            window.contentViewController = host
        } else {
            let window = NSWindow(contentViewController: host)
            window.title = "Synology Credentials"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Activation may be refused while another app is active (cooperative activation): show it anyway.
        window?.orderFrontRegardless()
    }
}

// MARK: - Previews (states of the card and of the credential window)

@MainActor
private enum CredentialPreview {
    static let config = SynologyConfig(host: "nas.example.test", user: "monitor")
    static let presented = CertificateFingerprint(sha256Of: Data("preview".utf8))

    static func form(_ status: CredentialForm.Status, saved: Bool = false) -> CredentialForm {
        CredentialForm(
            config: config, hasSavedPassword: saved, onTest: { _ in .success(.trusted) },
            onSave: { _ in .saved(.trusted) }, onRemove: { nil }, status: status)
    }
}

#Preview("Card") {
    VStack(spacing: 12) {
        SynologyCardContent(config: CredentialPreview.config, credentials: .missing, onSetUp: {})
        SynologyCardContent(
            config: CredentialPreview.config, credentials: .saved, trust: .pinnedExpired, onSetUp: {})
        SynologyCardContent(
            config: CredentialPreview.config, credentials: .saved, trust: .pinnedExpired,
            savedTest: .passed(.pinnedExpired), onSetUp: {})
        SynologyCardContent(
            config: CredentialPreview.config, credentials: .saved, savedTest: .failed(.keychain(.accessDenied)),
            onSetUp: {})
    }
    .frame(width: DiskCard.width)
    .padding()
}

#Preview("Form · idle") { CredentialPreview.form(.idle) }
#Preview("Form · saved, expired pinned") { CredentialPreview.form(.saved(.pinnedExpired), saved: true) }
#Preview("Form · certificate expired") {
    CredentialPreview.form(.failed(.tls(.certificateExpired(presented: CredentialPreview.presented))))
}
#Preview("Form · wrong password") { CredentialPreview.form(.failed(.invalidCredentials)) }
#Preview("Form · Keychain denied") { CredentialPreview.form(.keychainFailed(.accessDenied)) }
#Preview("Form · saved password works") { CredentialPreview.form(.savedWorks(.pinnedExpired), saved: true) }
