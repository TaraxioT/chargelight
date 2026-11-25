import Foundation

/// Errors thrown by chargelight. Each case carries a human-readable message
/// and maps to a stable ``code`` and process ``exitCode``.
public enum ChargeLightError: Error, LocalizedError, Equatable, Sendable {
    /// This Mac has no MagSafe LED key, or no AppleSMC.
    case unsupportedHardware(String)
    /// Writing needs the privileged helper, which is not installed or not allowed.
    case setupRequired(String)
    /// The operation needs root.
    case notPrivileged(String)
    /// The SMC or IOKit reported a failure.
    case smc(String)
    /// A bad argument, configuration value or command line.
    case invalidArgument(String)
    /// A file system or process failure.
    case io(String)

    /// Stable machine-readable identifier, used in `--json` output.
    public var code: String {
        switch self {
        case .unsupportedHardware: return "unsupported_hardware"
        case .setupRequired: return "setup_required"
        case .notPrivileged: return "not_privileged"
        case .smc: return "smc_error"
        case .invalidArgument: return "invalid_argument"
        case .io: return "io_error"
        }
    }

    /// Stable process exit code for the CLI.
    public var exitCode: Int32 {
        switch self {
        case .unsupportedHardware: return 3
        case .setupRequired: return 4
        case .notPrivileged: return 5
        case .smc: return 6
        case .invalidArgument: return 2
        case .io: return 1
        }
    }

    /// The message the error was created with.
    public var message: String {
        switch self {
        case .unsupportedHardware(let m), .setupRequired(let m), .notPrivileged(let m),
             .smc(let m), .invalidArgument(let m), .io(let m):
            return m
        }
    }

    public var errorDescription: String? { message }
}

extension ChargeLightError {
    /// Wraps any error as a ``ChargeLightError``, keeping it if it already is
    /// one and reporting anything else as ``io(_:)``.
    public static func wrap(_ error: Error) -> ChargeLightError {
        if let error = error as? ChargeLightError { return error }
        return .io(error.localizedDescription)
    }

    /// An ``io(_:)`` error describing the current `errno`.
    static func posix(_ what: String, _ path: String, errno code: Int32 = errno) -> ChargeLightError {
        .io("\(what) \(path): \(String(cString: strerror(code)))")
    }
}
