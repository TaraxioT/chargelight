import ChargeLight
import Foundation

// The shared visual vocabulary: the LED dot, the plug, the pattern strip and
// its playhead. Everything here is pure: state and time in, lines out.

/// What an ``LEDSpec`` shows over time, as the eye sees it: amber, green,
/// off, or system (macOS decides). The hardware blinks are drawn as amber
/// on/off steps (slow: 1 s / 1 s, fast: 0.25 s / 0.25 s).
struct LEDTimeline: Equatable {
    struct Segment: Equatable {
        var state: LEDState
        var duration: TimeInterval
    }

    /// One cycle.
    var segments: [Segment]
    /// A fixed state that never changes.
    var isStatic: Bool

    /// The length of one cycle, in seconds.
    var cycle: TimeInterval { segments.reduce(0) { $0 + $1.duration } }

    init(_ spec: LEDSpec) {
        switch spec {
        case .state(let state):
            if let blink = LEDTimeline.blink(state) {
                segments = [Segment(state: .amber, duration: blink), Segment(state: .off, duration: blink)]
                isStatic = false
            } else {
                segments = [Segment(state: state, duration: 1)]
                isStatic = true
            }
        case .pattern(let pattern):
            segments = pattern.steps.flatMap(LEDTimeline.expand)
            isStatic = Set(segments.map(\.state)).count == 1
        }
    }

    init(segments: [Segment]) {
        self.segments = segments
        self.isStatic = Set(segments.map(\.state)).count <= 1
    }

    /// Half a period of a hardware blink.
    static func blink(_ state: LEDState) -> TimeInterval? {
        switch state {
        case .blinkSlow: return 1
        case .blinkFast: return 0.25
        default: return nil
        }
    }

    /// A pattern step; a hardware blink inside a pattern becomes its on/off steps.
    private static func expand(_ step: Pattern.Step) -> [Segment] {
        guard let half = blink(step.state) else { return [Segment(state: step.state, duration: step.duration)] }
        var result: [Segment] = []
        var left = step.duration
        var on = true
        while left > 1e-9 {
            let length = min(half, left)
            result.append(Segment(state: on ? .amber : .off, duration: length))
            left -= length
            on.toggle()
        }
        return result
    }

    /// What shows `elapsed` seconds after the start (repeating).
    func state(at elapsed: TimeInterval) -> LEDState {
        guard !isStatic, cycle > 0 else { return segments.first?.state ?? .system }
        var t = elapsed.truncatingRemainder(dividingBy: cycle)
        if t < 0 { t += cycle }
        for segment in segments {
            if t < segment.duration { return segment.state }
            t -= segment.duration
        }
        return segments.last?.state ?? .system
    }
}

/// A timeline laid out as a row of cells.
struct Strip: Equatable {
    /// The state in each cell.
    var cells: [LEDState]
    /// Seconds per cell.
    var cellDuration: TimeInterval
    /// Nothing moves: no playhead.
    var isStatic: Bool

    /// The usual strip width, in cells.
    static let width = 24
    /// The most cells one cycle may take.
    static let maximumCycle = 32

    /// A repeating timeline: one cycle in at most 32 cells, repeated to fill
    /// 24 cells (whole cycles only, so the playhead never jumps).
    init(_ timeline: LEDTimeline, width: Int = Strip.width) {
        isStatic = timeline.isStatic
        guard !timeline.isStatic, timeline.cycle > 0 else {
            cells = Array(repeating: timeline.segments.first?.state ?? .system, count: width)
            cellDuration = 1
            return
        }
        let cycle = timeline.cycle
        let shortest = timeline.segments.map(\.duration).min() ?? cycle
        // Enough cells to show the shortest step, and at most 0.25 s per cell;
        // then the count that draws the steps most exactly, preferring one
        // that fills the width with whole cycles.
        let cap = width >= Strip.width ? Strip.maximumCycle : max(1, width)
        let least = min(cap, max(1, Int((cycle / shortest - 1e-6).rounded(.up)), Int((cycle / 0.25 - 1e-6).rounded(.up))))
        let most = max(least, min(cap, width))
        func error(_ cells: Int) -> Int {
            let total = timeline.segments.reduce(0.0) { sum, segment in
                let exact = segment.duration / cycle * Double(cells)
                return sum + abs(exact - exact.rounded())
            }
            return Int((total * 1000).rounded())
        }
        let perCycle = (least...most).min { a, b in
            (error(a), width % a == 0 ? 0 : 1, a) < (error(b), width % b == 0 ? 0 : 1, b)
        } ?? least
        let one = Strip.sample(timeline.segments, total: cycle, cells: perCycle)
        let repeats = max(1, width / perCycle)
        cells = Array([[LEDState]](repeating: one, count: repeats).joined())
        cellDuration = cycle / Double(perCycle)
    }

