import ChargeLight
import Foundation

// The interactive output of each command: only used when standard output is a
// terminal and neither --json nor --quiet is given (see `CLI.fancy`). Every
// line of the plain output has its counterpart here.

extension CLI {
    var visuals: Visuals { Visuals(style: style) }

    /// The widest line to print: one column short of the terminal, so nothing wraps.
    var lineWidth: Int { style.columns - 1 }

    /// Renders lines for standard output, each cut to the terminal width.
    func show(_ lines: [Line]) -> String {
        style.render(lines.map { $0.truncated(to: lineWidth, ellipsis: style.glyphs.ellipsis) })
    }

    /// Lines wrapped (not cut) to the terminal width.
    func wrap(_ lines: [Line], indent: Int = 2) -> [Line] {
        lines.flatMap { $0.wrapped(to: lineWidth, indent: indent) }
    }

    // MARK: - get, set, claim, release, reset

    func fancyGet(_ state: LEDState?, text: String) -> String {
        show([Line([state.map { visuals.dot($0) } ?? Span("?", .grey), Span(" "), Span(text, bold: true)])])
    }

    /// `● name` and, for something that moves, its strip.
    func ledSummary(_ spec: LEDSpec, strip: Bool = true) -> Line {
        var line = Line([visuals.dot(spec.firstState), Span(" "), Span(abbreviated(spec.description, 40), bold: true)])
        if strip, !LEDTimeline(spec).isStatic {
            line += Span("  ")
            line += visuals.strip(Strip(LEDTimeline(spec), width: lineWidth >= 60 ? Strip.width : 12))
        }
        return line
    }

    /// The LED summary and a dim hint, on one line if it fits.
    func ledLine(_ spec: LEDSpec, hint: Line) -> [Line] {
        for strip in [true, false] {
            let line = ledSummary(spec, strip: strip) + Span("  ") + hint
            if line.width <= lineWidth { return [line] }
        }
        return [ledSummary(spec, strip: false)] + wrap([hint.indented(2)], indent: 2)
    }

    func fancySet(_ result: SyncResult, ttl: TimeInterval?, ending: Bool) -> String {
        let hint: String
        if ending {
            hint = result.claims.isEmpty ? "override cleared" : "\(result.claims.count) claim(s) decide the LED again"
        } else {
            hint = ttl.map { "for \(formatDuration($0)), then back to the claims" } ?? "until: chargelight set system"
        }
        return show(ledLine(result.led, hint: Line([.dim(hint)])))
    }

    func fancyLEDLine(_ led: LEDSpec, _ detail: Line) -> String {
        show(ledLine(led, hint: detail))
    }

    func fancyClaim(_ result: SyncResult, claim: Claim, configuration: Configuration, plain: String) -> String {
        guard result.accepted else { return fancyLEDLine(result.led, Line([.dim(plain)])) }
        var detail = Line([
            Span(claim.id, bold: true),
            .dim(" claimed \(claim.show), priority \(claim.priority), expires in \(formatDuration(claim.expiresAt.timeIntervalSinceNow))"),
        ])
        if result.override != nil {
            detail += .dim("; an override decides the LED until: chargelight set system")
        } else if let winner = winningClaim(result.claims, configuration), winner.id != claim.id {
            detail += .dim("; ")
            detail += Span(winner.id, bold: true)
            detail += .dim(" wins with priority \(winner.priority)")
        } else {
            detail += .dim(" and wins")
        }
        return show(ledLine(result.led, hint: detail))
    }

    func fancyRelease(_ result: SyncResult, id: String) -> String {
        let detail = result.released > 0
            ? Line([.dim("released "), Span(id, bold: true)]) : Line([.dim("no claim \(id)")])
        return fancyLEDLine(result.led, detail)
    }

    // MARK: - status

