import ChargeLight
@testable import ChargeLightCommands
import Foundation
import XCTest

/// A terminal on stdout (and stderr), `columns` wide.
func tty(columns: Int = 100, rows: Int = 40, stdin: Bool = false, stderr: Bool = false) -> TerminalFacts {
    TerminalFacts(stdoutIsTerminal: true, stdinIsTerminal: stdin, stderrIsTerminal: stderr, size: { (columns, rows) })
}

/// The interactive terminal layer: capabilities, the visual vocabulary, the
/// interactive output of each command, and the guarantee that plain output
/// is unchanged.
final class TerminalTests: XCTestCase {
    var home: TempHome!
    var env: [String: String] = [:]

    override func setUp() {
        home = TempHome()
        env = home.environment
        env["LANG"] = "en_US.UTF-8"
    }

    override func tearDown() {
        home = nil
    }

    // MARK: - Capabilities

    func testInteractiveNeedsATerminalThatIsNotDumb() {
        XCTAssertTrue(Style(facts: tty(), environment: [:], noColor: false).interactive)
        XCTAssertFalse(Style(facts: TerminalFacts(), environment: [:], noColor: false).interactive)
        let dumb = Style(facts: tty(), environment: ["TERM": "dumb"], noColor: false)
        XCTAssertFalse(dumb.interactive)
        XCTAssertFalse(dumb.color)
        XCTAssertFalse(dumb.motion)
    }

    func testColourRules() {
        func color(_ environment: [String: String], noColor: Bool = false, facts: TerminalFacts = tty()) -> Bool {
            Style(facts: facts, environment: environment, noColor: noColor).color
        }
        XCTAssertTrue(color([:]))
        XCTAssertFalse(color(["NO_COLOR": "1"]))
        XCTAssertTrue(color(["NO_COLOR": ""]), "an empty NO_COLOR does not count")
        XCTAssertTrue(color(["NO_COLOR": "1", "CLICOLOR_FORCE": "1"]))
        XCTAssertFalse(color(["CLICOLOR_FORCE": "1"], noColor: true), "--no-color wins")
        XCTAssertFalse(color([:], facts: TerminalFacts()), "never in plain output")
        XCTAssertFalse(color(["CLICOLOR_FORCE": "1"], facts: TerminalFacts()), "plain output stays plain")

        let style = Style(facts: tty(), environment: [:], noColor: false)
        XCTAssertEqual(style.render(Span("x", .amber)), "\u{1B}[38;5;214mx\u{1B}[0m")
        let truecolor = Style(facts: tty(), environment: ["COLORTERM": "truecolor"], noColor: false)
        XCTAssertEqual(truecolor.render(Span("x", .green)), "\u{1B}[38;2;48;209;88mx\u{1B}[0m")
        XCTAssertEqual(Style(facts: tty(), environment: ["COLORTERM": "24bit"], noColor: false).render(Span("x", .grey)),
                       "\u{1B}[38;2;110;110;115mx\u{1B}[0m")
        XCTAssertEqual(Style(facts: tty(), environment: ["NO_COLOR": "1"], noColor: false).render(Span("x", .red, bold: true)), "x")
    }

    func testMotionAndGlyphs() {
        XCTAssertTrue(Style(facts: tty(), environment: [:], noColor: false).motion)
        XCTAssertFalse(Style(facts: tty(), environment: ["CHARGELIGHT_NO_ANIMATION": "1"], noColor: false).motion)
        func unicode(_ environment: [String: String]) -> Bool {
            Style(facts: tty(), environment: environment, noColor: false).unicode
        }
        XCTAssertFalse(unicode([:]))
        XCTAssertTrue(unicode(["LANG": "en_US.UTF-8"]))
        XCTAssertTrue(unicode(["LC_CTYPE": "UTF-8"]))
        XCTAssertTrue(unicode(["LC_ALL": "de_DE.utf8"]))
        XCTAssertFalse(unicode(["LC_ALL": "C", "LANG": "en_US.UTF-8"]), "LC_ALL comes first")
        XCTAssertFalse(unicode(["LANG": "C"]))
        XCTAssertEqual(Style(facts: tty(), environment: ["LANG": "C"], noColor: false).glyphs.lit, "*")
    }

    func testWidth() {
        XCTAssertEqual(Style(facts: tty(columns: 132), environment: [:], noColor: false).columns, 132)
        XCTAssertEqual(Style(facts: tty(columns: 3), environment: [:], noColor: false).columns, 10)
        XCTAssertEqual(Style(facts: TerminalFacts(stdoutIsTerminal: true), environment: [:], noColor: false).columns, 80)
    }

