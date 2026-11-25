import Foundation

// MARK: - What the terminal can do

/// Facts about the process's terminal, detected once per run and injectable
/// so tests can force either the plain or the interactive output.
public struct TerminalFacts {
    /// Standard output is a terminal.
    public var stdoutIsTerminal: Bool
    /// Standard input is a terminal (needed to read keys).
    public var stdinIsTerminal: Bool
    /// Standard error is a terminal.
    public var stderrIsTerminal: Bool
    /// The current size of the terminal (columns, rows), if known. Called again
    /// on every frame, so a resize is picked up.
    public var size: () -> (columns: Int, rows: Int)?

    /// Creates a set of facts; everything defaults to "not a terminal".
    public init(
        stdoutIsTerminal: Bool = false, stdinIsTerminal: Bool = false, stderrIsTerminal: Bool = false,
        size: @escaping () -> (columns: Int, rows: Int)? = { nil }
    ) {
        self.stdoutIsTerminal = stdoutIsTerminal
        self.stdinIsTerminal = stdinIsTerminal
        self.stderrIsTerminal = stderrIsTerminal
        self.size = size
    }

    /// The real standard input, output and error.
    public static func detect() -> TerminalFacts {
        TerminalFacts(
            stdoutIsTerminal: isatty(STDOUT_FILENO) == 1, stdinIsTerminal: isatty(STDIN_FILENO) == 1,
            stderrIsTerminal: isatty(STDERR_FILENO) == 1,
            size: { windowSize(STDOUT_FILENO) ?? windowSize(STDERR_FILENO) })
    }

    /// The window size of the terminal on `fd`, from `TIOCGWINSZ`.
    static func windowSize(_ fd: Int32) -> (columns: Int, rows: Int)? {
        var size = winsize()
        guard ioctl(fd, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
        return (Int(size.ws_col), Int(size.ws_row))
    }
}

/// How to draw: decided from ``TerminalFacts``, the environment and `--no-color`.
struct Style {
    /// Standard output is a terminal and `TERM` is not `dumb`: use the
    /// interactive layouts. Otherwise every command prints its plain output.
    var interactive = false
    /// Colour and bold.
    var color = false
    /// 24-bit colour; otherwise the 256-colour palette.
    var trueColor = false
    /// Animations (`CHARGELIGHT_NO_ANIMATION=1` turns them off).
    var motion = false
    /// Unicode glyphs; otherwise ASCII.
    var unicode = false
    /// The terminal's size, read again on every call.
    var size: () -> (columns: Int, rows: Int)? = { nil }

    /// Plain output: no escape codes of any kind.
    static let plain = Style()

    init() {}

    init(facts: TerminalFacts, environment: [String: String], noColor: Bool) {
        let dumb = environment["TERM"] == "dumb"
        interactive = facts.stdoutIsTerminal && !dumb
        color = interactive && Style.colorAllowed(environment: environment, noColor: noColor)
        trueColor = ["truecolor", "24bit"].contains(environment["COLORTERM"]?.lowercased() ?? "")
        motion = interactive && environment["CHARGELIGHT_NO_ANIMATION"] != "1"
        unicode = Style.isUTF8(environment: environment)
        size = facts.size
    }

    /// For text on standard error: colour only if standard error is a terminal.
    static func forStandardError(facts: TerminalFacts, environment: [String: String], noColor: Bool) -> Style {
        var style = Style()
        style.interactive = facts.stderrIsTerminal && environment["TERM"] != "dumb"
        style.color = style.interactive && colorAllowed(environment: environment, noColor: noColor)
        style.trueColor = ["truecolor", "24bit"].contains(environment["COLORTERM"]?.lowercased() ?? "")
        style.unicode = isUTF8(environment: environment)
        style.size = { TerminalFacts.windowSize(STDERR_FILENO) }
        return style
    }

