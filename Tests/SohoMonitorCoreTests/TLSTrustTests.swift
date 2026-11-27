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
    }

    private final class NoSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }
}
