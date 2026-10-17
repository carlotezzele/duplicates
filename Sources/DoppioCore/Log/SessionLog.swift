import Darwin
import Foundation

/// One line of a session log. Fields that don't apply to an event are omitted.
public struct LogEntry: Codable, Sendable, Hashable {
    public enum Event: String, Codable, Sendable {
        case sessionStart = "session_start"
        /// Written (and fsync'ed) right before a file is moved to the Trash.
        case intent
        case trashed
        /// A safety check failed; the file was not touched.
        case skipped
        /// The move to the Trash was attempted and failed; the file was not touched.
        case failed
        case restored
        case sessionEnd = "session_end"
    }

    public var event: Event
    public var time: String
    // session_start
    public var tool: String?
    public var version: String?
    public var command: String?
    public var roots: [String]?
    public var sourceLog: String?
    // file events
    public var group: String?
    public var original: String?
    public var trash: String?
    public var kept: String?
    public var size: Int64?
    public var sha256: String?
    public var device: Int32?
    public var inode: UInt64?
    public var reason: String?
    // session_end
    public var trashedCount: Int?
    public var restoredCount: Int?
    public var skippedCount: Int?
    public var failedCount: Int?
    public var bytes: Int64?
    public var cancelled: Bool?

    public init(_ event: Event, at date: Date = Date()) {
        self.event = event
        time = iso(date)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

public enum LogError: Error, Sendable, CustomStringConvertible {
    case cannotCreate(String, String)
    case cannotWrite(String, String)

    public var description: String {
        switch self {
        case let .cannotCreate(path, reason): "Cannot create the log \(path): \(reason). Nothing was changed."
        case let .cannotWrite(path, reason): "Cannot write to the log \(path): \(reason). Stopped so that nothing happens unlogged."
        }
    }
}

/// Append-only JSON Lines log of one `clean` or `restore` session, plus a human-readable
/// summary written when the session ends. Each line is fsync'ed before the action it
/// announces, so the log survives a crash.
public final class SessionLog: @unchecked Sendable {
    public struct Paths: Sendable, Hashable {
        public let jsonl: URL
        public let summary: URL
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Doppio", isDirectory: true)
    }

    public let paths: Paths
    private let fd: Int32
    private let lock = NSLock()

    /// Creates a new log named `doppio-<kind>-<timestamp>.jsonl`; never reuses an existing file.
    init(kind: String, directory: URL, date: Date = Date()) throws(LogError) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .cannotCreate(directory.path, error.localizedDescription)
        }
        let stem = "doppio-\(kind)-\(fileTimestamp(date))"
        for attempt in 1...100 {
            let name = attempt == 1 ? stem : "\(stem)-\(attempt)"
            let jsonl = directory.appendingPathComponent(name + ".jsonl")
            let fd = Darwin.open(jsonl.path, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw .cannotCreate(jsonl.path, String(cString: strerror(errno)))
            }
            self.fd = fd
            paths = Paths(jsonl: jsonl, summary: directory.appendingPathComponent(name + ".txt"))
            return
        }
        throw .cannotCreate(directory.appendingPathComponent(stem).path, "too many logs with the same name")
    }

    deinit { Darwin.close(fd) }

    func append(_ entry: LogEntry) throws(LogError) {
        let data: Data
        do { data = try LogEntry.encoder.encode(entry) + Data("\n".utf8) } catch {
            throw .cannotWrite(paths.jsonl.path, error.localizedDescription)
        }
        lock.lock()
        defer { lock.unlock() }
        let failure: Int32? = data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += n
            }
            return fsync(fd) == 0 ? nil : errno
        }
        if let failure { throw .cannotWrite(paths.jsonl.path, String(cString: strerror(failure))) }
    }

    func writeSummary(_ text: String) throws(LogError) {
        do {
            try Data(text.utf8).write(to: paths.summary, options: .withoutOverwriting)
        } catch {
            throw .cannotWrite(paths.summary.path, error.localizedDescription)
        }
    }

    /// Reads every entry of a log. A malformed last line (a crash mid-write) is reported via
    /// `incompleteLastLine`; a malformed line anywhere else makes the whole log unusable.
    public static func read(_ url: URL) throws -> (entries: [LogEntry], incompleteLastLine: Bool) {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            throw RestoreError.unreadableLog(url.path, error.localizedDescription)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var entries: [LogEntry] = []
        for (index, line) in lines.enumerated() {
            do {
                entries.append(try LogEntry.decoder.decode(LogEntry.self, from: Data(line.utf8)))
            } catch {
                if index == lines.count - 1 && !text.hasSuffix("\n") { return (entries, true) }
                throw RestoreError.malformedLog(url.path, line: index + 1)
            }
        }
        return (entries, false)
    }
}