    /// `--no-color` wins, then `CLICOLOR_FORCE=1`, then `NO_COLOR` (any non-empty value).
    static func colorAllowed(environment: [String: String], noColor: Bool) -> Bool {
        if noColor { return false }
        if let force = environment["CLICOLOR_FORCE"], !force.isEmpty, force != "0" { return true }
        return (environment["NO_COLOR"] ?? "").isEmpty
    }

    /// Whether the locale (`LC_ALL`, else `LC_CTYPE`, else `LANG`) is UTF-8.
    static func isUTF8(environment: [String: String]) -> Bool {
        let locale = ["LC_ALL", "LC_CTYPE", "LANG"].lazy.compactMap { environment[$0] }.first { !$0.isEmpty } ?? ""
        let lower = locale.lowercased()
        return lower.contains("utf-8") || lower.contains("utf8")
    }

    /// The terminal width in columns (80 if unknown, never below 10).
    var columns: Int { max(10, size()?.columns ?? 80) }
    /// The terminal height in rows (24 if unknown, never below 5).
    var rows: Int { max(5, size()?.rows ?? 24) }

    var glyphs: Glyphs { unicode ? .unicode : .ascii }

    // MARK: Rendering

    /// The escape sequence that starts `ink` (empty without colour).
    func start(_ ink: Ink?, bold: Bool) -> String {
        guard color, ink != nil || bold else { return "" }
        var codes: [String] = []
        if bold { codes.append("1") }
        if let ink {
            let (r, g, b, palette) = ink.rgb
            codes.append(trueColor ? "38;2;\(r);\(g);\(b)" : "38;5;\(palette)")
        }
        return "\u{1B}[" + codes.joined(separator: ";") + "m"
    }

    func render(_ span: Span) -> String {
        let open = start(span.ink, bold: span.bold)
        return open.isEmpty ? span.text : open + span.text + "\u{1B}[0m"
    }

    func render(_ line: Line) -> String {
        line.spans.map(render).joined()
    }

    func render(_ lines: [Line]) -> String {
        lines.map(render).joined(separator: "\n")
    }
}

/// The palette: two accents and a grey. Never a background colour.
enum Ink: Equatable {
    case amber, green, grey, red

    /// 24-bit value and the nearest 256-colour palette index.
    var rgb: (Int, Int, Int, Int) {
        switch self {
        case .amber: return (0xFF, 0x9F, 0x0A, 214)
        case .green: return (0x30, 0xD1, 0x58, 77)
        case .grey: return (0x6E, 0x6E, 0x73, 242)
        case .red: return (0xFF, 0x45, 0x3A, 203)
        }
    }
}

/// A run of text in one style.
struct Span: Equatable {
    var text: String
    var ink: Ink?
    var bold = false

    init(_ text: String, _ ink: Ink? = nil, bold: Bool = false) {
        self.text = text
        self.ink = ink
        self.bold = bold
    }

    static func dim(_ text: String) -> Span { Span(text, .grey) }
    static func strong(_ text: String) -> Span { Span(text, bold: true) }
}

/// One line of styled text. Every glyph used is one column wide.
struct Line: Equatable, ExpressibleByStringLiteral {
    var spans: [Span]

    init(_ spans: [Span] = []) { self.spans = spans }
    init(_ text: String) { self.spans = text.isEmpty ? [] : [Span(text)] }
    init(stringLiteral value: String) { self.init(value) }

    static let blank = Line()

    /// The width in columns.
    var width: Int { spans.reduce(0) { $0 + $1.text.count } }
    /// The text without styling.
    var text: String { spans.map(\.text).joined() }

    static func + (lhs: Line, rhs: Line) -> Line { Line(lhs.spans + rhs.spans) }
    static func + (lhs: Line, rhs: Span) -> Line { Line(lhs.spans + [rhs]) }
    static func += (lhs: inout Line, rhs: Span) { lhs.spans.append(rhs) }
    static func += (lhs: inout Line, rhs: Line) { lhs.spans += rhs.spans }

