import Foundation
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

    @Test("same-version treats missing components as zero")
    func sameVersion() {
        #expect(UpdateChecker.isSameVersion("1.3", "1.3.0"))
        #expect(UpdateChecker.isSameVersion("1.3.0", "1.3.0"))
        #expect(!UpdateChecker.isSameVersion("1.3.0", "1.3.1"))
        #expect(!UpdateChecker.isSameVersion("2.0", "1.9.9"))
    }

    @Test("same-version compares numerically, so prerelease suffixes are ignored")
    func sameVersionIgnoresPrereleaseSuffix() {
        // Deliberate: the installer's version check shares isNewer's numeric
        // semantics; the code-signature requirement is what actually gates an
        // install, so a signed 1.3.0-beta passing for tag v1.3.0 is accepted.
        #expect(UpdateChecker.isSameVersion("1.3.0-beta", "1.3.0"))
    }
}

@Suite("Update asset selection")
struct UpdateAssetTests {
    @Test("zip feeds the installer, dmg stays the browser fallback")
    func prefersZipWithDmgFallback() {
        let targets = UpdateChecker.downloadTargets(
            assets: [
                ("UsageMeter.dmg", "https://example.com/UsageMeter.dmg"),
                ("UsageMeter.zip", "https://example.com/UsageMeter.zip"),
            ],
            releasePage: "https://example.com/releases/v1.3.0")
        #expect(targets?.zip?.absoluteString == "https://example.com/UsageMeter.zip")
        #expect(targets?.fallback.absoluteString == "https://example.com/UsageMeter.dmg")
    }

    @Test("a stray zip asset never reaches the installer")
    func ignoresDecoyZips() {
        let targets = UpdateChecker.downloadTargets(
            assets: [
                ("dSYMs.zip", "https://example.com/dSYMs.zip"),
                ("UsageMeter.dmg", "https://example.com/UsageMeter.dmg"),
            ],
            releasePage: "https://example.com/releases/v1.3.0")
        #expect(targets?.zip == nil)
        #expect(targets?.fallback.absoluteString == "https://example.com/UsageMeter.dmg")
    }

    @Test("a release without a zip still offers the dmg fallback")
    func dmgOnly() {
        let targets = UpdateChecker.downloadTargets(
            assets: [("UsageMeter.dmg", "https://example.com/UsageMeter.dmg")],
            releasePage: "https://example.com/releases/v1.3.0")
        #expect(targets?.zip == nil)
        #expect(targets?.fallback.absoluteString == "https://example.com/UsageMeter.dmg")
    }

    @Test("a release without assets falls back to its page")
    func noAssets() {
        let targets = UpdateChecker.downloadTargets(
            assets: [], releasePage: "https://example.com/releases/v1.3.0")
        #expect(targets?.zip == nil)
        #expect(targets?.fallback.absoluteString == "https://example.com/releases/v1.3.0")
    }
}

@Suite("In-place install eligibility")
struct UpdateInstallerEligibilityTests {
    @Test("a bare dev binary (swift run) is not eligible")
    func devBuildIneligible() {
        let url = URL(fileURLWithPath: "/tmp/usage-meter/.build/release/UsageMeter")
        #expect(!UpdateInstaller.isEligibleBundle(at: url))
    }

    @Test("a translocated copy is not eligible")
    func translocatedIneligible() {
        let url = URL(
            fileURLWithPath:
                "/private/var/folders/ab/T/AppTranslocation/1B2C/d/UsageMeter.app")
        #expect(!UpdateInstaller.isEligibleBundle(at: url))
    }

    @Test("a writable installed bundle is eligible")
    func writableBundleEligible() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EligibilityTest-\(UUID().uuidString)", isDirectory: true)
        let app = dir.appendingPathComponent("UsageMeter.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(UpdateInstaller.isEligibleBundle(at: app))
    }
}
