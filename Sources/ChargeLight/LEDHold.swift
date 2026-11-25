import Foundation

/// Something that keeps the LED in a state until told otherwise.
public protocol LEDHolding: AnyObject {
    /// Holds `state` from now on, replacing the previous one.
    func set(_ state: LEDState) throws
    /// Stops holding. With `restoreSystem`, control goes back to macOS;
    /// without, the LED is left exactly as it is.
    func stop(restoreSystem: Bool)
}

/// A backend that can hold a state as well as write it once.
///
/// A single write does not always last: macOS can take the LED back within
/// seconds, and always does when the charger is replugged. ``Watcher`` uses a
/// hold when the backend offers one.
public protocol HoldingLEDBackend: LEDBackend {
    /// Starts a hold. Nothing is written until the first ``LEDHolding/set(_:)``.
    func makeHold() throws -> LEDHolding
}

/// Keeps the MagSafe LED in a state for as long as this object lives.
///
/// ```swift
/// let hold = try ChargeLight.hold(.amber)   // stays amber, whatever macOS does
/// hold.set(.blinkFast)
/// hold.stop()                               // back to the normal charging light
/// ```
///
/// Behind it is one long-running `chargelight-helper hold` process (started
/// with `sudo -n`, or directly when already root) that checks the LED about
/// thirty times a second and writes the state again when it has changed. If this
/// process exits or crashes the helper notices and hands the LED back to
/// macOS, so a hold can never leave the light stuck.
public final class LEDHold: LEDHolding {
    private let helperPath: String
    private let sudoPath: String
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?

    /// Creates a hold driven by the helper at `helperPath`.
    ///
    /// - Throws: ``ChargeLightError/setupRequired(_:)`` if the helper is not
    ///   installed or cannot be run without a password.
    public init(helperPath: String = SMCBackend.defaultHelperPath, sudoPath: String = "/usr/bin/sudo") throws {
        self.helperPath = helperPath
        self.sudoPath = sudoPath
        try preflight()
    }

    deinit {
        stop(restoreSystem: true)
    }

    /// Holds `state` from now on. Starts the helper on first use and restarts
    /// it if it has died.
    public func set(_ state: LEDState) throws {
        lock.lock()
        defer { lock.unlock() }
        let line = Data((state.rawValue + "\n").utf8)
        if process?.isRunning == true, let input, write(line, to: input) { return }
        closeLocked(sendQuit: false)
        try startLocked()
        guard let input, write(line, to: input) else {
            closeLocked(sendQuit: false)
            throw ChargeLightError.smc("the LED helper stopped unexpectedly")
        }
    }

    /// Stops holding. By default control goes back to macOS; pass
    /// `restoreSystem: false` to leave the LED showing the last state.
    public func stop(restoreSystem: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        closeLocked(sendQuit: !restoreSystem)
    }

    // MARK: - Internals

    private var isRoot: Bool { geteuid() == 0 }

    /// Fails early, with a useful error, instead of leaving a helper that
    /// exits the moment it starts.
    private func preflight() throws {
        guard FileIO.exists(helperPath) else { throw ChargeLightError.setupRequired(SMCBackend.setupHint) }
        guard !isRoot else { return }
        let check = try Subprocess.run(sudoPath, ["-n", helperPath, "--version"])
        if let error = SMCBackend.helperError(status: check.status, stderr: check.stderr) { throw error }
    }

    private func startLocked() throws {
        let child = Process()
        if isRoot {
            child.executableURL = URL(fileURLWithPath: helperPath)
            child.arguments = ["hold"]
        } else {
            child.executableURL = URL(fileURLWithPath: sudoPath)
            child.arguments = ["-n", helperPath, "hold"]
        }
        let pipe = Pipe()
        child.standardInput = pipe
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            throw ChargeLightError.io("cannot start the LED helper: \(error.localizedDescription)")
        }
        // The helper sees end-of-input only if this is the last copy of the
        // write end, and a dead helper must not kill us with SIGPIPE.
        try? pipe.fileHandleForReading.close()
        let handle = pipe.fileHandleForWriting
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        process = child
        input = handle
    }

    private func closeLocked(sendQuit: Bool) {
        if let input {
            if sendQuit { _ = write(Data("quit\n".utf8), to: input) }
            try? input.close()
        }
        input = nil
        process = nil
    }

    /// Writes all of `data`, returning `false` if the pipe is broken.
    private func write(_ data: Data, to handle: FileHandle) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(handle.fileDescriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }
}

/// Routes writes through a hold, so a state that is synced is also kept.
struct HeldBackend: LEDBackend {
    var base: LEDBackend
    var hold: LEDHolding

    func read() throws -> LEDReading { try base.read() }
    func write(_ state: LEDState) throws { try hold.set(state) }
}