    /// Prefixed with `count` spaces.
    func indented(_ count: Int) -> Line { count > 0 ? Line([Span(String(repeating: " ", count: count))] + spans) : self }

    /// Padded with spaces to `width` columns.
    func padded(to width: Int) -> Line {
        let missing = width - self.width
        return missing > 0 ? self + Span(String(repeating: " ", count: missing)) : self
    }

    /// Cut to at most `width` columns, ending in `ellipsis` if anything was cut.
    func truncated(to width: Int, ellipsis: String = "…") -> Line {
        guard self.width > width else { return self }
        guard width > 0 else { return Line() }
        var cells = Array(self.cells.prefix(max(0, width - ellipsis.count)))
        let ink = cells.last?.ink
        cells += ellipsis.map { Cell(character: $0, ink: ink, bold: false) }
        return Line(cells: Array(cells.prefix(width)))
    }

    /// Word-wrapped to `width` columns; continuation lines start with `indent` spaces.
    func wrapped(to width: Int, indent: Int = 0) -> [Line] {
        guard self.width > width, width > indent + 4 else { return [truncated(to: max(1, width))] }
        var result: [Line] = []
        var rest = cells
        var first = true
        while !rest.isEmpty {
            let lead = first ? 0 : indent
            let room = width - lead
            if rest.count <= room {
                result.append(Line(cells: rest).indented(lead))
                break
            }
            // Break at the last space that fits; otherwise mid-word.
            var cut = room
            if let space = rest[0...room].lastIndex(where: { $0.character == " " }), space > room / 3 { cut = space }
            result.append(Line(cells: Array(rest[..<cut])).trimmingTrailingSpaces().indented(lead))
            rest = Array(rest[cut...].drop { $0.character == " " })
            first = false
        }
        return result
    }

    func trimmingTrailingSpaces() -> Line {
        var cells = self.cells
        while cells.last?.character == " " { cells.removeLast() }
        return Line(cells: cells)
    }

    // One character with its style, for cutting lines.
    struct Cell: Equatable {
        var character: Character
        var ink: Ink?
        var bold: Bool
    }

    var cells: [Cell] {
        spans.flatMap { span in span.text.map { Cell(character: $0, ink: span.ink, bold: span.bold) } }
    }

    init(cells: [Cell]) {
        var spans: [Span] = []
        for cell in cells {
            if let last = spans.last, last.ink == cell.ink, last.bold == cell.bold {
                spans[spans.count - 1].text.append(cell.character)
            } else {
                spans.append(Span(String(cell.character), cell.ink, bold: cell.bold))
            }
        }
        self.spans = spans
    }
}

/// Removes ANSI escape sequences (CSI, OSC and two-byte escapes).
func stripANSI(_ text: String) -> String {
    var result = ""
    var iterator = text.unicodeScalars.makeIterator()
    while let scalar = iterator.next() {
        guard scalar == "\u{1B}" else {
            result.unicodeScalars.append(scalar)
            continue
        }
        guard let kind = iterator.next() else { break }
        switch kind {
        case "[":
            while let next = iterator.next(), !(0x40...0x7E).contains(next.value) {}
        case "]":
            var previous: Unicode.Scalar?
            while let next = iterator.next() {
                if next == "\u{7}" || (previous == "\u{1B}" && next == "\\") { break }
                previous = next
            }
        default:
            break
        }
    }
    return result
}

// MARK: - Glyphs

/// Every symbol drawn, in Unicode and in ASCII.
struct Glyphs {
    var lit: String
    var unlit: String
    var system: String
    var cellLit: String
    var cellOff: String
    var cellSystem: String
    var caret: String
    var check: String
    var cross: String
    var bullet: String
    var winner: String
    var ellipsis: String
    var morseDot: String
    var morseDash: String
    var separator: String
    var cursor: String
    /// The plug: rows, with `@` where the dot goes.
    var plug: [String]
    /// The one-row plug, `@` for the dot.
    var inlinePlug: String

