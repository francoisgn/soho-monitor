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
}
