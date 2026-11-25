import Foundation

/// The LED state chargelight last wrote, and when.
public struct AppliedState: Codable, Equatable, Sendable {
    /// The state written.
    public var led: LEDState
    /// When it was written.
    public var appliedAt: Date

    /// Creates a record of a write.
    public init(led: LEDState, appliedAt: Date) {
        self.led = led
        self.appliedAt = appliedAt
    }
}

/// A manual LED state that takes precedence over every claim.
public struct Override: Codable, Equatable, Sendable {
    /// The state to show.
    public var led: LEDState
    /// When the override was set.
    public var setAt: Date
    /// When it stops counting; `nil` means until it is cleared.
    public var expiresAt: Date?

    /// Creates an override.
    public init(led: LEDState, setAt: Date, expiresAt: Date? = nil) {
        self.led = led
        self.setAt = setAt
        self.expiresAt = expiresAt
    }

    /// Whether the override has expired at `date`.
    public func isExpired(at date: Date) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }
}

/// The outcome of a ``StatusLight`` operation.
public struct SyncResult: Equatable, Sendable {
    /// The LED state called for by the override or, failing that, the claims.
    /// It is now applied if ``wrote`` is true or it already was.
    public var led: LEDState
    /// Whether the backend was written. `false` when the LED already matched,
    /// or when the operation was asked not to apply.
    public var wrote: Bool
    /// Active claims, highest precedence first.
    public var claims: [Claim]
    /// Claims dropped because they had expired.
    public var expired: [Claim]
    /// The manual override in force, if any.
    public var override: Override?
    /// For ``StatusLight/claim(id:status:ttl:label:stamp:now:apply:)``: the stored
    /// claim (the existing one if the request was ignored; `nil` if the id
    /// had just been released).
    public var claim: Claim?
    /// For ``StatusLight/claim(id:status:ttl:label:stamp:now:apply:)``: `false` when
    /// the request was older than the stored claim, or older than a release of
    /// the same id, and was ignored.
    public var accepted: Bool
    /// For ``StatusLight/release(id:stamp:now:apply:)`` and
    /// ``StatusLight/reset(now:apply:)``: how many claims were removed.
    public var released: Int

    /// The claim that would drive the LED without an override, if any.
    public var winner: Claim? { claims.first }
    /// Whether nothing asks for the LED: no claims and no override.
    public var isIdle: Bool { claims.isEmpty && override == nil }
}

/// A read-only view of the current state.
public struct Snapshot: Equatable, Sendable {
    /// Active claims, highest precedence first.
    public var claims: [Claim]
    /// The manual override in force, if any.
    public var override: Override?
    /// The LED state called for by the override or, failing that, the claims.
    public var desired: LEDState
    /// What chargelight last wrote, if anything.
    public var applied: AppliedState?

    /// The claim that would drive the LED without an override, if any.
    public var winner: Claim? { claims.first }
    /// Whether nothing asks for the LED: no claims and no override.
    public var isIdle: Bool { claims.isEmpty && override == nil }
}

/// Turns agent claims into an LED state.
///
/// Each agent session *claims* the light with a status (working, attention,
/// ready). The highest-priority active claim decides the LED; with no claims
/// the LED returns to the configured idle state. A manual ``Override`` beats
/// every claim. Claims are files under ``Paths/claimsDirectory``, so separate
/// processes (one per hook invocation) cooperate; every mutation runs under an
/// exclusive `flock`.
///
/// Every mutating method takes `apply`. With `apply: true` (the default) it
/// writes the LED itself, once. Pass `apply: false` to only record the change
/// and let a running ``Watcher`` write and *hold* the LED, which is what the
/// `chargelight` CLI does: macOS can take the LED back within seconds of a
/// single write.
public final class StatusLight {
    /// How long a release keeps rejecting older claim requests for the same id.
    public static let releaseMarkerLifetime: TimeInterval = 60

