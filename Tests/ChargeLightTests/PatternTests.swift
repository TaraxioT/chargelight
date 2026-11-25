@testable import ChargeLight
import XCTest

final class PatternTests: XCTestCase {
    func testParsingDurationForms() throws {
        let pattern = try Pattern(parsing: "amber:300, off:300ms,green:0.5s,blink-fast:1S,off:62.5")
        XCTAssertEqual(pattern.steps.map(\.state), [.amber, .off, .green, .blinkFast, .off])
        let durations = pattern.steps.map(\.duration)
        for (actual, expected) in zip(durations, [0.3, 0.3, 0.5, 1, 0.0625]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-9)
        }
        XCTAssertNil(pattern.name)
        XCTAssertEqual(try Pattern(parsing: "green:100", name: "x").name, "x")
    }

    func testLiteralRoundTrip() throws {
        let pattern = try Pattern(parsing: "green:0.5s,off:250ms,amber:1000")
        XCTAssertEqual(pattern.literal, "green:500,off:250,amber:1000")
        XCTAssertEqual(try Pattern(parsing: pattern.literal), pattern)
        XCTAssertEqual(pattern.duration, 1.75, accuracy: 1e-9)
        for (name, builtIn) in Pattern.builtIn {
            // Morse durations are computed (3 x 0.15), so compare at millisecond precision.
            XCTAssertEqual(try Pattern(parsing: builtIn.literal).literal, builtIn.literal, name)
        }
    }

    func testLimits() throws {
        XCTAssertNoThrow(try Pattern(parsing: "amber:50"))
        XCTAssertNoThrow(try Pattern(parsing: "amber:60s"))
        XCTAssertThrowsError(try Pattern(parsing: "amber:49"))
        XCTAssertThrowsError(try Pattern(parsing: "amber:60.001s"))
        XCTAssertThrowsError(try Pattern(parsing: "amber:0"))
        let many = Array(repeating: "amber:50", count: Pattern.maximumSteps)
        XCTAssertEqual(try Pattern(parsing: many.joined(separator: ",")).steps.count, 512)
        XCTAssertThrowsError(try Pattern(parsing: (many + ["off:50"]).joined(separator: ",")))
        XCTAssertThrowsError(try Pattern(steps: []))
        for bad in ["", "amber", "amber:", ":300", "purple:300", "amber:-5", "amber:1e3", "amber:5m",
                    "amber:300,", "amber:300,,off:300", "amber:3:00", "amber:nan", "amber:1.2.3"] {
            XCTAssertThrowsError(try Pattern(parsing: bad), bad) { error in
                XCTAssertEqual((error as? ChargeLightError)?.code, "invalid_argument", bad)
            }
        }
    }

    func testBuiltInsAreValid() {
        XCTAssertEqual(
            Set(Pattern.builtIn.keys),
            ["blink-green", "blink-green-fast", "alternate", "heartbeat", "heartbeat-green", "sos"])
        for (name, pattern) in Pattern.builtIn {
            XCTAssertEqual(pattern.name, name)
            XCTAssertFalse(pattern.steps.isEmpty)
            XCTAssertTrue(pattern.steps.allSatisfy { $0.duration >= Pattern.minimumStep && $0.duration <= Pattern.maximumStep })
            XCTAssertNil(LEDState(rawValue: name), "\(name) must not shadow a state")
        }
        XCTAssertEqual(Pattern.builtIn["heartbeat"]?.literal, "amber:120,off:120,amber:120,off:840")
    }

    func testMorse() throws {
        let sos = try Pattern.morse("SOS")
        XCTAssertEqual(sos.literal, [
            "amber:150,off:150,amber:150,off:150,amber:150,off:450",  // S
            "amber:450,off:150,amber:450,off:150,amber:450,off:450",  // O
            "amber:150,off:150,amber:150,off:150,amber:150,off:1050",  // S, then the word gap
        ].joined(separator: ","))
        XCTAssertEqual(Pattern.builtIn["sos"]?.literal, sos.literal)
        XCTAssertEqual(try Pattern.morse("sos"), sos, "case does not matter")

        // A word gap is seven units, not a letter gap plus a word gap; leading
        // and repeated separators add nothing.
        XCTAssertEqual(try Pattern.morse("  E  E!").literal, "amber:150,off:1050,amber:150,off:1050")
        XCTAssertEqual(try Pattern.morse("T", lit: .green, unit: 0.1).literal, "green:300,off:700")
        XCTAssertEqual(try Pattern.morse("0").steps.count, 10)
        XCTAssertEqual(try Pattern.morse("hi", name: "hi").name, "hi")
        for bad in ["", "   ", "!?", "\u{1F600}"] {
            XCTAssertThrowsError(try Pattern.morse(bad), bad)
        }
        XCTAssertThrowsError(try Pattern.morse("E", unit: 0.01), "steps below the minimum")
    }

    func testLEDSpec() throws {
        let heartbeat = try XCTUnwrap(Pattern.builtIn["heartbeat"])
        let literal = try Pattern(parsing: "green:300,off:300")
        XCTAssertEqual(LEDSpec.amber.description, "amber")
        XCTAssertEqual(LEDSpec.blinkSlow.description, "blink-slow")
        XCTAssertEqual(LEDSpec.pattern(heartbeat).description, "heartbeat")
        XCTAssertEqual(LEDSpec.pattern(literal).description, "green:300,off:300")
        XCTAssertEqual(LEDSpec.amber.firstState, .amber)
        XCTAssertEqual(LEDSpec.pattern(literal).firstState, .green)
        XCTAssertEqual(LEDSpec.amber.state, .amber)
        XCTAssertNil(LEDSpec.amber.pattern)
        XCTAssertEqual(LEDSpec.pattern(literal).pattern, literal)
        XCTAssertNil(LEDSpec.pattern(literal).state)
        XCTAssertNotEqual(LEDSpec.pattern(literal), LEDSpec.green)
    }
}

