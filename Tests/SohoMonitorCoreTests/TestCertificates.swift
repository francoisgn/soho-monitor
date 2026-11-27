import Foundation

/// Throwaway self-signed certificates for the TLS tests: P-256, CN and SAN `nas.example.test`, serverAuth, at most
/// 398 days (Apple's TLS rules), private keys discarded. Made with `openssl req -x509 -not_before … -not_after …`.
/// DER in base64; fingerprints as printed by `openssl x509 -noout -fingerprint -sha256`.
enum TestCertificates {
    static let host = "nas.example.test"

    /// Valid from 2026-06-01 to 2027-05-31.
    static let valid = der(
        """
        MIIBmTCCAT+gAwIBAgIUKTfO6aLTe61zHmjElyjGUQ47oP0wCgYIKoZIzj0EAwIwGzEZMBcGA1UE
        AwwQbmFzLmV4YW1wbGUudGVzdDAeFw0yNjA2MDEwMDAwMDBaFw0yNzA1MzEwMDAwMDBaMBsxGTAX
        BgNVBAMMEG5hcy5leGFtcGxlLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQ73p84YPWh
        8d3MPVE+cCZd7zdHmkV3FI9ITuXEDWFWd8OXGVtpNLh+T+Si1BW9UXopXcvQlla074n+LYixxzMv
        o2EwXzAdBgNVHQ4EFgQUmRThLuvXiU5YjdwMBivWFcEQ/YIwGwYDVR0RBBQwEoIQbmFzLmV4YW1w
        bGUudGVzdDATBgNVHSUEDDAKBggrBgEFBQcDATAMBgNVHRMBAf8EAjAAMAoGCCqGSM49BAMCA0gA
        MEUCIQDtcrkAWOPtbzWFhz14bUJx1N76TvLyq7lJ/FPByekJKQIgU0cPskvKrFyecrwnIzA83GJn
        ahMCBNOVcnNmYzR2GhM=
        """)
    static let validFingerprint =
        "5C:AD:11:29:E1:56:F6:59:FC:B9:52:CD:E8:9F:FB:59:1E:CD:87:A9:13:4D:E8:67:0C:9A:80:A1:15:01:D1:7C"

    /// Valid from 2024-03-21 to 2025-03-20 23:59:59 UTC: expired.
    static let expired = der(
        """
        MIIBmjCCAT+gAwIBAgIUKsuM0PDbI4RKj7xf6LYf8fPn/PQwCgYIKoZIzj0EAwIwGzEZMBcGA1UE
        AwwQbmFzLmV4YW1wbGUudGVzdDAeFw0yNDAzMjEwMDAwMDBaFw0yNTAzMjAyMzU5NTlaMBsxGTAX
        BgNVBAMMEG5hcy5leGFtcGxlLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQ6DFZcdhGT
        /aKZmRWLfvwYdBhoVnqtPy+WhZjNqOeTk0mKzqaJPHb685ldbk2RG7WM3PA0nzG7rgvhPe1S9u2z
        o2EwXzAdBgNVHQ4EFgQUNAIyY8Ez5xSrNqBJxbAGnsxz6DYwGwYDVR0RBBQwEoIQbmFzLmV4YW1w
        bGUudGVzdDATBgNVHSUEDDAKBggrBgEFBQcDATAMBgNVHRMBAf8EAjAAMAoGCCqGSM49BAMCA0kA
        MEYCIQDqf6RVM73hzHBvYkZE4HPR/5+6gt+Vz1EqP4kXOdtjLwIhANUlgjCJZXY1+LD11kgt692k
        WH2Uzils7h5I+1SA2RRc
        """)
    static let expiredFingerprint =
        "E7:93:D9:2C:6C:AE:BB:42:CA:59:10:DF:CF:E7:D3:DF:6C:2A:D4:6F:95:A2:98:63:4C:DA:47:3C:78:A3:F9:B4"

    /// Same names and dates as `valid`, another key: what an impostor (or a rotated certificate) presents.
    static let other = der(
        """
        MIIBmTCCAT+gAwIBAgIUcad5j0tNNjgf5Xi8Udy1J8sIxvgwCgYIKoZIzj0EAwIwGzEZMBcGA1UE
        AwwQbmFzLmV4YW1wbGUudGVzdDAeFw0yNjA2MDEwMDAwMDBaFw0yNzA1MzEwMDAwMDBaMBsxGTAX
        BgNVBAMMEG5hcy5leGFtcGxlLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASJNuSepHOT
        lb+XzDCIU36VJSWG4oI2sOvkEv6ks3PJYbT/ywq407/tpOk11H/nYiAvlB++oiAUa4v+jLNtABU7
        o2EwXzAdBgNVHQ4EFgQU45y2NZfj4KFsOdROGN8hZkKimi8wGwYDVR0RBBQwEoIQbmFzLmV4YW1w
        bGUudGVzdDATBgNVHSUEDDAKBggrBgEFBQcDATAMBgNVHRMBAf8EAjAAMAoGCCqGSM49BAMCA0gA
        MEUCIQDAhsvmSsu+6/qkMhdBPMo85LPSm0GZT/lqVppUj+bsjgIgIlJNyzBCEYaF9Nlr5PAj6UNp
        QrT/j6o0gPqyGj8rh3k=
        """)
    static let otherFingerprint =
        "0F:08:80:5C:07:24:B2:68:9E:48:A3:D6:A7:04:F5:77:04:6A:40:A2:82:A2:24:15:16:DA:53:68:87:66:55:8D"

    private static func der(_ base64: String) -> Data {
        Data(base64Encoded: base64.filter { !$0.isWhitespace }) ?? Data()
    }
}
