import ChargeLight
import XCTest

final class ConfigurationTests: XCTestCase {
    func assertInvalid(_ json: String, mentions key: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Configuration.decode(Data(json.utf8)), json, file: file, line: line) { error in
            guard case .invalidArgument(let message)? = error as? ChargeLightError else {
                return XCTFail("expected invalidArgument, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(message.contains(key), "\(message) should mention \(key)", file: file, line: line)
        }
    }

    func testDefaults() throws {
        let c = Configuration()
        XCTAssertEqual(c.led(for: .working), .amber)
        XCTAssertEqual(c.led(for: .attention), .blinkFast)
        XCTAssertEqual(c.led(for: .ready), .green)
        XCTAssertEqual(c.idle, .system)
        XCTAssertEqual(c.ttl(for: .working), 1800)
        XCTAssertEqual(c.ttl(for: .attention), 7200)
        XCTAssertEqual(c.ttl(for: .ready), 600)
        XCTAssertEqual(c.presets, Configuration.builtInPresets)
        XCTAssertEqual(c.patterns, Pattern.builtIn)
        XCTAssertEqual(c.presets["attention"]?.priority, 30)
        XCTAssertEqual(c.presets["working"]?.priority, 20)
        XCTAssertEqual(c.presets["ready"]?.priority, 10)
    }

    func testResolve() throws {
        let c = Configuration()
        XCTAssertEqual(try c.resolve("working"), .amber, "a preset")
        XCTAssertEqual(try c.resolve("off"), .off, "a state")
        XCTAssertEqual(try c.resolve("heartbeat"), .pattern(Pattern.builtIn["heartbeat"]!), "a pattern name")
        XCTAssertEqual(try c.resolve("green:300,off:0.3s").pattern?.literal, "green:300,off:300", "a literal")
        XCTAssertThrowsError(try c.resolveLED("working"), "resolveLED takes no presets")
        XCTAssertThrowsError(try c.resolve("purple"))
        XCTAssertThrowsError(try c.resolve("green:10,off:300"), "step too short")
        XCTAssertEqual(c.preset("ready")?.led, "green")
        XCTAssertNil(c.preset("green"))
    }

    func testMissingFileGivesDefaults() throws {
        let home = TempHome()
        XCTAssertEqual(try Configuration.load(paths: home.paths, environment: [:]), Configuration())
        XCTAssertEqual(try Configuration.decode(Data("{}".utf8)), Configuration())
    }

    func testLegacyLedsAndTTLKeys() throws {
        let full = """
            {"leds":{"working":"blink-slow","attention":"amber","ready":"off","idle":"green"},
             "ttl":{"working":60,"attention":120,"ready":30}}
            """
        let c = try Configuration.decode(Data(full.utf8))
        XCTAssertEqual(c.led(for: .working), .blinkSlow)
        XCTAssertEqual(c.led(for: .attention), .amber)
        XCTAssertEqual(c.led(for: .ready), .off)
        XCTAssertEqual(c.idle, .green)
        XCTAssertEqual(c.ttl(for: .working), 60)
        XCTAssertEqual(c.ttl(for: .attention), 120)
        XCTAssertEqual(c.ttl(for: .ready), 30)
        XCTAssertEqual(c.presets["working"]?.priority, 20, "leds and ttl leave priorities alone")

        let partial = try Configuration.decode(Data(#"{"leds":{"ready":"heartbeat-green"}}"#.utf8))
        XCTAssertEqual(partial.led(for: .ready), .pattern(Pattern.builtIn["heartbeat-green"]!), "leds may name patterns")
        XCTAssertEqual(partial.led(for: .working), .amber)
        XCTAssertEqual(partial.ttl(for: .ready), 600)
    }

    func testPresetsAndPatterns() throws {
        let json = """
            {
              "idle": "off",
              "patterns": { "triple": "green:100,off:100,green:100,off:600", "heartbeat": "green:200,off:800" },
              "presets": {
                "deploy": { "led": "triple", "priority": 25, "ttl": 900 },
                "ci": { "led": "blue-ish:1", "priority": 5 },
                "attention": { "priority": 40 },
                "ready": { "led": "heartbeat", "ttl": 60 }
              }
            }
            """
        XCTAssertThrowsError(try Configuration.decode(Data(json.utf8)), "ci shows something invalid")
        let fixed = json.replacingOccurrences(of: "blue-ish:1", with: "alternate")
        let c = try Configuration.decode(Data(fixed.utf8))
        XCTAssertEqual(c.idle, .off)
        XCTAssertEqual(c.presets["deploy"], Preset(led: "triple", priority: 25, ttl: 900))
        XCTAssertEqual(c.presets["ci"], Preset(led: "alternate", priority: 5, ttl: Configuration.defaultTTL))
        XCTAssertEqual(c.presets["attention"], Preset(led: "blink-fast", priority: 40, ttl: 7200), "only priority changed")
        XCTAssertEqual(c.presets["ready"], Preset(led: "heartbeat", priority: 10, ttl: 60))
        XCTAssertEqual(c.presets["working"], Configuration.builtInPresets["working"])
        XCTAssertEqual(try c.resolve("deploy").pattern?.literal, "green:100,off:100,green:100,off:600")
        XCTAssertEqual(try c.resolve("deploy").description, "triple")
        XCTAssertEqual(try c.resolve("heartbeat").pattern?.literal, "green:200,off:800", "a file pattern replaces a built-in")
        XCTAssertEqual(try c.resolve("ready").description, "heartbeat")
        XCTAssertEqual(c.patterns["sos"], Pattern.builtIn["sos"], "other built-ins stay")
    }

    func testInvalidFileValuesNameTheKey() {
        let cases: [(String, String)] = [
            (#"{"leds":{"working":"purple"}}"#, "leds.working"),
            (#"{"leds":{"idle":3}}"#, "leds.idle"),
            (#"{"leds":{"idle":"heartbeat"}}"#, "leds.idle"),
            (#"{"leds":{"deploy":"amber"}}"#, "leds.deploy"),
            (#"{"ttl":{"ready":-5}}"#, "ttl.ready"),
            (#"{"ttl":{"attention":"1h"}}"#, "ttl.attention"),
            (#"{"ttl":{"deploy":5}}"#, "ttl.deploy"),
            (#"{"leds":[]}"#, "leds"),
            (#"{"idle":"blink"}"#, "idle"),
            (#"{"colour":"amber"}"#, "colour"),
            ("[]", "top level"),
            ("not json", "not valid JSON"),
            // presets
            (#"{"presets":{"deploy":{"priority":5}}}"#, "presets.deploy.led"),
            (#"{"presets":{"deploy":{"led":"amber","priority":"high"}}}"#, "presets.deploy.priority"),
            (#"{"presets":{"deploy":{"led":"amber","priority":1.5}}}"#, "presets.deploy.priority"),
            (#"{"presets":{"deploy":{"led":"amber","ttl":0}}}"#, "presets.deploy.ttl"),
            (#"{"presets":{"deploy":{"led":"amber","colour":"x"}}}"#, "presets.deploy.colour"),
            (#"{"presets":{"deploy":{"led":"nope"}}}"#, "presets.deploy.led"),
            (#"{"presets":{"deploy":"amber"}}"#, "presets.deploy"),
            (#"{"presets":{"amber":{"led":"green"}}}"#, "presets.amber"),
            (#"{"presets":{"heartbeat":{"led":"green"}}}"#, "presets.heartbeat"),
            (#"{"presets":{"bad name":{"led":"green"}}}"#, "presets.bad name"),
            // patterns
            (#"{"patterns":{"off":"green:100,off:100"}}"#, "patterns.off"),
            (#"{"patterns":{"working":"green:100,off:100"}}"#, "patterns.working"),
            (#"{"patterns":{"-x":"green:100,off:100"}}"#, "patterns.-x"),
            (#"{"patterns":{"p":"green:10,off:100"}}"#, "patterns.p"),
            (#"{"patterns":{"p":"purple:100"}}"#, "patterns.p"),
            (#"{"patterns":{"p":5}}"#, "patterns.p"),
            (#"{"patterns":{"p":""}}"#, "patterns.p"),
        ]
        for (json, key) in cases {
            assertInvalid(json, mentions: key)
        }
    }

    func testEnvironmentOverridesFile() throws {
        let home = TempHome()
        try Data(#"{"leds":{"working":"green","ready":"off"}}"#.utf8).write(to: home.paths.configFile)
        let c = try Configuration.load(paths: home.paths, environment: [
            "CHARGELIGHT_LED_WORKING": "blink-slow",
            "CHARGELIGHT_LED_ATTENTION": "sos",
            "CHARGELIGHT_LED_IDLE": "off",
            "CHARGELIGHT_LED_READY": "",
        ])
        XCTAssertEqual(c.led(for: .working), .blinkSlow, "env beats file")
        XCTAssertEqual(c.led(for: .attention).description, "sos", "env may name a pattern")
        XCTAssertEqual(c.led(for: .ready), .off, "empty env value is ignored")
        XCTAssertEqual(c.idle, .off)
    }

    func testInvalidEnvironmentValueNamesTheVariable() {
        let home = TempHome()
        for (name, value) in [("CHARGELIGHT_LED_READY", "rainbow"), ("CHARGELIGHT_LED_IDLE", "heartbeat")] {
            XCTAssertThrowsError(try Configuration.load(paths: home.paths, environment: [name: value])) { error in
                XCTAssertEqual((error as? ChargeLightError)?.code, "invalid_argument")
                XCTAssertTrue((error as? ChargeLightError)?.message.contains(name) == true, "\(error)")
            }
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
