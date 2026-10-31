import Foundation
import os

let version = "2.2.0"

extension CommandLine {
    /// This binary's absolute path, symlinks resolved: what launchd must run,
    /// and what macOS ties the Accessibility permission to.
    static var executable: String {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return arguments[0] }
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(buffer, &resolved) != nil ? String(cString: resolved) : String(cString: buffer)
    }
}

// Everything goes to the unified log; `scope logs` follows it. Lifecycle
// messages and warnings always, the switcher's decisions only with
// `trace = true` in scope.conf.
enum Log {
    static let subsystem = "io.github.np25071984.scope"
    private static let logger = Logger(subsystem: subsystem, category: "scope")

    // Read on several threads, written on reload; a stale read costs one line
    // of trace either way.
    nonisolated(unsafe) static var tracing = false

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    static func trace(_ message: @autoclosure () -> String) {
        guard tracing else { return }
        let text = message()
        logger.notice("\(text, privacy: .public)")
    }

    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }
}

/// A thread with a run loop of its own, for work that must not wait on the
/// main thread or be waited on by it: the key tap, and Accessibility
/// observers whose apps may be slow to answer.
final class RunLoopThread: Thread {
    private var loop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    init(name: String) {
        super.init()
        self.name = name
        qualityOfService = .userInteractive
    }

    override func main() {
        loop = CFRunLoopGetCurrent()
        // A run loop with no sources returns at once; the port keeps it alive.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while !isCancelled { RunLoop.current.run(mode: .default, before: .distantFuture) }
    }

    var runLoop: CFRunLoop {
        if loop == nil {
            start()
            ready.wait()
        }
        return loop!
    }

    func async(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    func add(_ source: CFRunLoopSource) {
        CFRunLoopAddSource(runLoop, source, .commonModes)
    }

    func remove(_ source: CFRunLoopSource) {
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
    }
}
