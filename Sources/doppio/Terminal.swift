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
        show(text)
    }

    func update(_ p: CleanProgress) {
        let pct = Int((p.fraction ?? 0) * 100)
        show("Checking and moving to the Trash: \(p.filesDone)/\(p.filesTotal) files  (\(pct)% verified)")
    }

    func show(_ text: String) {
        guard enabled else { return }
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
/// `notice` is printed when Ctrl-C is pressed; bodies that stop gracefully (clean, restore)
/// return their partial result instead of throwing `CancellationError`.
func runCancellableOnSIGINT<T: Sendable>(notice: String = "\nCancelling…\n",
                                         _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    signal(SIGINT, SIG_IGN)
    let task = Task { try await body() }
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        FileHandle.standardError.write(Data(notice.utf8))
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

func printError(_ message: String) {
    var err = StandardError()
    print(message, to: &err)
}

enum Prompt {
    /// Both ends must be a terminal: Doppio never takes "yes" from a pipe or a script.
    static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }

    /// nil on end of input (Ctrl-D).
    static func ask(_ question: String) -> String? {
        print(question, terminator: "")
        fflush(stdout)
        guard let line = readLine() else {
            print()
            return nil
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Anything but "y" / "yes" is a no.
    static func confirm(_ question: String) -> Bool {
        guard let answer = ask(question + " [y/N] ") else { return false }
        return ["y", "yes"].contains(answer.lowercased())
    }
}

/// Shows long text in `less`, or prints it if that isn't possible.
func page(_ text: String) {
    let less = Process()
    less.executableURL = URL(fileURLWithPath: "/usr/bin/less")
    let pipe = Pipe()
    less.standardInput = pipe
    signal(SIGPIPE, SIG_IGN) // quitting less early must not kill Doppio
    do {
        try less.run()
    } catch {
        print(text)
        return
    }
    let writer = pipe.fileHandleForWriting
    DispatchQueue.global().async {
        try? writer.write(contentsOf: Data(text.utf8))
        try? writer.close()
    }
    less.waitUntilExit()
}

/// Launches a helper app (Quick Look, Finder) without waiting for it.
func launch(_ executable: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { print("  Could not run \(executable): \(error.localizedDescription)") }
}

func shortDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}

/// "1 file", "2 files".
func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

/// An ISO 8601 timestamp from a log, shown in local time.
func localTime(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: iso).map(shortDate) ?? iso
}
