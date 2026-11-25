import ChargeLight
@testable import ChargeLightCommands
import XCTest

/// The commands added in 0.2, run in-process with the file backend.
final class CommandTests: XCTestCase {
    var home: TempHome!
    var env: [String: String] { home.environment }
    /// For `run` tests whose command needs `PATH`.
    var envWithPath: [String: String] { env.merging(["PATH": "/usr/bin:/bin"]) { $1 } }

    override func setUp() { home = TempHome() }
    override func tearDown() { home = nil }

    func json(_ args: [String], code: Int32 = 0, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let run = runCLI(args + ["--json"], environment: env)
        XCTAssertEqual(run.code, code, "\(args): \(run.stdout)", file: file, line: line)
        return run.json
    }

    func usageError(_ args: [String], file: StaticString = #filePath, line: UInt = #line) {
        let run = runCLI(args, environment: env)
        XCTAssertEqual(run.code, 2, "\(args): \(run.stdout) \(run.stderr)", file: file, line: line)
        XCTAssertTrue(run.stderr.hasPrefix("chargelight: "), "\(args): \(run.stderr)", file: file, line: line)
    }

    var claims: [[String: Any]] { json(["status"])["claims"] as? [[String: Any]] ?? [] }

    func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: home.paths.configFile)
    }

    // MARK: - Parsing

    func testRunTakesEverythingAfterTheFirstDoubleDash() throws {
        let inv = try Invocation.parse(["--json", "run", "--id", "x", "--", "make", "--json", "-q", "--", "--ttl"])
        XCTAssertEqual(inv.command, "run")
        XCTAssertTrue(inv.json)
        XCTAssertFalse(inv.quiet)
        XCTAssertEqual(inv.options, ["--id": "x"])
        XCTAssertEqual(inv.trailing, ["make", "--json", "-q", "--", "--ttl"])
        XCTAssertNil(try Invocation.parse(["release", "--", "--id"]).trailing)
        XCTAssertEqual(try Invocation.parse(["flash", "--wait"]).flags, ["--wait"])
        XCTAssertThrowsError(try Invocation.parse(["flash", "--wait=yes"]))
        XCTAssertEqual(try Invocation.parse(["claim", "a", "b", "--priority", "-5"]).options, ["--priority": "-5"])
    }

    func testUnknownOptionsPerCommand() {
        let cases: [[String]] = [
            ["get", "--wait"], ["set", "amber", "--times", "2"], ["amber", "--ttl", "5"], ["flash", "--for", "1m"],
            ["morse", "hi", "--times", "2"], ["demo", "--count", "1"], ["claim", "a", "amber", "--for", "1m"],
            ["claim", "a", "amber", "--wait"], ["release", "a", "--id", "b"], ["reset", "--priority", "1"],
            ["status", "--count", "1"], ["list", "--label", "x"], ["watch", "--id", "x"], ["pipe", "--keep", "1"],
            ["pipe", "--ttl", "1m"], ["run", "--priority", "1", "--", "true"], ["run", "--wait", "--", "true"],
            ["completions", "zsh", "--count", "1"], ["doctor", "--wait"], ["version", "--for", "1"],
            ["release", "a", "--", "b"], ["set", "--", "amber", "extra"],
        ]
        for args in cases { usageError(args) }
    }

    // MARK: - set and the shorthand

    func testShorthand() {
        var object = json(["amber"])
        XCTAssertEqual(object["led"] as? String, "amber")
        XCTAssertEqual((object["override"] as? [String: Any])?["show"] as? String, "amber")
        XCTAssertEqual(home.ledFile, "amber")
        XCTAssertEqual(runCLI(["green"], environment: env).stdout, "green (until: chargelight set system)\n")

        object = json(["off", "--for", "2h"])
        let override = object["override"] as? [String: Any]
        let formatter = ISO8601DateFormatter()
        let setAt = formatter.date(from: override?["setAt"] as? String ?? "")
        let expiresAt = formatter.date(from: override?["expiresAt"] as? String ?? "")
        XCTAssertEqual(expiresAt.flatMap { e in setAt.map { e.timeIntervalSince($0) } } ?? 0, 7200, accuracy: 1)

        object = json(["heartbeat"])
        XCTAssertEqual(object["led"] as? String, "heartbeat")
        XCTAssertEqual(home.ledFile, "amber", "without a watcher a pattern shows its first step")

        object = json(["system"])
        XCTAssertTrue(object["override"] is NSNull)
        XCTAssertEqual(home.ledFile, "system")

        usageError(["purple"])
        usageError(["working"])  // a preset, not a state or pattern
        usageError(["green:300,off:300"])  // literals need `set`
        usageError(["heartbeat", "extra"])
    }

    func testShorthandKnowsConfiguredPatternsAndRealCommandsWin() throws {
        try writeConfig(#"{"patterns":{"triple":"green:100,off:100","status":"amber:100,off:100"}}"#)
        XCTAssertEqual(json(["triple"])["led"] as? String, "triple")
        let status = json(["status"])
        XCTAssertNotNil(status["claims"], "status is still the command")
        XCTAssertEqual(json(["set", "status"])["led"] as? String, "status", "and set reaches the pattern")
    }

    func testSetWithAPattern() {
        var object = json(["set", "green:300,off:300", "--for", "1m"])
        XCTAssertEqual(object["led"] as? String, "green:300,off:300")
        XCTAssertEqual((object["override"] as? [String: Any])?["show"] as? String, "green:300,off:300")
        XCTAssertEqual(home.ledFile, "green")
        object = json(["status"])
        XCTAssertEqual((object["led"] as? [String: Any])?["desired"] as? String, "green:300,off:300")
        XCTAssertEqual(runCLI(["set", "sos"], environment: env).stdout, "sos (until: chargelight set system)\n")

        let preset = runCLI(["set", "working"], environment: env)
        XCTAssertEqual(preset.code, 2)
        XCTAssertTrue(preset.stderr.contains("preset"), preset.stderr)
        usageError(["set", "green:20,off:300"])
    }

    // MARK: - flash and morse

    func testFlash() throws {
        var object = json(["flash"])
        var flash = object["flash"] as? [String: Any]
        XCTAssertEqual(flash?["show"] as? String, "amber:150,off:150")
        XCTAssertEqual(flash?["times"] as? Int, 3)
        XCTAssertEqual(flash?["duration"] as? Double, 0.9)
        XCTAssertTrue((flash?["id"] as? String)?.hasPrefix("flash:\(getpid())-") == true)
        XCTAssertEqual(home.ledFile, "amber")
        let claim = try XCTUnwrap(claims.first)
        XCTAssertEqual(claim["priority"] as? Int, Configuration.noticePriority)
        XCTAssertEqual(claim["show"] as? String, "amber:150,off:150")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertNotNil(formatter.date(from: claim["expiresAt"] as? String ?? ""))

        flash = json(["flash", "green", "--times", "5"])["flash"] as? [String: Any]
        XCTAssertEqual(flash?["show"] as? String, "green:150,off:150")
        XCTAssertEqual(flash?["duration"] as? Double, 1.5)

        flash = json(["flash", "green:100,off:100", "--times", "2"])["flash"] as? [String: Any]
        XCTAssertEqual(flash?["show"] as? String, "green:100,off:100")
        XCTAssertEqual(flash?["duration"] as? Double, 0.4)

        flash = json(["flash", "heartbeat", "--times", "1"])["flash"] as? [String: Any]
        XCTAssertEqual(flash?["show"] as? String, Pattern.builtIn["heartbeat"]?.literal)
        XCTAssertEqual(flash?["duration"] as? Double, 1.2)

        object = json(["flash", "--times=1", "-q"])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(runCLI(["flash", "green"], environment: env).stdout, "flash green:150,off:150 3 time(s) (0.9 s)\n")

        for bad in [["flash", "blink-fast"], ["flash", "off"], ["flash", "system"], ["flash", "working"],
                    ["flash", "--times", "0"], ["flash", "--times", "101"], ["flash", "--times", "x"],
                    ["flash", "amber", "green"]] {
            usageError(bad)
        }
    }

    func testFlashWaitsAndGoesBack() throws {
        _ = json(["claim", "base", "green"])
        let start = Date()
        let object = json(["flash", "--times", "1", "--wait"])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual((object["flash"] as? [String: Any])?["duration"] as? Double, 0.3)
        XCTAssertGreaterThanOrEqual(elapsed, 0.28)
        XCTAssertLessThan(elapsed, 1.5)
        XCTAssertEqual(claims.compactMap { $0["id"] as? String }, ["base"], "the flash is over")
        // With no watcher, the next change re-applies what the claims call for.
        _ = json(["release", "nothing"])
        XCTAssertEqual(home.ledFile, "green")
    }

    func testFlashUnderAnOverrideWarns() {
        _ = json(["set", "off"])
        let run = runCLI(["flash"], environment: env)
        XCTAssertEqual(run.code, 0)
        XCTAssertTrue(run.stderr.contains("override"), run.stderr)
        XCTAssertEqual(home.ledFile, "off")
    }

    func testMorse() throws {
        var object = json(["morse", "sos"])
        var morse = object["morse"] as? [String: Any]
        let expected = try Pattern.morse("sos")
        XCTAssertEqual(morse?["text"] as? String, "sos")
        XCTAssertEqual(morse?["pattern"] as? String, expected.literal)
        XCTAssertEqual(morse?["duration"] as? Double ?? 0, expected.duration, accuracy: 0.001)
        let claim = try XCTUnwrap(claims.first)
        XCTAssertEqual(claim["priority"] as? Int, 100)
        XCTAssertTrue((claim["id"] as? String)?.hasPrefix("morse:") == true)
        XCTAssertEqual(claim["label"] as? String, "morse: sos")

        object = json(["morse", "hi", "there", "--color", "green", "--unit", "100"])
        morse = object["morse"] as? [String: Any]
        XCTAssertEqual(morse?["text"] as? String, "hi there")
        XCTAssertEqual(morse?["pattern"] as? String, try Pattern.morse("hi there", lit: .green, unit: 0.1).literal)
        XCTAssertEqual(home.ledFile, "green")
        XCTAssertEqual(json(["morse", "e", "--unit", "50ms"])["ok"] as? Bool, true)

        for bad in [["morse"], ["morse", "!!"], ["morse", "hi", "--unit", "20"], ["morse", "hi", "--unit", "1001"],
                    ["morse", "hi", "--color", "red"], ["morse", "hi", "--unit", "fast"]] {
            usageError(bad)
        }
    }

    // MARK: - Discovery

    func testList() throws {
        try writeConfig(#"{"patterns":{"triple":"green:100,off:100"},"presets":{"deploy":{"led":"triple","priority":25}}}"#)
        let object = json(["list"])
        XCTAssertEqual(object["states"] as? [String], LEDState.allCases.map(\.rawValue))
        XCTAssertEqual(object["idle"] as? String, "system")
        let presets = object["presets"] as? [String: [String: Any]]
        XCTAssertEqual(Set(presets?.keys.map { $0 } ?? []), ["attention", "working", "ready", "deploy"])
        XCTAssertEqual(presets?["working"]?["led"] as? String, "amber")
        XCTAssertEqual(presets?["working"]?["priority"] as? Int, 20)
        XCTAssertEqual(presets?["working"]?["ttl"] as? Int, 1800)
        XCTAssertEqual(presets?["deploy"]?["led"] as? String, "triple")
        let patterns = object["patterns"] as? [String: String]
        XCTAssertEqual(patterns?["heartbeat"], "amber:120,off:120,amber:120,off:840")
        XCTAssertEqual(patterns?["triple"], "green:100,off:100")
        XCTAssertEqual(patterns?.count, Pattern.builtIn.count + 1)

        let human = runCLI(["list"], environment: env).stdout
        for heading in ["States (idle: system)", "Presets", "Patterns"] {
            XCTAssertTrue(human.contains(heading), human)
        }
        XCTAssertTrue(human.contains("deploy     triple"), human)
    }

    func testHelpHasTheNewFraming() {
        let help = runCLI(["help"], environment: env).stdout
        XCTAssertTrue(help.hasPrefix("chargelight \(ChargeLight.version) - program the LED on your MagSafe charger"), help)
        for text in ["Try it", "chargelight run -- sleep 5", "chargelight morse hi", "\nLED\n", "\nShared light", "\nIntegrations\n",
                     "\nSetup\n", "heartbeat", "attention (blink-fast, 30)", "Exit codes", "CHARGELIGHT_NO_WATCHER"] {
            XCTAssertTrue(help.contains(text), text)
        }
        for command in CLI.commands {
            XCTAssertTrue(help.contains(command.name), command.name)
        }
    }

    // MARK: - Claims

    func testClaimWithPriority() throws {
        _ = json(["claim", "agent", "attention"])
        var object = json(["claim", "deploy", "heartbeat", "--priority", "50", "--label", "prod"])
        XCTAssertEqual(object["led"] as? String, "heartbeat")
        let claim = object["claim"] as? [String: Any]
        XCTAssertEqual(claim?["show"] as? String, "heartbeat")
        XCTAssertEqual(claim?["led"] as? String, "heartbeat")
        XCTAssertEqual(claim?["priority"] as? Int, 50)
        XCTAssertEqual(Set(claim?.keys.map { $0 } ?? []),
                       ["id", "show", "led", "priority", "label", "updatedAt", "expiresAt", "stamp"])

        object = json(["claim", "chore", "amber", "--priority=-5"])
        XCTAssertEqual(object["led"] as? String, "heartbeat")
        XCTAssertEqual((object["claim"] as? [String: Any])?["priority"] as? Int, -5)

        let human = runCLI(["claim", "low", "ready"], environment: env)
        XCTAssertTrue(human.stdout.hasSuffix("; deploy wins with priority 50\n"), human.stdout)

        usageError(["claim", "x", "amber", "--priority", "high"])
        usageError(["claim", "x", "amber", "--priority", "1.5"])
        usageError(["claim", "x", "amber", "--priority", "99999999"])
    }

    func testStatusWithPatternsOverrideAndAStaleClaim() throws {
        try writeConfig(#"{"patterns":{"triple":"green:100,off:100"}}"#)
        _ = json(["claim", "build", "triple", "--priority", "40", "--label", "ci"])
        _ = json(["claim", "agent", "working"])
        _ = json(["set", "sos", "--for", "10m"])
        var object = json(["status"])
        XCTAssertEqual((object["led"] as? [String: Any])?["desired"] as? String, "sos")
        XCTAssertEqual((object["override"] as? [String: Any])?["show"] as? String, "sos")
        var list = object["claims"] as? [[String: Any]] ?? []
        XCTAssertEqual(list.compactMap { $0["id"] as? String }, ["build", "agent"])
        XCTAssertEqual(list.first?["led"] as? String, "triple")

        let human = runCLI(["status"], environment: env).stdout
        let rows = human.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        XCTAssertTrue(rows.contains(["SHOW", "LED", "PRI", "EXPIRES", "LABEL", "ID"]), human)
        XCTAssertTrue(rows.contains { $0.first == "triple" && $0.count == 6 && $0[1] == "triple" && $0[2] == "40" && $0[5] == "build" }, human)
        XCTAssertTrue(rows.contains { $0.first == "working" && $0[1] == "amber" && $0[2] == "20" }, human)
        XCTAssertTrue(human.contains("override sos (for 10m)"), human)

        // The pattern is removed from the configuration: the claim is shown but passed over.
        try writeConfig("{}")
        _ = json(["set", "system"])
        object = json(["status"])
        list = object["claims"] as? [[String: Any]] ?? []
        XCTAssertTrue(list.first?["led"] is NSNull)
        XCTAssertEqual((object["led"] as? [String: Any])?["desired"] as? String, "amber")
        XCTAssertEqual(home.ledFile, "amber")
        XCTAssertTrue(runCLI(["status"], environment: env).stdout.contains("? (unknown)"))
    }

    // MARK: - watch

    func testWatchCountOneJSON() {
        _ = json(["claim", "a", "working", "--label", "x"])
        let run = runCLI(["watch", "--count", "1", "--json"], environment: env)
        XCTAssertEqual(run.code, 0)
        let object = run.json
        XCTAssertEqual(Set(object.keys), ["time", "led", "claims", "override"])
        XCTAssertEqual(object["led"] as? String, "amber")
        XCTAssertEqual((object["claims"] as? [[String: Any]])?.first?["id"] as? String, "a")
        XCTAssertTrue(object["override"] is NSNull)

        let human = runCLI(["watch", "--count", "1"], environment: env).stdout
        XCTAssertTrue(human.range(of: #"^\d\d:\d\d:\d\d  amber  a \(working\)\n$"#, options: .regularExpression) != nil, human)
        usageError(["watch", "--count", "0"])
    }

    func testWatchPrintsChangesNotRenewals() {
        let harness = CLIHarness(environment: env)
        harness.cli.watchInterval = 0.02
        let done = expectation(description: "watch")
        DispatchQueue.global().async {
            XCTAssertEqual(harness.run(["watch", "--count", "3"]), 0)
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.15)
        _ = json(["claim", "a", "working"])
        Thread.sleep(forTimeInterval: 0.15)
        _ = json(["claim", "a", "working"])  // a renewal: no line
        Thread.sleep(forTimeInterval: 0.15)
        _ = json(["set", "off"])
        wait(for: [done], timeout: 5)
        let lines = harness.stdout.split(separator: "\n").map { $0.dropFirst(10) }
        XCTAssertEqual(lines, ["system  idle", "amber  a (working)", "off  override"])
    }

    // MARK: - pipe

    func testPipe() {
        let lines = ["amber", "", "  nope  ", "green:200,off:200", "release", "-", "ready"]
        var seen: [String?] = []
        var index = 0
        let harness = CLIHarness(environment: env, readLine: { [self] in
            seen.append(home.ledFile)
            defer { index += 1 }
            return index < lines.count ? lines[index] : nil
        })
        XCTAssertEqual(harness.run(["pipe", "--json", "--id", "feed", "--priority", "7"]), 0)
        // The LED as each line was read: changes happen line by line, not at the end.
        XCTAssertEqual(seen, [nil, "amber", "amber", "amber", "green", "system", "system", "green"])
        XCTAssertEqual(home.ledFile, "system", "end of input releases")
        XCTAssertTrue(claims.isEmpty)

        let output = harness.stdout.split(separator: "\n").map {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] ?? [:]
        }
        XCTAssertEqual(output.count, 6, harness.stdout)
        XCTAssertEqual(output.map { $0["ok"] as? Bool }, [true, false, true, true, true, true])
        XCTAssertEqual(output[0]["led"] as? String, "amber")
        XCTAssertEqual((output[1]["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        XCTAssertEqual(output[2]["led"] as? String, "green:200,off:200")
        XCTAssertEqual(output[3]["led"] as? String, "system")
        XCTAssertEqual(harness.stderr, "")
    }

    func testPipeClaimsWithItsIdAndPriority() {
        var snapshot: [[String: Any]] = []
        var lines = ["working"]
        let harness = CLIHarness(environment: env, readLine: { [self] in
            if lines.isEmpty {
                snapshot = claims
                return nil
            }
            return lines.removeFirst()
        })
        XCTAssertEqual(harness.run(["pipe", "--id", "feed", "--priority", "7", "--label", "logs"]), 0)
        XCTAssertEqual(snapshot.first?["id"] as? String, "feed")
        XCTAssertEqual(snapshot.first?["priority"] as? Int, 7)
        XCTAssertEqual(snapshot.first?["label"] as? String, "logs")
        XCTAssertEqual(snapshot.first?["show"] as? String, "working")
        XCTAssertEqual(harness.stdout, "", "human mode prints nothing on success")
    }

    func testPipeHumanErrorsAndDefaultID() {
        let run = runCLI(["pipe"], environment: env, stdin: "amber\nbogus\n")
        XCTAssertEqual(run.code, 0)
        XCTAssertEqual(run.stdout, "")
        XCTAssertTrue(run.stderr.hasPrefix("chargelight: pipe: line 2: unknown LED state or pattern \"bogus\""), run.stderr)
        XCTAssertEqual(home.ledFile, "system")
        usageError(["pipe", "--priority", "x"])
        usageError(["pipe", "extra"])
    }

    func testPipeRenewsItsClaim() throws {
        var expiries: [Date] = []
        var lines = ["amber"]
        let harness = CLIHarness(environment: env, readLine: { [self] in
            if lines.isEmpty {
                for _ in 0..<3 {
                    Thread.sleep(forTimeInterval: 0.3)
                    if let light = try? StatusLight(environment: env), let claim = light.snapshot().claims.first {
                        expiries.append(claim.expiresAt)
                    }
                }
                return nil
            }
            return lines.removeFirst()
        })
        harness.cli.renewInterval = 0.2
        XCTAssertEqual(harness.run(["pipe"]), 0)
        XCTAssertEqual(expiries.count, 3)
        XCTAssertGreaterThan(expiries[2], expiries[0], "renewed while waiting for input")
        XCTAssertEqual(expiries[0].timeIntervalSinceNow, 60, accuracy: 2)
    }

    // MARK: - run

    func testRunFailureLeavesTheFailClaim() throws {
        let run = runCLI(["run", "--", "/bin/sh", "-c", "exit 3"], environment: env)
        XCTAssertEqual(run.code, 3)
        XCTAssertEqual(run.stdout + run.stderr, "")
        let claim = try XCTUnwrap(claims.first)
        XCTAssertEqual(claim["id"] as? String, "run:\(getpid())")
        XCTAssertEqual(claim["show"] as? String, "attention")
        XCTAssertEqual(claim["label"] as? String, "sh")
        let expires = ISO8601DateFormatter().date(from: claim["expiresAt"] as? String ?? "")
        XCTAssertEqual(expires?.timeIntervalSinceNow ?? 0, 60, accuracy: 2)
        XCTAssertEqual(home.ledFile, "blink-fast")
    }

    func testRunSuccess() throws {
        XCTAssertEqual(runCLI(["run", "--", "true"], environment: env).code, 0)
        let claim = try XCTUnwrap(claims.first)
        XCTAssertEqual(claim["show"] as? String, "ready")
        XCTAssertEqual(claim["label"] as? String, "true")
        let expires = ISO8601DateFormatter().date(from: claim["expiresAt"] as? String ?? "")
        XCTAssertEqual(expires?.timeIntervalSinceNow ?? 0, 10, accuracy: 2)
        XCTAssertEqual(home.ledFile, "green")

        XCTAssertEqual(runCLI(["run", "--id", "job", "--keep", "5m", "--ok", "heartbeat-green", "true"], environment: env).code, 0)
        let job = claims.first { $0["id"] as? String == "job" }
        XCTAssertEqual(job?["show"] as? String, "heartbeat-green")
    }

    func testRunKeepZeroLeavesNoClaim() {
        XCTAssertEqual(runCLI(["run", "--keep", "0", "--", "true"], environment: env).code, 0)
        XCTAssertTrue(claims.isEmpty)
        XCTAssertEqual(home.ledFile, "system")
        XCTAssertEqual(runCLI(["run", "--keep", "0s", "--", "false"], environment: env).code, 1)
        XCTAssertTrue(claims.isEmpty)
    }

    func testRunMissingCommand() {
        let run = runCLI(["run", "--", "no-such-command-chargelight"], environment: env)
        XCTAssertEqual(run.code, 127)
        XCTAssertTrue(run.stderr.contains("no-such-command-chargelight: command not found"), run.stderr)
        XCTAssertEqual(run.stdout, "")
        XCTAssertTrue(claims.isEmpty)

        let path = runCLI(["run", "--", home.url.appendingPathComponent("missing").path], environment: env)
        XCTAssertEqual(path.code, 127)
        XCTAssertTrue(claims.isEmpty, "the claim made before the start failed is released")
    }

    func testRunPassesOptionsThroughAndShowsWorking() throws {
        let out = home.url.appendingPathComponent("out").path
        let script = #"printf '%s|' "$@" > "$0"; cat "$CHARGELIGHT_HOME/led" >> "$0""#
        let run = runCLI(
            ["run", "--working", "blink-slow", "--label", "custom", "--", "/bin/sh", "-c", script, out,
             "--json", "-q", "--ttl", "5", "--", "x"],
            environment: envWithPath)
        XCTAssertEqual(run.code, 0)
        XCTAssertEqual(run.stdout, "", "chargelight prints nothing of its own")
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "--json|-q|--ttl|5|--|x|blink-slow\n")
        XCTAssertEqual(claims.first?["label"] as? String, "custom")
    }

    func testRunValidatesBeforeStarting() {
        let marker = home.url.appendingPathComponent("started").path
        for option in ["--working", "--ok", "--fail"] {
            let run = runCLI(["run", option, "purple", "--", "/usr/bin/touch", marker], environment: env)
            XCTAssertEqual(run.code, 2)
            XCTAssertTrue(run.stderr.contains(option), run.stderr)
        }
        usageError(["run", "--keep", "soon", "--", "/usr/bin/touch", marker])
        usageError(["run"])
        usageError(["run", "--"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testRunReportsDeathBySignal() {
        XCTAssertEqual(runCLI(["run", "--", "/bin/sh", "-c", "kill -TERM $$"], environment: env).code, 143)
        XCTAssertEqual(claims.first?["show"] as? String, "attention")
    }

    func testRunForwardsSIGTERM() {
        let start = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { kill(getpid(), SIGTERM) }
        let run = runCLI(["run", "--keep", "0", "--", "/bin/sleep", "10"], environment: env)
        XCTAssertEqual(run.code, 143, "sleep was killed by the forwarded SIGTERM")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertTrue(claims.isEmpty)
    }

    func testRunRenewsWhileTheCommandRuns() throws {
        let harness = CLIHarness(environment: envWithPath)
        harness.cli.renewInterval = 0.2
        let out = home.url.appendingPathComponent("counts").path
        let script = #"for i in 1 2 3; do sleep 0.3; ls "$CHARGELIGHT_HOME/claims" | wc -l >> "$0"; done"#
        XCTAssertEqual(harness.run(["run", "--keep", "0", "--", "/bin/sh", "-c", script, out]), 0)
        // The claim file was rewritten by renewals; it exists throughout.
        let counts = try String(contentsOfFile: out, encoding: .utf8).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(counts.count, 3)
        XCTAssertFalse(counts.contains("0"), "\(counts)")
        XCTAssertTrue(claims.isEmpty)
    }

    // MARK: - completions

    func testCompletionScripts() throws {
        for shell in ["zsh", "bash", "fish"] {
            let run = runCLI(["completions", shell], environment: env)
            XCTAssertEqual(run.code, 0, shell)
            let script = run.stdout
            for word in ["claim", "flash", "morse", "pipe", "run", "watch", "heartbeat", "blink-fast", "attention",
                         "--priority", "--keep"].map({ $0.hasPrefix("--") && shell == "fish" ? String($0.dropFirst(2)) : $0 }) {
                XCTAssertTrue(script.contains(word), "\(shell) completion lacks \(word)")
            }
            let file = home.url.appendingPathComponent("completion.\(shell)")
            try script.write(to: file, atomically: true, encoding: .utf8)
            let checker = shell == "fish" ? ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
                .first { FileManager.default.isExecutableFile(atPath: $0) } : "/bin/\(shell)"
            guard let checker else { continue }
            let result = try shellRun(checker, ["-n", file.path])
            XCTAssertEqual(result.status, 0, "\(shell) -n: \(result.output)")
        }
        XCTAssertEqual(json(["completions", "bash"])["shell"] as? String, "bash")
        usageError(["completions", "powershell"])
        usageError(["completions"])
    }

    func testBashCompletionWorks() throws {
        let file = home.url.appendingPathComponent("completion.bash")
        try runCLI(["completions", "bash"], environment: env).stdout.write(to: file, atomically: true, encoding: .utf8)
        func complete(_ words: [String]) throws -> [String] {
            let quoted = words.map { "'\($0)'" }.joined(separator: " ")
            let script = "source '\(file.path)'; COMP_WORDS=(\(quoted)); COMP_CWORD=\(words.count - 1); _chargelight; "
                + #"printf '%s\n' "${COMPREPLY[@]}""#
            return try shellRun("/bin/bash", ["-c", script]).output.split(separator: "\n").map(String.init)
        }
        XCTAssertEqual(try complete(["chargelight", "fl"]), ["flash"])
        XCTAssertEqual(try complete(["chargelight", "heart"]), ["heartbeat", "heartbeat-green"])
        XCTAssertEqual(try complete(["chargelight", "claim", "id", "wor"]), ["working"])
        XCTAssertEqual(try complete(["chargelight", "claim", "wor"]), [], "the first claim argument is an id")
        XCTAssertEqual(try complete(["chargelight", "run", "--ke"]), ["--keep"])
        XCTAssertEqual(try complete(["chargelight", "run", "--fail", "blink-f"]), ["blink-fast"])
        XCTAssertEqual(try complete(["chargelight", "morse", "--color", ""]), ["amber", "green"])
        XCTAssertEqual(try complete(["chargelight", "completions", "z"]), ["zsh"])
        XCTAssertTrue(try complete(["chargelight", "run", "--", "chargelight-no-such-prefix"]).isEmpty)
    }

    private func shellRun(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - doctor

    func testHelperVersionCheck() throws {
        XCTAssertEqual(ChargeLight.helperVersion, "0.1.0")
        XCTAssertNotEqual(ChargeLight.helperVersion, ChargeLight.version, "0.2 must not ask for setup again")
        XCTAssertTrue(CLI.helperVersionCheck(reported: ChargeLight.helperVersion).ok)
        for reported in [ChargeLight.version, "0.0.9", nil] {
            let check = CLI.helperVersionCheck(reported: reported)
            XCTAssertFalse(check.ok)
            XCTAssertTrue(check.detail.contains("fix: sudo chargelight setup"), check.detail)
        }

        // Through `doctor`, with a stand-in helper that reports a version.
        let helper = home.url.appendingPathComponent("fake-helper")
        for (version, ok) in [(ChargeLight.helperVersion, true), (ChargeLight.version, false)] {
            try "#!/bin/sh\necho \(version)\n".write(to: helper, atomically: true, encoding: .utf8)
            chmod(helper.path, 0o755)
            var env = self.env
            env["CHARGELIGHT_HELPER"] = helper.path
            let checks = runCLI(["doctor", "--json"], environment: env).json["checks"] as? [[String: Any]] ?? []
            let check = checks.first { $0["name"] as? String == "helper-version" }
            XCTAssertEqual(check?["ok"] as? Bool, ok, "\(version): \(String(describing: check))")
        }
    }
}
