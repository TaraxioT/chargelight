@testable import ChargeLight
import XCTest

/// Claims with priorities, patterns and overrides (0.2).
final class SharedLightTests: XCTestCase {
    var home: TempHome!
    var backend: CountingBackend!
    var light: StatusLight!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        home = TempHome()
        backend = CountingBackend()
        light = StatusLight(paths: home.paths, backend: backend)
    }

    override func tearDown() {
        light = nil
        home = nil
    }

    func testVersion01ClaimFileStillLoads() throws {
        try FileManager.default.createDirectory(at: home.paths.claimsDirectory, withIntermediateDirectories: true)
        let legacy = """
            {"expiresAt":"2027-01-15T08:30:00.000Z","id":"claude:old","label":"proj","stamp":7,
             "status":"attention","updatedAt":"2027-01-15T08:00:00Z"}
            """
        try Data(legacy.utf8).write(to: home.paths.claimFile(for: "claude:old"))
        let now = ISO8601DateFormatter().date(from: "2027-01-15T08:10:00Z")!
        let snapshot = light.snapshot(now: now)
        let claim = try XCTUnwrap(snapshot.claims.first)
        XCTAssertEqual(claim.show, "attention")
        XCTAssertEqual(claim.priority, 30, "priority comes from the built-in preset")
        XCTAssertEqual(claim.status, .attention)
        XCTAssertEqual(claim.label, "proj")
        XCTAssertEqual(snapshot.desired, .blinkFast)

        // A working claim from 0.1 ranks below it, as before.
        let working = legacy.replacingOccurrences(of: "attention", with: "working")
            .replacingOccurrences(of: "claude:old", with: "claude:w")
        try Data(working.utf8).write(to: home.paths.claimFile(for: "claude:w"))
        XCTAssertEqual(light.snapshot(now: now).claims.map(\.priority), [30, 20])

        // Rewritten in the 0.2 format on renewal.
        _ = try light.claim(id: "claude:old", status: .ready, stamp: 8, now: now)
        let stored = try String(contentsOf: home.paths.claimFile(for: "claude:old"), encoding: .utf8)
        XCTAssertTrue(stored.contains(#""show":"ready""#), stored)
        XCTAssertTrue(stored.contains(#""priority":10"#), stored)
        // The 0.1 key is kept for built-in presets, so a 0.1 watcher still
        // running right after an upgrade understands the claim; other claims omit it.
        XCTAssertTrue(stored.contains(#""status":"ready""#), stored)
        _ = try light.claim(id: "custom", show: "green:300,off:300", stamp: 9, now: now)
        let custom = try String(contentsOf: home.paths.claimFile(for: "custom"), encoding: .utf8)
        XCTAssertFalse(custom.contains("status"), custom)
    }

    func testExplicitPriorityBeatsBuiltInsBothWays() throws {
        _ = try light.claim(id: "agent", status: .attention, stamp: 1, now: t0)
        let high = try light.claim(id: "deploy", show: "green:300,off:300", priority: 50, stamp: 1, now: t0)
        XCTAssertEqual(high.winner?.id, "deploy")
        XCTAssertEqual(high.led.description, "green:300,off:300")
        XCTAssertEqual(backend.writes.last, .green, "without a watcher a pattern shows its first step")

        _ = try light.release(id: "deploy", stamp: 1, now: t0)
        _ = try light.release(id: "agent", stamp: 1, now: t0)
        _ = try light.claim(id: "agent", status: .ready, stamp: 2, now: t0)
        let low = try light.claim(id: "chore", show: "amber", priority: 5, stamp: 2, now: t0.addingTimeInterval(1))
        XCTAssertEqual(low.winner?.id, "agent", "ready (10) beats a newer claim at 5")
        XCTAssertEqual(low.led, .green)

        let negative = try light.claim(id: "neg", show: "off", priority: -3, stamp: 2, now: t0)
        XCTAssertEqual(negative.claim?.priority, -3)
        XCTAssertEqual(negative.claims.map(\.id), ["agent", "chore", "neg"])
    }

    func testDefaultPriorityAndTTLForNonPresets() throws {
        let result = try light.claim(id: "x", show: "heartbeat", stamp: 1, now: t0)
        XCTAssertEqual(result.claim?.priority, Configuration.defaultPriority)
        XCTAssertEqual(result.claim?.expiresAt, t0.addingTimeInterval(Configuration.defaultTTL))
        XCTAssertEqual(result.led.description, "heartbeat")
        XCTAssertThrowsError(try light.claim(id: "y", show: "nope", now: t0))
        XCTAssertThrowsError(try light.claim(id: "y", show: "green:10", now: t0))
    }

    func testUnresolvableClaimIsPassedOver() throws {
        var configuration = Configuration()
        configuration.patterns["deploy"] = try Pattern(parsing: "green:100,off:100", name: "deploy")
        let configured = StatusLight(paths: home.paths, backend: backend, configuration: configuration)
        _ = try configured.claim(id: "low", show: "ready", stamp: 1, now: t0)
        _ = try configured.claim(id: "high", show: "deploy", priority: 90, stamp: 1, now: t0)
        XCTAssertEqual(configured.snapshot(now: t0).desired.description, "deploy")

        // The pattern is gone from the configuration: the claim stays but no longer decides.
        let snapshot = light.snapshot(now: t0)
        XCTAssertEqual(snapshot.claims.map(\.id), ["high", "low"])
        XCTAssertEqual(snapshot.desired, .green)
        let result = try light.sync(now: t0)
        XCTAssertEqual(result.led, .green)
        XCTAssertEqual(result.claims.count, 2)
    }

    func testOverrideWithAPattern() throws {
        _ = try light.claim(id: "s", status: .attention, stamp: 1, now: t0)
        let result = try light.setOverride(show: "alternate", ttl: 30, now: t0)
        XCTAssertEqual(result.override?.show, "alternate")
        XCTAssertEqual(result.led.description, "alternate")
        XCTAssertEqual(backend.writes.last, .amber)
        XCTAssertEqual(light.readApplied()?.show, "alternate")
        let literal = try light.setOverride(show: "off:100,green:100", now: t0)
        XCTAssertEqual(literal.led.pattern?.literal, "off:100,green:100")
        XCTAssertThrowsError(try light.setOverride(show: "working", now: t0), "presets are for claims")
        XCTAssertThrowsError(try light.setOverride(show: "amber:1", now: t0))
        XCTAssertEqual(try light.setOverride(show: "system", now: t0).led, .blinkFast)
    }

    func testIdleCheckWaitsUntilExpiredClaimsAreCleared() throws {
        // Expired after the watcher's last sync: the idle state is not applied yet.
        let past = Date().addingTimeInterval(-10)
        _ = try light.claim(id: "s", status: .working, ttl: 1, stamp: 1, now: past)
        XCTAssertFalse(try light.ifIdle {})
        _ = try light.sync()
        XCTAssertEqual(backend.writes.last, .system)
        XCTAssertTrue(try light.ifIdle {})

        _ = try light.setOverride(show: "off", ttl: 1, now: past)
        XCTAssertFalse(try light.ifIdle {})
        _ = try light.sync()
        XCTAssertTrue(try light.ifIdle {})
    }

    func testNextExpiry() throws {
        XCTAssertNil(try light.sync(now: t0).nextExpiry)
        _ = try light.claim(id: "a", status: .working, ttl: 100, stamp: 1, now: t0)
        XCTAssertEqual(try light.claim(id: "b", status: .ready, ttl: 10, stamp: 1, now: t0).nextExpiry, t0.addingTimeInterval(10))
        XCTAssertEqual(try light.setOverride(show: "off", ttl: 5, now: t0).nextExpiry, t0.addingTimeInterval(5))
        XCTAssertEqual(try light.setOverride(show: "off", now: t0).nextExpiry, t0.addingTimeInterval(10), "an endless override")
    }
}

/// The watcher playing patterns and ending claims on time, with the file backend.
final class WatcherPatternTests: XCTestCase {
    /// Runs the watcher on a background thread; the returned expectation is
    /// fulfilled when it exits.
    func startWatcher(_ light: StatusLight) -> XCTestExpectation {
        let done = expectation(description: "watcher exits")
        Thread.detachNewThread {
            Watcher.run(light: light)
            done.fulfill()
        }
        return done
    }

    /// Reads the LED file every 10 ms for `duration` seconds.
    func sample(_ home: TempHome, for duration: TimeInterval) -> [(time: TimeInterval, state: String)] {
        var samples: [(TimeInterval, String)] = []
        let start = Date()
        while Date().timeIntervalSince(start) < duration {
            if let state = home.ledFile, !state.isEmpty { samples.append((Date().timeIntervalSince(start), state)) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return samples
    }

    func testPatternClaimAlternatesTheLED() throws {
        let home = TempHome()
        let light = StatusLight(paths: home.paths, backend: FileBackend(url: home.paths.ledFile))
        _ = try light.claim(id: "p", show: "amber:100,off:100", ttl: 1.2, apply: false)
        let done = startWatcher(light)
        let samples = sample(home, for: 1.0)
        var runs: [String] = []
        for sample in samples where runs.last != sample.state { runs.append(sample.state) }
        XCTAssertGreaterThanOrEqual(runs.count, 7, "\(runs)")
        XCTAssertTrue(runs.allSatisfy { $0 == "amber" || $0 == "off" }, "\(runs)")
        wait(for: [done], timeout: 5)
        XCTAssertEqual(home.ledFile, "system", "back to idle once the claim expires")
    }

    func testShortClaimEndsOnTime() throws {
        let home = TempHome()
        let light = StatusLight(paths: home.paths, backend: FileBackend(url: home.paths.ledFile))
        _ = try light.claim(id: "base", show: "green", ttl: 1.5, apply: false)
        let short = try XCTUnwrap(try light.claim(
            id: "notice", show: "amber", priority: Configuration.noticePriority, ttl: 0.4, apply: false).claim)
        let done = startWatcher(light)
        let start = Date()
        let samples = sample(home, for: 1.0)
        let end = short.expiresAt.timeIntervalSince(start)
        XCTAssertEqual(samples.first?.state, "amber")
        let back = try XCTUnwrap(samples.first { $0.state == "green" }, "\(samples)")
        XCTAssertGreaterThan(back.time, end - 0.02, "not before the claim expires")
        XCTAssertLessThan(back.time, end + 0.15, "green \(back.time - end) s after the expiry")
        XCTAssertTrue(samples.drop { $0.state != "green" }.allSatisfy { $0.state == "green" })
        wait(for: [done], timeout: 5)
    }

    func testFirstTickReappliesWhatANewWatcherFinds() throws {
        let home = TempHome()
        let light = StatusLight(paths: home.paths, backend: FileBackend(url: home.paths.ledFile))
        // Recorded as applied by an earlier writer (a watcher that crashed
        // mid-pattern): the new watcher must still play it.
        _ = try light.claim(id: "p", show: "off:100,green:100", ttl: 0.8)
        XCTAssertEqual(home.ledFile, "off")
        let done = startWatcher(light)
        let states = Set(sample(home, for: 0.5).map(\.state))
        XCTAssertEqual(states, ["off", "green"])
        wait(for: [done], timeout: 5)
    }
}
