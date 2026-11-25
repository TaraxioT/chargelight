import ChargeLight
@testable import ChargeLightCommands
import Foundation
import XCTest

/// A temporary state directory, removed on deinit.
final class TempHome {
    let url: URL
    var paths: Paths { Paths(root: url) }

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chargelight-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// A hermetic environment: file backend, no watcher, a helper path that does not exist.
    var environment: [String: String] {
        [
            "CHARGELIGHT_HOME": url.path,
            "CHARGELIGHT_BACKEND": "file",
            "CHARGELIGHT_NO_WATCHER": "1",
            "CHARGELIGHT_HELPER": url.appendingPathComponent("no-such-helper").path,
        ]
    }

    /// The state name in the file backend's LED file, or nil if never written.
    var ledFile: String? {
        (try? String(contentsOf: paths.ledFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// An in-memory backend that counts writes and can simulate hardware drift.
final class CountingBackend: LEDBackend {
    var current: LEDState = .system
    var raw: UInt8?
    private(set) var writes: [LEDState] = []
    var failWrites: ChargeLightError?

    func read() throws -> LEDReading {
        LEDReading(raw: raw ?? current.byte)
    }

    func write(_ state: LEDState) throws {
        if let failWrites { throw failWrites }
        writes.append(state)
        current = state
        raw = nil
    }
}

/// A backend that offers a hold, recording what goes through it and what is written directly.
final class HoldingBackend: HoldingLEDBackend {
    final class Hold: LEDHolding {
        private let lock = NSLock()
        private var recordedStates: [LEDState] = []
        private var recordedStops: [Bool] = []
        var states: [LEDState] { lock.lock(); defer { lock.unlock() }; return recordedStates }
        var stops: [Bool] { lock.lock(); defer { lock.unlock() }; return recordedStops }
        func set(_ state: LEDState) throws { lock.lock(); recordedStates.append(state); lock.unlock() }
        func stop(restoreSystem: Bool) { lock.lock(); recordedStops.append(restoreSystem); lock.unlock() }
    }

    let hold = Hold()
    private(set) var direct: [LEDState] = []

    func makeHold() throws -> LEDHolding { hold }
    func read() throws -> LEDReading { LEDReading(raw: (hold.states.last ?? .system).byte) }
    func write(_ state: LEDState) throws { direct.append(state) }
}

/// The captured result of one `runChargeLight` call.
struct CLIRun {
    var code: Int32
    var stdout: String
    var stderr: String

    /// stdout parsed as a single JSON object.
    var json: [String: Any] {
        let lines = stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "expected exactly one line of JSON, got: \(stdout)")
        let object = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
        XCTAssertNotNil(object, "not a JSON object: \(stdout)")
        return object ?? [:]
    }
}

func runCLI(
    _ arguments: [String], environment: [String: String], stdin: String = "", stamp: UInt64? = nil,
    terminal: TerminalFacts = TerminalFacts()
) -> CLIRun {
    var out = ""
    var err = ""
    var lines = stdin.isEmpty ? [] : stdin.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    let code = runChargeLight(
        arguments: arguments, environment: environment, stdin: { Data(stdin.utf8) },
        readLine: { lines.isEmpty ? nil : lines.removeFirst() },
        stdout: { out += $0 }, stderr: { err += $0 },
        stamp: stamp ?? Claim.currentStamp(), executablePath: "/nonexistent/chargelight", terminal: terminal)
    return CLIRun(code: code, stdout: out, stderr: err)
}

/// A CLI run in-process with injected input lines, keeping its output.
final class CLIHarness {
    let cli: CLI
    private let lock = NSLock()
    private var out = ""
    private var err = ""

    var stdout: String { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return err }

    init(
        environment: [String: String], readLine: @escaping () -> String? = { nil },
        terminal: TerminalFacts = TerminalFacts()
    ) {
        var appendOut: (String) -> Void = { _ in }
        var appendErr: (String) -> Void = { _ in }
        cli = CLI(
            environment: environment, stdin: { Data() }, readLine: readLine,
            stdout: { appendOut($0) }, stderr: { appendErr($0) },
            stamp: Claim.currentStamp(), executablePath: "/nonexistent/chargelight", terminal: { terminal })
        appendOut = { [unowned self] text in lock.lock(); out += text; lock.unlock() }
        appendErr = { [unowned self] text in lock.lock(); err += text; lock.unlock() }
    }

    func run(_ arguments: [String]) -> Int32 {
        cli.run(arguments)
    }
}
