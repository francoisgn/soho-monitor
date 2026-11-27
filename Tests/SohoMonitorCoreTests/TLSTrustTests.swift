import Foundation
import Security
import Testing

@testable import SohoMonitorCore

/// The trust decision runs on real `SecTrust` objects built from throwaway certificates (L77): what is tested is what
/// the `URLSession` delegate runs.
@Suite struct TLSTrustTests {
    private static let inValidity = Date(timeIntervalSince1970: 1_798_761_600)  // 2027-01-01, inside `valid`

    private func trust(_ der: Data, anchored: Bool = false) throws -> SecTrust {
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, TestCertificates.host as CFString)
        #expect(SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess)
        let result = try #require(trust)
        if anchored {
            // Stands for a certificate from a public authority: trusted by the system.
            SecTrustSetAnchorCertificates(result, [certificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(result, true)
        }
        return result
    }

    private func evaluate(_ der: Data, policy: TLSPolicy, anchored: Bool = false, now: Date = inValidity) throws
        -> Result<TLSTrustState, TLSFailure>
    {
        TLSTrustEvaluator(host: TestCertificates.host, policy: policy, now: { now })
            .evaluate(try trust(der, anchored: anchored))
    }

    private func pin(_ fingerprint: String) throws -> TLSPolicy {
        .pinned(try #require(CertificateFingerprint(fingerprint)))
    }

    // MARK: System trust

    @Test func systemTrustAcceptsATrustedCertificate() throws {
        let result = try evaluate(TestCertificates.valid, policy: .systemTrust, anchored: true)
        #expect(result == .success(.trusted), "\(result)")
    }

    @Test func systemTrustRefusesASelfSignedCertificate() throws {
        let result = try evaluate(TestCertificates.valid, policy: .systemTrust)
        guard case .failure(.untrusted(_, let presented)) = result else {
            Issue.record("expected .untrusted, got \(result)")
            return
        }
        // The presented fingerprint is given so that the operator can pin it.
        #expect(presented.description == TestCertificates.validFingerprint)
    }

    @Test func systemTrustRefusesAnExpiredCertificateWithAPlainMessage() throws {
        let result = try evaluate(TestCertificates.expired, policy: .systemTrust, anchored: true)
        let presented = try #require(CertificateFingerprint(TestCertificates.expiredFingerprint))
        #expect(result == .failure(.certificateExpired(presented: presented)))
        #expect(
            TLSFailure.certificateExpired(presented: presented).message
                == "certificate expired; renew it in DSM or pin its fingerprint")
    }

    // MARK: Pinned

    @Test func pinAcceptsTheMatchingLeafEvenWhenSelfSigned() throws {
        let policy = try pin(TestCertificates.validFingerprint)
        #expect(try evaluate(TestCertificates.valid, policy: policy) == .success(.pinned))
    }

    @Test func pinAcceptsAnExpiredMatchingLeafWithAWarning() throws {
        let policy = try pin(TestCertificates.expiredFingerprint)
        #expect(try evaluate(TestCertificates.expired, policy: policy) == .success(.pinnedExpired))
        #expect(TLSTrustState.pinnedExpired.warning == "certificate expired, pinned")
    }

    @Test func pinRefusesAnotherCertificateAndNamesItsFingerprint() throws {
        let policy = try pin(TestCertificates.validFingerprint)
        // Even one the system trusts: the pin wins.
        let result = try evaluate(TestCertificates.other, policy: policy, anchored: true)
        let presented = try #require(CertificateFingerprint(TestCertificates.otherFingerprint))
        #expect(result == .failure(.certificateMismatch(presented: presented)))
        #expect(
            TLSFailure.certificateMismatch(presented: presented).message
                == "pinned certificate changed: the host now presents \(TestCertificates.otherFingerprint)")
    }

    // MARK: Opt-out

    @Test func allowSelfSignedAcceptsAnyCertificateAndRaisesTheWarning() throws {
        #expect(try evaluate(TestCertificates.other, policy: .allowSelfSigned) == .success(.insecure))
        #expect(try evaluate(TestCertificates.expired, policy: .allowSelfSigned) == .success(.insecure))
        #expect(TLSTrustState.insecure.warning != nil)
        #expect(TLSTrustState.trusted.warning == nil)
        #expect(TLSTrustState.pinned.warning == nil)
    }
}