    func testLineHelpers() {
        let line = Line([Span("hello ", .amber), Span("world", bold: true)])
        XCTAssertEqual(line.width, 11)
        XCTAssertEqual(line.truncated(to: 8).text, "hello w…")
        XCTAssertEqual(line.truncated(to: 11), line)
        XCTAssertEqual(Line("one two three four five").wrapped(to: 10, indent: 2).map(\.text), ["one two", "  three", "  four", "  five"])
        XCTAssertEqual(stripANSI("\u{1B}[1;38;5;214mA\u{1B}[0m\u{1B}[?25h\u{1B}[3;1HB\u{1B}]0;title\u{7}C"), "ABC")
    }

    func testKeyParsing() {
        XCTAssertEqual(KeyReader.parse(Array("a1 ".utf8)), [.character("a"), .character("1"), .character(" ")])
        XCTAssertEqual(KeyReader.parse([0x0D, 0x7F, 0x03, 0x1B]), [.enter, .backspace, .interrupt, .escape])
        XCTAssertEqual(KeyReader.parse([0x1B, 0x5B, 0x41, 0x71]), [.other, .character("q")], "an arrow key, then q")
        XCTAssertEqual(KeyReader.parse(Array("é".utf8)), [.character("é")])
    }

    // MARK: - The pattern strip and the dot

    private func strip(_ show: String, width: Int = Strip.width) throws -> Strip {
        Strip(LEDTimeline(try Configuration().resolveLED(show)), width: width)
    }

    private func text(_ strip: Strip, unicode: Bool = true) -> String {
        Visuals(style: Style(facts: tty(), environment: unicode ? ["LANG": "en_US.UTF-8"] : [:], noColor: false))
            .strip(strip).text
    }

    func testStripForStates() throws {
        for (state, cell) in [("amber", "▇"), ("green", "▇"), ("off", "░"), ("system", "·")] {
            let laid = try strip(state)
            XCTAssertTrue(laid.isStatic)
            XCTAssertEqual(text(laid), String(repeating: cell, count: 24), state)
            XCTAssertNil(laid.playhead(at: 3))
        }
        XCTAssertEqual(text(try strip("amber"), unicode: false), String(repeating: "#", count: 24))
    }

    func testStripForHardwareBlinks() throws {
        let slow = try strip("blink-slow")
        XCTAssertFalse(slow.isStatic)
        XCTAssertEqual(text(slow), String(repeating: "▇▇▇▇░░░░", count: 3))
        XCTAssertEqual(slow.cellDuration, 0.25, accuracy: 1e-9)
        XCTAssertEqual(Set(slow.cells), [.amber, .off])
        let fast = try strip("blink-fast")
        XCTAssertEqual(text(fast), String(repeating: "▇░", count: 12))
        XCTAssertEqual(text(fast, unicode: false), String(repeating: "#-", count: 12))
    }

    func testStripForPatterns() throws {
        XCTAssertEqual(text(try strip("heartbeat")), String(repeating: "▇░▇░░░░░░░", count: 2), "exact steps, whole cycles")
        XCTAssertEqual(text(try strip("green:300,off:300")), String(repeating: "▇▇░░", count: 6))
        XCTAssertEqual(text(try strip("blink-green")), String(repeating: "▇▇░░", count: 6))
        let alternate = try strip("alternate")
        XCTAssertEqual(alternate.cells, Array([[LEDState]](repeating: [.amber, .amber, .green, .green], count: 6).joined()))
        for name in Pattern.builtIn.keys {
            let laid = try strip(name)
            let cycle = LEDTimeline(try Configuration().resolveLED(name)).cycle
            let perCycle = Int((cycle / laid.cellDuration).rounded())
            XCTAssertLessThanOrEqual(perCycle, Strip.maximumCycle, name)
            XCTAssertEqual(laid.cells.count % perCycle, 0, "\(name): whole cycles")
        }
        // A finite run, as flash draws it: 3 flashes in 24 cells.
        let flash = Strip(finite: Array(Array(repeating: LEDTimeline(.pattern(try Pattern(parsing: "green:150,off:150"))).segments, count: 3).joined()))
        XCTAssertEqual(text(flash), String(repeating: "▇▇▇▇░░░░", count: 3))
    }

