import ChargeLight
@testable import ChargeLightCommands
import XCTest

final class CLITests: XCTestCase {
    var home: TempHome!
    var env: [String: String] { home.environment }

    override func setUp() { home = TempHome() }
    override func tearDown() { home = nil }

    func json(_ args: [String], code: Int32 = 0, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let run = runCLI(args + ["--json"], environment: env)
        XCTAssertEqual(run.code, code, "\(args): \(run.stdout)", file: file, line: line)
        XCTAssertEqual(run.stderr, "", file: file, line: line)
        return run.json
    }

    func assertError(_ args: [String], code: String, exit: Int32, file: StaticString = #filePath, line: UInt = #line) {
        let object = json(args, code: exit, file: file, line: line)
        XCTAssertEqual(object["ok"] as? Bool, false, file: file, line: line)
        let error = object["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, code, file: file, line: line)
        XCTAssertFalse((error?["message"] as? String ?? "").isEmpty, file: file, line: line)
    }

    // MARK: - Durations

    func testParseDuration() {
        XCTAssertEqual(parseDuration("90"), 90)
        XCTAssertEqual(parseDuration("90s"), 90)
        XCTAssertEqual(parseDuration("10m"), 600)
        XCTAssertEqual(parseDuration("2h"), 7200)
        XCTAssertEqual(parseDuration("1.5h"), 5400)
        XCTAssertEqual(parseDuration(" 3S "), 3)
        for bad in ["", "s", "0", "0s", "-5", "+5", "5d", "1e3", "nan", "inf", "1.2.3", "m10", "10 m"] {
            XCTAssertNil(parseDuration(bad), bad)
        }
        XCTAssertEqual(formatDuration(45), "45s")
        XCTAssertEqual(formatDuration(600), "10m")
        XCTAssertEqual(formatDuration(3900), "1h05m")
        XCTAssertEqual(formatDuration(7200), "2h")
    }

    // MARK: - Argument parsing

    func testGlobalFlagsAnywhere() throws {
        let inv = try Invocation.parse(["claim", "--json", "id", "-q", "working", "--ttl=5m", "--label", "--json"])
        XCTAssertEqual(inv.command, "claim")
        XCTAssertEqual(inv.positionals, ["id", "working"])
        XCTAssertTrue(inv.json)
        XCTAssertTrue(inv.quiet)
        XCTAssertEqual(inv.options, ["--ttl": "5m", "--label": "--json"])
        XCTAssertEqual(try Invocation.parse(["release", "--", "--weird-id"]).positionals, ["--weird-id"])
        XCTAssertThrowsError(try Invocation.parse(["get", "--bogus"]))
        XCTAssertThrowsError(try Invocation.parse(["claim", "a", "working", "--ttl"]))
    }

    // MARK: - Commands

    func testGetAndSet() {
        var object = json(["get"])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["led"] as? String, "system")
        XCTAssertEqual(object["raw"] as? Int, 0)

        object = json(["set", "amber"])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["led"] as? String, "amber")
        XCTAssertEqual((object["override"] as? [String: Any])?["led"] as? String, "amber")
        XCTAssertTrue((object["override"] as? [String: Any])?["expiresAt"] is NSNull)
        XCTAssertEqual(home.ledFile, "amber")
        object = json(["get"])
        XCTAssertEqual(object as NSDictionary, ["ok": true, "led": "amber", "raw": 4])

        let human = runCLI(["set", "blink-slow"], environment: env)
        XCTAssertEqual(human.code, 0)
        XCTAssertEqual(human.stdout, "blink-slow (until: chargelight set system)\n")
        XCTAssertEqual(runCLI(["get"], environment: env).stdout, "blink-slow\n")
        XCTAssertEqual(runCLI(["set", "off", "-q"], environment: env).stdout, "")

