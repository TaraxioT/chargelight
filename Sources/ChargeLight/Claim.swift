import Foundation

/// The three built-in presets, by name. A convenience for agents; anything
/// else can claim the LED with any preset, state or pattern.
public enum AgentStatus: String, CaseIterable, Codable, Sendable {
    /// The agent is busy.
    case working
    /// The agent is blocked on the user (a permission prompt, a question).
    case attention
    /// The agent has finished and is waiting for the next prompt.
    case ready

    /// The priority of the built-in preset: attention 30, working 20, ready 10.
    public var priority: Int {
        Configuration.builtInPresets[rawValue]?.priority ?? Configuration.defaultPriority
    }

    /// The lifetime of the built-in preset: working 30 min, attention 2 h, ready 10 min.
    public var defaultTTL: TimeInterval {
        Configuration.builtInPresets[rawValue]?.ttl ?? Configuration.defaultTTL
    }
}

/// One request for the LED. The highest-priority active claim decides what is
/// shown. Claims expire on their own, so a program that dies never leaves the
/// light stuck.
public struct Claim: Codable, Equatable, Sendable {
    /// Caller-chosen identifier, e.g. `build` or `claude:<session_id>`.
    public var id: String
    /// What to show, as the caller wrote it: a preset, a state, a pattern name
    /// or a pattern. Resolved with ``Configuration/resolve(_:)`` when the LED
    /// is synced, so changing a preset changes live claims too.
    public var show: String
    /// Higher wins. Ties go to the most recently updated claim.
    public var priority: Int
    /// Optional short description, e.g. the project directory name.
    public var label: String?
    /// When the claim was last set.
    public var updatedAt: Date
    /// When the claim stops counting.
    public var expiresAt: Date
    /// Ordering token: a claim with a lower stamp than the stored one is ignored.
    public var stamp: UInt64

    /// Creates a claim.
    public init(
        id: String, show: String, priority: Int = Configuration.defaultPriority, label: String? = nil,
        updatedAt: Date, expiresAt: Date, stamp: UInt64
    ) {
        self.id = id
        self.show = show
        self.priority = priority
        self.label = label
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.stamp = stamp
    }

    /// The built-in preset this claim names, if it names one.
    public var status: AgentStatus? {
        AgentStatus(rawValue: show)
    }

    private enum CodingKeys: String, CodingKey {
        case id, show, status, priority, label, updatedAt, expiresAt, stamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // Files written by 0.1 carry "status" and no priority.
        if let show = try c.decodeIfPresent(String.self, forKey: .show) {
            self.show = show
        } else {
            show = try c.decode(String.self, forKey: .status)
        }
        priority = try c.decodeIfPresent(Int.self, forKey: .priority)
            ?? Configuration.builtInPresets[show]?.priority ?? Configuration.defaultPriority
        label = try c.decodeIfPresent(String.self, forKey: .label)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        stamp = try c.decode(UInt64.self, forKey: .stamp)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(show, forKey: .show)
        // Also written in the 0.1 form, so a 0.1 watcher that is still running
        // right after an upgrade keeps understanding agent claims.
        try c.encodeIfPresent(status, forKey: .status)
        try c.encode(priority, forKey: .priority)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(stamp, forKey: .stamp)
    }

    /// Whether the claim has expired at `date`.
    public func isExpired(at date: Date) -> Bool {
        expiresAt <= date
    }

    /// Sorts claims so the one that should drive the LED comes first: highest
    /// priority, then most recently updated.
    public static func byPrecedence(_ a: Claim, _ b: Claim) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id < b.id
    }

    /// Current wall-clock time in nanoseconds since 1970, the default stamp.
    public static func currentStamp() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_REALTIME)
    }
}
