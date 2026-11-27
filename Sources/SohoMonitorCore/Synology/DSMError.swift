import Foundation

/// Why a DSM Web API exchange failed. Codes from Synology's "DSM Login Web API Guide" (last updated 2023-04-19):
/// common codes p. 8-9, `SYNO.API.Auth` codes p. 18
/// (https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Login_Web_API_Guide_enu.pdf).
/// Messages never contain a URL, a request body, the password or the session id.
public enum DSMError: Error, Sendable, Equatable {
    /// No password in the Keychain for this module: nothing was sent.
    case needsSetup
    case keychain(SecretStoreError)
    /// DNS failure, connection refused, timeout, no route: the NAS cannot be reached from here.
    case unreachable(String)
    /// The certificate was refused by the configured `TLSPolicy`; nothing was sent.
    case tls(TLSFailure)
    /// 400: no such account or incorrect password.
    case invalidCredentials
    /// 401: the account is disabled.
    case accountDisabled
    /// 105 again after a fresh login: the account may not use this API.
    case permissionDenied
    /// 402 at login: the account may not sign in through the Web API (its permissions or group in DSM).
    case signInNotAllowed
    /// 403, 404, 406: the account requires 2-factor authentication, which an unattended monitor cannot answer.
    case otpRequired
    /// 407: DSM blocked this Mac's IP address (auto block after failed logins).
    case ipBlocked
    /// 408, 409, 410: the password expired or must be changed.
    case passwordExpired
    /// 106, 107 or 119 again right after a fresh login.
    case sessionLost(code: Int)
    /// The API is missing from `SYNO.API.Info` (package not installed) or does not support the version needed.
    case apiUnavailable(String)
    /// Any other error code returned by an API.
    case api(name: String, code: Int)
    /// Not the documented JSON envelope (HTTP error, HTML page, `success: false` without a code).
    case invalidResponse(String)

    /// Codes after which one fresh login and one retry are attempted: 105 (no permission, also what an expired sid
    /// can yield), 106 (session timeout), 107 (interrupted by a duplicate login), 119 (invalid session).
    public static let sessionCodes: Set<Int> = [105, 106, 107, 119]

    /// The error for an `SYNO.API.Auth` login code.
    public static func login(code: Int) -> DSMError {
        switch code {
        case 400: .invalidCredentials
        case 401: .accountDisabled
        case 402: .signInNotAllowed
        case 403, 404, 406: .otpRequired
        case 407: .ipBlocked
        case 408, 409, 410: .passwordExpired
        default: .api(name: "SYNO.API.Auth", code: code)
        }
    }

    /// Credentials, account or policy problems: polling stops until the secret or the configuration changes, so
    /// that repeated bad logins never get the account or the Mac blocked.
    public var isAuthFailure: Bool {
        switch self {
        case .invalidCredentials, .accountDisabled, .permissionDenied, .signInNotAllowed, .otpRequired, .ipBlocked,
            .passwordExpired:
            true
        default:
            false
        }
    }

    public var message: String {
        switch self {
        case .needsSetup: "no password saved: set up the credentials"
        case .keychain(let error): error.message
        case .unreachable(let reason): "unreachable (\(reason))"
        case .tls(let failure): failure.message
        case .invalidCredentials: "wrong user name or password"
        case .accountDisabled: "the DSM account is disabled"
        case .permissionDenied: "the DSM account is not allowed to use this (check its application permissions)"
        case .signInNotAllowed:
            "the DSM account is not allowed to sign in through the API: check its permissions and group in DSM"
        case .otpRequired:
            "the DSM account requires 2-factor authentication: use a dedicated account without it"
        case .ipBlocked: "DSM blocked this Mac's IP address (Control Panel › Security › Protection › Allow/Block List)"
        case .passwordExpired: "the DSM account's password expired: change it in DSM, then save it here"
        case .sessionLost(let code): "the DSM session was lost again right after logging in (code \(code))"
        case .apiUnavailable(let name): "\(name) is not available on this NAS"
        case .api(let name, let code): "\(name) failed (DSM error \(code))"
        case .invalidResponse(let detail): "unexpected answer from DSM (\(detail))"
        }
    }
}
