import Foundation

// Small internal helpers shared by the library: atomic files, advisory locks,
// and running child processes.

enum FileIO {
    /// Writes `data` to `url` atomically: a hidden temporary file in the same
    /// directory, then `rename(2)` over the destination.
    static func writeAtomically(_ data: Data, to url: URL, mode: mode_t = 0o644) throws {
        let directory = url.deletingLastPathComponent()
        try createDirectory(directory)
        let temp = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0 ... .max)).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw ChargeLightError.posix("cannot create", temp.path) }
        var ok = false
        defer {
            if !ok { unlink(temp.path) }
        }
        do {
            try writeAll(fd: fd, data: data, path: temp.path)
            close(fd)
        } catch {
            close(fd)
            throw error
        }
        guard rename(temp.path, url.path) == 0 else {
            throw ChargeLightError.posix("cannot rename to", url.path)
        }
        ok = true
    }

    static func writeAll(fd: Int32, data: Data, path: String) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ChargeLightError.posix("cannot write", path)
                }
                offset += n
            }
        }
    }

    /// Reads a file, returning `nil` if it does not exist.
    static func readIfPresent(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        } catch {
            throw ChargeLightError.io("cannot read \(url.path): \(error.localizedDescription)")
        }
    }

    /// Removes a file; a missing file is not an error. Returns whether it existed.
    @discardableResult
    static func remove(_ url: URL) throws -> Bool {
        if unlink(url.path) == 0 { return true }
        if errno == ENOENT { return false }
        throw ChargeLightError.posix("cannot remove", url.path)
    }

    static func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ChargeLightError.io("cannot create directory \(url.path): \(error.localizedDescription)")
        }
    }

    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}

/// An advisory `flock(2)` lock on a file, released when the value is closed or
/// the process exits.
final class FileLock {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    deinit { unlock() }

    /// Blocks until an exclusive lock on `url` is held, creating the file if needed.
    static func exclusive(_ url: URL) throws -> FileLock {
        try FileIO.createDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ChargeLightError.posix("cannot open lock", url.path) }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let code = errno
            close(fd)
            throw ChargeLightError.posix("cannot lock", url.path, errno: code)
        }
        return FileLock(fd: fd)
    }

    /// Takes an exclusive lock without waiting. Returns `nil` if another
    /// process holds it. Creates the file only if `create` is true.
    static func tryExclusive(_ url: URL, create: Bool) throws -> FileLock? {
        if create { try FileIO.createDirectory(url.deletingLastPathComponent()) }
        let fd = open(url.path, (create ? O_RDWR | O_CREAT : O_RDONLY) | O_CLOEXEC, 0o644)
        if fd < 0 {
            if !create && errno == ENOENT { return nil }
            throw ChargeLightError.posix("cannot open lock", url.path)
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return FileLock(fd: fd)
    }

    /// Releases the lock. Safe to call more than once.
    func unlock() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}

/// The result of running a child process to completion.
struct ProcessOutput {
    var status: Int32
    var stdout: String
    var stderr: String
}

enum Subprocess {
    /// Runs `path` with `arguments`, capturing its output. Standard input is `/dev/null`.
    static func run(_ path: String, _ arguments: [String]) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ChargeLightError.io("cannot run \(path): \(error.localizedDescription)")
        }
        // Drain stderr on another thread so a chatty child cannot fill one
        // pipe while we block reading the other.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return ProcessOutput(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self))
    }

    /// Written by one thread, read by another only after `DispatchGroup.wait()`.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}

/// Shared date coding for files chargelight stores (ISO 8601 with fractional seconds).
enum StoredJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter().string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = formatter().date(from: text) ?? ISO8601DateFormatter().date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "invalid ISO 8601 date: \(text)")
        }
        return decoder
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