    /// Where state is stored.
    public let paths: Paths
    /// What changes the LED.
    public let backend: LEDBackend
    /// LED states and lifetimes per status.
    public let configuration: Configuration

    /// Creates a status light from explicit parts.
    public init(paths: Paths, backend: LEDBackend, configuration: Configuration = Configuration()) {
        self.paths = paths
        self.backend = backend
        self.configuration = configuration
    }

    /// Creates a status light configured from `environment`: `CHARGELIGHT_HOME`,
    /// `CHARGELIGHT_BACKEND`, `CHARGELIGHT_HELPER`, `CHARGELIGHT_LED_*` and `config.json`.
    public convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let paths = Paths(environment: environment)
        self.init(
            paths: paths,
            backend: try ChargeLight.backend(environment: environment, paths: paths),
            configuration: try Configuration.load(paths: paths, environment: environment))
    }

    // MARK: - Claims

    /// Sets (or renews) the claim `id`.
    ///
    /// - Parameters:
    ///   - ttl: Lifetime in seconds; defaults to the configured TTL for `status`.
    ///   - label: Short description; when `nil` an existing label is kept.
    ///   - stamp: Ordering token. If the stored claim for `id` has a higher
    ///     stamp, or `id` was released with a higher stamp in the last minute,
    ///     this request is stale (hooks can land out of order) and is ignored.
    ///   - apply: Write the LED now; see ``StatusLight``.
    public func claim(
        id: String, status: AgentStatus, ttl: TimeInterval? = nil, label: String? = nil,
        stamp: UInt64 = Claim.currentStamp(), now: Date = Date(), apply: Bool = true
    ) throws -> SyncResult {
        guard !id.isEmpty else { throw ChargeLightError.invalidArgument("claim id must not be empty") }
        let lifetime = ttl ?? configuration.ttl(for: status)
        guard lifetime > 0, lifetime.isFinite else {
            throw ChargeLightError.invalidArgument("ttl must be a positive number of seconds")
        }
        return try withLock {
            let file = paths.claimFile(for: id)
            let existing = readClaim(file).flatMap { $0.id == id && !$0.isExpired(at: now) ? $0 : nil }
            var stored: Claim?
            var accepted = true
            if let released = readReleaseMarker(for: id, now: now), stamp < released.stamp {
                stored = existing
                accepted = false
            } else if let existing, stamp < existing.stamp {
                stored = existing
                accepted = false
            } else {
                let claim = Claim(
                    id: id, status: status, label: label ?? existing?.label,
                    updatedAt: now, expiresAt: now.addingTimeInterval(lifetime), stamp: stamp)
                try FileIO.writeAtomically(try StoredJSON.encoder().encode(claim), to: file)
                stored = claim
            }
            var result = try syncLocked(now: now, force: false, apply: apply)
            result.claim = stored
            result.accepted = accepted
            return result
        }
    }

    /// Removes the claim `id` (if present).
    ///
    /// - Parameters:
    ///   - stamp: Ordering token. Claim requests for `id` with a lower stamp
    ///     are ignored for the next minute, so a hook that started before the
    ///     release but finished after it cannot bring the claim back.
    ///   - apply: Write the LED now; see ``StatusLight``.
    public func release(
        id: String, stamp: UInt64 = Claim.currentStamp(), now: Date = Date(), apply: Bool = true
    ) throws -> SyncResult {
        try withLock {
            let removed = try FileIO.remove(paths.claimFile(for: id))
            let marker = ReleaseMarker(stamp: stamp, releasedAt: now)
            try FileIO.writeAtomically(try StoredJSON.encoder().encode(marker), to: paths.releaseMarker(for: id))
            var result = try syncLocked(now: now, force: false, apply: apply)
            result.released = removed ? 1 : 0
            return result
        }
    }

    /// Removes every claim and the override. With `apply`, the idle state is
    /// written whatever the LED was believed to show.
    public func reset(now: Date = Date(), apply: Bool = true) throws -> SyncResult {
        try withLock {
            var count = 0
            for url in claimFiles() where try FileIO.remove(url) {
                count += 1
            }
            try FileIO.remove(paths.overrideFile)
            var result = try syncLocked(now: now, force: true, apply: apply)
            result.released = count
            return result
        }
    }

    // MARK: - Override

    /// Shows `state` regardless of the claims, until it is cleared or `ttl`
    /// seconds have passed. `nil` or ``LEDState/system`` clears the override,
    /// handing the LED back to the claims.
    public func setOverride(
        _ state: LEDState?, ttl: TimeInterval? = nil, now: Date = Date(), apply: Bool = true
    ) throws -> SyncResult {
        if let ttl, !(ttl > 0 && ttl.isFinite) {
            throw ChargeLightError.invalidArgument("duration must be a positive number of seconds")
        }
        return try withLock {
            if let state, state != .system {
                let override = Override(led: state, setAt: now, expiresAt: ttl.map { now.addingTimeInterval($0) })
                try FileIO.writeAtomically(try StoredJSON.encoder().encode(override), to: paths.overrideFile)
            } else {
                try FileIO.remove(paths.overrideFile)
            }
            return try syncLocked(now: now, force: false, apply: apply)
        }
    }

    // MARK: - Sync

    /// Drops expired claims and writes the desired LED state if it differs
    /// from what was last applied.
    ///
    /// - Parameter force: Write even if the LED is believed to be up to date.
    public func sync(now: Date = Date(), force: Bool = false) throws -> SyncResult {
        try withLock { try syncLocked(now: now, force: force, apply: true) }
    }

    /// The current claims, override and desired LED, without changing anything.
    /// Unreadable claim files are skipped.
    public func snapshot(now: Date = Date()) -> Snapshot {
        let active = loadClaims(deleteCorrupt: false)
            .filter { !$0.isExpired(at: now) }
            .sorted(by: Claim.byPrecedence)
        let override = readOverride(now: now)
        return Snapshot(
            claims: active, override: override,
            desired: desiredLED(for: active, override: override), applied: readApplied())
    }

    /// The LED state the given claims call for, unless `override` is in force.
    public func desiredLED(for claims: [Claim], override: Override? = nil) -> LEDState {
        if let override { return override.led }
        guard let winner = claims.min(by: Claim.byPrecedence) else { return configuration.leds.idle }
        return configuration.led(for: winner.status)
    }

    // MARK: - Watcher support

    /// Syncs, then re-writes the desired LED if the hardware no longer shows it.
    ///
    /// For backends without a hold: if the desired state is not
    /// ``LEDState/system``, the last write is older than `settle` seconds (a
    /// readback right after a write can still show the old value), and the
    /// backend reads back something else, the state is written again.
    ///
    /// - Returns: The sync result and whether the LED was re-written.
    func syncAndReassert(now: Date, settle: TimeInterval) throws -> (SyncResult, reasserted: Bool) {
        try withLock {
            var result = try syncLocked(now: now, force: false, apply: true)
            guard !result.isIdle, result.led != .system,
                  let applied = readApplied(), applied.led == result.led,
                  now.timeIntervalSince(applied.appliedAt) > settle
            else { return (result, false) }
            let reading = try backend.read()
            guard reading.state != result.led else { return (result, false) }
            try apply(result.led, now: now)
            result.wrote = true
            return (result, true)
        }
    }

    /// Runs `body` and returns `true` if nothing asks for the LED. The check
    /// and `body` run under the claims lock, so no claim can arrive in between.
    func ifIdle(now: Date = Date(), _ body: () -> Void) throws -> Bool {
        try withLock {
            let active = loadClaims(deleteCorrupt: false).contains { !$0.isExpired(at: now) }
            guard !active, readOverride(now: now) == nil else { return false }
            body()
            return true
        }
    }

    /// The same claims and configuration, writing through `backend`.
    func using(backend: LEDBackend) -> StatusLight {
        StatusLight(paths: paths, backend: backend, configuration: configuration)
    }

    // MARK: - Internals

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let lock = try FileLock.exclusive(paths.lockFile)
        defer { lock.unlock() }
        return try body()
    }

    private func syncLocked(now: Date, force: Bool, apply shouldApply: Bool) throws -> SyncResult {
        var active: [Claim] = []
        var expired: [Claim] = []
        for claim in loadClaims(deleteCorrupt: true) {
            if claim.isExpired(at: now) {
                try FileIO.remove(paths.claimFile(for: claim.id))
                expired.append(claim)
            } else {
                active.append(claim)
            }
        }
        removeOldReleaseMarkers(now: now)
        let override = readOverride(now: now)
        if override == nil { try FileIO.remove(paths.overrideFile) }
        active.sort(by: Claim.byPrecedence)
        let desired = desiredLED(for: active, override: override)
        var wrote = false
        if shouldApply, force || readApplied()?.led != desired {
            try apply(desired, now: now)
            wrote = true
        }
        return SyncResult(
            led: desired, wrote: wrote, claims: active, expired: expired, override: override,
            claim: nil, accepted: true, released: 0)
    }

    private func apply(_ state: LEDState, now: Date) throws {
        try backend.write(state)
        let record = AppliedState(led: state, appliedAt: now)
        try FileIO.writeAtomically(try StoredJSON.encoder().encode(record), to: paths.appliedFile)
    }

    func readApplied() -> AppliedState? {
        guard let data = try? FileIO.readIfPresent(paths.appliedFile) else { return nil }
        return try? StoredJSON.decoder().decode(AppliedState.self, from: data)
    }

    /// The override in force at `now`; an expired or unreadable one is ignored.
    private func readOverride(now: Date) -> Override? {
        guard let data = try? FileIO.readIfPresent(paths.overrideFile),
              let override = try? StoredJSON.decoder().decode(Override.self, from: data),
              !override.isExpired(at: now), override.led != .system
        else { return nil }
        return override
    }

    private struct ReleaseMarker: Codable {
        var stamp: UInt64
        var releasedAt: Date
    }

    /// The marker left by a recent release of `id`, if it is still in force.
    private func readReleaseMarker(for id: String, now: Date) -> ReleaseMarker? {
        guard let data = try? FileIO.readIfPresent(paths.releaseMarker(for: id)),
              let marker = try? StoredJSON.decoder().decode(ReleaseMarker.self, from: data),
              abs(now.timeIntervalSince(marker.releasedAt)) < StatusLight.releaseMarkerLifetime
        else { return nil }
        return marker
    }

    private func removeOldReleaseMarkers(now: Date) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.claimsDirectory.path)) ?? []
        for name in names where name.hasSuffix(".released") {
            let url = paths.claimsDirectory.appendingPathComponent(name)
            let marker = (try? FileIO.readIfPresent(url))
                .flatMap { try? StoredJSON.decoder().decode(ReleaseMarker.self, from: $0) }
            if let marker, abs(now.timeIntervalSince(marker.releasedAt)) < StatusLight.releaseMarkerLifetime { continue }
            _ = try? FileIO.remove(url)
        }
    }

    private func claimFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.claimsDirectory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted()
            .map { paths.claimsDirectory.appendingPathComponent($0) }
    }

    private func readClaim(_ url: URL) -> Claim? {
        guard let data = try? FileIO.readIfPresent(url) else { return nil }
        return try? StoredJSON.decoder().decode(Claim.self, from: data)
    }

    /// Reads every claim file. A file that cannot be decoded, or whose name
    /// does not match its id, is skipped and (if `deleteCorrupt`) removed.
    private func loadClaims(deleteCorrupt: Bool) -> [Claim] {
        claimFiles().compactMap { url in
            if let claim = readClaim(url), url.lastPathComponent == Paths.claimFileName(for: claim.id) {
                return claim
            }
            // Re-check existence: a concurrent release may have removed it.
            if deleteCorrupt && FileIO.exists(url.path) { _ = try? FileIO.remove(url) }
            return nil
        }
    }
}
