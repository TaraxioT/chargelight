import CChargeLightSMC
import Foundation

/// Something that can read and change the LED: the real hardware, or a stand-in.
public protocol LEDBackend {
    /// Reads the current LED value.
    func read() throws -> LEDReading
    /// Changes the LED.
    func write(_ state: LEDState) throws
}

/// The MagSafe LED on this Mac, through AppleSMC.
///
/// Reading works for any user. Writing is done directly when running as root,
/// and otherwise through `sudo -n <helperPath> set <state>`, which works
/// without a password once `sudo chargelight setup` has installed the helper.
///
/// ``write(_:)`` writes once. macOS can take the LED back within seconds, so
/// to keep a state use ``makeHold()`` (or ``ChargeLight/hold(_:)``).
public struct SMCBackend: HoldingLEDBackend {
    /// Where `chargelight setup` installs the privileged helper.
    public static let defaultHelperPath = "/Library/PrivilegedHelperTools/chargelight-helper"

    /// The message every "not set up yet" error carries.
    public static let setupHint = "run: sudo chargelight setup"

    /// The installed helper used for unprivileged writes.
    public var helperPath: String

    /// Path to `sudo`.
    public var sudoPath: String

    /// Creates a backend that writes through the helper at `helperPath`.
    public init(helperPath: String = SMCBackend.defaultHelperPath, sudoPath: String = "/usr/bin/sudo") {
        self.helperPath = helperPath
        self.sudoPath = sudoPath
    }

    public func read() throws -> LEDReading {
        var raw: UInt8 = 0
        let status = cl_led_read(&raw)
        guard status == CL_OK else { throw SMCBackend.error(for: status, action: "read") }
        return LEDReading(raw: raw)
    }

    /// Whether the privileged helper is installed at ``helperPath``.
    public var isHelperInstalled: Bool { FileIO.exists(helperPath) }

    public func makeHold() throws -> LEDHolding {
        try LEDHold(helperPath: helperPath, sudoPath: sudoPath)
    }

    public func write(_ state: LEDState) throws {
        if geteuid() == 0 {
            let status = cl_led_write(state.byte)
            guard status == CL_OK else { throw SMCBackend.error(for: status, action: "write") }
            return
        }
        guard FileIO.exists(helperPath) else { throw ChargeLightError.setupRequired(SMCBackend.setupHint) }
        let result = try Subprocess.run(sudoPath, ["-n", helperPath, "set", state.rawValue])
        if let error = SMCBackend.helperError(status: result.status, stderr: result.stderr) {
            throw error
        }
    }

    /// Maps the outcome of `sudo -n chargelight-helper set ...` to an error, or
    /// `nil` on success.
    static func helperError(status: Int32, stderr: String) -> ChargeLightError? {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 0: return nil
        case 2: return .invalidArgument(detail.isEmpty ? "helper rejected the arguments" : detail)
        case 3: return .unsupportedHardware(detail.isEmpty ? "this Mac has no MagSafe LED" : detail)
        case 5: return .notPrivileged(detail.isEmpty ? "helper is not running as root" : detail)
        case 6: return .smc(detail.isEmpty ? "SMC write failed" : detail)
        default:
            let lower = detail.lowercased()
            if lower.contains("password is required") || lower.contains("not allowed")
                || lower.contains("may not run sudo") || lower.contains("not in the sudoers")
            {
                return .setupRequired(SMCBackend.setupHint)
            }
            return .smc("helper failed (exit \(status))" + (detail.isEmpty ? "" : ": \(detail)"))
        }
    }

    static func error(for status: cl_status, action: String) -> ChargeLightError {
        let detail = cl_last_error_detail()
        let text = "cannot \(action) the LED: \(String(cString: cl_status_string(status)))"
            + (detail.code != 0 ? " (\(detail.from_smc != 0 ? "SMC result" : "IOKit") 0x\(String(detail.code, radix: 16)))" : "")
        switch status {
        case CL_ERR_NO_SERVICE, CL_ERR_KEY_NOT_FOUND:
            return .unsupportedHardware(text + "; this Mac has no MagSafe 3 LED")
        case CL_ERR_NOT_PRIVILEGED: return .notPrivileged(text)
        case CL_ERR_INVALID: return .invalidArgument(text)
        default: return .smc(text)
        }
    }
}

/// A stand-in backend that keeps the LED state as a name in a text file.
///
/// It returns exactly what was last written (``LEDState/system`` if nothing
/// was), needs no hardware and no root, and is what `CHARGELIGHT_BACKEND=file`
/// selects.
public struct FileBackend: LEDBackend {
    /// The file holding the state name.
    public var url: URL

    /// Creates a backend storing its state in `url`.
    public init(url: URL) {
        self.url = url
    }

    public func read() throws -> LEDReading {
        guard let data = try FileIO.readIfPresent(url) else { return LEDReading(raw: LEDState.system.byte) }
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let state = LEDState(rawValue: name) else {
            throw ChargeLightError.io("\(url.path): unknown LED state \"\(name)\"")
        }
        return LEDReading(raw: state.byte)
    }

    public func write(_ state: LEDState) throws {
        try FileIO.writeAtomically(Data((state.rawValue + "\n").utf8), to: url)
    }
}
