import ChargeLight
import XCTest

final class InstallerTests: XCTestCase {
    var home: TempHome!
    var installer: Installer!
    var source: URL!

    override func setUpWithError() throws {
        home = TempHome()
        installer = Installer(
            helperDestination: home.url.appendingPathComponent("PrivilegedHelperTools/chargelight-helper"),
            sudoersFile: home.url.appendingPathComponent("sudoers.d/chargelight"),
            visudoPath: "/usr/sbin/visudo",
            setOwnership: false)
        source = home.url.appendingPathComponent("build/chargelight-helper")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho \(ChargeLight.version)\n".utf8).write(to: source)
        chmod(source.path, 0o755)
    }

    override func tearDown() {
        home = nil
    }

    func mode(_ url: URL) -> mode_t {
        var st = stat()
        XCTAssertEqual(stat(url.path, &st), 0, url.path)
        return st.st_mode & 0o7777
    }

    func testSudoersRuleText() {
        XCTAssertEqual(Installer.sudoersRule, """
            # Installed by `chargelight setup`. Lets local users change the MagSafe LED
            # (cosmetic only) without a password. Remove with: sudo chargelight uninstall
            ALL ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/chargelight-helper

            """)
    }

    func testInstallCopiesValidatesAndRenames() throws {
        let report = try installer.install(helperSource: source)
        XCTAssertEqual(report.helperVersion, ChargeLight.version)
        XCTAssertEqual(try Data(contentsOf: installer.helperDestination), try Data(contentsOf: source))
        XCTAssertEqual(mode(installer.helperDestination), 0o755)
        XCTAssertEqual(try String(contentsOf: installer.sudoersFile, encoding: .utf8), Installer.sudoersRule)
        XCTAssertEqual(mode(installer.sudoersFile), 0o440)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.sudoersTempFile.path))
        XCTAssertTrue(installer.sudoersTempFile.lastPathComponent.contains("."), "sudo ignores dotted names")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installer.helperDestination.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["chargelight-helper"])

        // Re-running replaces both files in place.
        try Data("#!/bin/sh\necho 9.9.9\n".utf8).write(to: source)
        XCTAssertEqual(try installer.install(helperSource: source).helperVersion, "9.9.9")
    }

    func testInvalidSudoersRuleNeverGoesLive() throws {
        _ = try installer.install(helperSource: source)
        var broken = installer!
        broken.sudoersContent = "this is not sudoers syntax\n"
        XCTAssertThrowsError(try broken.install(helperSource: source)) { error in
            XCTAssertEqual((error as? ChargeLightError)?.code, "io_error")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.sudoersTempFile.path))
        XCTAssertEqual(try String(contentsOf: installer.sudoersFile, encoding: .utf8), Installer.sudoersRule,
                       "the previous valid rule is untouched")
    }

    func testValidationCanBeSkipped() throws {
        var unchecked = installer!
        unchecked.visudoPath = nil
        unchecked.sudoersContent = "anything\n"
        _ = try unchecked.install(helperSource: source)
        XCTAssertEqual(try String(contentsOf: unchecked.sudoersFile, encoding: .utf8), "anything\n")
    }

    func testMissingSourceFails() {
        XCTAssertThrowsError(try installer.install(helperSource: home.url.appendingPathComponent("nope")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.helperDestination.path))
    }

    func testUninstall() throws {
        XCTAssertEqual(try installer.uninstall(), [])
        _ = try installer.install(helperSource: source)
        let removed = try installer.uninstall()
        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), ["chargelight", "chargelight-helper"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.helperDestination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.sudoersFile.path))
    }

    func testLocateHelper() throws {
        let fm = FileManager.default
        // Homebrew layout: bin/chargelight -> ../Cellar/chargelight/0.1.0/bin/chargelight,
        // helper in Cellar/.../libexec.
        let cellar = home.url.appendingPathComponent("Cellar/chargelight/1.0")
        try fm.createDirectory(at: cellar.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: cellar.appendingPathComponent("libexec"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.url.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let exe = cellar.appendingPathComponent("bin/chargelight")
        try Data().write(to: exe)
        let link = home.url.appendingPathComponent("bin/chargelight")
        try fm.createSymbolicLink(at: link, withDestinationURL: exe)

        XCTAssertNil(Installer.locateHelper(executablePath: link.path))

        let libexecHelper = cellar.appendingPathComponent("libexec/chargelight-helper")
        try fm.copyItem(at: source, to: libexecHelper)
        XCTAssertEqual(
            Installer.locateHelper(executablePath: link.path)?.resolvingSymlinksInPath().path,
            libexecHelper.resolvingSymlinksInPath().path)

        // A helper next to the binary (SwiftPM build directory) wins.
        let sibling = cellar.appendingPathComponent("bin/chargelight-helper")
        try fm.copyItem(at: source, to: sibling)
        XCTAssertEqual(
            Installer.locateHelper(executablePath: link.path)?.resolvingSymlinksInPath().path,
            sibling.resolvingSymlinksInPath().path)
    }
}
