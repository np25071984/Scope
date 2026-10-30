import Foundation
import os

// Tracing goes to the unified log. Off by default; switch it on from the menu,
// then watch it with:
//   log stream --predicate 'subsystem == "io.github.np25071984.scope"'
enum Log {
    private static let logger = Logger(subsystem: "io.github.np25071984.scope", category: "scope")

    // Read on several threads, written from the menu; a stale read costs one
    // line of trace either way.
    nonisolated(unsafe) static var tracing = false

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
