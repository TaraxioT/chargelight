import ChargeLight
import Foundation

// `chargelight play`: a full-screen panel to switch the light from the
// keyboard. Built in three layers so most of it is testable without a
// terminal: a pure key-to-action map and a pure view-to-frame renderer
// (``PlayPanel``), a session that performs actions through the same code
// paths as the commands (``PlaySession``), and a thin raw-mode loop.

/// What a key asks `play` to do.
enum PlayAction: Equatable {
    case show(String)
    case system
    case flash
    case beginMorse
    case type(Character)
    case erase
    case sendMorse
    case cancelMorse
    case toggleLegend
    case quit
    case none
}

/// Everything one frame of the panel shows.
struct PlayView {
    /// What the LED shows.
    var desired: LEDSpec
    /// Its name, as the panel calls it ("heartbeat", "flash green").
    var name: String
    /// A pattern written out, when the name does not say it.
    var detail: String?
    /// Seconds since it started showing; nil draws a still frame.
    var elapsed: TimeInterval?
    /// Who decides the LED.
    var holder: String
    var claims: [Claim]
    var override: Override?
    /// The override is the one this panel set.
    var overrideIsYours: Bool
    var configuration: Configuration
    var now: Date
    /// Named patterns for keys 1 to 9.
    var patterns: [String]
    var legend: Bool
    /// The Morse text being typed, when typing.
    var morse: String?
    /// An error to show.
    var message: String?
    /// A Morse message being sent, and how far it has got.
    var sending: (script: MorseScript, elapsed: TimeInterval)?
    /// Display names for claim ids (play's own flash and Morse claims).
    var names: [String: String] = [:]
    var version: String = ChargeLight.version
}

enum PlayPanel {
    /// Keys for the fixed states.
    static let stateKeys: [(key: Character, show: String)] = [
        ("a", "amber"), ("g", "green"), ("o", "off"), ("s", "blink-slow"), ("f", "blink-fast"),
    ]

    /// The longest Morse text the panel takes.
    static let morseLimit = 32

    /// Maps a key to an action. While typing Morse, keys are text.
    static func action(for key: Key, typing: Bool, patterns: [String]) -> PlayAction {
        if typing {
            switch key {
            case .enter: return .sendMorse
            case .escape: return .cancelMorse
            case .backspace: return .erase
            case .interrupt: return .quit
            case .character(let c) where c == " " || (c.isASCII && (c.isLetter || c.isNumber)): return .type(c)
            default: return .none
            }
        }
        switch key {
        case .escape, .interrupt: return .quit
        case .character(let raw):
            let c = Character(raw.lowercased())
            if let state = stateKeys.first(where: { $0.key == c }) { return .show(state.show) }
            if let digit = c.wholeNumberValue, (1...9).contains(digit) {
                return digit <= patterns.count ? .show(patterns[digit - 1]) : .none
            }
            switch c {
            case " ": return .flash
            case "m": return .beginMorse
            case "x", "0": return .system
            case "?": return .toggleLegend
            case "q": return .quit
            default: return .none
            }
        default:
            return .none
        }
    }

