import Foundation

/// Installs and removes the privileged helper and its sudoers rule.
///
/// `install` must run as root. It copies the helper next to the running
/// executable to ``helperDestination`` and adds a sudoers rule that lets any
/// local user run it without a password. Both files are written to a temporary
/// name first and moved into place with `rename(2)`, so neither is ever seen
/// half-written; the sudoers rule is validated with `visudo -cf` before it
/// goes live.
///
/// All paths are injectable so the logic can be tested against temporary
/// directories with ``setOwnership`` turned off.
public struct Installer {
    /// The sudoers rule installed by ``install(helperSource:)``.
    public static let sudoersRule = """
        # Installed by `chargelight setup`. Lets local users change the MagSafe LED
        # (cosmetic only) without a password. Remove with: sudo chargelight uninstall
        ALL ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/chargelight-helper

        """

    /// Where the helper is installed.
    public var helperDestination: URL
    /// The live sudoers file.
    public var sudoersFile: URL
    /// The sudoers rule text. Defaults to ``sudoersRule``.
    public var sudoersContent: String
    /// `visudo`, used to validate the rule; `nil` skips validation.
    public var visudoPath: String?
    /// Whether to `chown 0:0` the installed files. Turn off in tests.
    public var setOwnership: Bool

    /// What an install did.
    public struct Report: Equatable, Sendable {
        /// The helper that was copied.
        public var helperSource: URL
        /// Where it was installed.
        public var helperDestination: URL
        /// The sudoers file written.
        public var sudoersFile: URL
        /// The output of `<helper> --version`, if it ran.
        public var helperVersion: String?
    }

    /// Creates an installer. The defaults are the real system locations.
    public init(
        helperDestination: URL = URL(fileURLWithPath: SMCBackend.defaultHelperPath),
        sudoersFile: URL = URL(fileURLWithPath: "/private/etc/sudoers.d/chargelight"),
        sudoersContent: String = Installer.sudoersRule,
        visudoPath: String? = "/usr/sbin/visudo",
        setOwnership: Bool = true
    ) {
        self.helperDestination = helperDestination
        self.sudoersFile = sudoersFile
        self.sudoersContent = sudoersContent
        self.visudoPath = visudoPath
        self.setOwnership = setOwnership
    }

    /// Temporary name for the sudoers rule. It contains a dot, so sudo's
    /// `#includedir` ignores it while it is being written and validated.
    public var sudoersTempFile: URL {
        sudoersFile.deletingLastPathComponent().appendingPathComponent(".\(sudoersFile.lastPathComponent).tmp")
    }

    /// Finds the helper shipped with the executable at `executablePath`, after
    /// resolving symlinks (Homebrew links `bin/chargelight` into the Cellar):
    /// `<dir>/chargelight-helper`, then `<dir>/../libexec/chargelight-helper`.
    public static func locateHelper(executablePath: String) -> URL? {
        let resolved = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        let directory = resolved.deletingLastPathComponent()
        let candidates = [
            directory.appendingPathComponent("chargelight-helper"),
            directory.deletingLastPathComponent().appendingPathComponent("libexec/chargelight-helper"),
        ]
        return candidates.map(\.standardizedFileURL).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    /// Installs the helper from `helperSource` and the sudoers rule, then
    /// verifies the installed helper runs.
    public func install(helperSource: URL) throws -> Report {
        try installHelper(from: helperSource)
        try installSudoersRule()
        let version = try? Subprocess.run(helperDestination.path, ["--version"])
        return Report(
            helperSource: helperSource, helperDestination: helperDestination, sudoersFile: sudoersFile,
            helperVersion: version.flatMap {
                $0.status == 0 ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            })
    }

    /// Removes the helper and the sudoers rule. Returns the files that existed.
    public func uninstall() throws -> [URL] {
        var removed: [URL] = []
        for url in [sudoersFile, sudoersTempFile, helperDestination] where try FileIO.remove(url) {
            removed.append(url)
        }
        return removed
    }

    /// Copies the helper into place: temp file in the destination directory,
    /// owner 0:0, mode 0755, then an atomic rename.
    func installHelper(from source: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw ChargeLightError.io("cannot read helper \(source.path): \(error.localizedDescription)")
        }
        let directory = helperDestination.deletingLastPathComponent()
        if !FileIO.exists(directory.path) {
            try FileIO.createDirectory(directory)
            if setOwnership { try chown(directory, mode: 0o755) }
        }
        let temp = directory.appendingPathComponent(".\(helperDestination.lastPathComponent).\(getpid()).tmp")
        try writeFile(data, to: temp, mode: 0o755)
        guard rename(temp.path, helperDestination.path) == 0 else {
            let code = errno
            unlink(temp.path)
            throw ChargeLightError.posix("cannot install helper to", helperDestination.path, errno: code)
        }
    }

    /// Writes the sudoers rule to ``sudoersTempFile`` (0:0, 0440), validates
    /// it with `visudo -cf`, and renames it into place. On a validation
    /// failure the temporary file is removed and nothing goes live.
    func installSudoersRule() throws {
        let temp = sudoersTempFile
        try FileIO.createDirectory(temp.deletingLastPathComponent())
        _ = try? FileIO.remove(temp)
        try writeFile(Data(sudoersContent.utf8), to: temp, mode: 0o440)
        if let visudoPath {
            let check: ProcessOutput
            do {
                check = try Subprocess.run(visudoPath, ["-cf", temp.path])
            } catch {
                unlink(temp.path)
                throw error
            }
            guard check.status == 0 else {
                unlink(temp.path)
                let detail = (check.stderr + check.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ChargeLightError.io("sudoers rule failed validation; nothing was changed" + (detail.isEmpty ? "" : ": \(detail)"))
            }
        }
        guard rename(temp.path, sudoersFile.path) == 0 else {
            let code = errno
            unlink(temp.path)
            throw ChargeLightError.posix("cannot install sudoers rule to", sudoersFile.path, errno: code)
        }
    }

    /// Creates `url` exclusively (no symlink following), writes `data`, sets
    /// ownership and mode on the open descriptor, and syncs it to disk.
    private func writeFile(_ data: Data, to url: URL, mode: mode_t) throws {
        unlink(url.path)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChargeLightError.posix("cannot create", url.path) }
        do {
            defer { close(fd) }
            try FileIO.writeAll(fd: fd, data: data, path: url.path)
            if setOwnership && fchown(fd, 0, 0) != 0 { throw ChargeLightError.posix("cannot chown", url.path) }
            if fchmod(fd, mode) != 0 { throw ChargeLightError.posix("cannot chmod", url.path) }
            if fsync(fd) != 0 { throw ChargeLightError.posix("cannot sync", url.path) }
        } catch {
            unlink(url.path)
            throw error
        }
    }

    private func chown(_ url: URL, mode: mode_t) throws {
        if Darwin.chown(url.path, 0, 0) != 0 { throw ChargeLightError.posix("cannot chown", url.path) }
        if Darwin.chmod(url.path, mode) != 0 { throw ChargeLightError.posix("cannot chmod", url.path) }
    }
}
