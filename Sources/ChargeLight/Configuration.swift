import Foundation

/// Which LED state each agent status shows, and how long claims last.
///
/// Loaded from `config.json` in the state directory, shaped like
/// `{"leds":{"working":"amber","attention":"blink-fast","ready":"green","idle":"system"},
/// "ttl":{"working":1800,"attention":7200,"ready":600}}` with every key
/// optional, then overridden by `CHARGELIGHT_LED_WORKING`,
/// `CHARGELIGHT_LED_ATTENTION`, `CHARGELIGHT_LED_READY` and `CHARGELIGHT_LED_IDLE`.
public struct Configuration: Codable, Equatable, Sendable {
    /// LED state per agent status, plus the idle state used when nothing claims the LED.
    public struct LEDs: Codable, Equatable, Sendable {
        /// Shown while an agent works. Default ``LEDState/amber``.
        public var working: LEDState = .amber
        /// Shown while an agent needs the user. Default ``LEDState/blinkFast``.
        public var attention: LEDState = .blinkFast
        /// Shown when an agent has finished. Default ``LEDState/green``.
        public var ready: LEDState = .green
        /// Shown when there are no claims. Default ``LEDState/system``.
        public var idle: LEDState = .system

        private enum CodingKeys: String, CodingKey {
            case working, attention, ready, idle
        }

        /// The defaults.
        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            working = try c.decodeIfPresent(LEDState.self, forKey: .working) ?? working
            attention = try c.decodeIfPresent(LEDState.self, forKey: .attention) ?? attention
            ready = try c.decodeIfPresent(LEDState.self, forKey: .ready) ?? ready
            idle = try c.decodeIfPresent(LEDState.self, forKey: .idle) ?? idle
        }
    }

    /// Claim lifetime in seconds per agent status.
    public struct TTLs: Codable, Equatable, Sendable {
        /// Default 1800 (30 minutes).
        public var working: TimeInterval = AgentStatus.working.defaultTTL
        /// Default 7200 (2 hours).
        public var attention: TimeInterval = AgentStatus.attention.defaultTTL
        /// Default 600 (10 minutes).
        public var ready: TimeInterval = AgentStatus.ready.defaultTTL

        private enum CodingKeys: String, CodingKey {
            case working, attention, ready
        }

        /// The defaults.
        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            working = try Self.positive(c, .working) ?? working
            attention = try Self.positive(c, .attention) ?? attention
            ready = try Self.positive(c, .ready) ?? ready
        }

        private static func positive(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> TimeInterval? {
            guard let value = try c.decodeIfPresent(TimeInterval.self, forKey: key) else { return nil }
            guard value > 0, value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: c, debugDescription: "must be a positive number of seconds")
            }
            return value
        }
    }

    /// LED state per status.
    public var leds = LEDs()
    /// Claim lifetime per status.
    public var ttl = TTLs()

    /// The built-in defaults.
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        leds = try c.decodeIfPresent(LEDs.self, forKey: .leds) ?? LEDs()
        ttl = try c.decodeIfPresent(TTLs.self, forKey: .ttl) ?? TTLs()
    }

    /// The LED state shown for `status`.
    public func led(for status: AgentStatus) -> LEDState {
        switch status {
        case .working: return leds.working
        case .attention: return leds.attention
        case .ready: return leds.ready
        }
    }

    /// The default claim lifetime for `status`, in seconds.
    public func ttl(for status: AgentStatus) -> TimeInterval {
        switch status {
        case .working: return ttl.working
        case .attention: return ttl.attention
        case .ready: return ttl.ready
        }
    }

    /// Environment variables that override ``leds``, and the field each sets.
    static let environmentKeys: [(name: String, keyPath: WritableKeyPath<LEDs, LEDState>)] = [
        ("CHARGELIGHT_LED_WORKING", \.working),
        ("CHARGELIGHT_LED_ATTENTION", \.attention),
        ("CHARGELIGHT_LED_READY", \.ready),
        ("CHARGELIGHT_LED_IDLE", \.idle),
    ]

    /// Decodes a configuration from JSON. Throws ``ChargeLightError/invalidArgument(_:)``
    /// naming the offending key.
    public static func decode(_ data: Data, source: String = "config.json") throws -> Configuration {
        do {
            return try JSONDecoder().decode(Configuration.self, from: data)
        } catch let error as DecodingError {
            throw ChargeLightError.invalidArgument("\(source): \(describe(error))")
        } catch {
            throw ChargeLightError.invalidArgument("\(source): \(error.localizedDescription)")
        }
    }

    /// Loads `paths.configFile` (if present) and applies environment overrides.
    public static func load(paths: Paths, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Configuration {
        var configuration = Configuration()
        if let data = try FileIO.readIfPresent(paths.configFile) {
            configuration = try decode(data, source: paths.configFile.path)
        }
        try configuration.applyEnvironment(environment)
        return configuration
    }

    /// Applies the `CHARGELIGHT_LED_*` overrides. Empty values are ignored.
    public mutating func applyEnvironment(_ environment: [String: String]) throws {
        for (name, keyPath) in Configuration.environmentKeys {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { continue }
            guard let state = LEDState(rawValue: value) else {
                throw ChargeLightError.invalidArgument(
                    "\(name): unknown LED state \"\(value)\" (expected one of: \(LEDState.namesList))")
            }
            leds[keyPath: keyPath] = state
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .dataCorrupted(let context):
            if context.codingPath.isEmpty { return "not valid JSON" }
            // An unknown enum value surfaces here with the offending key in the path.
            if context.codingPath.first?.stringValue == "leds" {
                return "\(path(context.codingPath)): unknown LED state (expected one of: \(LEDState.namesList))"
            }
            return "\(path(context.codingPath)): \(context.debugDescription)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let key = path(context.codingPath)
            return "\(key.isEmpty ? "top level" : key): wrong type (\(context.debugDescription))"
        case .keyNotFound(let key, _):
            return "\(key.stringValue): missing"
        @unknown default:
            return error.localizedDescription
        }
    }
}