    func testDotFollowsTheTimeline() throws {
        let heartbeat = LEDTimeline(try Configuration().resolveLED("heartbeat"))
        XCTAssertEqual(heartbeat.cycle, 1.2, accuracy: 1e-9)
        XCTAssertEqual(heartbeat.state(at: 0.05), .amber)
        XCTAssertEqual(heartbeat.state(at: 0.13), .off)
        XCTAssertEqual(heartbeat.state(at: 0.25), .amber)
        XCTAssertEqual(heartbeat.state(at: 0.5), .off)
        XCTAssertEqual(heartbeat.state(at: 1.25), .amber, "repeats")
        let slow = LEDTimeline(.state(.blinkSlow))
        XCTAssertEqual(slow.state(at: 0.5), .amber)
        XCTAssertEqual(slow.state(at: 1.5), .off)
        XCTAssertEqual(LEDTimeline(.state(.green)).state(at: 99), .green)
        // A hardware blink inside a pattern becomes on/off steps.
        let mixed = LEDTimeline(.pattern(try Pattern(parsing: "blink-fast:600,green:400")))
        XCTAssertEqual(mixed.segments.map(\.state), [.amber, .off, .amber, .green])
        XCTAssertEqual(mixed.cycle, 1.0, accuracy: 1e-9)
        // The playhead moves through the strip in time with the dot.
        let laid = try strip("blink-slow")
        XCTAssertEqual(laid.playhead(at: 0), 0)
        XCTAssertEqual(laid.playhead(at: 1.1), 4)
        XCTAssertEqual(laid.playhead(at: 6.1), 0, "wraps after the strip's 6 s")
        let visuals = Visuals(style: Style(facts: tty(), environment: ["LANG": "en_US.UTF-8"], noColor: false))
        XCTAssertEqual(visuals.dot(.state(.blinkSlow), elapsed: 1.5).text, "○")
        XCTAssertEqual(visuals.dot(.state(.blinkSlow), elapsed: 0.5), Span("●", .amber))
        XCTAssertEqual(visuals.dot(.state(.system), elapsed: nil), Span("◌", .grey))
        XCTAssertEqual(visuals.dot(.green), Span("●", .green))
    }

    func testPlug() {
        let visuals = Visuals(style: Style(facts: tty(), environment: ["LANG": "en_US.UTF-8"], noColor: false))
        let plug = visuals.plug(visuals.dot(.amber))
        XCTAssertEqual(plug.count, 3)
        XCTAssertTrue(plug.allSatisfy { $0.width == 30 })
        XCTAssertEqual(plug[1].spans.filter { $0.ink != nil }, [Span("●", .amber)], "the dot is the only coloured cell")
        XCTAssertEqual(visuals.plug(visuals.dot(.amber), width: 20).count, 1, "narrow: the one-row plug")
        let ascii = Visuals(style: Style(facts: tty(), environment: [:], noColor: false))
        XCTAssertTrue(ascii.plug(ascii.dot(.off)).allSatisfy { $0.text.allSatisfy(\.isASCII) })
    }

    // MARK: - play: frame

    private func playView(claims: [Claim] = [], override: Override? = nil, morse: String? = nil) -> PlayView {
        PlayView(
            desired: try! Configuration().resolveLED("heartbeat"), name: "heartbeat",
            detail: "amber:120,off:120,amber:120,off:840", elapsed: 0.3, holder: "you (play)", claims: claims,
            override: override, overrideIsYours: true, configuration: Configuration(), now: Date(),
            patterns: Configuration().patterns.keys.sorted(), legend: true, morse: morse, message: nil)
    }

    private func sampleClaims() -> [Claim] {
        let now = Date()
        return [
            Claim(id: "claude:abc", show: "working", priority: 20, label: "my-project", updatedAt: now,
                  expiresAt: now.addingTimeInterval(1800), stamp: 1),
            Claim(id: "build", show: "ready", priority: 10, updatedAt: now, expiresAt: now.addingTimeInterval(600), stamp: 1),
        ]
    }

    func testPlayFrameFitsEveryWidth() {
        let view = playView(claims: sampleClaims(), override: Override(show: "heartbeat", setAt: Date()))
        for unicode in [true, false] {
            let style = Style(facts: tty(), environment: unicode ? ["LANG": "en_US.UTF-8"] : [:], noColor: false)
            for width in [40, 60, 80, 120] {
                let frame = PlayPanel.frame(view, width: width, height: 40, style: style)
                let text = frame.map(\.text).joined(separator: "\n")
                for line in frame {
                    XCTAssertLessThanOrEqual(line.width, width, "\(width): \(line.text)")
                    XCTAssertLessThanOrEqual(stripANSI(style.render(line)).count, width)
                }
                XCTAssertTrue(text.contains("chargelight play"), "\(width)")
                XCTAssertTrue(text.contains(unicode ? "━━━━━━━━━━━━━┥" : "=============|"), "\(width): the plug")
                XCTAssertTrue(text.contains("a amber"), "\(width): the legend")
                XCTAssertTrue(text.contains("1 alternate"), "\(width): pattern keys")
                XCTAssertTrue(text.contains("who holds the light"), "\(width)")
                XCTAssertTrue(text.contains("claude:"), "\(width): the claims")
                XCTAssertTrue(text.contains("you (play)"), "\(width): the override is yours")
                XCTAssertTrue(text.contains("q quit"), "\(width): the footer")
                XCTAssertTrue(text.contains(unicode ? "▲" : "^"), "\(width): the playhead")
            }
        }
    }

