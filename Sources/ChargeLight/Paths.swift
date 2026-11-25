import Foundation

/// Where chargelight keeps its state.
///
/// The root is `$CHARGELIGHT_HOME` if set, else
/// `~/Library/Application Support/chargelight`.
public struct Paths: Equatable, Sendable {
    /// The state directory.
    public var root: URL

    /// Uses `root` as the state directory.
    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Resolves the state directory from `CHARGELIGHT_HOME`, falling back to
    /// `~/Library/Application Support/chargelight`.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let home = environment["CHARGELIGHT_HOME"], !home.isEmpty {
            self.init(root: URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true))
        } else {
            let base = FileManager.default.homeDirectoryForCurrentUser
            self.init(root: base.appendingPathComponent("Library/Application Support/chargelight", isDirectory: true))
        }
    }

    /// One JSON file per active claim.
    public var claimsDirectory: URL { root.appendingPathComponent("claims", isDirectory: true) }
    /// Optional user configuration.
    public var configFile: URL { root.appendingPathComponent("config.json") }
    /// The LED state last written by ``StatusLight/sync(now:)``, and when.
    public var appliedFile: URL { root.appendingPathComponent("applied.json") }
    /// Serialises every read-modify-write of the claims.
    public var lockFile: URL { root.appendingPathComponent("lock") }
    /// Held by the running watcher for its whole life.
    public var watcherLockFile: URL { root.appendingPathComponent("watcher.lock") }
    /// The LED state file used by ``FileBackend``.
    public var ledFile: URL { root.appendingPathComponent("led") }
    /// Where `chargelight hook` logs failures when `CHARGELIGHT_DEBUG=1`.
    public var hookLogFile: URL { root.appendingPathComponent("hook.log") }

    /// A manual override set with ``StatusLight/setOverride(_:ttl:now:apply:)``.
    /// It lives in the claims directory so one directory watch sees every change.
    public var overrideFile: URL { claimsDirectory.appendingPathComponent("manual.override") }

    /// The file storing the claim with `id`.
    ///
    /// Claim ids may contain any character (`claude:<uuid>`, paths, very long
    /// strings), so the file name is a sanitised, truncated prefix plus a hash
    /// of the full id. The real id is stored inside the file.
    public func claimFile(for id: String) -> URL {
        claimsDirectory.appendingPathComponent(Paths.claimFileName(for: id))
    }

    /// A short-lived marker left by ``StatusLight/release(id:stamp:now:)`` so a
    /// claim request that started before the release (hooks run concurrently
    /// and can land out of order) does not bring the claim back.
    public func releaseMarker(for id: String) -> URL {
        claimsDirectory.appendingPathComponent(
            String(Paths.claimFileName(for: id).dropLast(".json".count)) + ".released")
    }

    /// File name used for a claim id; see ``claimFile(for:)``.
    public static func claimFileName(for id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var prefix = String(id.prefix(48).map { allowed.contains($0) ? $0 : "_" })
        if prefix.isEmpty { prefix = "_" }
        return "\(prefix)-\(hexHash(id)).json"
    }

    /// 64-bit FNV-1a of the UTF-8 bytes, as 16 hex digits. Stable across runs
    /// and platforms, unlike `Hasher`.
    static func hexHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
