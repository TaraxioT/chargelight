import Foundation

/// A named reason to light the LED: what to show, how it ranks against other
/// claims, and how long a claim lasts unless renewed.
public struct Preset: Equatable, Sendable {
    /// What to show: a state, a pattern name or a pattern such as `green:300,off:300`.
    public var led: String
    /// Higher wins when several claims are active.
    public var priority: Int
    /// Claim lifetime in seconds.
    public var ttl: TimeInterval

    /// Creates a preset.
    public init(led: String, priority: Int, ttl: TimeInterval) {
        self.led = led
        self.priority = priority
        self.ttl = ttl
    }
}

/// Presets, named patterns and the idle state.
///
/// Loaded from `config.json` in the state directory. Every key is optional:
///
/// ```json
/// {
///   "idle": "system",
///   "presets":  { "deploy": { "led": "heartbeat", "priority": 25, "ttl": 900 } },
///   "patterns": { "triple": "green:100,off:100,green:100,off:100,green:100,off:600" },
///   "leds":     { "working": "amber", "attention": "blink-fast", "ready": "green" },
///   "ttl":      { "working": 1800 }
/// }
/// ```
///
/// `leds` and `ttl` are shorthand for changing the three built-in presets.
/// `CHARGELIGHT_LED_WORKING`, `_ATTENTION`, `_READY` and `_IDLE` override the
/// file.
public struct Configuration: Equatable, Sendable {
    /// The priority of a claim that names no preset and passes none.
    public static let defaultPriority = 20
    /// The lifetime, in seconds, of a claim that names no preset and passes none.
    public static let defaultTTL: TimeInterval = 30 * 60
    /// The priority used by transient effects such as `chargelight flash`.
    public static let noticePriority = 100

    /// The presets every installation starts with.
    public static let builtInPresets: [String: Preset] = [
        "attention": Preset(led: "blink-fast", priority: 30, ttl: 2 * 60 * 60),
        "working": Preset(led: "amber", priority: 20, ttl: 30 * 60),
        "ready": Preset(led: "green", priority: 10, ttl: 10 * 60),
    ]

    /// Presets by name: the built-in three plus any from `config.json`.
    public var presets: [String: Preset] = Configuration.builtInPresets
    /// Patterns by name: ``Pattern/builtIn`` plus any from `config.json`.
    public var patterns: [String: Pattern] = Pattern.builtIn
    /// Shown when nothing claims the LED. Default ``LEDState/system``.
    public var idle: LEDState = .system

    /// The built-in defaults.
    public init() {}

    // MARK: - Resolving

    /// Turns what a caller asked to show into an ``LEDSpec``. `text` may be a
    /// preset name, a state name, a pattern name, or a pattern written out.
    public func resolve(_ text: String) throws -> LEDSpec {
        if let preset = presets[text] { return try resolveLED(preset.led) }
        return try resolveLED(text)
    }

    /// Like ``resolve(_:)`` but does not accept preset names.
    public func resolveLED(_ text: String) throws -> LEDSpec {
        if let state = LEDState(rawValue: text) { return .state(state) }
        if let pattern = patterns[text] { return .pattern(pattern) }
        if text.contains(":") { return .pattern(try Pattern(parsing: text)) }
        throw ChargeLightError.invalidArgument(
            "unknown LED state or pattern \"\(text)\" (states: \(LEDState.namesList); patterns: "
                + "\(patterns.keys.sorted().joined(separator: ", ")); or write one, e.g. green:300,off:300)")
    }

    /// The preset named `name`, if any.
    public func preset(_ name: String) -> Preset? {
        presets[name]
    }

    /// What the built-in preset for `status` shows.
    public func led(for status: AgentStatus) -> LEDSpec {
        (try? resolve(status.rawValue)) ?? .state(.amber)
    }

    /// The claim lifetime of the built-in preset for `status`, in seconds.
    public func ttl(for status: AgentStatus) -> TimeInterval {
        presets[status.rawValue]?.ttl ?? Configuration.defaultTTL
    }

    // MARK: - Loading