    /// A finite run (a flash, a Morse message): `total` seconds in `width` cells.
    init(finite segments: [LEDTimeline.Segment], width: Int = Strip.width) {
        let total = segments.reduce(0) { $0 + $1.duration }
        cells = Strip.sample(segments, total: total, cells: width)
        cellDuration = total / Double(max(1, width))
        isStatic = false
    }

    /// Cells for segments by rounding their boundaries (a very short step can vanish).
    private static func sample(_ segments: [LEDTimeline.Segment], total: TimeInterval, cells count: Int) -> [LEDState] {
        var result: [LEDState] = []
        var elapsed: TimeInterval = 0
        for segment in segments {
            elapsed += segment.duration
            let boundary = min(count, Int((elapsed / total * Double(count)).rounded()))
            while result.count < boundary { result.append(segment.state) }
        }
        while result.count < count { result.append(segments.last?.state ?? .off) }
        return result
    }

    /// The cell under the playhead `elapsed` seconds after the start, or nil
    /// for a static strip.
    func playhead(at elapsed: TimeInterval) -> Int? {
        guard !isStatic, cellDuration > 0, !cells.isEmpty else { return nil }
        let span = cellDuration * Double(cells.count)
        var t = elapsed.truncatingRemainder(dividingBy: span)
        if t < 0 { t += span }
        return min(cells.count - 1, Int(t / cellDuration))
    }
}

/// Drawing helpers for one style.
struct Visuals {
    var style: Style
    var glyphs: Glyphs { style.glyphs }

    /// The LED dot: amber or green when lit, a dim ring when off, a dim
    /// dotted ring for system (macOS decides).
    func dot(_ state: LEDState) -> Span {
        switch state {
        case .amber, .blinkSlow, .blinkFast: return Span(glyphs.lit, .amber)
        case .green: return Span(glyphs.lit, .green)
        case .off: return Span(glyphs.unlit, .grey)
        case .system: return Span(glyphs.system, .grey)
        }
    }

    /// The dot for what `spec` shows `elapsed` seconds in (nil: its first state).
    func dot(_ spec: LEDSpec, elapsed: TimeInterval?) -> Span {
        let timeline = LEDTimeline(spec)
        return dot(elapsed.map { timeline.state(at: $0) } ?? timeline.segments.first?.state ?? .system)
    }

    /// The MagSafe plug with its cable, the dot the only coloured cell.
    func plug(_ dot: Span) -> [Line] {
        glyphs.plug.map { row in
            guard let marker = row.firstIndex(of: "@") else { return Line(row) }
            return Line([Span(String(row[..<marker])), dot, Span(String(row[row.index(after: marker)...]))])
        }
    }

    /// The plug in one row.
    func inlinePlug(_ dot: Span) -> Line {
        let row = glyphs.inlinePlug
        guard let marker = row.firstIndex(of: "@") else { return Line(row) }
        return Line([Span(String(row[..<marker])), dot, Span(String(row[row.index(after: marker)...]))])
    }

    /// The plug that fits `width`: the drawing, or the one-row version.
    func plug(_ dot: Span, width: Int) -> [Line] {
        let big = plug(dot)
        return big.allSatisfy({ $0.width <= width }) ? big : [inlinePlug(dot)]
    }

