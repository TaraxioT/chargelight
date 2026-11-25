import Foundation

/// A repeating sequence of LED states, played in software.
///
/// The hardware has two blinks of its own, both amber
/// (``LEDState/blinkSlow``, ``LEDState/blinkFast``). A pattern gives you
/// everything else: green blinks, two-colour alternation, a heartbeat, Morse.
///
/// Written as text, a pattern is steps separated by commas, each
/// `state:duration`. A bare number is milliseconds; `ms` and `s` suffixes work
/// too: `amber:300,off:300`, `green:0.5s,off:1s`.
public struct Pattern: Equatable, Sendable {
    /// One state shown for a length of time.
    public struct Step: Equatable, Sendable {
        /// The state to show.
        public var state: LEDState
        /// How long to show it, in seconds.
        public var duration: TimeInterval

        /// Creates a step.
        public init(_ state: LEDState, _ duration: TimeInterval) {
            self.state = state
            self.duration = duration
        }
    }

    /// The shortest step allowed. A write takes about 15 to 30 ms to reach the
    /// LED, so anything shorter does not show reliably.
    public static let minimumStep: TimeInterval = 0.05
    /// The longest step allowed.
    public static let maximumStep: TimeInterval = 60
    /// The most steps a pattern may have.
    public static let maximumSteps = 512

    /// The steps, played in order and then repeated.
    public var steps: [Step]
    /// The name the pattern was looked up by, if any.
    public var name: String?

    /// Creates a pattern from steps.
    ///
    /// - Throws: ``ChargeLightError/invalidArgument(_:)`` if there are no
    ///   steps, too many, or a step is outside the allowed durations.
    public init(steps: [Step], name: String? = nil) throws {
        guard !steps.isEmpty else { throw ChargeLightError.invalidArgument("a pattern needs at least one step") }
        guard steps.count <= Pattern.maximumSteps else {
            throw ChargeLightError.invalidArgument("a pattern can have at most \(Pattern.maximumSteps) steps")
        }
        for step in steps where !(step.duration >= Pattern.minimumStep && step.duration <= Pattern.maximumStep) {
            throw ChargeLightError.invalidArgument(
                "pattern step \(step.state.rawValue):\(Pattern.format(step.duration)) must last between 50 ms and 60 s")
        }
        self.steps = steps
        self.name = name
    }