/// The delegate answers only the configured host's server-trust challenges; anything else gets the default handling.
@Suite struct HostTrustDelegateTests {
    private func challenge(host: String, port: Int, method: String = NSURLAuthenticationMethodServerTrust)
        -> URLAuthenticationChallenge
    {
        let space = URLProtectionSpace(
            host: host, port: port, protocol: "https", realm: nil, authenticationMethod: method)
        return URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil,
            error: nil, sender: NoSender())
    }

    @Test func otherHostsPortsAndMethodsGetTheDefaultHandling() {
        let delegate = HostTrustDelegate(host: "nas.example.test", port: 5001, policy: .allowSelfSigned)
        #expect(delegate.disposition(for: challenge(host: "other.example.test", port: 5001)) == nil)
        #expect(delegate.disposition(for: challenge(host: "nas.example.test", port: 443)) == nil)
        #expect(
            delegate.disposition(
                for: challenge(host: "nas.example.test", port: 5001, method: NSURLAuthenticationMethodHTTPBasic))
                == nil)
        #expect(delegate.lastState == nil)
    }

    @Test func aChallengeWithoutServerTrustIsCancelled() {
        let delegate = HostTrustDelegate(host: "NAS.example.test", port: 5001, policy: .allowSelfSigned)
        // The protection space of a hand-made challenge carries no SecTrust: refuse rather than pass.
        #expect(
            delegate.disposition(for: challenge(host: "nas.example.test", port: 5001)) == .cancelAuthenticationChallenge
        )
        #expect(delegate.lastFailure == .noCertificate)
        // Forgotten before the next request: a later cancellation is not reported as this refusal.
        delegate.forgetFailure()
        #expect(delegate.lastFailure == nil)
        #expect(
            URLSessionTransport.map(URLError(.cancelled), host: "nas.example.test", tlsFailure: delegate.lastFailure)
                == .failed("network error -999"))
        #expect(
            URLSessionTransport.map(URLError(.cancelled), host: "nas.example.test", tlsFailure: .noCertificate)
                == .tls(.noCertificate))
    }

    private final class NoSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }
}

/// An IP literal cannot fail a DNS lookup: "host not found" for one is macOS Local Network privacy denying the app
/// (TN3179; seen on a Mac where the app was denied and Terminal, allowed automatically, reached the NAS).
@Suite struct LocalNetworkDenialTests {
    @Test(arguments: ["192.168.1.20", "10.0.0.2", "fe80::1", "[fd00::2]"])
    func hostNotFoundForAnIPLiteralPointsAtLocalNetworkPrivacy(host: String) {
        for code in [URLError.Code.cannotFindHost, .dnsLookupFailed] {
            #expect(
                URLSessionTransport.map(URLError(code), host: host, tlsFailure: nil)
                    == .unreachable(TransportError.localNetworkDenied))
        }
    }

    @Test(arguments: ["nas.example.test", "nas", "192.168.1.300", "1.2.3"])
    func hostNotFoundForANameStaysHostNotFound(host: String) {
        #expect(
            URLSessionTransport.map(URLError(.cannotFindHost), host: host, tlsFailure: nil)
                == .unreachable("host not found"))
    }

    @Test func theMessageSaysWhereToAllowIt() {
        let message = DSMError.unreachable(TransportError.localNetworkDenied).message
        #expect(message.contains("Local Network privacy"))
        #expect(message.contains("System Settings › Privacy & Security › Local Network"))
    }
}

@Suite struct RequestTimeoutTests {
    @Test func aRequestTimeoutOverridesTheTransportDefault() {
        var request = HTTPRequest(url: URL(string: "https://nas.example.test:5001/webapi/entry.cgi")!, fields: [])
        #expect(URLSessionTransport.urlRequest(for: request, defaultTimeout: 10).timeoutInterval == 10)
        request.timeout = 30
        #expect(URLSessionTransport.urlRequest(for: request, defaultTimeout: 10).timeoutInterval == 30)
    }

    @Test func theWholeExchangeMayLastAsLongAsTheLongestRequest() {
        #expect(URLSessionTransport.resourceTimeout(defaultTimeout: 10) >= DSMClient.loginTimeout)
    }
}
