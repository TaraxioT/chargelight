@testable import ChargeLight
import XCTest

final class StatusLightTests: XCTestCase {
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

    func testIdleFallbackWithoutClaims() throws {
        let result = try light.sync(now: t0)
        XCTAssertEqual(result.led, .system)
        XCTAssertTrue(result.claims.isEmpty)
        XCTAssertNil(result.winner)
        XCTAssertEqual(backend.writes, [.system])
    }

    func testPriorityAttentionOverWorkingOverReady() throws {
        XCTAssertEqual(try light.claim(id: "a", status: .ready, stamp: 1, now: t0).led, .green)
        XCTAssertEqual(try light.claim(id: "b", status: .working, stamp: 1, now: t0).led, .amber)
        XCTAssertEqual(try light.claim(id: "c", status: .attention, stamp: 1, now: t0).led, .blinkFast)
        // A later ready claim does not beat attention.
        let result = try light.claim(id: "d", status: .ready, stamp: 1, now: t0.addingTimeInterval(1))
        XCTAssertEqual(result.led, .blinkFast)
        XCTAssertEqual(result.winner?.id, "c")
        XCTAssertEqual(result.claims.map(\.id), ["c", "b", "d", "a"], "priority, then most recent")

        let snapshot = light.snapshot(now: t0.addingTimeInterval(2))
        XCTAssertEqual(snapshot.desired, .blinkFast)
        XCTAssertEqual(snapshot.winner?.id, "c")
        XCTAssertEqual(snapshot.claims.map(\.id), ["c", "b", "d", "a"])
        XCTAssertEqual(snapshot.applied?.show, "blink-fast")

        XCTAssertEqual(try light.release(id: "c", now: t0).led, .amber)
        XCTAssertEqual(try light.release(id: "b", now: t0).led, .green)
    }

    func testClaimRenewalChangesStatusAndKeepsLabel() throws {
        _ = try light.claim(id: "s", status: .working, label: "proj", stamp: 1, now: t0)
        let result = try light.claim(id: "s", status: .ready, stamp: 2, now: t0)
        XCTAssertEqual(result.claims.count, 1)
        XCTAssertEqual(result.claim?.status, .ready)
        XCTAssertEqual(result.claim?.label, "proj")
        XCTAssertEqual(result.led, .green)
    }

    func testDefaultAndCustomTTL() throws {
        let a = try light.claim(id: "a", status: .working, stamp: 1, now: t0)
        XCTAssertEqual(a.claim?.expiresAt, t0.addingTimeInterval(1800))
        let b = try light.claim(id: "b", status: .attention, stamp: 1, now: t0)
        XCTAssertEqual(b.claim?.expiresAt, t0.addingTimeInterval(7200))
        let c = try light.claim(id: "c", status: .ready, ttl: 5, stamp: 1, now: t0)
        XCTAssertEqual(c.claim?.expiresAt, t0.addingTimeInterval(5))
        XCTAssertThrowsError(try light.claim(id: "d", status: .ready, ttl: 0, now: t0))
        XCTAssertThrowsError(try light.claim(id: "", status: .ready, now: t0))
    }

    func testExpiryDropsClaimsAndFiles() throws {
        _ = try light.claim(id: "short", status: .attention, ttl: 10, stamp: 1, now: t0)
        _ = try light.claim(id: "long", status: .ready, ttl: 100, stamp: 1, now: t0)
        XCTAssertEqual(light.snapshot(now: t0.addingTimeInterval(5)).desired, .blinkFast)
        XCTAssertEqual(light.snapshot(now: t0.addingTimeInterval(10)).desired, .green, "expiry is inclusive")

        let result = try light.sync(now: t0.addingTimeInterval(11))
        XCTAssertEqual(result.led, .green)
        XCTAssertEqual(result.expired.map(\.id), ["short"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.claimFile(for: "short").path))

        let end = try light.sync(now: t0.addingTimeInterval(101))
        XCTAssertEqual(end.led, .system)
        XCTAssertTrue(end.claims.isEmpty)
        XCTAssertEqual(backend.writes.last, .system)
    }