    /// Draws the panel in `width` columns and at most `height` rows.
    static func frame(_ view: PlayView, width: Int, height: Int, style: Style) -> [Line] {
        let v = Visuals(style: style)
        let g = style.glyphs
        let inner = max(1, width - 2)
        func pad(_ line: Line) -> Line { line.truncated(to: inner, ellipsis: g.ellipsis).indented(2) }

        // Title, plug, what is showing.
        var top: [Line] = [.blank]
        var title = Line([Span("chargelight play", bold: true)])
        let version = Line([.dim(view.version)])
        if title.width + 2 + version.width <= inner { title = title.padded(to: inner - version.width) + version }
        top.append(pad(title))
        top.append(.blank)
        top += v.plug(v.dot(view.desired, elapsed: view.elapsed), width: inner).map(pad)
        top.append(.blank)
        if let morse = view.morse {
            top.append(pad(Line([.dim("morse  "), Span(morse, bold: true), Span(g.cursor, .amber)])))
        } else {
            var name = Line([Span(view.name, bold: true)])
            if let detail = view.detail, detail != view.name { name += .dim("  " + detail) }
            top.append(pad(name))
        }
        let strip = v.stripWithPlayhead(view.desired, elapsed: view.elapsed, width: inner)
        top += strip.map(pad)
        if strip.count == 1 { top.append(.blank) }
        if let sending = view.sending, view.morse == nil {
            top.append(pad(sending.script.line(at: sending.elapsed, visuals: v, width: inner)))
        } else if view.morse != nil {
            top.append(pad(Line([.dim("type letters, digits, spaces  "), Span("enter", bold: true), .dim(" send  "),
                                 Span("esc", bold: true), .dim(" cancel")])))
        } else if let message = view.message {
            top.append(pad(Line([Span(message, .red)])))
        } else {
            top.append(pad(Line([.dim("held by " + view.holder)])))
        }

        // The keys.
        var legend: [Line] = []
        if view.legend {
            legend.append(.blank)
            legend += v.legend(stateKeys.map { (String($0.key), $0.show) }, width: inner).map(pad)
            legend += v.legend(view.patterns.enumerated().map { (String($0.offset + 1), $0.element) }, width: inner).map(pad)
            legend += v.legend([("space", "flash"), ("m", "morse"), ("x", "system")], width: inner).map(pad)
        }

        // Who holds the light.
        var claims: [Line] = [.blank, pad(Line([.dim("who holds the light")]))]
        if view.claims.isEmpty && view.override == nil {
            claims.append(pad(Line([.dim("nobody: macOS decides (idle)")])))
        } else {
            claims += v.claimsTable(
                claims: view.claims, override: view.override, configuration: view.configuration, now: view.now,
                width: inner, overrideLabel: view.overrideIsYours ? "you (play)" : "override", names: view.names
            ).map(pad)
        }

        let footer: [Line] = [.blank, pad(v.legend([("q", "quit"), ("?", view.legend ? "hide keys" : "keys")], width: inner).first ?? Line())]

        // Fit the height: the top first, then the keys, then as much of the table as fits.
        let room = max(1, height - footer.count)
        var lines = Array(top.prefix(room))
        if lines.count + legend.count <= room { lines += legend }
        let left = room - lines.count
        if left >= 3 { lines += claims.prefix(left) }
        if height > room { lines += footer.prefix(height - lines.count) }
        return lines.map { $0.truncated(to: width, ellipsis: g.ellipsis) }
    }
}

/// The light as `play` drives it.
final class PlaySession {
    let cli: CLI
    let light: StatusLight
    /// The override in force when play started; put back on quit.
    let before: Override?
    /// Named patterns for keys 1 to 9, in `chargelight list` order.
    let patterns: [String]
    let motion: Bool
    var legend = true
    private(set) var morse: String?
    private(set) var message: String?
    private(set) var quit = false
    /// What play last showed as an override; nil after `x`.
    private(set) var chosen: String?
    /// A flash or Morse message in progress, and the override it lifted.
    private(set) var notice: (claim: Claim, name: String, resume: Override?, script: MorseScript?)?
    private var seen: (show: String, at: Date) = ("", Date())

    init(cli: CLI, light: StatusLight, motion: Bool) {
        self.cli = cli
        self.light = light
        self.motion = motion
        before = light.snapshot().override
        patterns = Array(light.configuration.patterns.keys.sorted().prefix(9))
    }

    /// Handles a key; an error is shown in the panel.
    func handle(_ key: Key) {
        do {
            try perform(PlayPanel.action(for: key, typing: morse != nil, patterns: patterns))
        } catch {
            message = ChargeLightError.wrap(error).message
        }
    }

    func perform(_ action: PlayAction) throws {
        switch action {
        case .show(let show):
            message = nil
            try endNotice(resume: false)
            _ = try light.setOverride(show: show, apply: false)
            try cli.applyChange(light)
            chosen = show
        case .system:
            message = nil
            try endNotice(resume: false)
            _ = try light.setOverride(show: nil, apply: false)
            try cli.applyChange(light, force: true)
            chosen = nil
        case .flash:
            message = nil
            let pattern = try cli.flashPattern("green", configuration: light.configuration)
            try startNotice(
                kind: "flash", pattern: pattern, length: 3 * pattern.duration, label: "green", name: "flash green", script: nil)
        case .beginMorse:
            message = nil
            morse = ""
        case .type(let character):
            if (morse?.count ?? 0) < PlayPanel.morseLimit { morse?.append(character) }
        case .erase:
            if morse?.isEmpty == false { morse?.removeLast() }
        case .cancelMorse:
            morse = nil
        case .sendMorse:
            let text = (morse ?? "").trimmingCharacters(in: .whitespaces)
            morse = nil
            guard !text.isEmpty else { return }
            let pattern = try Pattern.morse(text, lit: .amber, unit: 0.15)
            try startNotice(
                kind: "morse", pattern: pattern, length: pattern.duration, label: "morse: \(text)", name: "morse \"\(text)\"",
                script: MorseScript(text: text, pattern: pattern))
        case .toggleLegend:
            legend.toggle()
        case .quit:
            quit = true
        case .none:
            break
        }
    }

