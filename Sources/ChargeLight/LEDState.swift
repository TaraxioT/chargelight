import CChargeLightSMC

/// A state the MagSafe 3 charger LED can be put in.
///
/// The raw values are the names used on the command line and in configuration
/// files; ``byte`` is the value written to the SMC key `ACLC`.
public enum LEDState: String, CaseIterable, Codable, Sendable {
    /// Hand control back to macOS, which shows the charging state (amber or green).
    case system
    /// LED off.
    case off
    /// Solid green.
    case green
    /// Solid amber.
    case amber
    /// Amber, blinking slowly.
    case blinkSlow = "blink-slow"
    /// Amber, blinking fast.
    case blinkFast = "blink-fast"

    /// The raw byte for the `ACLC` SMC key.
    public var byte: UInt8 {
        switch self {
        case .system: return UInt8(CL_LED_SYSTEM.rawValue)
        case .off: return UInt8(CL_LED_OFF.rawValue)
        case .green: return UInt8(CL_LED_GREEN.rawValue)
        case .amber: return UInt8(CL_LED_AMBER.rawValue)
        case .blinkSlow: return UInt8(CL_LED_BLINK_SLOW.rawValue)
        case .blinkFast: return UInt8(CL_LED_BLINK_FAST.rawValue)
        }
    }

    /// Decodes a raw `ACLC` byte. `0x02`, which some firmware reports for the
    /// system-controlled green, maps to ``green``. Returns `nil` for unknown bytes.
    public init?(byte: UInt8) {
        if byte == 0x02 {
            self = .green
            return
        }
        guard let state = LEDState.allCases.first(where: { $0.byte == byte }) else { return nil }
        self = state
    }

    /// The accepted state names, joined for help and error messages.
    public static var namesList: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}

/// One reading of the LED key.
public struct LEDReading: Equatable, Sendable {
    /// The byte read from `ACLC`.
    public var raw: UInt8
    /// The decoded state, or `nil` if the byte is not one chargelight knows.
    public var state: LEDState?

    /// Creates a reading from a raw byte, decoding the state with ``LEDState/init(byte:)``.
    public init(raw: UInt8) {
        self.raw = raw
        self.state = LEDState(byte: raw)
    }
}