    func testOrderingGuardIgnoresStaleStamps() throws {
        _ = try light.claim(id: "s", status: .attention, stamp: 200, now: t0)
        let stale = try light.claim(id: "s", status: .working, stamp: 100, now: t0.addingTimeInterval(1))
        XCTAssertFalse(stale.accepted)
        XCTAssertEqual(stale.claim?.status, .attention)
        XCTAssertEqual(stale.claim?.stamp, 200)
        XCTAssertEqual(stale.led, .blinkFast)

        let same = try light.claim(id: "s", status: .ready, stamp: 200, now: t0)
        XCTAssertTrue(same.accepted, "an equal stamp (same process) is accepted")
        let newer = try light.claim(id: "s", status: .working, stamp: 300, now: t0)
        XCTAssertTrue(newer.accepted)
        XCTAssertEqual(newer.led, .amber)
    }

    func testStaleStampAcceptedOnceStoredClaimExpired() throws {
        _ = try light.claim(id: "s", status: .working, ttl: 1, stamp: 500, now: t0)
        let result = try light.claim(id: "s", status: .ready, stamp: 100, now: t0.addingTimeInterval(5))
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.led, .green)
    }

    func testSyncWritesOnlyOnChange() throws {
        _ = try light.sync(now: t0)
        _ = try light.sync(now: t0)
        XCTAssertEqual(backend.writes, [.system])
        for i in 0..<5 {
            _ = try light.claim(id: "s", status: .working, stamp: UInt64(i), now: t0)
        }
        XCTAssertEqual(backend.writes, [.system, .amber], "renewing the same status must not rewrite")
        _ = try light.claim(id: "other", status: .ready, stamp: 1, now: t0)
        XCTAssertEqual(backend.writes, [.system, .amber], "a lower-priority claim does not change the LED")
        _ = try light.claim(id: "s", status: .attention, stamp: 10, now: t0)
        XCTAssertEqual(backend.writes, [.system, .amber, .blinkFast])
        XCTAssertEqual(light.readApplied(), AppliedState(show: "blink-fast", appliedAt: t0))
        XCTAssertTrue(try light.sync(now: t0, force: true).wrote)
        XCTAssertEqual(backend.writes.count, 4)
    }

    func testFailedWriteIsRetriedOnNextSync() throws {
        backend.failWrites = .setupRequired("run: sudo chargelight setup")
        XCTAssertThrowsError(try light.claim(id: "s", status: .working, stamp: 1, now: t0)) { error in
            XCTAssertEqual((error as? ChargeLightError)?.code, "setup_required")
        }
        XCTAssertEqual(light.snapshot(now: t0).claims.count, 1, "the claim is kept")
        backend.failWrites = nil
        XCTAssertTrue(try light.sync(now: t0).wrote)
        XCTAssertEqual(backend.writes, [.amber])
    }

    func testReleaseRejectsOlderClaimRequests() throws {
        _ = try light.claim(id: "s", status: .working, stamp: 100, now: t0)
        _ = try light.release(id: "s", stamp: 300, now: t0.addingTimeInterval(1))

        // A hook that started before the release but landed after it.
        let late = try light.claim(id: "s", status: .ready, stamp: 200, now: t0.addingTimeInterval(2))
        XCTAssertFalse(late.accepted)
        XCTAssertNil(late.claim)
        XCTAssertTrue(late.claims.isEmpty)
        XCTAssertEqual(late.led, .system)

        // A request newer than the release (the session was resumed) is accepted.
        let resumed = try light.claim(id: "s", status: .working, stamp: 400, now: t0.addingTimeInterval(3))
        XCTAssertTrue(resumed.accepted)
        XCTAssertEqual(resumed.led, .amber)
    }

    func testReleaseMarkersExpireAndAreRemoved() throws {
        _ = try light.release(id: "s", stamp: 300, now: t0)
        let marker = home.paths.releaseMarker(for: "s")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        let later = t0.addingTimeInterval(StatusLight.releaseMarkerLifetime + 1)
        XCTAssertTrue(try light.claim(id: "s", status: .working, stamp: 200, now: later).accepted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "sync removes old markers")
        XCTAssertEqual(light.snapshot(now: later).claims.map(\.id), ["s"], "markers are never read as claims")
    }

    func testOverrideBeatsClaimsUntilCleared() throws {
        _ = try light.claim(id: "s", status: .working, stamp: 1, now: t0)
        let off = try light.setOverride(.off, now: t0)
        XCTAssertEqual(off.led, .off)
        XCTAssertEqual(off.override?.show, "off")
        XCTAssertFalse(off.isIdle)
        XCTAssertEqual(try light.claim(id: "s", status: .attention, stamp: 2, now: t0).led, .off)
        XCTAssertEqual(light.snapshot(now: t0).desired, .off)

        // `system` (or nil) ends the override and the claims decide again.
        let cleared = try light.setOverride(.system, now: t0)
        XCTAssertNil(cleared.override)
        XCTAssertEqual(cleared.led, .blinkFast)
        XCTAssertEqual(backend.current, .blinkFast)
    }

    func testOverrideExpiresAndKeepsTheLightBusyOnItsOwn() throws {
        let held = try light.setOverride(.blinkSlow, ttl: 60, now: t0)
        XCTAssertFalse(held.isIdle, "an override alone keeps the watcher alive")
        XCTAssertEqual(light.snapshot(now: t0.addingTimeInterval(59)).desired, .blinkSlow)

        let later = try light.sync(now: t0.addingTimeInterval(61))
        XCTAssertNil(later.override)
        XCTAssertTrue(later.isIdle)
        XCTAssertEqual(later.led, .system)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.overrideFile.path))
        XCTAssertThrowsError(try light.setOverride(.amber, ttl: 0, now: t0))
    }

    func testApplyFalseRecordsWithoutWriting() throws {
        let stored = try light.claim(id: "s", status: .working, stamp: 1, now: t0, apply: false)
        XCTAssertEqual(stored.led, .amber, "the desired state is still reported")
        XCTAssertFalse(stored.wrote)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertNil(light.snapshot(now: t0).applied)

        XCTAssertEqual(try light.sync(now: t0).wrote, true)
        XCTAssertEqual(backend.writes, [.amber])
        _ = try light.release(id: "s", stamp: 2, now: t0, apply: false)
        _ = try light.setOverride(.off, now: t0, apply: false)
        _ = try light.reset(now: t0, apply: false)
        XCTAssertEqual(backend.writes, [.amber], "nothing is written until a sync")
    }

    func testResetClearsTheOverrideAndAlwaysWritesIdle() throws {
        _ = try light.setOverride(.amber, now: t0)
        // Even if something changed the LED behind chargelight's back, reset writes.
        _ = try light.reset(now: t0)
        backend.current = .blinkFast
        let reset = try light.reset(now: t0)
        XCTAssertTrue(reset.wrote)
        XCTAssertNil(reset.override)
        XCTAssertEqual(backend.current, .system)
    }

    func testReleaseAndReset() throws {
        XCTAssertEqual(try light.release(id: "missing", now: t0).released, 0)
        for id in ["a", "b", "c"] {
            _ = try light.claim(id: id, status: .working, stamp: 1, now: t0)
        }
        XCTAssertEqual(try light.release(id: "a", now: t0).released, 1)
        let reset = try light.reset(now: t0)
        XCTAssertEqual(reset.released, 2)
        XCTAssertEqual(reset.led, .system)
        XCTAssertTrue(reset.claims.isEmpty)
    }

    func testUnsafeAndLongIDs() throws {
        let ids = [
            "claude:2f1e-uuid", "../../etc/passwd", "a/b/c", "with space:and:colons", "",
            String(repeating: "x", count: 5000), "emoji-\u{1F600}", ".hidden", "claude:2f1e-uuid ",
        ].filter { !$0.isEmpty }
        for (index, id) in ids.enumerated() {
            _ = try light.claim(id: id, status: .working, label: "l\(index)", stamp: 1, now: t0)
            let name = Paths.claimFileName(for: id)
            XCTAssertLessThanOrEqual(name.utf8.count, 100)
            XCTAssertFalse(name.contains("/"))
            XCTAssertFalse(name.hasPrefix("."))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: home.paths.claimsDirectory.path)
        XCTAssertEqual(files.count, ids.count, "distinct ids get distinct files, all inside claims/")
        XCTAssertEqual(Set(light.snapshot(now: t0).claims.map(\.id)), Set(ids))
        for id in ids {
            XCTAssertEqual(try light.release(id: id, now: t0).released, 1)
        }
        XCTAssertEqual(Paths.claimFileName(for: "x"), Paths.claimFileName(for: "x"), "stable")
    }

    func testCorruptClaimFileIsSkippedAndDeleted() throws {
        _ = try light.claim(id: "good", status: .working, stamp: 1, now: t0)
        let corrupt = home.paths.claimsDirectory.appendingPathComponent("junk-0000000000000000.json")
        try Data("{not json".utf8).write(to: corrupt)
        // A valid claim stored under the wrong file name is also rejected.
        let misplaced = home.paths.claimsDirectory.appendingPathComponent("other-1111111111111111.json")
        try FileManager.default.copyItem(at: home.paths.claimFile(for: "good"), to: misplaced)

        XCTAssertEqual(light.snapshot(now: t0).claims.map(\.id), ["good"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path), "snapshot does not modify")
        let result = try light.sync(now: t0)
        XCTAssertEqual(result.claims.map(\.id), ["good"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: misplaced.path))
    }

    func testCorruptAppliedFileIsIgnored() throws {
        try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: home.paths.appliedFile)
        XCTAssertTrue(try light.sync(now: t0).wrote)
        XCTAssertEqual(light.readApplied()?.show, "system")
    }

    func testConcurrentClaimsFromManyThreads() throws {
        let paths = home.paths
        let fileBackend = FileBackend(url: paths.ledFile)
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            let light = StatusLight(paths: paths, backend: fileBackend)
            let status: AgentStatus = i == 17 ? .attention : .working
            do {
                _ = try light.claim(id: "s\(i % 10)-\(i)", status: status, stamp: UInt64(i))
            } catch {
                XCTFail("claim \(i) failed: \(error)")
            }
        }
        let light = StatusLight(paths: paths, backend: fileBackend)
        XCTAssertEqual(light.snapshot().claims.count, 40)
        XCTAssertEqual(light.snapshot().desired, .blinkFast)
        XCTAssertEqual(try fileBackend.read().state, .blinkFast)
    }

    func testCustomConfigurationLEDs() throws {
        var configuration = Configuration()
        configuration.presets["working"]?.led = "blink-slow"
        configuration.idle = .off
        let light = StatusLight(paths: home.paths, backend: backend, configuration: configuration)
        XCTAssertEqual(try light.sync(now: t0).led, .off)
        XCTAssertEqual(try light.claim(id: "s", status: .working, stamp: 1, now: t0).led, .blinkSlow)
    }

    func testEnvironmentInitialiser() throws {
        var env = home.environment
        env["CHARGELIGHT_LED_READY"] = "off"
        let light = try StatusLight(environment: env)
        XCTAssertEqual(light.paths, home.paths)
        XCTAssertTrue(light.backend is FileBackend)
        XCTAssertEqual(try light.claim(id: "x", status: .ready).led, .off)
        XCTAssertEqual(home.ledFile, "off")
    }
}