    /// A strip: lit cells in their colour, off and system cells dim.
    func strip(_ strip: Strip, upTo limit: Int? = nil) -> Line {
        var line = Line()
        for state in strip.cells.prefix(limit ?? strip.cells.count) {
            switch state {
            case .amber, .blinkSlow, .blinkFast: line += Span(glyphs.cellLit, .amber)
            case .green: line += Span(glyphs.cellLit, .green)
            case .off: line += Span(glyphs.cellOff, .grey)
            case .system: line += Span(glyphs.cellSystem, .grey)
            }
        }
        return Line(cells: line.cells)
    }

    /// The marker under a strip at cell `index`.
    func caret(_ index: Int) -> Line {
        Line([Span(String(repeating: " ", count: index)), Span(glyphs.caret)])
    }

    /// A strip for `spec` with its playhead row (when it moves and `elapsed` is known).
    func stripWithPlayhead(_ spec: LEDSpec, elapsed: TimeInterval?, width: Int) -> [Line] {
        let cells = width >= Strip.width ? Strip.width : max(4, width)
        let laid = Strip(LEDTimeline(spec), width: cells)
        var lines = [strip(laid).truncated(to: width, ellipsis: "")]
        if let elapsed, let head = laid.playhead(at: elapsed) { lines.append(caret(head)) }
        return lines
    }

    // MARK: Tables

    /// Lays out rows of cells in columns two spaces apart (by visible width).
    func table(_ rows: [[Line]], gap: Int = 2) -> [Line] {
        guard let count = rows.map(\.count).max() else { return [] }
        let widths = (0..<count).map { column in rows.map { column < $0.count ? $0[column].width : 0 }.max() ?? 0 }
        return rows.map { row in
            var line = Line()
            for (index, cell) in row.enumerated() {
                line += index == row.count - 1 ? cell : cell.padded(to: widths[index] + gap)
            }
            return line.trimmingTrailingSpaces()
        }
    }

    /// Who holds the light: the override (if any) and the claims, the winner
    /// marked, columns dropped right to left until it fits `width`.
    func claimsTable(
        claims: [Claim], override: Override?, configuration: Configuration, now: Date, width: Int,
        overrideLabel: String = "override", names: [String: String] = [:]
    ) -> [Line] {
        let winnerID = override == nil ? claims.first(where: { (try? configuration.resolve($0.show)) != nil })?.id : nil
        func ledCell(_ resolved: LEDSpec?, name: String? = nil) -> Line {
            guard let resolved else { return Line([Span.dim("? (unknown)")]) }
            return Line([dot(resolved.firstState), Span(" " + abbreviated(name ?? resolved.description, 24))])
        }
        var rows: [[Line]] = [[
            Line(" "), Line([.dim("SHOW")]), Line([.dim("LED")]), Line([.dim("PRI")]), Line([.dim("EXPIRES")]),
            Line([.dim("LABEL")]), Line([.dim("ID")]),
        ]]
        if let override {
            let until = override.expiresAt.map { formatDuration($0.timeIntervalSince(now)) } ?? "-"
            rows.append([
                Line([Span(glyphs.winner, bold: true)]), Line([Span(abbreviated(override.show, 24), bold: true)]),
                ledCell(try? configuration.resolveLED(override.show)), Line([.dim("top")]),
                Line(until), Line([.dim("-")]), Line([Span(overrideLabel, bold: true)]),
            ])
        }
        for claim in claims {
            let wins = claim.id == winnerID
            rows.append([
                wins ? Line([Span(glyphs.winner, bold: true)]) : Line(" "),
                Line([Span(abbreviated(names[claim.id] ?? claim.show, 24), bold: wins)]),
                ledCell(try? configuration.resolve(claim.show), name: names[claim.id]),
                Line(String(claim.priority)), Line(formatDuration(claim.expiresAt.timeIntervalSince(now))),
                Line(claim.label.map { abbreviated($0, 20) } ?? "-"), Line(claim.id),
            ])
        }
        // Drop LABEL, then EXPIRES, then PRI while too wide; then truncate.
        var drop: [Int] = []
        var laid = table(rows)
        for column in [5, 4, 3] where laid.contains(where: { $0.width > width }) {
            drop.append(column)
            laid = table(rows.map { row in row.enumerated().filter { !drop.contains($0.offset) }.map(\.element) })
        }
        return laid.map { $0.truncated(to: width, ellipsis: glyphs.ellipsis) }
    }

