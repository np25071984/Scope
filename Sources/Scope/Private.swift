// The undocumented calls scope depends on, kept in one file so that a macOS
// update that breaks one of them breaks it here.
//
// SkyLight is looked up at run time rather than linked, so a symbol that
// disappears degrades to the public fallback instead of a launch failure.

import ApplicationServices
import Foundation

// Maps an Accessibility window to its window-server id, which is what ties the
// AX world (titles, subroles, focusing) to the CGWindowList one (Spaces,
// z-order). Exported by HIServices; AltTab uses it too.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum SkyLight {
    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ names: [String], as type: T.Type) -> T? {
        for name in names {
            if let handle, let p = dlsym(handle, name) { return unsafeBitCast(p, to: type) }
            if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {  // RTLD_DEFAULT
                return unsafeBitCast(p, to: type)
            }
        }
        return nil
    }

    private typealias SetFrontProcess = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecord = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    // Deprecated since 10.9 and so hidden from Swift, but still exported, and
    // still the only way to get the serial number the calls below take.
    private typealias ProcessForPID = @convention(c) (
        pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64

    private static let setFrontProcess = symbol(
        ["_SLPSSetFrontProcessWithOptions"], as: SetFrontProcess.self)
    private static let postEventRecord = symbol(
        ["SLPSPostEventRecordTo"], as: PostEventRecord.self)
    private static let processForPID = symbol(["GetProcessForPID"], as: ProcessForPID.self)
    private static let mainConnection = symbol(
        ["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConnection.self)
    private static let activeSpaceID = symbol(
        ["SLSGetActiveSpace", "CGSGetActiveSpace"], as: ActiveSpace.self)

    static var canFocusSingleWindow: Bool {
        setFrontProcess != nil && postEventRecord != nil && processForPID != nil
    }

    /// The Space on screen on the display that has focus, or nil if the call is gone.
    static func activeSpace() -> UInt64? {
        guard let mainConnection, let activeSpaceID else { return nil }
        let id = activeSpaceID(mainConnection())
        return id == 0 ? nil : id
    }

    /// Brings one window of `pid` forward and makes it key, leaving the app's
    /// other windows where they are. Returns false when the private calls are
    /// unavailable or refuse, so the caller can fall back to activating the app.
    static func focus(pid: pid_t, window: CGWindowID) -> Bool {
        guard let setFrontProcess, let postEventRecord, let processForPID else { return false }
        var psn = ProcessSerialNumber()
        guard processForPID(pid, &psn) == noErr else { return false }

        // kCPSUserGenerated: treat it as the user's own choice, so the app is
        // allowed to take focus.
        guard setFrontProcess(&psn, window, 0x200) == .success else { return false }

        // A synthesized "make key window" event record, the same bytes AltTab
        // posts: without it the process comes forward but key
        // focus can stay on whichever of its windows had it before.
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var wid = window
        withUnsafeBytes(of: &wid) { raw in
            for i in 0..<4 { bytes[0x3c + i] = raw[i] }
        }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = postEventRecord(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEventRecord(&psn, &bytes)
        return true
    }
}
