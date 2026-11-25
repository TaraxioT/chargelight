import CChargeLightSMC
import Foundation

/// Convenience entry points for the MagSafe LED on this Mac.
///
/// ```swift
/// let hold = try ChargeLight.hold(.amber)   // keep it amber
/// hold.stop()                               // back to the charging light
/// let reading = try ChargeLight.read()
/// ```
///
/// For agent status with claims and expiry, use ``StatusLight``.
public enum ChargeLight {
    /// The chargelight version (shared by the library, the CLI and the helper).
    public static let version: String = CL_VERSION

    /// Reads the LED.
    public static func read() throws -> LEDReading {
        try SMCBackend().read()
    }

    /// Writes the LED once, through the privileged helper unless running as
    /// root. macOS can take the LED back within seconds; use ``hold(_:)`` to
    /// keep a state.
    public static func set(_ state: LEDState) throws {
        try SMCBackend().write(state)
    }

    /// Keeps the LED in `state` until the returned hold is stopped or released.
    public static func hold(_ state: LEDState) throws -> LEDHold {
        let hold = try LEDHold()
        try hold.set(state)
        return hold
    }

    /// Whether this Mac has a readable MagSafe LED key (`ACLC`).
    public static var isSupported: Bool {
        (try? read()) != nil
    }

    /// The backend selected by `environment`: ``FileBackend`` at
    /// ``Paths/ledFile`` when `CHARGELIGHT_BACKEND=file`, otherwise
    /// ``SMCBackend`` using `CHARGELIGHT_HELPER` as the helper path if set.
    public static func backend(environment: [String: String], paths: Paths) throws -> LEDBackend {
        switch environment["CHARGELIGHT_BACKEND"] ?? "" {
        case "", "smc":
            return SMCBackend(helperPath: helperPath(environment: environment))
        case "file":
            return FileBackend(url: paths.ledFile)
        case let other:
            throw ChargeLightError.invalidArgument("CHARGELIGHT_BACKEND: unknown backend \"\(other)\" (expected smc or file)")
        }
    }

    /// The helper path: `CHARGELIGHT_HELPER` if set, else ``SMCBackend/defaultHelperPath``.
    public static func helperPath(environment: [String: String]) -> String {
        if let path = environment["CHARGELIGHT_HELPER"], !path.isEmpty { return path }
        return SMCBackend.defaultHelperPath
    }
}