    /// Shows a flash or Morse message over everything: an override would
    /// hide it, so it is lifted for the length of the message and put back
    /// afterwards (see ``tick(now:)``).
    private func startNotice(
        kind: String, pattern: Pattern, length: TimeInterval, label: String, name: String, script: MorseScript?
    ) throws {
        let resume = notice?.resume ?? light.snapshot().override
        if let running = notice {
            notice = nil
            _ = try light.release(id: running.claim.id, apply: false)
        }
        if resume != nil { _ = try light.setOverride(show: nil, apply: false) }
        let claim = try cli.notice(
            kind: kind, pattern: pattern, length: length, label: label, light: light, wait: false, warnings: false)
        notice = (claim, name, resume, script)
    }

    /// Stops the flash or Morse message (if still running) and, if `resume`,
    /// puts back the override it lifted.
    private func endNotice(resume: Bool) throws {
        guard let running = notice else { return }
        notice = nil
        if running.claim.expiresAt > Date() {
            _ = try light.release(id: running.claim.id, apply: false)
            try cli.applyChange(light)
        }
        if resume, let override = running.resume { _ = try cli.restoreOverride(override, light: light) }
    }

    /// Ends a finished flash or Morse message.
    func tick(now: Date = Date()) {
        guard let running = notice, now >= running.claim.expiresAt else { return }
        do { try endNotice(resume: true) } catch { message = ChargeLightError.wrap(error).message }
    }

    /// Stops any message and puts back the override from before play started.
    func finish() throws -> SyncResult {
        if let running = notice {
            notice = nil
            if running.claim.expiresAt > Date() { _ = try light.release(id: running.claim.id, apply: false) }
        }
        return try cli.restoreOverride(before, light: light)
    }

    /// The panel's view of the light at `now`.
    func view(now: Date = Date()) -> PlayView {
        let snapshot = light.snapshot(now: now)
        let desired = snapshot.desired
        if seen.show != desired.description { seen = (desired.description, now) }
        let phase = cli.phaseStart(snapshot, seen: seen.at)
        let yours = chosen != nil && snapshot.override?.show == chosen
        var name = desired.description
        var detail = desired.pattern?.literal
        var holder = yours ? "you (play)" : cli.holder(snapshot, configuration: light.configuration)
        var sending: (script: MorseScript, elapsed: TimeInterval)?
        var names: [String: String] = [:]
        if let running = notice {
            names[running.claim.id] = running.name
            if snapshot.override == nil, cli.winningClaim(snapshot.claims, light.configuration)?.id == running.claim.id {
                name = running.name
                detail = nil
                holder = "you (play): \(running.name)"
                if let script = running.script { sending = (script, now.timeIntervalSince(running.claim.updatedAt)) }
            }
        }
        var view = PlayView(
            desired: desired, name: abbreviated(name, 40), detail: detail, elapsed: motion ? now.timeIntervalSince(phase) : nil,
            holder: holder, claims: snapshot.claims, override: snapshot.override, overrideIsYours: yours,
            configuration: light.configuration, now: now, patterns: patterns, legend: legend, morse: morse,
            message: message)
        view.sending = sending
        view.names = names
        return view
    }
}

extension CLI {
    /// `chargelight play`: the panel on the alternate screen, keys in raw mode.
    func playCommand() throws -> CommandOutput {
        if json { throw ChargeLightError.invalidArgument("play is interactive and does not take --json") }
        guard style.interactive, terminal.stdinIsTerminal else {
            throw ChargeLightError.invalidArgument(
                "play needs a terminal: run it in an interactive terminal, without redirecting its input or output")
        }
        let light = try makeWritableLight()
        let session = PlaySession(cli: self, light: light, motion: style.motion)
        let restorePipe = ignoreSIGPIPE()
        defer { restorePipe() }
        let interruption = Interruption()
        defer { interruption.remove() }
        let screen = TerminalSession(write: writeOut)
        screen.begin(alternateScreen: true, raw: true)
        defer { screen.end() }
        let painter = ScreenPainter(write: writeOut)
        let reader = KeyReader(wake: interruption.fd)
        while interruption.signal == nil, !outputClosed(), !session.quit {
            let now = Date()
            session.tick(now: now)
            let view = session.view(now: now)
            let (columns, rows) = (style.columns, style.rows)
            painter.paint(PlayPanel.frame(view, width: columns, height: rows, style: style), style: style, columns: columns, rows: rows)
            let animating = view.elapsed != nil && !LEDTimeline(view.desired).isStatic
            for key in reader.read(timeout: animating ? 0.05 : 0.25) {
                session.handle(key)
                if session.quit { break }
            }
        }
        let restored = try session.finish()
        screen.end()
        return CommandOutput(
            text: show([Line([visuals.dot(restored.led.firstState), .dim(" restored: "),
                              Span(abbreviated(restored.led.description, 40), bold: true)])]),
            exitCode: interruption.signal.map { 128 + $0 })
    }
}
