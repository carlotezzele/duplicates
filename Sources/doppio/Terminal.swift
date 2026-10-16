import ArgumentParser
import Darwin
import DoppioCore
import Foundation

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) { FileHandle.standardError.write(Data(string.utf8)) }
}

/// A single self-overwriting progress line on stderr (only when stderr is a terminal).
final class ProgressLine: @unchecked Sendable {
    private let lock = NSLock()
    private let enabled = isatty(STDERR_FILENO) == 1
    private var lastLength = 0

    func update(_ p: ScanProgress) {
        guard enabled else { return }
        var text = p.phase.rawValue
        if p.phase == .walking {
            text += ": \(p.filesDone) files"
        } else if p.bytesTotal > 0 {
            let pct = Int((p.fraction ?? 0) * 100)
            text += ": \(pct)%  \(formatBytes(p.bytesDone)) of \(formatBytes(p.bytesTotal))"
            if p.filesTotal > 0 { text += "  (\(p.filesDone)/\(p.filesTotal))" }
        } else if p.filesTotal > 0 {
            text += ": \(p.filesDone)/\(p.filesTotal)"
        }
        lock.withLock {
            let pad = String(repeating: " ", count: max(0, lastLength - text.count))
            FileHandle.standardError.write(Data("\r\(text)\(pad)".utf8))
            lastLength = text.count
        }
    }

    func clear() {
        guard enabled else { return }
        lock.withLock {
            FileHandle.standardError.write(Data(("\r" + String(repeating: " ", count: lastLength) + "\r").utf8))
            lastLength = 0
        }
    }
}

/// Runs `body`, cancelling it cleanly on Ctrl-C instead of killing the process mid-read.
func runCancellableOnSIGINT<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
    signal(SIGINT, SIG_IGN)
    let task = Task { try await body() }
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        FileHandle.standardError.write(Data("\nCancelling…\n".utf8))
        task.cancel()
    }
    source.resume()
    defer {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
    do {
        return try await task.value
    } catch is CancellationError {
        FileHandle.standardError.write(Data("Cancelled. Nothing was changed.\n".utf8))
        throw ExitCode(130)
    }
}