/// Records what a ``PatternPlayer`` writes.
final class Recorder {
    private let lock = NSLock()
    private var recorded: [LEDState] = []
    var states: [LEDState] { lock.lock(); defer { lock.unlock() }; return recorded }
    func write(_ state: LEDState) { lock.lock(); recorded.append(state); lock.unlock() }
}

final class PatternPlayerTests: XCTestCase {
    /// Whether `states` follows `cycle` in order from its start, wrapping around.
    func follows(_ states: [LEDState], _ cycle: [LEDState]) -> Bool {
        states.enumerated().allSatisfy { $0.element == cycle[$0.offset % cycle.count] }
    }

    func testPatternRepeatsInOrder() throws {
        let recorder = Recorder()
        let player = PatternPlayer { recorder.write($0) }
        defer { player.stop() }
        try player.show(.pattern(try Pattern(parsing: "amber:60,off:50,green:55")))
        Thread.sleep(forTimeInterval: 0.6)
        let states = recorder.states
        XCTAssertGreaterThanOrEqual(states.count, 7, "\(states)")
        XCTAssertLessThanOrEqual(states.count, 13, "\(states)")
        XCTAssertTrue(follows(states, [.amber, .off, .green]), "\(states)")
    }

    func testStateStopsThePattern() throws {
        let recorder = Recorder()
        let player = PatternPlayer { recorder.write($0) }
        defer { player.stop() }
        try player.show(.pattern(try Pattern(parsing: "amber:50,off:50")))
        Thread.sleep(forTimeInterval: 0.22)
        try player.show(.blinkFast)
        let atSwitch = recorder.states
        XCTAssertEqual(atSwitch.last, .blinkFast, "a fixed state is written at once")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(recorder.states, atSwitch, "nothing from the old pattern after the switch")
        XCTAssertTrue(follows(Array(atSwitch.dropLast()), [.amber, .off]))
    }

    func testShowingTheSamePatternDoesNotRestartIt() throws {
        let recorder = Recorder()
        let player = PatternPlayer { recorder.write($0) }
        defer { player.stop() }
        let pattern = LEDSpec.pattern(try Pattern(parsing: "amber:60,off:60,green:60"))
        try player.show(pattern)
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 0.07)
            try player.show(pattern)
        }
        let states = recorder.states
        XCTAssertTrue(follows(states, [.amber, .off, .green]), "a restart would write amber out of turn: \(states)")
        XCTAssertGreaterThanOrEqual(states.count, 6)
    }

    func testANewPatternReplacesTheOld() throws {
        let recorder = Recorder()
        let player = PatternPlayer { recorder.write($0) }
        defer { player.stop() }
        try player.show(.pattern(try Pattern(parsing: "amber:50,off:50")))
        Thread.sleep(forTimeInterval: 0.12)
        try player.show(.pattern(try Pattern(parsing: "green:50,blink-slow:50")))
        Thread.sleep(forTimeInterval: 0.02)
        let switchedAt = recorder.states.count
        Thread.sleep(forTimeInterval: 0.3)
        let after = Array(recorder.states[(switchedAt - 1)...])
        XCTAssertTrue(follows(after, [.green, .blinkSlow]), "\(after)")
    }

    func testDroppedPlayerStopsItsThread() throws {
        let recorder = Recorder()
        do {
            let player = PatternPlayer { recorder.write($0) }
            try player.show(.pattern(try Pattern(parsing: "amber:50,off:50")))
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.12)
        let count = recorder.states.count
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(recorder.states.count, count, "no writes once the player is gone")
    }
}
