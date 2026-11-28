import Testing

@testable import SohoMonitorCore

@Suite struct DuOutputTests {
    @Test func parsesTotalAndDirectChildren() {
        let stdout = """
            120\t/Users/me/Git/alpha
            8\t/Users/me/Git/with space
            0\t/Users/me/Git/empty
            200\t/Users/me/Git

            """
        let m = DuOutput.parse(path: "/Users/me/Git", stdout: stdout, stderr: "")
        #expect(m.path == "/Users/me/Git")
        #expect(m.bytes == 200 * 1024)
        #expect(m.partial == false)
        #expect(
            m.children == [
                DuEntry(path: "/Users/me/Git/alpha", bytes: 120 * 1024),
                DuEntry(path: "/Users/me/Git/with space", bytes: 8 * 1024),
                DuEntry(path: "/Users/me/Git/empty", bytes: 0),
            ])
    }

    @Test func aFileHasNoChildren() {
        let m = DuOutput.parse(path: "/Users/me/big.iso", stdout: "4096\t/Users/me/big.iso\n", stderr: "")
        #expect(m.bytes == 4096 * 1024)
        #expect(m.children.isEmpty)
    }

    @Test func tabInsideANameStaysInThePath() {
        let m = DuOutput.parse(path: "/r", stdout: "1\t/r/a\tb\n3\t/r\n", stderr: "")
        #expect(m.children == [DuEntry(path: "/r/a\tb", bytes: 1024)])
        #expect(m.bytes == 3 * 1024)
    }

    @Test func malformedLinesAreSkipped() {
        let stdout = "garbage\n12x\t/r/x\n\t/r/y\n5\t/r/ok\n9\t/r\n"
        let m = DuOutput.parse(path: "/r", stdout: stdout, stderr: "")
        #expect(m.children == [DuEntry(path: "/r/ok", bytes: 5 * 1024)])
        #expect(m.bytes == 9 * 1024)
    }

    @Test func emptyOutputMeansZero() {
        let m = DuOutput.parse(path: "/r", stdout: "", stderr: "du: /r: No such file or directory\n")
        #expect(m.bytes == 0)
        #expect(m.children.isEmpty)
        #expect(m.partial == false)
    }

    @Test(arguments: [
        ("du: /Users/me/Library/Mail: Operation not permitted\n", true),
        ("du: /Users/me/Library/Containers/x: Permission denied\n", true),
        ("", false),
        ("du: /r/gone: No such file or directory\n", false),
    ])
    func partialFlagComesFromAccessErrors(stderr: String, partial: Bool) {
        let m = DuOutput.parse(path: "/r", stdout: "1\t/r\n", stderr: stderr)
        #expect(m.partial == partial)
    }

    @Test func operationNotPermittedIsMissingFullDiskAccess() {
        // TCC refuses with EPERM: only Full Disk Access lets the app in.
        let m = DuOutput.parse(
            path: "/Users/me/Library", stdout: "1\t/Users/me/Library\n",
            stderr: "du: /Users/me/Library/Mail: Operation not permitted\n")
        #expect(m.partial)
        #expect(m.fullDiskAccessDenied)
        #expect(m.unreadable.isEmpty)
    }

    @Test func permissionDeniedListsTheFolderWithoutAskingForFullDiskAccess() {
        // POSIX refuses with EACCES (a root-owned drwx------ folder): Full Disk Access does not help.
        let stderr = """
            du: /Users/me/Library/Application Support/Vendor/updater/1234.run: Permission denied
            du: /Users/me/Library/Application Support/Other: tricky/locked: Permission denied
            du: /Users/me/Library/Application Support/Vendor/updater/1234.run: Permission denied

            """
        let m = DuOutput.parse(path: "/Users/me/Library", stdout: "1\t/Users/me/Library\n", stderr: stderr)
        #expect(m.partial)
        #expect(!m.fullDiskAccessDenied)
        #expect(
            m.unreadable == [
                "/Users/me/Library/Application Support/Vendor/updater/1234.run",
                "/Users/me/Library/Application Support/Other: tricky/locked",
            ])
    }

    @Test func gnuPermissionDeniedQuotesThePath() {
        let stderr = """
            du: cannot read directory '/home/me/locked': Permission denied
            du: cannot open directory '/home/me/other one': Permission denied

            """
        let m = DuOutput.parse(path: "/home/me", stdout: "1\t/home/me\n", stderr: stderr)
        #expect(m.unreadable == ["/home/me/locked", "/home/me/other one"])
        #expect(!m.fullDiskAccessDenied)
    }

    @Test func bothKindsKeepTheFullDiskAccessFlagAndTheFolders() {
        let stderr = """
            du: /Users/me/Library/Mail: Operation not permitted
            du: /Users/me/Library/Application Support/Vendor/locked: Permission denied

            """
        let m = DuOutput.parse(path: "/Users/me/Library", stdout: "1\t/Users/me/Library\n", stderr: stderr)
        #expect(m.fullDiskAccessDenied)
        #expect(m.unreadable == ["/Users/me/Library/Application Support/Vendor/locked"])
    }

    @Test func permissionDeniedWithoutAPathIsStillPartial() {
        let m = DuOutput.parse(path: "/r", stdout: "1\t/r\n", stderr: "du: Permission denied\n")
        #expect(m.partial)
        #expect(!m.fullDiskAccessDenied)
        #expect(m.unreadable.isEmpty)
    }
}