    func testPlayFrameFitsSmallHeightsAndShowsMorseEntry() {
        let style = Style(facts: tty(), environment: ["LANG": "en_US.UTF-8"], noColor: false)
        for height in [8, 14, 20] {
            let frame = PlayPanel.frame(playView(claims: sampleClaims()), width: 60, height: height, style: style)
            XCTAssertLessThanOrEqual(frame.count, height)
            XCTAssertTrue(frame.last?.text.contains("q quit") == true, "\(height): footer kept")
        }
        let typing = PlayPanel.frame(playView(morse: "hi"), width: 80, height: 40, style: style).map(\.text)
        XCTAssertTrue(typing.contains { $0.contains("morse  hi▏") }, typing.joined(separator: "\n"))
        XCTAssertTrue(typing.contains { $0.contains("enter send") })
        var hidden = playView()
        hidden.legend = false
        XCTAssertFalse(PlayPanel.frame(hidden, width: 80, height: 40, style: style).contains { $0.text.contains("a amber") })
    }

    // MARK: - play: keys

    func testPlayKeyMap() {
        let patterns = Configuration().patterns.keys.sorted()
        func action(_ key: Key, typing: Bool = false) -> PlayAction {
            PlayPanel.action(for: key, typing: typing, patterns: patterns)
        }
        XCTAssertEqual(action(.character("a")), .show("amber"))
        XCTAssertEqual(action(.character("G")), .show("green"))
        XCTAssertEqual(action(.character("o")), .show("off"))
        XCTAssertEqual(action(.character("s")), .show("blink-slow"))
        XCTAssertEqual(action(.character("f")), .show("blink-fast"))
        XCTAssertEqual(action(.character("1")), .show("alternate"))
        XCTAssertEqual(action(.character("4")), .show("heartbeat"))
        XCTAssertEqual(action(.character("6")), .show("sos"))
        XCTAssertEqual(action(.character("7")), .none, "only six patterns")
        XCTAssertEqual(action(.character(" ")), .flash)
        XCTAssertEqual(action(.character("m")), .beginMorse)
        XCTAssertEqual(action(.character("x")), .system)
        XCTAssertEqual(action(.character("0")), .system)
        XCTAssertEqual(action(.character("?")), .toggleLegend)
        for quit in [Key.character("q"), .escape, .interrupt] { XCTAssertEqual(action(quit), .quit) }
        XCTAssertEqual(action(.other), .none)
        // Typing Morse: keys are text.
        XCTAssertEqual(action(.character("q"), typing: true), .type("q"))
        XCTAssertEqual(action(.character("7"), typing: true), .type("7"))
        XCTAssertEqual(action(.character("!"), typing: true), .none)
        XCTAssertEqual(action(.enter, typing: true), .sendMorse)
        XCTAssertEqual(action(.escape, typing: true), .cancelMorse)
        XCTAssertEqual(action(.backspace, typing: true), .erase)
        XCTAssertEqual(action(.interrupt, typing: true), .quit)
    }

