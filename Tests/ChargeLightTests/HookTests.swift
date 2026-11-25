import ChargeLight
import ChargeLightCommands
import XCTest

final class HookTests: XCTestCase {
    typealias Input = ClaudeCodeHook.Input

    func action(_ event: String, _ configure: (inout Input) -> Void = { _ in }) -> ClaudeCodeHook.Action? {
        var input = Input(hookEventName: event, sessionID: "s")
        configure(&input)
        return ClaudeCodeHook.action(for: input)
    }

    func testMappingTable() {
        XCTAssertEqual(action("SessionStart"), .claim(.ready))
        XCTAssertEqual(action("UserPromptSubmit"), .claim(.working))
        XCTAssertEqual(action("PreToolUse") { $0.toolName = "Bash" }, .claim(.working))
        XCTAssertEqual(action("PreToolUse"), .claim(.working))
        XCTAssertEqual(action("PreToolUse") { $0.toolName = "AskUserQuestion" }, .claim(.attention))
        XCTAssertEqual(action("PreToolUse") { $0.toolName = "ExitPlanMode" }, .claim(.attention))
        XCTAssertEqual(action("SessionStart") { $0.source = "resume" }, .claim(.ready))
        XCTAssertNil(action("SessionStart") { $0.source = "compact" }, "compaction happens mid-turn")
        XCTAssertEqual(action("PostToolUse"), .claim(.working))
        XCTAssertEqual(action("PostToolUseFailure"), .claim(.working))
        XCTAssertEqual(action("PostToolUseFailure") { $0.isInterrupt = false }, .claim(.working))
        XCTAssertEqual(action("PostToolUseFailure") { $0.isInterrupt = true }, .claim(.ready))
        XCTAssertEqual(action("PermissionRequest"), .claim(.attention))
        XCTAssertEqual(action("PermissionDenied"), .claim(.working))
        XCTAssertEqual(action("Elicitation"), .claim(.attention))
        XCTAssertEqual(action("ElicitationResult"), .claim(.working))
        for type in ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"] {
            XCTAssertEqual(action("Notification") { $0.notificationType = type }, .claim(.attention), type)
        }
        XCTAssertEqual(action("Notification") { $0.notificationType = "idle_prompt" }, .claim(.ready))
        XCTAssertNil(action("Notification") { $0.notificationType = "auth_success" })
        XCTAssertNil(action("Notification"))
        XCTAssertEqual(action("PreCompact"), .claim(.working))
        XCTAssertEqual(action("PostCompact") { $0.trigger = "manual" }, .claim(.ready))
        XCTAssertEqual(action("PostCompact") { $0.trigger = "auto" }, .claim(.working))
        XCTAssertEqual(action("PostCompact"), .claim(.working))
        XCTAssertEqual(action("Stop"), .claim(.ready))
        XCTAssertEqual(action("StopFailure"), .claim(.attention))
        XCTAssertEqual(action("SessionEnd"), .release)
        for event in ["SubagentStart", "SubagentStop", "TaskCreated", "", "stop"] {
            XCTAssertNil(action(event), event)
        }
        XCTAssertNil(ClaudeCodeHook.action(for: Input()))
    }

    func testDecodingIsLenient() {
        let json = #"{"hook_event_name":"PostToolUseFailure","session_id":"abc","cwd":"/tmp/proj","is_interrupt":"yes","tool_name":7,"extra":{"x":1}}"#
        let input = Input.decode(Data(json.utf8))
        XCTAssertEqual(input?.hookEventName, "PostToolUseFailure")
        XCTAssertEqual(input?.sessionID, "abc")
        XCTAssertNil(input?.isInterrupt)
        XCTAssertNil(input?.toolName)
        XCTAssertNil(Input.decode(Data("[1,2]".utf8)))
        XCTAssertNil(Input.decode(Data("garbage".utf8)))
    }

    func testActionArgumentAndIdentity() {
        XCTAssertEqual(ClaudeCodeHook.Action(argument: "release"), .release)
        XCTAssertEqual(ClaudeCodeHook.Action(argument: "attention"), .claim(.attention))
        XCTAssertNil(ClaudeCodeHook.Action(argument: "idle"))
        XCTAssertEqual(ClaudeCodeHook.claimID(sessionID: "abc"), "claude:abc")
        XCTAssertEqual(ClaudeCodeHook.label(cwd: "/Users/me/src/proj/"), "proj")
        XCTAssertNil(ClaudeCodeHook.label(cwd: "/"))
        XCTAssertNil(ClaudeCodeHook.label(cwd: nil))
    }

    // MARK: - `chargelight hook`

    func testHookClaimsAndReleases() {
        let home = TempHome()
        let env = home.environment
        var run = runCLI(["hook"], environment: env, stdin: #"{"hook_event_name":"UserPromptSubmit","session_id":"abc","cwd":"/tmp/proj"}"#)
        XCTAssertEqual(run.code, 0)
        XCTAssertEqual(run.stdout + run.stderr, "")
        XCTAssertEqual(home.ledFile, "amber")

        let status = runCLI(["status", "--json"], environment: env).json
        let claims = status["claims"] as? [[String: Any]]
        XCTAssertEqual(claims?.first?["id"] as? String, "claude:abc")
        XCTAssertEqual(claims?.first?["label"] as? String, "proj")

        run = runCLI(["hook"], environment: env, stdin: #"{"hook_event_name":"PermissionRequest","session_id":"abc"}"#)
        XCTAssertEqual(home.ledFile, "blink-fast")
        run = runCLI(["hook", "--as", "ready"], environment: env, stdin: #"{"hook_event_name":"Whatever","session_id":"abc"}"#)
        XCTAssertEqual(home.ledFile, "green")
        run = runCLI(["hook"], environment: env, stdin: #"{"hook_event_name":"SessionEnd","session_id":"abc"}"#)
        XCTAssertEqual(run.code, 0)
        XCTAssertEqual(run.stdout + run.stderr, "")
        XCTAssertEqual(home.ledFile, "system")
    }

    func testLateHookAfterSessionEndDoesNotReviveTheClaim() {
        let home = TempHome()
        let env = home.environment
        _ = runCLI(["hook"], environment: env, stdin: #"{"hook_event_name":"UserPromptSubmit","session_id":"s"}"#, stamp: 100)
        _ = runCLI(["hook"], environment: env, stdin: #"{"hook_event_name":"SessionEnd","session_id":"s"}"#, stamp: 300)
        // The asynchronous Stop hook started before SessionEnd but finished after it.
        let run = runCLI(["hook"], environment: env, stdin: #"{"hook_event_name":"Stop","session_id":"s"}"#, stamp: 200)
        XCTAssertEqual(run.code, 0)
        XCTAssertEqual(run.stdout + run.stderr, "")
        XCTAssertEqual(home.ledFile, "system")
        XCTAssertEqual((runCLI(["status", "--json"], environment: env).json["claims"] as? [Any])?.count, 0)

        let stale = runCLI(["claim", "claude:s", "ready", "--json"], environment: env, stamp: 250).json
        XCTAssertEqual(stale["accepted"] as? Bool, false)
        XCTAssertTrue(stale["claim"] is NSNull)
    }

    func testHookOrderingUsesProcessStamp() {
        let home = TempHome()
        let env = home.environment
        _ = runCLI(["hook"], environment: env, stdin: #"{"hook_event_name":"Stop","session_id":"s"}"#, stamp: 200)
        // An older hook process that finishes late must not override.
        _ = runCLI(["hook"], environment: env, stdin: #"{"hook_event_name":"PostToolUse","session_id":"s"}"#, stamp: 100)
        XCTAssertEqual(home.ledFile, "green")
    }

    func testHookIsSilentAndSucceedsOnGarbage() {
        let home = TempHome()
        let inputs = [
            "", "garbage", "[]", "{}", "null", #"{"hook_event_name":"Stop"}"#,
            #"{"hook_event_name":"Stop","session_id":""}"#, #"{"hook_event_name":42,"session_id":"x"}"#,
            String(repeating: "{", count: 10000),
        ]
        for input in inputs {
            let run = runCLI(["hook"], environment: home.environment, stdin: input)
            XCTAssertEqual(run.code, 0, input)
            XCTAssertEqual(run.stdout + run.stderr, "", input)
        }
        for args in [["hook", "--as", "bogus"], ["hook", "--json", "--frobnicate"], ["hook", "--as"], ["--json", "hook", "extra"]] {
            let run = runCLI(args, environment: home.environment, stdin: #"{"hook_event_name":"Stop","session_id":"x"}"#)
            XCTAssertEqual(run.code, 0, "\(args)")
            XCTAssertEqual(run.stdout + run.stderr, "", "\(args)")
        }
    }

    func testHookIsSilentWhenSetupIsMissingOrConfigBroken() throws {
        try XCTSkipIf(geteuid() == 0, "as root the SMC backend would write the real LED")
        let home = TempHome()
        var env = home.environment
        env["CHARGELIGHT_BACKEND"] = nil  // real SMC backend, helper path does not exist
        let stop = #"{"hook_event_name":"Stop","session_id":"abc","cwd":"/tmp/proj"}"#
        var run = runCLI(["hook"], environment: env, stdin: stop)
        XCTAssertEqual(run.code, 0)
        XCTAssertEqual(run.stdout + run.stderr, "")

        env["CHARGELIGHT_BACKEND"] = "file"
        env["CHARGELIGHT_LED_WORKING"] = "nope"
        run = runCLI(["hook"], environment: env, stdin: stop)
        XCTAssertEqual(run.code, 0)
        XCTAssertEqual(run.stdout + run.stderr, "")
    }

    func testHookDebugLog() throws {
        let home = TempHome()
        var env = home.environment
        _ = runCLI(["hook"], environment: env, stdin: "garbage")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.hookLogFile.path))
        env["CHARGELIGHT_DEBUG"] = "1"
        _ = runCLI(["hook"], environment: env, stdin: "garbage")
        let log = try String(contentsOf: home.paths.hookLogFile, encoding: .utf8)
        XCTAssertTrue(log.contains("invalid_argument"), log)
    }
}