    /// Parses `state:duration,state:duration,...`.
    public init(parsing text: String, name: String? = nil) throws {
        var steps: [Step] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let fields = part.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 2, let state = LEDState(rawValue: String(fields[0])) else {
                throw ChargeLightError.invalidArgument(
                    "invalid pattern step \"\(part)\" (expected state:duration, e.g. amber:300; states: \(LEDState.namesList))")
            }
            guard let duration = Pattern.parseStepDuration(String(fields[1])) else {
                throw ChargeLightError.invalidArgument(
                    "invalid duration in pattern step \"\(part)\" (examples: 300, 300ms, 0.5s)")
            }
            steps.append(Step(state, duration))
        }
        try self.init(steps: steps, name: name)
    }

    /// The length of one pass through the steps, in seconds.
    public var duration: TimeInterval {
        steps.reduce(0) { $0 + $1.duration }
    }

    /// The pattern as `state:milliseconds,...`.
    public var literal: String {
        steps.map { "\($0.state.rawValue):\(Pattern.format($0.duration))" }.joined(separator: ",")
    }

    /// Patterns available by name everywhere a state is accepted.
    public static let builtIn: [String: Pattern] = {
        let definitions: [(String, String)] = [
            ("blink-green", "green:500,off:500"),
            ("blink-green-fast", "green:150,off:150"),
            ("alternate", "amber:400,green:400"),
            ("heartbeat", "amber:120,off:120,amber:120,off:840"),
            ("heartbeat-green", "green:120,off:120,green:120,off:840"),
        ]
        var patterns: [String: Pattern] = [:]
        for (name, text) in definitions {
            patterns[name] = try? Pattern(parsing: text, name: name)
        }
        patterns["sos"] = try? Pattern.morse("SOS", name: "sos")
        return patterns
    }()

    /// Spells `text` in Morse code: letters and digits; anything else is a word gap.
    ///
    /// - Parameters:
    ///   - lit: The state shown for dots and dashes.
    ///   - unit: The length of a dot in seconds. A dash is three units, the gap
    ///     between letters three, between words seven.
    public static func morse(
        _ text: String, lit: LEDState = .amber, unit: TimeInterval = 0.15, name: String? = nil
    ) throws -> Pattern {
        var steps: [Step] = []
        func gap(_ units: Double) {
            // Extend the previous gap rather than adding a second one.
            if let last = steps.last, last.state == .off {
                steps[steps.count - 1].duration = max(last.duration, units * unit)
            } else if !steps.isEmpty {
                steps.append(Step(.off, units * unit))
            }
        }
        for character in text.uppercased() {
            guard let code = morseCode[character] else {
                gap(7)
                continue
            }
            for (index, symbol) in code.enumerated() {
                if index > 0 { steps.append(Step(.off, unit)) }
                steps.append(Step(lit, symbol == "-" ? 3 * unit : unit))
            }
            gap(3)
        }
        guard steps.contains(where: { $0.state != .off }) else {
            throw ChargeLightError.invalidArgument("nothing to send: Morse code covers letters and digits")
        }
        gap(7)
        return try Pattern(steps: steps, name: name)
    }

    static let morseCode: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.", "G": "--.", "H": "....",
        "I": "..", "J": ".---", "K": "-.-", "L": ".-..", "M": "--", "N": "-.", "O": "---", "P": ".--.",
        "Q": "--.-", "R": ".-.", "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-",
        "Y": "-.--", "Z": "--..", "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-",
        "5": ".....", "6": "-....", "7": "--...", "8": "---..", "9": "----.",
    ]

    /// Parses a step duration: `300` and `300ms` are milliseconds, `0.5s` seconds.
    static func parseStepDuration(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let (number, scale): (Substring, Double)
        if trimmed.hasSuffix("ms") {
            (number, scale) = (trimmed.dropLast(2), 0.001)
        } else if trimmed.hasSuffix("s") {
            (number, scale) = (trimmed.dropLast(), 1)
        } else {
            (number, scale) = (Substring(trimmed), 0.001)
        }
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              number.filter({ $0 == "." }).count <= 1, let value = Double(number)
        else { return nil }
        return value * scale
    }

    /// Whole milliseconds, as used in ``literal``.
    static func format(_ duration: TimeInterval) -> String {
        String(Int((duration * 1000).rounded()))
    }
}

/// What the LED should show: one state, or a pattern.
public enum LEDSpec: Equatable, Sendable, CustomStringConvertible {
    /// A fixed state.
    case state(LEDState)
    /// A repeating pattern.
    case pattern(Pattern)

    /// System control.
    public static let system = LEDSpec.state(.system)
    /// LED off.
    public static let off = LEDSpec.state(.off)
    /// Solid green.
    public static let green = LEDSpec.state(.green)
    /// Solid amber.
    public static let amber = LEDSpec.state(.amber)
    /// The hardware's slow amber blink.
    public static let blinkSlow = LEDSpec.state(.blinkSlow)
    /// The hardware's fast amber blink.
    public static let blinkFast = LEDSpec.state(.blinkFast)

    /// The state name, the pattern's name, or the pattern written out.
    public var description: String {
        switch self {
        case .state(let state): return state.rawValue
        case .pattern(let pattern): return pattern.name ?? pattern.literal
        }
    }

    /// The fixed state, or `nil` for a pattern.
    public var state: LEDState? {
        if case .state(let state) = self { return state }
        return nil
    }

    /// The pattern, or `nil` for a fixed state.
    public var pattern: Pattern? {
        if case .pattern(let pattern) = self { return pattern }
        return nil
    }

    /// The state itself, or a pattern's first step: what a single write shows.
    public var firstState: LEDState {
        switch self {
        case .state(let state): return state
        case .pattern(let pattern): return pattern.steps[0].state
        }
    }
}
