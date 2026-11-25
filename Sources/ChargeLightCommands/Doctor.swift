import ChargeLight
import Foundation
import IOKit.ps

/// One `chargelight doctor` check.
struct DoctorCheck {
    var name: String
    var ok: Bool
    var detail: String
    /// Informational checks are reported but do not affect the overall result.
    var required = true

    var json: JSON {
        var fields: [String: JSON] = ["name": .string(name), "ok": .bool(ok), "detail": .string(detail)]
        if !required { fields["required"] = .bool(false) }
        return .object(fields)
    }
}

extension CLI {
    func doctorCommand() -> CommandOutput {
        let checks = doctorChecks()
        let ok = checks.allSatisfy { $0.ok || !$0.required }
        let lines = checks.map { check -> String in
            let mark = check.ok ? "ok  " : (check.required ? "FAIL" : "note")
            return "\(mark)  \(check.name.padding(toLength: 19, withPad: " ", startingAt: 0))\(check.detail)"
        }
        return CommandOutput(
            fields: ["checks": .array(checks.map(\.json))],
            text: lines.joined(separator: "\n") + "\n" + (ok ? "all checks passed" : "some checks failed"),
            ok: ok)
    }

    func doctorChecks() -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        let arm64 = sysctlInt("hw.optional.arm64") == 1
        checks.append(DoctorCheck(
            name: "apple-silicon", ok: arm64,
            detail: arm64 ? "arm64" : "not an Apple Silicon Mac; the MagSafe LED key is only known on Apple Silicon"))

        do {
            let reading = try SMCBackend().read()
            checks.append(DoctorCheck(
                name: "magsafe-led", ok: true,
                detail: "AppleSMC key ACLC readable (raw 0x\(String(format: "%02x", reading.raw)), \(reading.state?.rawValue ?? "unknown"))"))
        } catch {
            checks.append(DoctorCheck(
                name: "magsafe-led", ok: false,
                detail: "\(ChargeLightError.wrap(error).message); a MacBook with a MagSafe 3 port is required"))
        }

        let source = powerSource()
        checks.append(DoctorCheck(
            name: "power-adapter", ok: source == kIOPSACPowerValue,
            detail: source == kIOPSACPowerValue
                ? "on AC power" : "on \(source ?? "unknown power source"); the LED only lights with a MagSafe charger plugged in",
            required: false))

        let helper = ChargeLight.helperPath(environment: environment)
        var st = stat()
        let exists = stat(helper, &st) == 0
        let safe = exists && st.st_uid == 0 && (st.st_mode & 0o022) == 0
        let installedDetail: String
        if !exists {
            installedDetail = "\(helper) not found; fix: sudo chargelight setup"
        } else if !safe {
            installedDetail = "\(helper) must be owned by root and not group/world-writable"
                + " (owner uid \(st.st_uid), mode \(String(st.st_mode & 0o7777, radix: 8))); fix: sudo chargelight setup"
        } else {
            installedDetail = "\(helper) (root-owned, mode \(String(st.st_mode & 0o7777, radix: 8)))"
        }
        checks.append(DoctorCheck(name: "helper-installed", ok: safe, detail: installedDetail))

        if exists {
            let output = try? runProcess(helper, ["--version"])
            checks.append(CLI.helperVersionCheck(reported: output.flatMap { $0.status == 0 ? $0.stdout : nil }))
        } else {
            checks.append(DoctorCheck(name: "helper-version", ok: false, detail: "skipped: helper not installed; fix: sudo chargelight setup"))
        }

        if safe {
            let output = try? runProcess("/usr/bin/sudo", ["-n", helper, "--version"])
            let ok = output?.status == 0
            checks.append(DoctorCheck(
                name: "passwordless-sudo", ok: ok,
                detail: ok
                    ? "sudo -n \(helper) works"
                    : "sudo -n refused (\(output?.stderr ?? "could not run sudo")); fix: sudo chargelight setup"))
        } else {
            checks.append(DoctorCheck(
                name: "passwordless-sudo", ok: false, detail: "skipped: helper not installed safely; fix: sudo chargelight setup"))
        }
        return checks
    }

    /// Compares what the installed helper reports with the helper version
    /// this build expects (``ChargeLight/helperVersion``, not the CLI version:
    /// the helper changes rarely, and only a change to it needs `setup` again).
    static func helperVersionCheck(reported version: String?) -> DoctorCheck {
        let expected = ChargeLight.helperVersion
        return DoctorCheck(
            name: "helper-version", ok: version == expected,
            detail: version == expected
                ? expected
                : "helper reports \(version ?? "nothing"), this chargelight needs \(expected); fix: sudo chargelight setup")
    }

    private func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    /// "AC Power", "Battery Power" or "UPS Power", from IOKit power sources.
    private func powerSource() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return nil }
        return type as String
    }

    /// Runs a short-lived process and captures trimmed output. Standard input is `/dev/null`.
    private func runProcess(_ path: String, _ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let trim = { (pipe: Pipe) in
            String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (process.terminationStatus, trim(out), trim(err))
    }
}