    func fancyStatus(
        snapshot: Snapshot, configuration: Configuration, actual: String, backendName: String,
        watcherRunning: Bool, helperInstalled: Bool, helperPath: String
    ) -> String {
        let v = visuals
        let desired = snapshot.desired
        var lines: [Line] = []
        var head = v.inlinePlug(v.dot(desired.firstState)) + Span("  ")
        head += Span(abbreviated(desired.description, 40), bold: true)
        if !LEDTimeline(desired).isStatic, head.width + 2 + Strip.width <= lineWidth {
            head += Span("  ")
            head += v.strip(Strip(LEDTimeline(desired)))
        }
        lines.append(head)
        lines.append(.blank)
        func fact(_ label: String, _ value: Line, bold: Bool = false) -> Line {
            Line([bold ? Span(label.padding(toLength: 10, withPad: " ", startingAt: 0), bold: true)
                : .dim(label.padding(toLength: 10, withPad: " ", startingAt: 0))]) + value
        }
        let pattern = desired.pattern == nil ? "" : " (pattern)"
        var led = Line([Span(actual), .dim(", desired "), Span(abbreviated(desired.description, 60) + pattern)])
        if backendName == "file" { led += .dim(" [file backend]") }
        lines += wrap([fact("led", led)], indent: 10)
        lines.append(fact("watcher", Line(watcherRunning ? "running" : "not running")))
        let helper = helperInstalled
            ? Line([Span("installed "), .dim(helperPath)])
            : Line([Span("not installed", .amber), .dim(" (run: sudo chargelight setup) \(helperPath)")])
        lines += wrap([fact("helper", helper)], indent: 10)
        if let override = snapshot.override {
            let until = override.expiresAt.map { "for \(formatDuration($0.timeIntervalSinceNow))" }
                ?? "until: chargelight set system"
            let spec = try? configuration.resolveLED(override.show)
            var value = Line([spec.map { v.dot($0.firstState) } ?? Span("?"), Span(" ")])
            value += Span(abbreviated(override.show, 60), bold: true)
            value += Span(" (\(until))")
            lines += wrap([fact("override", value, bold: true)], indent: 10)
        }
        lines.append(fact("claims", Line(snapshot.claims.isEmpty ? "none" : String(snapshot.claims.count))))
        if !snapshot.claims.isEmpty || snapshot.override != nil {
            lines.append(.blank)
            lines += v.claimsTable(
                claims: snapshot.claims, override: snapshot.override, configuration: configuration, now: Date(),
                width: lineWidth - 2
            ).map { $0.indented(2) }
        }
        return show(lines)
    }

    // MARK: - list

    func fancyList(
        configuration: Configuration, presets: [(key: String, value: Preset)], patterns: [(key: String, value: Pattern)]
    ) -> String {
        let v = visuals
        var lines: [Line] = [Line([Span("States", bold: true), .dim("  idle: \(configuration.idle.rawValue)")])]
        var row = Line()
        for state in LEDState.allCases {
            let item = Line([v.dot(state), Span(" " + state.rawValue)])
            if row.width > 0, row.width + 3 + item.width > lineWidth - 2 {
                lines.append(row.indented(2))
                row = Line()
            }
            if row.width > 0 { row += Span("   ") }
            row += item
        }
        lines.append(row.indented(2))
        lines += [.blank, Line([Span("Presets", bold: true)])]
        let presetRows: [[Line]] = [[Line([.dim("NAME")]), Line([.dim("LED")]), Line([.dim("PRI")]), Line([.dim("TTL")])]]
            + presets.map { name, preset in
                let spec = try? configuration.resolve(preset.led)
                return [
                    Line(name),
                    Line([spec.map { v.dot($0.firstState) } ?? Span("?"), Span(" " + preset.led)]),
                    Line(String(preset.priority)), Line(formatDuration(preset.ttl)),
                ]
            }
        lines += v.table(presetRows).map { $0.indented(2) }
        lines += [.blank, Line([Span("Patterns", bold: true)])]
        let nameWidth = (patterns.map(\.key.count).max() ?? 0) + 2
        let cells = lineWidth >= 60 ? Strip.width : 12
        let strips = patterns.map { v.strip(Strip(LEDTimeline(.pattern($0.value)), width: cells)) }
        let stripWidth = strips.map(\.width).max() ?? cells
        for ((name, pattern), strip) in zip(patterns, strips) {
            var row = Line(name).padded(to: nameWidth).indented(2)
            row += strip.padded(to: stripWidth + 2)
            let room = lineWidth - row.width
            if room >= 8 { row += Span.dim(abbreviated(pattern.literal, room)) }
            lines.append(row)
        }
        return show(lines)
    }

    // MARK: - doctor, setup, uninstall

