import Foundation

/// What an agent is doing, as shown on the LED.
public enum AgentStatus: String, CaseIterable, Codable, Sendable {
    /// The agent is busy.
    case working
    /// The agent is blocked on the user (a permission prompt, a question).
    case attention
    /// The agent has finished and is waiting for the next prompt.
    case ready

    /// Higher wins when several agents claim the LED: attention > working > ready.
    public var priority: Int {
        switch self {
        case .attention: return 2
        case .working: return 1
        case .ready: return 0
        }
    }

    /// How long a claim lasts unless renewed: working 30 min, attention 2 h, ready 10 min.
    public var defaultTTL: TimeInterval {
        switch self {
        case .working: return 30 * 60
        case .attention: return 2 * 60 * 60
        case .ready: return 10 * 60
        }
    }
}

/// One agent's request for the LED. Claims expire on their own, so a crashed
/// agent never leaves the light stuck.
public struct Claim: Codable, Equatable, Sendable {
    /// Caller-chosen identifier, e.g. `claude:<session_id>`.
    public var id: String
    /// What the agent is doing.
    public var status: AgentStatus
    /// Optional short description, e.g. the project directory name.
    public var label: String?
    /// When the claim was last set.
    public var updatedAt: Date
    /// When the claim stops counting.
    public var expiresAt: Date
    /// Ordering token: a claim with a lower stamp than the stored one is ignored.
    public var stamp: UInt64

    /// Creates a claim.
    public init(id: String, status: AgentStatus, label: String? = nil, updatedAt: Date, expiresAt: Date, stamp: UInt64) {
        self.id = id
        self.status = status
        self.label = label
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.stamp = stamp
    }

    /// Whether the claim has expired at `date`.
    public func isExpired(at date: Date) -> Bool {
        expiresAt <= date
    }

    /// Sorts claims so the one that should drive the LED comes first: highest
    /// priority, then most recently updated.
    public static func byPrecedence(_ a: Claim, _ b: Claim) -> Bool {
        if a.status.priority != b.status.priority { return a.status.priority > b.status.priority }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id < b.id
    }

    /// Current wall-clock time in nanoseconds since 1970, the default stamp.
    public static func currentStamp() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_REALTIME)
    }
}