    private func overrideShow() -> String? {
        guard let data = try? Data(contentsOf: home.paths.overrideFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["show"] as? String
    }

    private func makeSession() throws -> (PlaySession, CLIHarness) {
        let harness = CLIHarness(environment: env)
        let light = try StatusLight(environment: env)
        return (PlaySession(cli: harness.cli, light: light, motion: false), harness)
    }

    func testPlayKeysDriveTheLightAndQuitRestores() throws {
        XCTAssertEqual(runCLI(["claim", "build", "working"], environment: env).code, 0)
        XCTAssertEqual(runCLI(["set", "blink-fast"], environment: env).code, 0)
        let (session, _) = try makeSession()
        XCTAssertEqual(session.before?.show, "blink-fast")
        for (key, override, led) in [
            ("a", "amber", "amber"), ("g", "green", "green"), ("o", "off", "off"), ("s", "blink-slow", "blink-slow"),
            ("f", "blink-fast", "blink-fast"), ("1", "alternate", "amber"), ("4", "heartbeat", "amber"),
            ("2", "blink-green", "green"),
        ] {
            session.handle(.character(Character(key)))
            XCTAssertNil(session.message)
            XCTAssertEqual(overrideShow(), override, key)
            XCTAssertEqual(home.ledFile, led, key)
            XCTAssertTrue(session.view().overrideIsYours, key)
        }
        session.handle(.character("x"))
        XCTAssertNil(overrideShow(), "x hands the light back")
        XCTAssertEqual(home.ledFile, "amber", "the claim decides again")
        XCTAssertEqual(session.view().holder, "build (working)")
        session.handle(.character("g"))
        session.handle(.character("q"))
        XCTAssertTrue(session.quit)
        let restored = try session.finish()
        XCTAssertEqual(overrideShow(), "blink-fast", "the override from before play is back")
        XCTAssertEqual(restored.led.description, "blink-fast")
        XCTAssertEqual(home.ledFile, "blink-fast")
    }

    func testPlayQuitWithoutEarlierOverrideClearsIt() throws {
        let (session, _) = try makeSession()
        session.handle(.character("a"))
        XCTAssertEqual(overrideShow(), "amber")
        session.handle(.escape)
        XCTAssertTrue(session.quit)
        _ = try session.finish()
        XCTAssertNil(overrideShow())
        XCTAssertEqual(home.ledFile, "system")
    }

    func testPlayMorseEntryAndFlash() throws {
        let (session, _) = try makeSession()
        session.handle(.character("a"))
        session.handle(.character("m"))
        XCTAssertEqual(session.morse, "")
        for key in "hiq" { session.handle(.character(key)) }
        XCTAssertEqual(session.morse, "hiq", "while typing, q is a letter")
        session.handle(.backspace)
        XCTAssertEqual(session.morse, "hi")
        XCTAssertTrue(PlayPanel.frame(session.view(), width: 80, height: 40, style: .plain).contains { $0.text.contains("morse  hi") })
        session.handle(.escape)
        XCTAssertNil(session.morse, "Esc cancels")
        XCTAssertFalse(session.quit)
        XCTAssertNil(session.notice)

        // Morse over our own override: it is lifted while the message plays, then put back.
        session.handle(.character("m"))
        for key in "hi" { session.handle(.character(key)) }
        session.handle(.enter)
        XCTAssertNil(session.morse)
        let notice = try XCTUnwrap(session.notice)
        XCTAssertTrue(notice.claim.id.hasPrefix("morse:"))
        XCTAssertNil(overrideShow(), "lifted so the message shows")
        XCTAssertEqual(home.ledFile, "amber", "Morse starts lit")
        let view = session.view()
        XCTAssertEqual(view.name, "morse \"hi\"")
        XCTAssertEqual(view.names[notice.claim.id], "morse \"hi\"")
        XCTAssertNotNil(view.sending)
        session.tick(now: notice.claim.expiresAt.addingTimeInterval(0.01))
        XCTAssertNil(session.notice)
        XCTAssertEqual(overrideShow(), "amber", "put back when the message ends")

        // Flash: green, three times.
        session.handle(.character(" "))
        let flash = try XCTUnwrap(session.notice)
        XCTAssertTrue(flash.claim.id.hasPrefix("flash:"))
        XCTAssertEqual(flash.claim.show, "green:150,off:150")
        XCTAssertEqual(flash.claim.expiresAt.timeIntervalSince(flash.claim.updatedAt), 0.88, accuracy: 0.01)
        XCTAssertEqual(home.ledFile, "green")
        // A choice during the flash ends it and wins.
        session.handle(.character("o"))
        XCTAssertNil(session.notice)
        XCTAssertEqual(overrideShow(), "off")
        XCTAssertFalse(try StatusLight(environment: env).snapshot().claims.contains { $0.id == flash.claim.id })
        _ = try session.finish()
    }

    func testPlayNeedsATerminal() {
        let piped = runCLI(["play"], environment: env)
        XCTAssertEqual(piped.code, 2)
        XCTAssertTrue(piped.stderr.contains("needs a terminal"), piped.stderr)
        XCTAssertEqual(runCLI(["play"], environment: env, terminal: tty()).code, 2, "stdin must be a terminal too")
        let json = runCLI(["play", "--json"], environment: env, terminal: tty(stdin: true))
        XCTAssertEqual(json.code, 2)
        XCTAssertEqual(json.json["ok"] as? Bool, false)
        var dumb = env
        dumb["TERM"] = "dumb"
        XCTAssertEqual(runCLI(["play"], environment: dumb, terminal: tty(stdin: true)).code, 2)
    }

    // MARK: - Interactive output carries the plain facts

    private func fancy(_ arguments: [String], columns: Int = 100, environment: [String: String]? = nil) -> CLIRun {
        runCLI(arguments, environment: environment ?? env, terminal: tty(columns: columns))
    }

    private func assertFits(_ run: CLIRun, columns: Int, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        for text in stripANSI(run.stdout).split(separator: "\n") {
            XCTAssertLessThan(text.count, columns, "\(name) at \(columns): \(text)", file: file, line: line)
        }
    }

    func testStatusCarriesTheFacts() throws {
        XCTAssertEqual(runCLI(["claim", "claude:abc", "working", "--label", "proj"], environment: env).code, 0)
        XCTAssertEqual(runCLI(["claim", "build", "heartbeat", "--priority", "25"], environment: env).code, 0)
        XCTAssertEqual(runCLI(["set", "green", "--for", "10m"], environment: env).code, 0)
        let plain = runCLI(["status"], environment: env).stdout
        let run = fancy(["status"])
        XCTAssertEqual(run.code, 0)
        XCTAssertTrue(run.stdout.contains("\u{1B}["), "coloured")
        let text = stripANSI(run.stdout)
        for fact in ["led", "green, desired green", "[file backend]", "watcher", "not running", "helper", "not installed",
                     "sudo chargelight setup", "override", "(for 10m)", "claims", "2", "SHOW", "LED", "PRI", "EXPIRES",
                     "LABEL", "ID", "claude:abc", "working", "proj", "build", "heartbeat", "25", "▶", "━━┥ ● │▌"] {
            XCTAssertTrue(text.contains(fact), "status lacks \(fact):\n\(text)")
        }
        for id in ["claude:abc", "build"] { XCTAssertTrue(plain.contains(id)) }
        XCTAssertTrue(text.contains("▶  green"), "the override wins:\n\(text)")
        for columns in [40, 60, 80, 120] { assertFits(fancy(["status"], columns: columns), columns: columns, "status") }
    }

    func testListCarriesTheFacts() throws {
        let run = fancy(["list"])
        let text = stripANSI(run.stdout)
        for state in LEDState.allCases { XCTAssertTrue(text.contains("● \(state.rawValue)") || text.contains("○ \(state.rawValue)") || text.contains("◌ \(state.rawValue)"), state.rawValue) }
        XCTAssertTrue(text.contains("idle: system"))
        for (name, preset) in Configuration.builtInPresets {
            XCTAssertTrue(text.contains(name), name)
            XCTAssertTrue(text.contains(preset.led), preset.led)
        }
        for (name, pattern) in Pattern.builtIn {
            XCTAssertTrue(text.contains(name), name)
            XCTAssertTrue(text.contains(String(pattern.literal.prefix(30))), name)
        }
        XCTAssertTrue(text.contains("▇░▇░░░░░░░▇░▇░░░░░░░"), "heartbeat's strip")
        for columns in [40, 60, 80, 120] { assertFits(fancy(["list"], columns: columns), columns: columns, "list") }
    }

    func testDoctorCarriesTheFacts() throws {
        let plain = runCLI(["doctor"], environment: env)
        let run = fancy(["doctor"])
        XCTAssertEqual(run.code, plain.code)
        let text = stripANSI(run.stdout)
        for name in ["apple-silicon", "magsafe-led", "power-adapter", "helper-installed", "helper-version", "passwordless-sudo"] {
            XCTAssertTrue(text.contains(name), name)
        }
        XCTAssertTrue(text.contains("✘ helper-installed"), text)
        XCTAssertTrue(text.contains("some checks failed"))
        XCTAssertTrue(text.contains("no-such-helper"))
        XCTAssertTrue(run.stdout.contains("\u{1B}[38;5;203m"), "failures in red")
        for columns in [40, 60] { assertFits(fancy(["doctor"], columns: columns), columns: columns, "doctor") }
    }

    func testSetClaimReleaseResetCarryTheFacts() throws {
        var text = stripANSI(fancy(["set", "heartbeat"]).stdout)
        XCTAssertTrue(text.hasPrefix("● heartbeat  ▇░▇░░░░░░░"), text)
        XCTAssertTrue(text.contains("until: chargelight set system"))
        text = stripANSI(fancy(["amber", "--for", "10m"]).stdout)
        XCTAssertTrue(text.hasPrefix("● amber"), text)
        XCTAssertTrue(text.contains("for 10m"), text)
        text = stripANSI(fancy(["set", "system"]).stdout)
        XCTAssertTrue(text.hasPrefix("◌ system"), text)
        text = stripANSI(fancy(["claim", "build", "green", "--label", "ci"]).stdout)
        XCTAssertTrue(text.hasPrefix("● green"), text)
        for fact in ["build", "claimed green", "priority 20", "expires in 30m", "wins"] { XCTAssertTrue(text.contains(fact), fact) }
        text = stripANSI(fancy(["claim", "agent", "attention"]).stdout)
        XCTAssertTrue(text.contains("blink-fast"), text)
        text = stripANSI(fancy(["claim", "build", "green"]).stdout)
        XCTAssertTrue(text.contains("agent wins with priority 30"), text)
        text = stripANSI(fancy(["release", "build"]).stdout)
        XCTAssertTrue(text.contains("released build"), text)
        text = stripANSI(fancy(["release", "nobody"]).stdout)
        XCTAssertTrue(text.contains("no claim nobody"), text)
        text = stripANSI(fancy(["reset"]).stdout)
        XCTAssertTrue(text.contains("released 1 claim(s), cleared any override"), text)
        XCTAssertTrue(text.hasPrefix("◌ system"), text)
        text = stripANSI(fancy(["get"]).stdout)
        XCTAssertEqual(text, "◌ system\n")
    }

    func testSetupAndUninstallLines() {
        let harness = CLIHarness(environment: env, terminal: tty())
        _ = harness.run(["version"])
        let done = stripANSI(harness.cli.fancyChecks(["installed /a (version 0.1.0, from /b)", "installed /c"], footer: "try: chargelight flash green"))
        XCTAssertEqual(done, "✔ installed /a (version 0.1.0, from /b)\n✔ installed /c\ntry: chargelight flash green")
        XCTAssertEqual(stripANSI(harness.cli.fancyChecks([], footer: "nothing to remove")), "nothing to remove")
    }

    func testHelpIsTheSameTextStyled() {
        let plain = runCLI(["help"], environment: env).stdout
        let wide = fancy(["help"], columns: 200)
        XCTAssertNotEqual(wide.stdout, plain)
        XCTAssertEqual(stripANSI(wide.stdout), plain, "only styling is added when nothing needs wrapping")
        XCTAssertTrue(wide.stdout.contains("\u{1B}[1mTry it\u{1B}[0m"))
        XCTAssertTrue(plain.contains("chargelight play"))
        // Narrow: wrapped, never wider than the terminal, same words.
        for columns in [40, 60, 80] {
            let run = fancy(["help"], columns: columns)
            assertFits(run, columns: columns, "help")
            XCTAssertEqual(stripANSI(run.stdout).filter { !$0.isWhitespace }, plain.filter { !$0.isWhitespace }, "\(columns)")
        }
    }

    func testErrorsAreRedOnATerminal() {
        let red = runCLI(["nonsense"], environment: env, terminal: TerminalFacts(stderrIsTerminal: true))
        XCTAssertEqual(red.code, 2)
        XCTAssertTrue(red.stderr.hasPrefix("\u{1B}[38;5;203mchargelight:\u{1B}[0m unknown command"), red.stderr)
        var noColor = env
        noColor["NO_COLOR"] = "1"
        XCTAssertTrue(runCLI(["nonsense"], environment: noColor, terminal: TerminalFacts(stderrIsTerminal: true)).stderr
            .hasPrefix("chargelight: unknown command"))
        XCTAssertTrue(runCLI(["nonsense", "--no-color"], environment: env, terminal: TerminalFacts(stderrIsTerminal: true)).stderr
            .hasPrefix("chargelight: unknown command"))
    }

    func testRunSummaryOnStandardError() {
        let run = runCLI(["run", "--", "/bin/sh", "-c", "exit 3"], environment: env, terminal: TerminalFacts(stderrIsTerminal: true))
        XCTAssertEqual(run.code, 3)
        XCTAssertEqual(run.stdout, "", "stdout belongs to the command")
        let line = stripANSI(run.stderr)
        XCTAssertTrue(line.hasPrefix("✘ sh  "), line)
        for fact in [" s  exit 3", "light: ● blink-fast"] { XCTAssertTrue(line.contains(fact), line) }
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        let ok = stripANSI(runCLI(["run", "--", "/usr/bin/true"], environment: env, terminal: TerminalFacts(stderrIsTerminal: true)).stderr)
        XCTAssertTrue(ok.hasPrefix("✔ true  ") && ok.contains("exit 0") && ok.contains("light: ● green"), ok)
        XCTAssertEqual(runCLI(["run", "-q", "--", "/usr/bin/true"], environment: env, terminal: TerminalFacts(stderrIsTerminal: true)).stderr, "")
        XCTAssertEqual(runCLI(["run", "--json", "--", "/usr/bin/true"], environment: env, terminal: TerminalFacts(stderrIsTerminal: true)).stderr, "")
        XCTAssertEqual(runCLI(["run", "--", "/usr/bin/true"], environment: env).stderr, "", "not a terminal: nothing")
    }

    func testMorseAndFlashWaitAndSummarise() {
        var still = env
        still["CHARGELIGHT_NO_ANIMATION"] = "1"
        let start = Date()
        let morse = fancy(["morse", "hi", "--unit", "50"], environment: still)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.9, "waits as if --wait")
        XCTAssertEqual(morse.code, 0)
        XCTAssertEqual(stripANSI(morse.stdout), "✔ morse \"hi\" (1.0 s)  ·  now ◌ system\n  H ····  I ··\n")
        XCTAssertFalse(morse.stdout.contains("\u{1B}[?25l"), "no animation: no cursor games")

        // Animated: the cursor is hidden while it runs and shown again.
        let flash = fancy(["flash", "green", "--times", "1"])
        XCTAssertEqual(flash.code, 0)
        XCTAssertTrue(flash.stdout.contains("\u{1B}[?25l"))
        XCTAssertTrue(flash.stdout.contains("\u{1B}[?25h"))
        let text = stripANSI(flash.stdout)
        XCTAssertTrue(text.contains("flash green"), text)
        XCTAssertTrue(text.hasSuffix("✔ flash green 1 time(s) (0.3 s)  ·  now ◌ system\n"), text)
        XCTAssertTrue(try StatusLight(environment: env).snapshot().claims.isEmpty, "over when it returns")
    }

