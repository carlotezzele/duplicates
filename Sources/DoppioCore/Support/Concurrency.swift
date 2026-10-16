import Dispatch
import Foundation

/// A thread-safe cancellation flag that blocking file I/O checks between chunks.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }

    func check() throws(FileAccessError) {
        if isCancelled { throw .cancelled }
    }
}

/// Runs blocking file I/O off the Swift concurrency cooperative pool,
/// with a configurable amount of parallelism.
enum Blocking {
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    /// Maps `items` with at most `jobs` concurrent blocking calls. Results keep input order.
    static func map<T: Sendable, R: Sendable>(
        _ items: [T],
        jobs: Int,
        _ body: @escaping @Sendable (T) -> R
    ) async throws -> [R] {
        if items.isEmpty { return [] }
        let width = max(1, min(jobs, items.count))
        var results = [R?](repeating: nil, count: items.count)
        try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var next = 0
            while next < width {
                let index = next
                group.addTask { (index, try await run { body(items[index]) }) }
                next += 1
            }
            while let (index, result) = try await group.next() {
                results[index] = result
                try Task.checkCancellation()
                if next < items.count {
                    let index = next
                    group.addTask { (index, try await run { body(items[index]) }) }
                    next += 1
                }
            }
        }
        return results.map { $0! }
    }
}

/// Collects progress from many threads and forwards it, throttled, to a handler.
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (ScanProgress) -> Void
    private var state = ScanProgress(phase: .walking)
    private var lastEmit: UInt64 = 0
    private let interval: UInt64 = 100_000_000 // 0.1 s

    init(handler: @escaping @Sendable (ScanProgress) -> Void) {
        self.handler = handler
    }

    func start(_ phase: ScanPhase, filesTotal: Int = 0, bytesTotal: Int64 = 0) {
        let snapshot = lock.withLock {
            state = ScanProgress(phase: phase, filesTotal: filesTotal, bytesTotal: bytesTotal)
            lastEmit = DispatchTime.now().uptimeNanoseconds
            return state
        }
        handler(snapshot)
    }

    func add(files: Int = 0, bytes: Int64 = 0) {
        let snapshot: ScanProgress? = lock.withLock {
            state.filesDone += files
            state.bytesDone += bytes
            let now = DispatchTime.now().uptimeNanoseconds
            guard now - lastEmit >= interval else { return nil }
            lastEmit = now
            return state
        }
        if let snapshot { handler(snapshot) }
    }

    func finish() {
        let snapshot = lock.withLock { state }
        handler(snapshot)
    }
}