    static let unicode = Glyphs(
        lit: "●", unlit: "○", system: "◌", cellLit: "▇", cellOff: "░", cellSystem: "·", caret: "▲",
        check: "✔", cross: "✘", bullet: "•", winner: "▶", ellipsis: "…", morseDot: "·", morseDash: "−",
        separator: "·", cursor: "▏",
        plug: [
            "             ╭──────────────╮ ",
            "━━━━━━━━━━━━━┥      @       │▌",
            "             ╰──────────────╯ ",
        ],
        inlinePlug: "━━┥ @ │▌")

    static let ascii = Glyphs(
        lit: "*", unlit: "o", system: "~", cellLit: "#", cellOff: "-", cellSystem: ".", caret: "^",
        check: "ok", cross: "x", bullet: "-", winner: ">", ellipsis: "...", morseDot: ".", morseDash: "-",
        separator: "-", cursor: "_",
        plug: [
            "             .--------------. ",
            "=============|      @       |]",
            "             '--------------' ",
        ],
        inlinePlug: "==| @ |]")
}

// MARK: - Terminal state

/// Bytes and terminal settings a crash handler puts back. Global so a plain
/// C signal handler can reach them without allocating.
private var emergencyBytes: UnsafeMutablePointer<UInt8>?
private var emergencyCount = 0
private var emergencyTermios = termios()
private var emergencyHasTermios = false
private var emergencyPrevious: [Int32: sigaction] = [:]

private let crashSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGQUIT]

/// Restores the terminal with async-signal-safe calls only, then dies of the
/// same signal.
private func emergencyRestore(_ signal: Int32) {
    if let bytes = emergencyBytes { _ = write(STDOUT_FILENO, bytes, emergencyCount) }
    if emergencyHasTermios { _ = tcsetattr(STDIN_FILENO, TCSANOW, &emergencyTermios) }
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

/// Takes over the terminal (hidden cursor, alternate screen, raw keys) and
/// always gives it back: on ``end()``, and from a crash handler installed
/// before anything is changed.
final class TerminalSession {
    private let write: (String) -> Void
    private var restore = ""
    private var savedTermios: termios?
    private(set) var active = false

    init(write: @escaping (String) -> Void) {
        self.write = write
    }

    deinit { end() }

    /// - Parameters:
    ///   - alternateScreen: Draw on the alternate screen (left again on ``end()``).
    ///   - raw: Read keys one at a time, without echo (needs stdin to be a terminal).
    func begin(alternateScreen: Bool, raw: Bool) {
        guard !active else { return }
        active = true
        restore = "\u{1B}[0m\u{1B}[?2026l\u{1B}[?25h" + (alternateScreen ? "\u{1B}[?1049l" : "")
        var original = termios()
        let haveTermios = raw && tcgetattr(STDIN_FILENO, &original) == 0
        if haveTermios { savedTermios = original }
        // Arm the crash handler first, so nothing below can leave the terminal broken.
        TerminalSession.arm(restore: restore, termios: haveTermios ? original : nil)
        if haveTermios {
            var settings = original
            settings.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
            settings.c_iflag &= ~tcflag_t(IXON | ICRNL)
            withUnsafeMutablePointer(to: &settings.c_cc) {
                $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) {
                    $0[Int(VMIN)] = 1
                    $0[Int(VTIME)] = 0
                }
            }
            tcsetattr(STDIN_FILENO, TCSANOW, &settings)
        }
        write((alternateScreen ? "\u{1B}[?1049h\u{1B}[H\u{1B}[2J" : "") + "\u{1B}[?25l")
    }

    /// Shows the cursor, leaves the alternate screen and restores the
    /// terminal settings. Safe to call more than once.
    func end() {
        guard active else { return }
        active = false
        write(restore)
        if var saved = savedTermios { tcsetattr(STDIN_FILENO, TCSANOW, &saved) }
        savedTermios = nil
        TerminalSession.disarm()
    }

    private static func arm(restore: String, termios saved: termios?) {
        disarm()
        let bytes = Array(restore.utf8)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
        buffer.initialize(from: bytes, count: bytes.count)
        emergencyCount = bytes.count
        emergencyBytes = buffer
        if let saved {
            emergencyTermios = saved
            emergencyHasTermios = true
        }
        for sig in crashSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { emergencyRestore($0) }
            action.sa_flags = SA_RESETHAND
            sigemptyset(&action.sa_mask)
            var old = sigaction()
            if sigaction(sig, &action, &old) == 0 { emergencyPrevious[sig] = old }
        }
    }

    private static func disarm() {
        for (sig, old) in emergencyPrevious {
            var action = old
            sigaction(sig, &action, nil)
        }
        emergencyPrevious = [:]
        emergencyHasTermios = false
        if let bytes = emergencyBytes {
            emergencyBytes = nil
            emergencyCount = 0
            bytes.deallocate()
        }
    }
}