        // `set system` ends the override and hands the LED back.
        object = json(["set", "system"])
        XCTAssertEqual(object as NSDictionary, ["ok": true, "led": "system", "override": NSNull()])
        XCTAssertEqual(home.ledFile, "system")
        XCTAssertTrue(json(["status"])["override"] is NSNull)
    }

    func testSetForADuration() {
        let object = json(["set", "blink-fast", "--for", "10m"])
        XCTAssertEqual(object["led"] as? String, "blink-fast")
        XCTAssertNotNil((object["override"] as? [String: Any])?["expiresAt"] as? String)
        XCTAssertEqual((json(["status"])["override"] as? [String: Any])?["led"] as? String, "blink-fast")
        XCTAssertEqual(runCLI(["set", "amber", "--for", "5m"], environment: env).stdout, "amber for 5m\n")
        XCTAssertEqual(runCLI(["set", "amber", "--for", "soon"], environment: env).code, 2)
        XCTAssertEqual(runCLI(["set", "system", "--for", "5m"], environment: env).code, 2)
        XCTAssertEqual(runCLI(["get", "--for", "5m"], environment: env).code, 2)
    }

    func testSetOverridesClaimsAndWarns() {
        _ = json(["claim", "a", "working"])
        let run = runCLI(["set", "green"], environment: env)
        XCTAssertEqual(run.code, 0)
        XCTAssertTrue(run.stderr.contains("warning"), run.stderr)
        XCTAssertEqual(home.ledFile, "green")
        XCTAssertEqual(runCLI(["set", "green", "--json"], environment: env).stderr, "", "no warnings in JSON mode")

        // The claim is still there and takes over again once the override ends.
        _ = json(["claim", "a", "attention"])
        XCTAssertEqual(home.ledFile, "green")
        XCTAssertEqual(json(["set", "system"])["led"] as? String, "blink-fast")
        XCTAssertEqual(home.ledFile, "blink-fast")

        // reset clears claims and override alike.
        _ = json(["set", "off"])
        XCTAssertEqual(json(["reset"])["led"] as? String, "system")
        XCTAssertEqual(home.ledFile, "system")
        XCTAssertTrue(json(["status"])["override"] is NSNull)
    }

    func testClaimReleaseReset() {
        var object = json(["claim", "claude:1", "working", "--ttl", "10m", "--label", "proj"])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["led"] as? String, "amber")
        XCTAssertEqual(object["accepted"] as? Bool, true)
        let claim = object["claim"] as? [String: Any]
        XCTAssertEqual(claim?["id"] as? String, "claude:1")
        XCTAssertEqual(claim?["status"] as? String, "working")
        XCTAssertEqual(claim?["label"] as? String, "proj")
        XCTAssertEqual(claim?["led"] as? String, "amber")
        XCTAssertNotNil(claim?["stamp"] as? NSNumber)
        let formatter = ISO8601DateFormatter()
        let updated = formatter.date(from: claim?["updatedAt"] as? String ?? "")
        let expires = formatter.date(from: claim?["expiresAt"] as? String ?? "")
        XCTAssertNotNil(updated)
        XCTAssertEqual(expires.map { $0.timeIntervalSince(updated!) } ?? 0, 600, accuracy: 1)
        XCTAssertTrue((claim?["expiresAt"] as? String)?.hasSuffix("Z") == true)
        XCTAssertEqual(home.ledFile, "amber")

        object = json(["claim", "claude:2", "attention"])
        XCTAssertEqual(object["led"] as? String, "blink-fast")
        XCTAssertTrue((object["claim"] as? [String: Any])?["label"] is NSNull)

        object = json(["release", "claude:2"])
        XCTAssertEqual(object as NSDictionary, ["ok": true, "released": true, "led": "amber"])
        object = json(["release", "claude:2"])
        XCTAssertEqual(object as NSDictionary, ["ok": true, "released": false, "led": "amber"])

        _ = json(["claim", "claude:3", "ready"])
        object = json(["reset"])
        XCTAssertEqual(object as NSDictionary, ["ok": true, "released": 2, "led": "system"])
        XCTAssertEqual(home.ledFile, "system")
    }

    func testClaimHumanOutput() {
        let run = runCLI(["claim", "x", "ready", "--ttl", "90"], environment: env)
        XCTAssertEqual(run.code, 0)
        XCTAssertTrue(run.stdout.hasPrefix("green (x ready, expires in "), run.stdout)
    }

    func testStatus() {
        _ = json(["claim", "claude:a", "working", "--label", "one"])
        _ = json(["claim", "claude:b", "attention", "--label", "two"])
        let object = json(["status"])
        XCTAssertEqual(object["ok"] as? Bool, true)
        let led = object["led"] as? [String: Any]
        XCTAssertEqual(led?["desired"] as? String, "blink-fast")
        XCTAssertEqual(led?["actual"] as? String, "blink-fast")
        XCTAssertEqual(led?["raw"] as? Int, 7)
        let claims = object["claims"] as? [[String: Any]]
        XCTAssertEqual(claims?.compactMap { $0["id"] as? String }, ["claude:b", "claude:a"])
        XCTAssertEqual((object["watcher"] as? [String: Any])?["running"] as? Bool, false)
        let helper = object["helper"] as? [String: Any]
        XCTAssertEqual(helper?["installed"] as? Bool, false)
        XCTAssertEqual(helper?["path"] as? String, env["CHARGELIGHT_HELPER"])
        XCTAssertEqual(object["backend"] as? String, "file")

        let human = runCLI(["status"], environment: env)
        XCTAssertEqual(human.code, 0)
        XCTAssertTrue(human.stdout.contains("claude:b"), human.stdout)
        XCTAssertTrue(human.stdout.contains("attention"), human.stdout)
    }

    func testStatusWithUnreadableLED() {
        try? FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
        try? "nonsense".write(to: home.paths.ledFile, atomically: true, encoding: .utf8)
        let object = json(["status"])
        let led = object["led"] as? [String: Any]
        XCTAssertTrue(led?["actual"] is NSNull)
        XCTAssertNotNil(led?["error"])
    }

    func testDoctorShapeAndExitCode() {
        let run = runCLI(["doctor", "--json"], environment: env)
        XCTAssertEqual(run.code, 1, "the helper is not installed")
        let object = run.json
        XCTAssertEqual(object["ok"] as? Bool, false)
        let checks = object["checks"] as? [[String: Any]] ?? []
        let names = checks.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["apple-silicon", "magsafe-led", "power-adapter", "helper-installed", "helper-version", "passwordless-sudo"])
        for check in checks {
            XCTAssertNotNil(check["ok"] as? Bool)
            XCTAssertNotNil(check["detail"] as? String)
            if check["ok"] as? Bool == false && check["required"] == nil {
                XCTAssertTrue((check["detail"] as? String ?? "").contains("fix:") || check["name"] as? String == "apple-silicon"
                    || check["name"] as? String == "magsafe-led")
            }
        }
        let helper = checks.first { $0["name"] as? String == "helper-installed" }
        XCTAssertEqual(helper?["ok"] as? Bool, false)
        XCTAssertTrue((helper?["detail"] as? String ?? "").contains("sudo chargelight setup"))

        let quiet = runCLI(["doctor", "-q"], environment: env)
        XCTAssertEqual(quiet.code, 1)
        XCTAssertEqual(quiet.stdout + quiet.stderr, "")
    }

    func testSetupAndUninstallNeedRoot() throws {
        try XCTSkipIf(geteuid() == 0, "running as root")
        var object = json(["setup"], code: 5)
        XCTAssertEqual(object as NSDictionary, [
            "ok": false, "error": ["code": "not_privileged", "message": "run: sudo chargelight setup"],
        ])
        object = json(["uninstall"], code: 5)
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "not_privileged")
        let human = runCLI(["setup"], environment: env)
        XCTAssertEqual(human.code, 5)
        XCTAssertEqual(human.stderr, "chargelight: run: sudo chargelight setup\n")
    }

    func testSetupRequiredWithRealBackend() throws {
        try XCTSkipIf(geteuid() == 0, "as root the SMC backend would write the real LED")
        var env = self.env
        env["CHARGELIGHT_BACKEND"] = nil
        let run = runCLI(["set", "amber", "--json"], environment: env)
        XCTAssertEqual(run.code, 4)
        XCTAssertEqual(run.json as NSDictionary, [
            "ok": false, "error": ["code": "setup_required", "message": "run: sudo chargelight setup"],
        ])
    }

    func testDemo() {
        _ = json(["claim", "a", "working"])
        var out = ""
        let cli = CLI(
            environment: env, stdin: { Data() }, stdout: { out += $0 }, stderr: { _ in },
            stamp: Claim.currentStamp(), executablePath: "/nonexistent")
        cli.demoStep = 0
        XCTAssertEqual(cli.run(["demo", "--json"]), 0)
        let object = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        XCTAssertEqual(object?["shown"] as? [String], ["amber", "blink-slow", "blink-fast", "green", "off"])
        XCTAssertEqual(object?["led"] as? String, "amber")
        XCTAssertEqual(home.ledFile, "amber", "restored to what the claims call for")
    }

    func testVersionAndHelp() {
        XCTAssertEqual(json(["version"]) as NSDictionary, ["ok": true, "version": ChargeLight.version])
        XCTAssertEqual(json([], code: 0).isEmpty, false)
        XCTAssertEqual(runCLI(["--version"], environment: env).stdout, "chargelight \(ChargeLight.version)\n")
        for args in [["help"], ["--help"], ["-h"], ["claim", "--help"], []] {
            let run = runCLI(args, environment: env)
            XCTAssertEqual(run.code, 0, "\(args)")
            XCTAssertTrue(run.stdout.contains("Exit codes"), "\(args)")
            XCTAssertTrue(run.stdout.contains("CHARGELIGHT_BACKEND"), "\(args)")
        }
    }

    func testUsageErrors() {
        assertError(["frobnicate"], code: "invalid_argument", exit: 2)
        assertError(["set"], code: "invalid_argument", exit: 2)
        assertError(["set", "purple"], code: "invalid_argument", exit: 2)
        assertError(["claim", "a"], code: "invalid_argument", exit: 2)
        assertError(["claim", "a", "sleeping"], code: "invalid_argument", exit: 2)
        assertError(["claim", "a", "working", "--ttl", "soon"], code: "invalid_argument", exit: 2)
        assertError(["release"], code: "invalid_argument", exit: 2)
        assertError(["get", "extra"], code: "invalid_argument", exit: 2)
        assertError(["get", "--ttl", "5"], code: "invalid_argument", exit: 2)
        assertError(["get", "--nope"], code: "invalid_argument", exit: 2)

        let human = runCLI(["frobnicate"], environment: env)
        XCTAssertEqual(human.code, 2)
        XCTAssertEqual(human.stdout, "")
        XCTAssertTrue(human.stderr.hasPrefix("chargelight: unknown command"), human.stderr)
    }

    func testInvalidConfigurationIsAUsageError() {
        var env = self.env
        env["CHARGELIGHT_LED_IDLE"] = "disco"
        let run = runCLI(["status", "--json"], environment: env)
        XCTAssertEqual(run.code, 2)
        let error = run.json["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "invalid_argument")
        XCTAssertTrue((error?["message"] as? String ?? "").contains("CHARGELIGHT_LED_IDLE"))
    }

    func testIOErrorIsExitOne() {
        // The state directory is a file: nothing can be stored.
        let file = home.url.appendingPathComponent("not-a-dir")
        try? Data().write(to: file)
        var env = self.env
        env["CHARGELIGHT_HOME"] = file.path
        let run = runCLI(["claim", "a", "working", "--json"], environment: env)
        XCTAssertEqual(run.code, 1)
        XCTAssertEqual((run.json["error"] as? [String: Any])?["code"] as? String, "io_error")
    }

    func testJSONKeysAreSorted() {
        _ = json(["claim", "a", "working"])
        let run = runCLI(["status", "--json"], environment: env)
        let text = run.stdout
        let backend = text.range(of: "\"backend\"")!.lowerBound
        let claims = text.range(of: "\"claims\"")!.lowerBound
        let ok = text.range(of: "\"ok\"")!.lowerBound
        XCTAssertLessThan(backend, claims)
        XCTAssertLessThan(claims, ok)
    }
}