    func fancyDoctor(_ checks: [DoctorCheck], ok: Bool) -> String {
        let g = style.glyphs
        let markWidth = max(g.check.count, g.cross.count, g.bullet.count)
        var lines: [Line] = []
        for check in checks {
            let mark: Span
            if check.ok {
                mark = Span(g.check, .green)
            } else if check.required {
                mark = Span(g.cross, .red)
            } else {
                mark = Span(g.bullet, .grey)
            }
            let line = Line([mark]).padded(to: markWidth + 1)
                + Line(check.name).padded(to: 19)
                + Line([check.ok || check.required ? Span(check.detail) : .dim(check.detail)])
            lines += line.wrapped(to: lineWidth, indent: markWidth + 20)
        }
        lines.append(.blank)
        lines.append(Line([ok ? Span(g.check, .green) : Span(g.cross, .red), Span(" "),
                           Span(ok ? "all checks passed" : "some checks failed", ok ? .green : .red, bold: true)]))
        return show(lines)
    }

    func fancyChecks(_ done: [String], footer: String?) -> String {
        var lines = done.flatMap { Line([Span(style.glyphs.check, .green), Span(" " + $0)]).wrapped(to: lineWidth, indent: 2) }
        if let footer { lines.append(Line([.dim(footer)])) }
        return show(lines)
    }

    // MARK: - help