/// Catches SIGINT, SIGTERM and SIGHUP while an animation or panel runs, so
/// it can end cleanly; wakes anyone waiting in ``wait(_:)`` or polling ``fd``.
final class Interruption {
    private let lock = NSLock()
    private var caught: Int32?
    private var pipeFDs: [Int32] = [-1, -1]
    private var trap: SignalTrap?

    init() {
        if pipe(&pipeFDs) == 0 {
            for fd in pipeFDs { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        }
        let writeFD = pipeFDs[1]
        trap = SignalTrap { [weak self] sig in
            self?.record(sig)
            var byte: UInt8 = 1
            _ = Darwin.write(writeFD, &byte, 1)
        }
    }

    deinit {
        trap?.remove()
        for fd in pipeFDs where fd >= 0 { close(fd) }
    }

    /// The signal that arrived, if any.
    var signal: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return caught
    }

    /// A descriptor that becomes readable when a signal arrives.
    var fd: Int32 { pipeFDs[0] }

    /// Removes the handlers (signals then act as before).
    func remove() {
        trap?.remove()
        trap = nil
    }

    private func record(_ sig: Int32) {
        lock.lock()
        if caught == nil { caught = sig }
        lock.unlock()
    }

    /// Sleeps for `seconds`, or less if a signal arrives.
    func wait(_ seconds: TimeInterval) {
        guard seconds > 0, signal == nil else { return }
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&pollFD, 1, Int32(max(1, (seconds * 1000).rounded())))
    }
}

// MARK: - Drawing in place

/// Redraws a block of lines in place below the cursor, for animations in
/// the normal screen. Each frame goes out in one write.
final class InlineRegion {
    private let write: (String) -> Void
    private var height = 0
    private var previous: [String]?

    init(write: @escaping (String) -> Void) {
        self.write = write
    }

    /// Replaces the block with `lines` (already rendered, each narrower than
    /// the terminal). Nothing is written if they have not changed.
    func draw(_ lines: [String]) {
        if lines == previous { return }
        previous = lines
        var out = "\u{1B}[?2026h"
        if height > 0 {
            out += "\r"
            if height > 1 { out += "\u{1B}[\(height - 1)A" }
        }
        out += lines.map { $0 + "\u{1B}[K" }.joined(separator: "\n")
        if lines.count < height { out += "\u{1B}[J" }
        out += "\u{1B}[?2026l"
        write(out)
        height = lines.count
    }

    /// Ends the block: the cursor moves to the line below it.
    func finish() {
        if height > 0 { write("\n") }
        height = 0
        previous = nil
    }
}

/// Paints full frames on the alternate screen, rewriting only the rows that
/// changed, in one write per frame.
final class ScreenPainter {
    private let write: (String) -> Void
    private var previous: [String] = []
    private var lastSize: (Int, Int) = (0, 0)

