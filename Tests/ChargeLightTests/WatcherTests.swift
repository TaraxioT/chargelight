@testable import ChargeLight
import XCTest

final class WatcherTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testTickStopsWhenNoClaims() throws {
        let home = TempHome()
        let backend = CountingBackend()
        let light = StatusLight(paths: home.paths, backend: backend)
        let tick = try Watcher.tick(light: light, now: t0)
        XCTAssertFalse(tick.shouldContinue)
        XCTAssertEqual(tick.result.led, .system)
        XCTAssertEqual(backend.writes, [.system], "idle LED applied before exiting")
    }

    func testTickExpiresClaimsAndRestoresIdle() throws {
        let home = TempHome()
        let backend = CountingBackend()
        let light = StatusLight(paths: home.paths, backend: backend)
        _ = try light.claim(id: "s", status: .working, ttl: 5, stamp: 1, now: t0)
        XCTAssertTrue(try Watcher.tick(light: light, now: t0.addingTimeInterval(1)).shouldContinue)
        let last = try Watcher.tick(light: light, now: t0.addingTimeInterval(6))
        XCTAssertFalse(last.shouldContinue)
        XCTAssertEqual(last.result.expired.map(\.id), ["s"])
        XCTAssertEqual(backend.writes, [.amber, .system])
    }

    func testReplugRecovery() throws {
        let home = TempHome()
        let backend = CountingBackend()
        let light = StatusLight(paths: home.paths, backend: backend)
        _ = try light.claim(id: "s", status: .working, stamp: 1, now: t0)
        XCTAssertEqual(backend.writes, [.amber])

        // Charger replugged: firmware reports the system colour.
        backend.raw = 0x03
        var tick = try Watcher.tick(light: light, now: t0.addingTimeInterval(2))
        XCTAssertFalse(tick.reasserted, "within the settle time the readback is not trusted")
        XCTAssertEqual(backend.writes, [.amber])

        tick = try Watcher.tick(light: light, now: t0.addingTimeInterval(4))
        XCTAssertTrue(tick.reasserted)
        XCTAssertEqual(backend.writes, [.amber, .amber])

        // Hardware agrees now: nothing to do, even long after.
        tick = try Watcher.tick(light: light, now: t0.addingTimeInterval(60))
        XCTAssertFalse(tick.reasserted)
        XCTAssertEqual(backend.writes.count, 2)

        // Drift again; the settle time counts from the re-write.
        backend.raw = 0x02
        XCTAssertFalse(try Watcher.tick(light: light, now: t0.addingTimeInterval(6)).reasserted)
        XCTAssertTrue(try Watcher.tick(light: light, now: t0.addingTimeInterval(61)).reasserted)
    }

    func testNoReassertForSystemOrUnknownMatch() throws {
        let home = TempHome()
        let backend = CountingBackend()
        var configuration = Configuration()
        configuration.leds.working = .system
        let light = StatusLight(paths: home.paths, backend: backend, configuration: configuration)
        _ = try light.claim(id: "s", status: .working, stamp: 1, now: t0)
        backend.raw = 0x04
        XCTAssertFalse(try Watcher.tick(light: light, now: t0.addingTimeInterval(60)).reasserted,
                       "system shows amber or green; never fight it")
    }

    func testReplugWithFileBackend() throws {
        let home = TempHome()
        let backend = FileBackend(url: home.paths.ledFile)
        let light = StatusLight(paths: home.paths, backend: backend)
        _ = try light.claim(id: "s", status: .attention, stamp: 1, now: t0)
        try backend.write(.system)  // simulate replug
        XCTAssertTrue(try Watcher.tick(light: light, now: t0.addingTimeInterval(10)).reasserted)
        XCTAssertEqual(home.ledFile, "blink-fast")
    }

    func testRunExitsWhenClaimsExpire() throws {
        let home = TempHome()
        let backend = FileBackend(url: home.paths.ledFile)
        let light = StatusLight(paths: home.paths, backend: backend)
        _ = try light.claim(id: "s", status: .working, ttl: 0.3)
        XCTAssertEqual(home.ledFile, "amber")
        let start = Date()
        XCTAssertTrue(Watcher.run(light: light, interval: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(home.ledFile, "system")
        XCTAssertFalse(Watcher.isRunning(paths: home.paths))
    }

    func testRunWritesThroughAHoldAndReactsToClaimChanges() throws {
        let home = TempHome()
        let backend = HoldingBackend()
        let light = StatusLight(paths: home.paths, backend: backend)
        _ = try light.claim(id: "s", status: .working, ttl: 30, apply: false)
        XCTAssertTrue(backend.direct.isEmpty)

        // A second "process" changes the claim while the watcher runs, then
        // releases it. The long interval proves the directory watch wakes it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            _ = try? light.claim(id: "s", status: .attention, ttl: 30, apply: false)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
            _ = try? light.release(id: "s", apply: false)
        }
        let start = Date()
        XCTAssertTrue(Watcher.run(light: light, interval: 30))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "woken by claim changes, not by the interval")

        XCTAssertEqual(backend.hold.states, [.amber, .blinkFast, .system])
        XCTAssertTrue(backend.direct.isEmpty, "every write goes through the hold")
        XCTAssertEqual(backend.hold.stops, [false], "idle exit leaves the idle state as written")
        XCTAssertFalse(Watcher.isRunning(paths: home.paths))
    }

    func testRunKeepsRunningForAnOverrideAlone() throws {
        let home = TempHome()
        let backend = HoldingBackend()
        let light = StatusLight(paths: home.paths, backend: backend)
        _ = try light.setOverride(.off, ttl: 0.3, apply: false)
        XCTAssertTrue(Watcher.run(light: light, interval: 0.05))
        XCTAssertEqual(backend.hold.states, [.off, .system])
    }

    func testApplyWritesInlineWhenTheWatcherIsDisabled() throws {
        let home = TempHome()
        let backend = CountingBackend()
        let light = StatusLight(paths: home.paths, backend: backend)
        _ = try light.claim(id: "s", status: .working, apply: false)
        try Watcher.apply(light: light, executablePath: "/nonexistent", environment: ["CHARGELIGHT_NO_WATCHER": "1"])
        XCTAssertEqual(backend.writes, [.amber])
        XCTAssertFalse(Watcher.isRunning(paths: home.paths))

        // Idle with no watcher running: the idle state is written directly.
        _ = try light.release(id: "s", apply: false)
        try Watcher.apply(light: light, executablePath: "/nonexistent", environment: [:])
        XCTAssertEqual(backend.writes, [.amber, .system])
    }

    func testRunExitsImmediatelyIfAnotherWatcherHoldsTheLock() throws {
        let home = TempHome()
        let light = StatusLight(paths: home.paths, backend: CountingBackend())
        XCTAssertFalse(Watcher.isRunning(paths: home.paths))
        let lock = try XCTUnwrap(try FileLock.tryExclusive(home.paths.watcherLockFile, create: true))
        XCTAssertTrue(Watcher.isRunning(paths: home.paths))
        _ = try light.claim(id: "s", status: .working)
        XCTAssertFalse(Watcher.run(light: light, interval: 0.01))
        lock.unlock()
        XCTAssertFalse(Watcher.isRunning(paths: home.paths))
    }

    func testEnsureRunningHonoursOptOut() throws {
        let home = TempHome()
        let pid = try Watcher.ensureRunning(
            paths: home.paths, executablePath: "/nonexistent", environment: ["CHARGELIGHT_NO_WATCHER": "1"])
        XCTAssertNil(pid)
    }

    func testEnsureRunningSkipsWhenAlreadyRunning() throws {
        let home = TempHome()
        let lock = try XCTUnwrap(try FileLock.tryExclusive(home.paths.watcherLockFile, create: true))
        defer { lock.unlock() }
        XCTAssertNil(try Watcher.ensureRunning(paths: home.paths, executablePath: "/nonexistent", environment: [:]))
    }
}