    func fancyHelp() -> String {
        let labels = ["<show>", "States", "Patterns", "Presets", "Durations", "Config", "Options", "Exit codes"]
        var lines: [Line] = []
        var section = ""
        // Where wrapped text continues: the column it started at, unless that leaves too little room.
        let hang = { (column: Int) in column <= self.lineWidth - 24 ? column : min(column, 6) }
        for (index, raw) in CLI.helpText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(raw)
            let indent = text.prefix(while: { $0 == " " }).count
            if index == 0 {
                let parts = text.components(separatedBy: " - ")
                lines += Line([Span(parts[0], bold: true), .dim(parts.count > 1 ? " - " + parts.dropFirst().joined(separator: " - ") : "")])
                    .wrapped(to: lineWidth, indent: 2)
                continue
            }
            if text.isEmpty {
                lines.append(.blank)
                continue
            }
            if indent == 0 {
                if let label = labels.first(where: { text.hasPrefix($0) }) {
                    let line = Line([Span(label, bold: true), Span(String(text.dropFirst(label.count)))])
                    lines += line.wrapped(to: lineWidth, indent: 11)
                } else if text.hasPrefix("usage:") {
                    lines += Line([Span("usage:", bold: true), Span(String(text.dropFirst(6)))]).wrapped(to: lineWidth, indent: 7)
                } else if let colon = text.firstIndex(of: ":") {
                    section = String(text[..<colon])
                    lines += Line([Span(section, bold: true), .dim(String(text[colon...]))]).wrapped(to: lineWidth, indent: 2)
                } else {
                    section = text
                    lines.append(Line([Span(text, bold: true)]))
                }
                continue
            }
            // An indented row: a command (or option) and, after two spaces, what it does.
            let body = text.dropFirst(indent)
            let lead = String(repeating: " ", count: indent)
            if indent >= 20 {
                let column = hang(indent)
                lines += Line([Span(String(repeating: " ", count: column)), .dim(String(body))]).wrapped(to: lineWidth, indent: column)
                continue
            }
            let tryIt = section == "Try it"
            var line = Line([Span(lead)])
            var descriptionColumn = indent + 4
            if let gap = body.range(of: "  ") {
                let head = String(body[..<gap.lowerBound])
                let tail = body[gap.lowerBound...]
                let spaces = tail.prefix(while: { $0 == " " })
                descriptionColumn = indent + head.count + spaces.count
                line += Span(head, bold: tryIt)
                line += Span(String(spaces))
                line += Span.dim(String(tail.dropFirst(spaces.count)))
            } else {
                line += Span(String(body), bold: tryIt)
            }
            lines += line.wrapped(to: lineWidth, indent: hang(descriptionColumn))
        }
        return show(lines)
    }

    // MARK: - run

    /// One dim line on standard error after `run`: how it ended, how long it
    /// took, what the light shows now.
    func runSummary(name: String, status: Int32, seconds: TimeInterval, led: LEDSpec) -> String {
        let g = errorStyle.glyphs
        let v = Visuals(style: errorStyle)
        let took = seconds < 60 ? formatSeconds(seconds) : formatDuration(seconds)
        let line = Line([
            status == 0 ? Span(g.check, .green) : Span(g.cross, .red),
            .dim(" \(name)  \(took)  exit \(status)  \(g.separator)  light: "), v.dot(led.firstState),
            .dim(" " + abbreviated(led.description, 40)),
        ])
        return errorStyle.render(line.truncated(to: errorStyle.columns - 1, ellipsis: g.ellipsis))
    }

    // MARK: - Animation

    /// Redraws `frame` in place about 20 times a second until `end`, a
    /// signal, or standard output closing; then clears it. Without motion it
    /// just waits. Returns the signal, if one arrived.
    func animateInPlace(until end: Date, interruption: Interruption, frame: (Date) -> [Line]) -> Int32? {
        guard style.motion else {
            while interruption.signal == nil, end.timeIntervalSinceNow > 0 { interruption.wait(end.timeIntervalSinceNow) }
            return interruption.signal
        }
        let session = TerminalSession(write: writeOut)
        session.begin(alternateScreen: false, raw: false)
        defer { session.end() }
        let region = InlineRegion(write: writeOut)
        while interruption.signal == nil, !outputClosed() {
            let now = Date()
            region.draw(frame(now).prefix(style.rows - 1).map {
                style.render($0.truncated(to: lineWidth, ellipsis: style.glyphs.ellipsis))
            })
            let left = end.timeIntervalSince(now)
            if left <= 0 { break }
            interruption.wait(min(0.05, left))
        }
        region.draw([])
        return interruption.signal
    }

    /// Ends a flash or Morse claim early (interrupted).
    private func dropNotice(_ claim: Claim, light: StatusLight) {
        _ = try? light.release(id: claim.id, stamp: Claim.currentStamp(), apply: false)
        try? applyChange(light)
    }

    /// `· now ● system`: what the light went back to.
    private func backTo(_ light: StatusLight) -> Line {
        let desired = light.snapshot().desired
        return Line([.dim("  \(style.glyphs.separator)  now "), visuals.dot(desired.firstState),
                     .dim(" " + abbreviated(desired.description, 40))])
    }

    func animateFlash(
        pattern: Pattern, name fullName: String, times: Int, claim: Claim, light: StatusLight, into output: inout CommandOutput
    ) {
        let v = visuals
        let segments = Array(Array(repeating: LEDTimeline(.pattern(pattern)).segments, count: times).joined())
        let timeline = LEDTimeline(segments: segments)
        let total = Double(times) * pattern.duration
        let strip = Strip(finite: segments, width: lineWidth >= 60 ? Strip.width : 12)
        let name = abbreviated(fullName, 24)
        let interruption = Interruption()
        defer { interruption.remove() }
        let signal = animateInPlace(until: claim.expiresAt.addingTimeInterval(0.03), interruption: interruption) { now in
            let elapsed = min(max(0, now.timeIntervalSince(claim.updatedAt)), total - 0.001)
            let lead = Line([v.dot(timeline.state(at: elapsed)), Span(" flash "), Span(name, bold: true),
                             .dim(" \(times)\(style.unicode ? "×" : "x")  ")])
            let line = lead + v.strip(strip) + Line([.dim("  " + formatSeconds(max(0, total - elapsed)))])
            let head = strip.playhead(at: elapsed) ?? 0
            return [line, v.caret(head).indented(lead.width)]
        }
        let g = style.glyphs
        if let signal {
            dropNotice(claim, light: light)
            output.text = show([Line([Span(g.bullet, .grey), Span(" flash "), Span(name, bold: true), .dim(" stopped")]) + backTo(light)])
            output.exitCode = 128 + signal
        } else {
            output.text = show([Line([Span(g.check, .green), Span(" flash "), Span(name, bold: true),
                                      .dim(" \(times) time(s) (\(formatSeconds(total)))")]) + backTo(light)])
        }
    }

    func animateMorse(text: String, pattern: Pattern, claim: Claim, light: StatusLight, into output: inout CommandOutput) {
        let v = visuals
        let script = MorseScript(text: text, pattern: pattern)
        let timeline = LEDTimeline(.pattern(pattern))
        let total = pattern.duration
        let quoted = "\"" + abbreviated(text, 40) + "\""
        let interruption = Interruption()
        defer { interruption.remove() }
        let signal = animateInPlace(until: claim.expiresAt.addingTimeInterval(0.03), interruption: interruption) { now in
            let elapsed = min(max(0, now.timeIntervalSince(claim.updatedAt)), total - 0.001)
            return [
                Line([v.dot(timeline.state(at: elapsed)), Span(" morse "), Span(quoted, bold: true),
                      .dim("  \(formatSeconds(elapsed)) / \(formatSeconds(total))")]),
                script.line(at: elapsed, visuals: v, width: lineWidth - 2).indented(2),
            ]
        }
        let g = style.glyphs
        if let signal {
            dropNotice(claim, light: light)
            output.text = show([
                Line([Span(g.bullet, .grey), Span(" morse "), Span(quoted, bold: true), .dim(" stopped")]) + backTo(light),
            ])
            output.exitCode = 128 + signal
        } else {
            output.text = show([
                Line([Span(g.check, .green), Span(" morse "), Span(quoted, bold: true), .dim(" (\(formatSeconds(total)))")])
                    + backTo(light),
                script.line(at: nil, visuals: v, width: lineWidth - 2).indented(2),
            ])
        }
    }

    // MARK: - demo

    /// One step of the tour: counter, name, purpose, the plug, the strip.
    func demoFrame(index: Int, count: Int, show name: String, purpose: String, spec: LEDSpec, elapsed: TimeInterval?) -> [Line] {
        let v = visuals
        var lines: [Line] = [
            Line([.dim("\(index + 1)/\(count)  "), Span(name, bold: true)]),
            Line([.dim(purpose)]).indented("\(index + 1)/\(count)  ".count),
            .blank,
        ]
        lines += v.plug(v.dot(spec, elapsed: elapsed), width: lineWidth - 2).map { $0.indented(2) }
        lines.append(.blank)
        lines += v.stripWithPlayhead(spec, elapsed: elapsed, width: lineWidth - 2).map { $0.indented(2) }
        return lines
    }

    func fancyDemo(light: StatusLight, before: Override?) throws -> CommandOutput {
        let interruption = Interruption()
        defer { interruption.remove() }
        let session = TerminalSession(write: writeOut)
        if style.motion { session.begin(alternateScreen: false, raw: false) }
        defer { session.end() }
        let region = InlineRegion(write: writeOut)
        let steps = CLI.demoSequence
        var shown: [String] = []
        for (index, step) in steps.enumerated() {
            if interruption.signal != nil || outputClosed() { break }
            _ = try light.setOverride(show: step.show, apply: false)
            try applyChange(light)
            shown.append(step.show)
            let spec = try light.configuration.resolveLED(step.show)
            let start = Date()
            let end = start.addingTimeInterval(demoStep)
            if style.motion {
                repeat {
                    let now = Date()
                    let frame = demoFrame(
                        index: index, count: steps.count, show: step.show, purpose: step.purpose, spec: spec,
                        elapsed: now.timeIntervalSince(start))
                    region.draw(frame.prefix(style.rows - 1).map {
                        style.render($0.truncated(to: lineWidth, ellipsis: style.glyphs.ellipsis))
                    })
                    interruption.wait(min(0.05, end.timeIntervalSinceNow))
                } while end.timeIntervalSinceNow > 0 && interruption.signal == nil && !outputClosed()
            } else {
                writeOut(show(demoFrame(
                    index: index, count: steps.count, show: step.show, purpose: step.purpose, spec: spec, elapsed: nil))
                    + "\n\n")
                interruption.wait(demoStep)
            }
        }
        if style.motion { region.draw([]) }
        session.end()
        let restored = try restoreOverride(before, light: light)
        let g = style.glyphs
        var lines: [Line]
        if shown.count == steps.count {
            lines = Line([Span(g.check, .green), Span(" shown "), .dim(shown.joined(separator: ", "))]).wrapped(to: lineWidth, indent: 2)
        } else {
            lines = Line([Span(g.bullet, .grey), Span(" stopped after \(shown.count) of \(steps.count) "),
                          .dim(shown.joined(separator: ", "))]).wrapped(to: lineWidth, indent: 2)
        }
        lines.append(Line([visuals.dot(restored.led.firstState), Span(" restored: "),
                           Span(abbreviated(restored.led.description, 40), bold: true)]))
        lines.append(Line([.dim("  try it yourself: "), Span("chargelight play", bold: true)]))
        return CommandOutput(
            fields: [:], text: show(lines), exitCode: interruption.signal.map { 128 + $0 })
    }

    // MARK: - watch

    /// When what is showing started, so the dot keeps time with the watcher:
    /// when it was applied, or when this view first saw it.
    func phaseStart(_ snapshot: Snapshot, seen: Date) -> Date {
        if let applied = snapshot.applied, applied.show == snapshot.desired.description { return applied.appliedAt }
        return seen
    }

    /// Who decides the LED: the override, the winning claim, or nobody.
    func holder(_ snapshot: Snapshot, configuration: Configuration) -> String {
        if snapshot.override != nil { return "override" }
        if let winner = winningClaim(snapshot.claims, configuration) {
            return "\(winner.id) (\(abbreviated(winner.show, 32)))"
        }
        return "idle"
    }

    func watchFrame(
        snapshot: Snapshot, configuration: Configuration, now: Date, since: Date, phase: Date, keys: Bool
    ) -> [Line] {
        let v = visuals
        let width = lineWidth - 2
        let desired = snapshot.desired
        let elapsed: TimeInterval? = style.motion ? now.timeIntervalSince(phase) : nil
        var lines = v.plug(v.dot(desired, elapsed: elapsed), width: width).map { $0.indented(2) }
        lines.append(.blank)
        lines.append(Line([Span(abbreviated(desired.description, 40), bold: true), .dim("  " + holder(snapshot, configuration: configuration))])
            .truncated(to: width, ellipsis: style.glyphs.ellipsis).indented(2))
        lines += v.stripWithPlayhead(desired, elapsed: elapsed, width: width).map { $0.indented(2) }
        lines.append(.blank)
        if snapshot.claims.isEmpty && snapshot.override == nil {
            lines.append(Line([.dim("no claims; the LED shows the idle state")]).indented(2))
        } else {
            lines += v.claimsTable(
                claims: snapshot.claims, override: snapshot.override, configuration: configuration, now: now, width: width
            ).map { $0.indented(2) }
        }
        lines.append(.blank)
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss"
        lines.append(Line([.dim("changed \(clock.string(from: since))  \(style.glyphs.separator)  "),
                           Span(keys ? "q" : "Ctrl-C", bold: true), .dim(" to leave")]).indented(2))
        return lines
    }

    /// `watch` in a terminal: a live view, redrawn in place until q or Ctrl-C.
    func liveWatch(light: StatusLight) -> CommandOutput {
        let restore = ignoreSIGPIPE()
        defer { restore() }
        let interruption = Interruption()
        defer { interruption.remove() }
        let keys = terminal.stdinIsTerminal
        let session = TerminalSession(write: writeOut)
        session.begin(alternateScreen: false, raw: keys)
        defer { session.end() }
        let reader = keys ? KeyReader(wake: interruption.fd) : nil
        let region = InlineRegion(write: writeOut)
        var snapshot = light.snapshot()
        var last = changeKey(snapshot, winner: winningClaim(snapshot.claims, light.configuration))
        var since = Date()
        var lastRead = Date()
        var desiredSeen = (snapshot.desired.description, Date())
        while interruption.signal == nil, !outputClosed() {
            let now = Date()
            if now.timeIntervalSince(lastRead) >= 0.2 {
                snapshot = light.snapshot(now: now)
                lastRead = now
                let key = changeKey(snapshot, winner: winningClaim(snapshot.claims, light.configuration))
                if key != last {
                    last = key
                    since = now
                }
                if desiredSeen.0 != snapshot.desired.description { desiredSeen = (snapshot.desired.description, now) }
            }
            let frame = watchFrame(
                snapshot: snapshot, configuration: light.configuration, now: now, since: since,
                phase: phaseStart(snapshot, seen: desiredSeen.1), keys: keys)
            region.draw(frame.prefix(style.rows - 1).map {
                style.render($0.truncated(to: lineWidth, ellipsis: style.glyphs.ellipsis))
            })
            let timeout = style.motion && !LEDTimeline(snapshot.desired).isStatic ? 0.05 : 0.2
            if let reader {
                let pressed = reader.read(timeout: timeout)
                if pressed.contains(where: { [.character("q"), .character("Q"), .escape, .interrupt].contains($0) }) { break }
            } else {
                interruption.wait(timeout)
            }
        }
        region.finish()
        session.end()
        return CommandOutput(silent: true, exitCode: interruption.signal.map { 128 + $0 })
    }
}