    init(write: @escaping (String) -> Void) {
        self.write = write
    }

    func paint(_ lines: [Line], style: Style, columns: Int, rows: Int) {
        var out = ""
        if lastSize != (columns, rows) {
            out += "\u{1B}[2J"
            previous = []
            lastSize = (columns, rows)
        }
        let rendered = lines.prefix(rows).map { style.render($0.truncated(to: columns, ellipsis: style.glyphs.ellipsis)) }
        let widths = lines.prefix(rows).map { min($0.width, columns) }
        for row in 0..<max(rendered.count, previous.count) where row < rows {
            let new = row < rendered.count ? rendered[row] : ""
            if row < previous.count, previous[row] == new { continue }
            out += "\u{1B}[\(row + 1);1H" + new
            if (row < widths.count ? widths[row] : 0) < columns { out += "\u{1B}[K" }
        }
        previous = rendered
        // Only rows that changed are sent; nothing at all if none did.
        if !out.isEmpty { write("\u{1B}[?2026h" + out + "\u{1B}[?2026l") }
    }
}

// MARK: - Keys

/// A key press.
enum Key: Equatable {
    case character(Character)
    case enter
    case escape
    case backspace
    /// Ctrl-C (or Ctrl-D, Ctrl-\) in raw mode.
    case interrupt
    /// Arrow keys and anything else without a meaning here.
    case other
}

/// Reads keys from a terminal in raw mode.
final class KeyReader {
    private let fd: Int32
    private let wake: Int32

    init(fd: Int32 = STDIN_FILENO, wake: Int32) {
        self.fd = fd
        self.wake = wake
    }

    /// Waits up to `timeout` seconds for input (or a wake-up) and returns the
    /// keys read; empty on timeout. A closed input reads as ``Key/interrupt``.
    func read(timeout: TimeInterval) -> [Key] {
        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
        let ready = poll(&fds, wake >= 0 ? 2 : 1, Int32(max(0, (timeout * 1000).rounded())))
        guard ready > 0, fds[0].revents != 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count == 0 { return [.interrupt] }
        guard count > 0 else { return [] }
        var bytes = Array(buffer[0..<count])
        // A lone Escape, or the start of a sequence still arriving?
        if bytes == [0x1B] {
            var more = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&more, 1, 30) > 0 {
                let extra = Darwin.read(fd, &buffer, buffer.count)
                if extra > 0 { bytes += buffer[0..<extra] }
            }
        }
        return KeyReader.parse(bytes)
    }

    /// Turns raw bytes into keys; escape sequences become ``Key/other``.
    static func parse(_ bytes: [UInt8]) -> [Key] {
        var keys: [Key] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case 0x0D, 0x0A: keys.append(.enter)
            case 0x7F, 0x08: keys.append(.backspace)
            case 0x03, 0x04, 0x1C: keys.append(.interrupt)
            case 0x1B:
                guard index < bytes.count else {
                    keys.append(.escape)
                    continue
                }
                let kind = bytes[index]
                if kind == UInt8(ascii: "[") || kind == UInt8(ascii: "O") {
                    index += 1
                    if kind == UInt8(ascii: "O") {
                        index += 1
                    } else {
                        while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) { index += 1 }
                        index += 1
                    }
                    keys.append(.other)
                } else {
                    keys.append(.escape)
                }
            case 0x20...0x7E:
                keys.append(.character(Character(Unicode.Scalar(byte))))
            case 0xC0...0xFF:
                // A UTF-8 sequence: decode it whole.
                let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
                let end = min(bytes.count, index - 1 + length)
                if let text = String(bytes: bytes[(index - 1)..<end], encoding: .utf8), let character = text.first {
                    keys.append(.character(character))
                } else {
                    keys.append(.other)
                }
                index = end
            default:
                keys.append(.other)
            }
        }
        return keys
    }
}
