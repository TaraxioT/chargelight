@testable import ChargeLight
import XCTest

final class LEDStateTests: XCTestCase {
    func testBytes() {
        let expected: [LEDState: UInt8] = [
            .system: 0x00, .off: 0x01, .green: 0x03, .amber: 0x04, .blinkSlow: 0x06, .blinkFast: 0x07,
        ]
        for state in LEDState.allCases {
            XCTAssertEqual(state.byte, expected[state], "\(state)")
            XCTAssertEqual(LEDState(byte: state.byte), state)
        }
    }

    func testDecodingQuirksAndUnknownBytes() {
        XCTAssertEqual(LEDState(byte: 0x02), .green)
        XCTAssertNil(LEDState(byte: 0x05))
        XCTAssertNil(LEDState(byte: 0xFF))
        XCTAssertEqual(LEDReading(raw: 0x02).state, .green)
        XCTAssertNil(LEDReading(raw: 0x08).state)
    }

    func testNames() {
        XCTAssertEqual(LEDState.allCases.map(\.rawValue), ["system", "off", "green", "amber", "blink-slow", "blink-fast"])
        XCTAssertEqual(LEDState(rawValue: "blink-fast"), .blinkFast)
        XCTAssertNil(LEDState(rawValue: "blinkFast"))
    }

    func testErrorCodes() {
        let cases: [(ChargeLightError, String, Int32)] = [
            (.unsupportedHardware("x"), "unsupported_hardware", 3),
            (.setupRequired("x"), "setup_required", 4),
            (.notPrivileged("x"), "not_privileged", 5),
            (.smc("x"), "smc_error", 6),
            (.invalidArgument("x"), "invalid_argument", 2),
            (.io("x"), "io_error", 1),
        ]
        for (error, code, exit) in cases {
            XCTAssertEqual(error.code, code)
            XCTAssertEqual(error.exitCode, exit)
            XCTAssertEqual(error.errorDescription, "x")
        }
    }

    func testHelperExitCodeMapping() {
        XCTAssertNil(SMCBackend.helperError(status: 0, stderr: ""))
        XCTAssertEqual(SMCBackend.helperError(status: 3, stderr: "")?.code, "unsupported_hardware")
        XCTAssertEqual(SMCBackend.helperError(status: 5, stderr: "")?.code, "not_privileged")
        XCTAssertEqual(SMCBackend.helperError(status: 6, stderr: "boom")?.code, "smc_error")
        XCTAssertEqual(
            SMCBackend.helperError(status: 1, stderr: "sudo: a password is required\n"),
            .setupRequired("run: sudo chargelight setup"))
        XCTAssertEqual(
            SMCBackend.helperError(status: 1, stderr: "Sorry, user bob is not allowed to execute ..."),
            .setupRequired("run: sudo chargelight setup"))
        XCTAssertEqual(SMCBackend.helperError(status: 1, stderr: "weird")?.code, "smc_error")
    }

    func testSMCBackendWithoutHelperNeedsSetup() throws {
        try XCTSkipIf(geteuid() == 0, "running as root writes directly")
        let backend = SMCBackend(helperPath: "/nonexistent/chargelight-helper")
        XCTAssertThrowsError(try backend.write(.amber)) { error in
            XCTAssertEqual(error as? ChargeLightError, .setupRequired("run: sudo chargelight setup"))
        }
    }

    func testFileBackend() throws {
        let home = TempHome()
        let backend = FileBackend(url: home.paths.ledFile)
        XCTAssertEqual(try backend.read(), LEDReading(raw: 0x00))
        try backend.write(.blinkSlow)
        XCTAssertEqual(try backend.read().state, .blinkSlow)
        XCTAssertEqual(home.ledFile, "blink-slow")
        try "purple".write(to: home.paths.ledFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try backend.read())
    }

    func testBackendSelection() throws {
        let home = TempHome()
        XCTAssertTrue(try ChargeLight.backend(environment: ["CHARGELIGHT_BACKEND": "file"], paths: home.paths) is FileBackend)
        let smc = try ChargeLight.backend(environment: ["CHARGELIGHT_HELPER": "/x/helper"], paths: home.paths)
        XCTAssertEqual((smc as? SMCBackend)?.helperPath, "/x/helper")
        XCTAssertThrowsError(try ChargeLight.backend(environment: ["CHARGELIGHT_BACKEND": "usb"], paths: home.paths))
    }
}