    func testDemoTourInATerminal() {
        var still = env
        still["CHARGELIGHT_NO_ANIMATION"] = "1"
        let harness = CLIHarness(environment: still, terminal: tty())
        harness.cli.demoStep = 0
        XCTAssertEqual(harness.run(["demo"]), 0)
        let text = stripANSI(harness.stdout)
        for (index, step) in CLI.demoSequence.enumerated() {
            XCTAssertTrue(text.contains("\(index + 1)/7  \(step.show)"), step.show)
            XCTAssertTrue(text.contains(step.purpose), step.purpose)
        }
        XCTAssertTrue(text.contains("restored: system"), text)
        XCTAssertTrue(text.contains("chargelight play"))
        XCTAssertNil(try? Data(contentsOf: home.paths.overrideFile))
    }

    // MARK: - Plain output is unchanged

    /// Commands whose plain output does not depend on the clock.
    private let stable: [[String]] = [
        ["help"], ["list"], ["version"], ["get"], ["set", "amber"], ["set", "system"], ["amber", "--for", "10m"],
        ["claim", "x", "green"], ["release", "x"], ["reset"], ["completions", "zsh"], ["nonsense"], ["set"],
    ]

    func testPlainOutputHasNoEscapeCodes() {
        let all = stable + [["status"], ["doctor"], ["flash"], ["morse", "e", "--unit", "50"], ["run", "--", "/usr/bin/true"],
                            ["watch", "--count", "1"], ["claim", "y", "heartbeat"], ["status"]]
        for arguments in all {
            for extra in [[], ["--json"]] {
                let run = runCLI(arguments + extra, environment: env)
                XCTAssertFalse(run.stdout.contains("\u{1B}"), "\(arguments + extra): \(run.stdout)")
                XCTAssertFalse(run.stderr.contains("\u{1B}"), "\(arguments + extra): \(run.stderr)")
            }
        }
        let fresh = TempHome()
        let harness = CLIHarness(environment: fresh.environment)
        harness.cli.demoStep = 0
        XCTAssertEqual(harness.run(["demo"]), 0)
        XCTAssertEqual(harness.stdout, CLI.demoSequence.map { $0.show + "\n" }.joined() + "restored: system\n")
    }

