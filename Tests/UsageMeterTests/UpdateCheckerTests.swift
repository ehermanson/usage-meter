import Testing

@testable import UsageMeter

@Suite("Update version comparison")
struct UpdateCheckerTests {
    @Test("a higher version is newer")
    func detectsNewer() {
        #expect(UpdateChecker.isNewer("1.3.0", than: "1.2.0"))
        #expect(UpdateChecker.isNewer("1.2.1", than: "1.2.0"))
        #expect(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
    }

    @Test("equal or older versions are not newer")
    func ignoresSameOrOlder() {
        #expect(!UpdateChecker.isNewer("1.2.0", than: "1.2.0"))
        #expect(!UpdateChecker.isNewer("1.1.9", than: "1.2.0"))
        #expect(!UpdateChecker.isNewer("1.2.0", than: "1.2.1"))
    }

    @Test("missing trailing components count as zero")
    func handlesShortVersions() {
        #expect(!UpdateChecker.isNewer("1.2", than: "1.2.0"))
        #expect(UpdateChecker.isNewer("1.3", than: "1.2.9"))
    }

    @Test("non-numeric suffixes are ignored")
    func handlesPreReleaseSuffixes() {
        #expect(UpdateChecker.isNewer("1.3.0-beta", than: "1.2.0"))
        #expect(!UpdateChecker.isNewer("1.2.0", than: "1.2.0-rc1"))
    }
}