    /// Loads `paths.configFile` (if present) and applies environment overrides.
    public static func load(
        paths: Paths, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Configuration {
        var configuration = Configuration()
        if let data = try FileIO.readIfPresent(paths.configFile) {
            configuration = try decode(data, source: paths.configFile.path)
        }
        try configuration.applyEnvironment(environment)
        return configuration
    }

    /// Decodes a configuration from JSON.
    ///
    /// - Throws: ``ChargeLightError/invalidArgument(_:)`` naming the offending key.
    public static func decode(_ data: Data, source: String = "config.json") throws -> Configuration {
        func fail(_ message: String) -> ChargeLightError { .invalidArgument("\(source): \(message)") }
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw fail("not valid JSON") }
        guard let object = root as? [String: Any] else { throw fail("top level: expected an object") }
        let known: Set<String> = ["idle", "presets", "patterns", "leds", "ttl"]
        if let unknown = object.keys.sorted().first(where: { !known.contains($0) }) {
            throw fail("\(unknown): unknown key (expected: \(known.sorted().joined(separator: ", ")))")
        }

        func table(_ key: String) throws -> [String: Any] {
            guard let value = object[key] else { return [:] }
            guard let table = value as? [String: Any] else { throw fail("\(key): expected an object") }
            return table
        }
        func seconds(_ value: Any, _ key: String) throws -> TimeInterval {
            guard let number = value as? NSNumber, !(value is Bool), number.doubleValue > 0, number.doubleValue.isFinite
            else { throw fail("\(key): must be a positive number of seconds") }
            return number.doubleValue
        }

        var configuration = Configuration()

        // Patterns first: presets and leds may name them.
        for (name, value) in try table("patterns").sorted(by: { $0.key < $1.key }) {
            let key = "patterns.\(name)"
            guard let text = value as? String else { throw fail("\(key): expected a pattern string") }
            // A preset of the same name would hide the pattern wherever both are accepted.
            guard isValidName(name), LEDState(rawValue: name) == nil, builtInPresets[name] == nil else {
                throw fail("\(key): not a usable name (letters, digits, - and _; not a state or preset name)")
            }
            do {
                configuration.patterns[name] = try Pattern(parsing: text, name: name)
            } catch {
                throw fail("\(key): \(ChargeLightError.wrap(error).message)")
            }
        }

        for (name, value) in try table("presets").sorted(by: { $0.key < $1.key }) {
            let key = "presets.\(name)"
            guard let fields = value as? [String: Any] else { throw fail("\(key): expected an object") }
            guard isValidName(name), LEDState(rawValue: name) == nil, configuration.patterns[name] == nil else {
                throw fail("\(key): not a usable name (letters, digits, - and _; not a state or pattern name)")
            }
            if let unknown = fields.keys.sorted().first(where: { !["led", "priority", "ttl"].contains($0) }) {
                throw fail("\(key).\(unknown): unknown key (expected: led, priority, ttl)")
            }
            var preset = configuration.presets[name]
                ?? Preset(led: "amber", priority: defaultPriority, ttl: defaultTTL)
            if let led = fields["led"] {
                guard let text = led as? String else { throw fail("\(key).led: expected a string") }
                preset.led = text
            } else if configuration.presets[name] == nil {
                throw fail("\(key).led: missing")
            }
            if let priority = fields["priority"] {
                guard let number = priority as? NSNumber, !(priority is Bool),
                      number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) <= 1_000_000
                else { throw fail("\(key).priority: expected a whole number") }
                preset.priority = number.intValue
            }
            if let ttl = fields["ttl"] { preset.ttl = try seconds(ttl, "\(key).ttl") }
            configuration.presets[name] = preset
        }

        for (name, value) in try table("leds").sorted(by: { $0.key < $1.key }) {
            let key = "leds.\(name)"
            guard let text = value as? String else { throw fail("\(key): expected a string") }
            if name == "idle" {
                configuration.idle = try idleState(text, key: key, fail: fail)
            } else if builtInPresets[name] != nil {
                configuration.presets[name]?.led = text
            } else {
                throw fail("\(key): unknown key (expected: working, attention, ready, idle)")
            }
        }
        if let idle = object["idle"] {
            guard let text = idle as? String else { throw fail("idle: expected a string") }
            configuration.idle = try idleState(text, key: "idle", fail: fail)
        }
        for (name, value) in try table("ttl").sorted(by: { $0.key < $1.key }) {
            guard builtInPresets[name] != nil else {
                throw fail("ttl.\(name): unknown key (expected: working, attention, ready)")
            }
            configuration.presets[name]?.ttl = try seconds(value, "ttl.\(name)")
        }

        // Every preset must show something that exists.
        for (name, preset) in configuration.presets.sorted(by: { $0.key < $1.key }) {
            do {
                _ = try configuration.resolveLED(preset.led)
            } catch {
                let key = builtInPresets[name] != nil && (object["presets"] as? [String: Any])?[name] == nil
                    ? "leds.\(name)" : "presets.\(name).led"
                throw fail("\(key): \(ChargeLightError.wrap(error).message)")
            }
        }
        return configuration
    }

    /// Environment variables that override what a built-in preset shows.
    static let environmentPresets: [(name: String, preset: String)] = [
        ("CHARGELIGHT_LED_WORKING", "working"),
        ("CHARGELIGHT_LED_ATTENTION", "attention"),
        ("CHARGELIGHT_LED_READY", "ready"),
    ]

    /// Applies the `CHARGELIGHT_LED_*` overrides. Empty values are ignored.
    public mutating func applyEnvironment(_ environment: [String: String]) throws {
        func value(_ name: String) -> String? {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return value
        }
        for (name, preset) in Configuration.environmentPresets {
            guard let text = value(name) else { continue }
            do {
                _ = try resolveLED(text)
            } catch {
                throw ChargeLightError.invalidArgument("\(name): \(ChargeLightError.wrap(error).message)")
            }
            presets[preset]?.led = text
        }
        if let text = value("CHARGELIGHT_LED_IDLE") {
            idle = try Configuration.idleState(text, key: "CHARGELIGHT_LED_IDLE") { .invalidArgument($0) }
        }
    }

    private static func idleState(
        _ text: String, key: String, fail: (String) -> ChargeLightError
    ) throws -> LEDState {
        guard let state = LEDState(rawValue: text) else {
            throw fail("\(key): unknown LED state \"\(text)\" (expected one of: \(LEDState.namesList))")
        }
        return state
    }

    /// Names are used on the command line, so keep them simple.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && !name.hasPrefix("-")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
