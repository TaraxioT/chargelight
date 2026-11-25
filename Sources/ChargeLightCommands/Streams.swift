import ChargeLight
import Foundation

/// Keeps one claim alive for a long-running command (`run`, `pipe`): each
/// claim lasts ``ttl`` seconds and is renewed every `interval` seconds, so if
/// the process dies the claim expires within a minute.
final class ClaimKeeper {
    /// Lifetime of each renewal, in seconds.
    static let ttl: TimeInterval = 60

    private let light: StatusLight
    private let id: String
    private let priority: Int?
    private let label: String?
    private let apply: (StatusLight) throws -> Void
    private let queue = DispatchQueue(label: "chargelight.renew")
    private var timer: DispatchSourceTimer?
    private var current: String?

    init(
        light: StatusLight, id: String, priority: Int?, label: String?, interval: TimeInterval,
        apply: @escaping (StatusLight) throws -> Void
    ) {
        self.light = light
        self.id = id
        self.priority = priority
        self.label = label
        self.apply = apply
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, let show = self.current else { return }
            _ = try? self.store(show, ttl: ClaimKeeper.ttl)
        }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
    }

    /// Claims `show` (renewed until changed, released or finished).
    @discardableResult
    func claim(_ show: String) throws -> SyncResult {
        try queue.sync {
            let result = try store(show, ttl: ClaimKeeper.ttl)
            current = show
            return result
        }
    }

    /// Drops the claim; renewals stop until the next ``claim(_:)``.
    @discardableResult
    func release() throws -> SyncResult {
        try queue.sync {
            current = nil
            let result = try light.release(id: id, stamp: Claim.currentStamp(), apply: false)
            try apply(light)
            return result
        }
    }

    /// Stops renewing, then leaves `show` claimed for `ttl` seconds, or
    /// releases the claim (`show` nil or `ttl` 0) if anything was claimed.
    func finish(show: String? = nil, ttl: TimeInterval = 0) throws {
        try queue.sync {
            timer?.cancel()
            timer = nil
            let claimed = current != nil
            current = nil
            if let show, ttl > 0 {
                _ = try store(show, ttl: ttl)
            } else if claimed {
                _ = try light.release(id: id, stamp: Claim.currentStamp(), apply: false)
                try apply(light)
            }
        }
    }

    private func store(_ show: String, ttl: TimeInterval) throws -> SyncResult {
        let result = try light.claim(
            id: id, show: show, priority: priority, ttl: ttl, label: label, stamp: Claim.currentStamp(), apply: false)
        try apply(light)
        return result
    }
}

/// Handles SIGINT, SIGTERM and SIGHUP on a queue while installed, then puts
/// the previous dispositions back. A signal that was ignored when the trap was
/// set (as under `nohup`) is left alone.
final class SignalTrap {
    /// The signals the trap handles.
    private(set) var signals: [Int32] = []
    private var previous: [Int32: sigaction] = [:]
    private var sources: [DispatchSourceSignal] = []

    init(_ candidates: [Int32] = [SIGINT, SIGTERM, SIGHUP], handler: @escaping (Int32) -> Void) {
        let queue = DispatchQueue(label: "chargelight.signals")
        for sig in candidates {
            var old = sigaction()
            guard sigaction(sig, nil, &old) == 0, !SignalTrap.isIgnored(old) else { continue }
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { handler(sig) }
            source.resume()
            signal(sig, SIG_IGN)
            previous[sig] = old
            sources.append(source)
            signals.append(sig)
        }
    }

    deinit {
        remove()
    }

    /// Restores the previous dispositions.
    func remove() {
        for source in sources { source.cancel() }
        sources = []
        for (sig, old) in previous {
            var action = old
            sigaction(sig, &action, nil)
        }
        previous = [:]
    }

    private static func isIgnored(_ action: sigaction) -> Bool {
        unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
    }
}

/// Ignores SIGPIPE until restored, so writing to a closed pipe fails with
/// `EPIPE` instead of killing the process.
private func ignoreSIGPIPE() -> () -> Void {
    let previous = signal(SIGPIPE, SIG_IGN)
    return { signal(SIGPIPE, previous) }
}

extension CLI {
    // MARK: - watch

    func watchCommand(options: [String: String]) throws -> CommandOutput {
        let count = try options["--count"].map { try integer($0, option: "--count", in: 1...1_000_000) }
        let light = try makeLight()
        let restore = ignoreSIGPIPE()
        defer { restore() }
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss"

        var last: String?
        var printed = 0
        while !outputClosed() {
            let now = Date()
            let snapshot = light.snapshot(now: now)
            let winner = winningClaim(snapshot.claims, light.configuration)
            // Renewals only move expiry times; they are not changes worth a line.
            let key = ([snapshot.desired.description, winner?.id ?? "", snapshot.override.map { "\($0.show)@\($0.expiresAt?.timeIntervalSince1970 ?? 0)" } ?? ""]
                + snapshot.claims.map { "\($0.id)\u{1}\($0.show)\u{1}\($0.priority)\u{1}\($0.label ?? "")" }.sorted())
                .joined(separator: "\u{0}")
            if key != last {
                last = key
                if json {
                    let line: JSON = .object([
                        "time": .date(now),
                        "led": .string(snapshot.desired.description),
                        "claims": .array(snapshot.claims.map { .claim($0, configuration: light.configuration) }),
                        "override": .override(snapshot.override),
                    ])
                    writeOut(line.serialized + "\n")
                } else {
                    let who = snapshot.override != nil
                        ? "override" : winner.map { "\($0.id) (\(abbreviate($0.show)))" } ?? "idle"
                    writeOut("\(clock.string(from: now))  \(abbreviate(snapshot.desired.description))  \(who)\n")
                }
                printed += 1
                if let count, printed >= count { break }
            }
            Thread.sleep(forTimeInterval: watchInterval)
        }
        return CommandOutput(silent: true)
    }

    // MARK: - pipe

    func pipeCommand(options: [String: String]) throws -> CommandOutput {
        let priority = try options["--priority"].map { try integer($0, option: "--priority", in: -1_000_000...1_000_000) }
        let id = options["--id"] ?? "pipe:\(getpid())"
        guard !id.isEmpty else { throw ChargeLightError.invalidArgument("--id must not be empty") }
        let light = try makeWritableLight()
        let keeper = ClaimKeeper(
            light: light, id: id, priority: priority, label: options["--label"], interval: renewInterval,
            apply: { [unowned self] in try self.applyChange($0) })
        let restore = ignoreSIGPIPE()
        defer { restore() }
        // Interrupted: drop the claim rather than leave it for a minute.
        let trap = SignalTrap { sig in
            try? keeper.finish()
            exit(128 + sig)
        }
        defer { trap.remove() }

        var number = 0
        while let line = readLine() {
            number += 1
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            do {
                let result = text == "release" || text == "-" ? try keeper.release() : try keeper.claim(text)
                if json { writeOut(JSON.object(["ok": .bool(true), "led": .string(result.led.description)]).serialized + "\n") }
            } catch {
                let error = ChargeLightError.wrap(error)
                if json {
                    writeOut(JSON.error(error).serialized + "\n")
                } else {
                    writeErr("chargelight: pipe: line \(number): \(error.message)\n")
                }
            }
            if outputClosed() { break }
        }
        try keeper.finish()
        return CommandOutput(silent: true)
    }
}
