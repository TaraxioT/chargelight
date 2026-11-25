import ChargeLight
import Foundation

/// Maps Claude Code hook events to LED claims.
///
/// `chargelight hook` reads the hook's JSON from standard input, picks an
/// ``Action`` with ``action(for:)``, and claims the LED as
/// `claude:<session_id>` labelled with the project directory name.
public enum ClaudeCodeHook {
    /// The fields of a Claude Code hook payload that chargelight uses. Every
    /// field is optional and decoding is lenient: a field of the wrong type is
    /// treated as missing.
    public struct Input: Decodable, Equatable, Sendable {
        /// `hook_event_name`, e.g. `PreToolUse`.
        public var hookEventName: String?
        /// `session_id`.
        public var sessionID: String?
        /// `cwd`, the session's working directory.
        public var cwd: String?
        /// `tool_name`, for tool events.
        public var toolName: String?
        /// `notification_type`, for `Notification`.
        public var notificationType: String?
        /// `is_interrupt`, for `PostToolUseFailure`.
        public var isInterrupt: Bool?
        /// `trigger` (`manual` or `auto`), for compaction events.
        public var trigger: String?
        /// `source` (`startup`, `resume`, `clear`, `compact`, `fork`), for `SessionStart`.
        public var source: String?

        /// Creates an input; all fields default to `nil`.
        public init(
            hookEventName: String? = nil, sessionID: String? = nil, cwd: String? = nil,
            toolName: String? = nil, notificationType: String? = nil, isInterrupt: Bool? = nil,
            trigger: String? = nil, source: String? = nil
        ) {
            self.hookEventName = hookEventName
            self.sessionID = sessionID
            self.cwd = cwd
            self.toolName = toolName
            self.notificationType = notificationType
            self.isInterrupt = isInterrupt
            self.trigger = trigger
            self.source = source
        }

        private enum CodingKeys: String, CodingKey {
            case hookEventName = "hook_event_name"
            case sessionID = "session_id"
            case cwd
            case toolName = "tool_name"
            case notificationType = "notification_type"
            case isInterrupt = "is_interrupt"
            case trigger
            case source
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hookEventName = try? c.decodeIfPresent(String.self, forKey: .hookEventName)
            sessionID = try? c.decodeIfPresent(String.self, forKey: .sessionID)
            cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
            toolName = try? c.decodeIfPresent(String.self, forKey: .toolName)
            notificationType = try? c.decodeIfPresent(String.self, forKey: .notificationType)
            isInterrupt = try? c.decodeIfPresent(Bool.self, forKey: .isInterrupt)
            trigger = try? c.decodeIfPresent(String.self, forKey: .trigger)
            source = try? c.decodeIfPresent(String.self, forKey: .source)
        }

        /// Decodes a hook payload, or returns `nil` if it is not a JSON object.
        public static func decode(_ data: Data) -> Input? {
            try? JSONDecoder().decode(Input.self, from: data)
        }
    }

    /// What a hook event does to the session's claim.
    public enum Action: Equatable, Sendable {
        /// Claim the LED with this status.
        case claim(AgentStatus)
        /// Drop the session's claim.
        case release

        /// Parses an `--as` argument: `working`, `attention`, `ready` or `release`.
        public init?(argument: String) {
            if argument == "release" {
                self = .release
            } else if let status = AgentStatus(rawValue: argument) {
                self = .claim(status)
            } else {
                return nil
            }
        }
    }

    /// Tools that stop and wait for the user: a question, or a plan to approve.
    public static let attentionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Notification types that mean the agent is waiting on the user.
    public static let attentionNotifications: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
    ]

    /// The action for a hook event, or `nil` if the event should not change the LED.
    ///
    /// | Event | Action |
    /// |---|---|
    /// | SessionStart | ready (nothing when `source` is `compact`: the agent is mid-turn) |
    /// | Stop | ready |
    /// | UserPromptSubmit, PostToolUse, PermissionDenied, ElicitationResult, PreCompact | working |
    /// | PreToolUse | attention for `AskUserQuestion` and `ExitPlanMode`, else working |
    /// | PostToolUseFailure | ready if interrupted, else working |
    /// | PermissionRequest, Elicitation, StopFailure | attention |
    /// | Notification | attention for prompts/dialogs, ready for `idle_prompt`, else nothing |
    /// | PostCompact | ready if triggered manually, else working |
    /// | SessionEnd | release |
    /// | anything else | nothing |
    public static func action(for input: Input) -> Action? {
        switch input.hookEventName {
        case "SessionStart":
            return input.source == "compact" ? nil : .claim(.ready)
        case "Stop":
            return .claim(.ready)
        case "UserPromptSubmit", "PostToolUse", "PermissionDenied", "ElicitationResult", "PreCompact":
            return .claim(.working)
        case "PreToolUse":
            return .claim(input.toolName.map(attentionTools.contains) == true ? .attention : .working)
        case "PostToolUseFailure":
            return .claim(input.isInterrupt == true ? .ready : .working)
        case "PermissionRequest", "Elicitation", "StopFailure":
            return .claim(.attention)
        case "Notification":
            guard let type = input.notificationType else { return nil }
            if attentionNotifications.contains(type) { return .claim(.attention) }
            if type == "idle_prompt" { return .claim(.ready) }
            return nil
        case "PostCompact":
            return .claim(input.trigger == "manual" ? .ready : .working)
        case "SessionEnd":
            return .release
        default:
            return nil
        }
    }

    /// The claim id for a Claude Code session: `claude:<session_id>`.
    public static func claimID(sessionID: String) -> String {
        "claude:\(sessionID)"
    }

    /// The claim label for a session: the last path component of `cwd`.
    public static func label(cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