    /// Runs `stable` in order in a fresh state directory, in one terminal setting.
    private func transcript(_ extra: [String], environment change: (inout [String: String]) -> Void = { _ in },
                            terminal: TerminalFacts = TerminalFacts()) -> [String] {
        let fresh = TempHome()
        var environment = fresh.environment
        environment["LANG"] = "en_US.UTF-8"
        change(&environment)
        return stable.map { arguments in
            let run = runCLI(arguments + extra, environment: environment, terminal: terminal)
            // Timestamps in JSON differ between runs.
            let stdout = run.stdout.replacingOccurrences(
                of: #""(updatedAt|expiresAt|setAt|stamp)":("[^"]*"|[0-9]+)"#, with: "", options: .regularExpression)
            return "\(arguments) \(run.code)\n\(stdout)\n--\n\(run.stderr)"
        }
    }

    func testTerminalWithJSONQuietOrDumbIsByteForBytePlain() {
        let terminal = tty(stdin: true, stderr: false)
        XCTAssertEqual(transcript([], environment: { $0["TERM"] = "dumb" }, terminal: terminal), transcript([]))
        XCTAssertEqual(transcript(["--json"], terminal: terminal), transcript(["--json"]))
        XCTAssertEqual(transcript(["--quiet"], terminal: terminal), transcript(["--quiet"]))
        XCTAssertNotEqual(transcript([], terminal: terminal), transcript([]), "a real terminal does get the new output")
        // watch with --count stays line-based in a terminal.
        let watch = runCLI(["watch", "--count", "1"], environment: env, terminal: tty(stdin: true))
        XCTAssertFalse(watch.stdout.contains("\u{1B}"))
        XCTAssertTrue(watch.stdout.hasSuffix("  system  idle\n"), watch.stdout)
    }

    func testNoColorFlagKeepsTheLayoutWithoutColour() {
        let run = fancy(["list", "--no-color"])
        XCTAssertEqual(run.code, 0)
        XCTAssertFalse(run.stdout.contains("\u{1B}"))
        XCTAssertTrue(run.stdout.contains("● green"), "still the interactive layout")
        var noColor = env
        noColor["NO_COLOR"] = "1"
        XCTAssertFalse(fancy(["status"], environment: noColor).stdout.contains("\u{1B}"))
    }
}
