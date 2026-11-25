import ChargeLight
import XCTest

final class ConfigurationTests: XCTestCase {
    func testDefaults() {
        let c = Configuration()
        XCTAssertEqual(c.led(for: .working), .amber)
        XCTAssertEqual(c.led(for: .attention), .blinkFast)
        XCTAssertEqual(c.led(for: .ready), .green)
        XCTAssertEqual(c.leds.idle, .system)
        XCTAssertEqual(c.ttl(for: .working), 1800)
        XCTAssertEqual(c.ttl(for: .attention), 7200)
        XCTAssertEqual(c.ttl(for: .ready), 600)
    }

    func testMissingFileGivesDefaults() throws {
        let home = TempHome()
        XCTAssertEqual(try Configuration.load(paths: home.paths, environment: [:]), Configuration())
    }

    func testFullAndPartialFiles() throws {
        let full = """
            {"leds":{"working":"blink-slow","attention":"amber","ready":"off","idle":"green"},
             "ttl":{"working":60,"attention":120,"ready":30}}
            """
        let c = try Configuration.decode(Data(full.utf8))
        XCTAssertEqual(c.leds.working, .blinkSlow)
        XCTAssertEqual(c.leds.attention, .amber)
        XCTAssertEqual(c.leds.ready, .off)
        XCTAssertEqual(c.leds.idle, .green)
        XCTAssertEqual(c.ttl(for: .working), 60)
        XCTAssertEqual(c.ttl(for: .attention), 120)
        XCTAssertEqual(c.ttl(for: .ready), 30)

        let partial = try Configuration.decode(Data(#"{"leds":{"ready":"off"}}"#.utf8))
        XCTAssertEqual(partial.leds.ready, .off)
        XCTAssertEqual(partial.leds.working, .amber)
        XCTAssertEqual(partial.ttl, Configuration.TTLs())
        XCTAssertEqual(try Configuration.decode(Data("{}".utf8)), Configuration())
    }

    func testRoundTrip() throws {
        var c = Configuration()
        c.leds.attention = .blinkSlow
        c.ttl.ready = 42
        XCTAssertEqual(try Configuration.decode(try JSONEncoder().encode(c)), c)
    }

    func testInvalidFileValuesNameTheKey() {
        let cases: [(String, String)] = [
            (#"{"leds":{"working":"purple"}}"#, "leds.working"),
            (#"{"leds":{"idle":3}}"#, "leds.idle"),
            (#"{"ttl":{"ready":-5}}"#, "ttl.ready"),
            (#"{"ttl":{"attention":"1h"}}"#, "ttl.attention"),
            (#"{"leds":[]}"#, "leds"),
            ("not json", "not valid JSON"),
        ]
        for (json, key) in cases {
            XCTAssertThrowsError(try Configuration.decode(Data(json.utf8)), json) { error in
                guard case .invalidArgument(let message)? = error as? ChargeLightError else {
                    return XCTFail("expected invalidArgument, got \(error)")
                }
                XCTAssertTrue(message.contains(key), "\(message) should mention \(key)")
            }
        }
    }

    func testEnvironmentOverridesFile() throws {
        let home = TempHome()
        try Data(#"{"leds":{"working":"green","ready":"off"}}"#.utf8).write(to: home.paths.configFile)
        let c = try Configuration.load(paths: home.paths, environment: [
            "CHARGELIGHT_LED_WORKING": "blink-slow",
            "CHARGELIGHT_LED_ATTENTION": "amber",
            "CHARGELIGHT_LED_IDLE": "off",
            "CHARGELIGHT_LED_READY": "",
        ])
        XCTAssertEqual(c.leds.working, .blinkSlow, "env beats file")
        XCTAssertEqual(c.leds.attention, .amber)
        XCTAssertEqual(c.leds.ready, .off, "empty env value is ignored")
        XCTAssertEqual(c.leds.idle, .off)
    }

    func testInvalidEnvironmentValueNamesTheVariable() {
        let home = TempHome()
        XCTAssertThrowsError(
            try Configuration.load(paths: home.paths, environment: ["CHARGELIGHT_LED_READY": "rainbow"])
        ) { error in
            XCTAssertEqual((error as? ChargeLightError)?.code, "invalid_argument")
            XCTAssertTrue((error as? ChargeLightError)?.message.contains("CHARGELIGHT_LED_READY") == true)
        }
    }

    func testInvalidConfigFileMessageIncludesPath() {
        let home = TempHome()
        try? Data(#"{"leds":{"working":"purple"}}"#.utf8).write(to: home.paths.configFile)
        XCTAssertThrowsError(try Configuration.load(paths: home.paths, environment: [:])) { error in
            let message = (error as? ChargeLightError)?.message ?? ""
            XCTAssertTrue(message.contains("config.json"), message)
            XCTAssertTrue(message.contains("leds.working"), message)
        }
    }
}