    /// A row of `key label` hints, wrapped to `width`.
    func legend(_ items: [(key: String, label: String)], width: Int, gap: Int = 3) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for item in items {
            let piece = Line([Span(item.key, bold: true), Span(" "), Span.dim(item.label)])
            if current.width > 0, current.width + gap + piece.width > width {
                lines.append(current)
                current = Line()
            }
            if current.width > 0 { current += Span(String(repeating: " ", count: gap)) }
            current += piece
        }
        if current.width > 0 { lines.append(current) }
        return lines.map { $0.truncated(to: width, ellipsis: glyphs.ellipsis) }
    }
}

/// Shortens text for a cell: the start, then an ellipsis.
func abbreviated(_ text: String, _ length: Int) -> String {
    text.count <= length ? text : String(text.prefix(length - 1)) + "…"
}

// MARK: - Morse spelled out

/// The letters of a Morse message with when each symbol is sent, read from
/// the pattern that sends it (one lit step per symbol).
struct MorseScript {
    struct Symbol {
        var dash: Bool
        var start: TimeInterval
        var duration: TimeInterval
    }

    struct Letter {
        var character: Character
        var symbols: [Symbol]
        /// A word gap comes before this letter.
        var newWord: Bool
    }

    var letters: [Letter]
    var lit: LEDState
    var duration: TimeInterval

    init(text: String, pattern: Pattern) {
        var starts: [(TimeInterval, TimeInterval)] = []
        var elapsed: TimeInterval = 0
        var lit = LEDState.amber
        for step in pattern.steps {
            if step.state != .off {
                starts.append((elapsed, step.duration))
                lit = step.state
            }
            elapsed += step.duration
        }
        self.lit = lit
        duration = elapsed
        var letters: [Letter] = []
        var next = 0
        var gap = false
        for character in text.uppercased() {
            guard let code = Pattern.morseCodeTable[character] else {
                gap = !letters.isEmpty
                continue
            }
            var symbols: [Symbol] = []
            for symbol in code where next < starts.count {
                symbols.append(Symbol(dash: symbol == "-", start: starts[next].0, duration: starts[next].1))
                next += 1
            }
            letters.append(Letter(character: character, symbols: symbols, newWord: gap))
            gap = false
        }
        self.letters = letters
    }

    /// The message as sent by `elapsed` (everything when nil): `H ····  I ··`,
    /// the symbol being sent in the LED colour. Long messages keep their end.
    func line(at elapsed: TimeInterval?, visuals: Visuals, width: Int) -> Line {
        let glyphs = visuals.glyphs
        let ink: Ink = lit == .green ? .green : .amber
        var line = Line()
        for letter in letters {
            guard let first = letter.symbols.first, elapsed.map({ first.start <= $0 }) ?? true else { break }
            if line.width > 0 { line += Span(letter.newWord ? "   " + glyphs.separator + "   " : "  ") }
            line += Span(String(letter.character), bold: true)
            line += Span(" ")
            for symbol in letter.symbols {
                guard let elapsed else {
                    line += Span(symbol.dash ? glyphs.morseDash : glyphs.morseDot)
                    continue
                }
                guard symbol.start <= elapsed else { break }
                let sending = elapsed < symbol.start + symbol.duration
                line += Span(symbol.dash ? glyphs.morseDash : glyphs.morseDot, sending ? ink : nil, bold: sending)
            }
        }
        guard line.width > width, width > 2 else { return line }
        let cells = line.cells
        return Line(cells: Line([Span(glyphs.ellipsis)]).cells + cells.suffix(width - glyphs.ellipsis.count))
    }
}
