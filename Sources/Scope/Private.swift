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

    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let copyDisplaySpaces = symbol(
        ["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"], as: CopyDisplaySpaces.self)
    private static let copySpacesForWindows = symbol(
        ["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"], as: CopySpacesForWindows.self)

    /// The Space type of an ordinary desktop; full-screen apps have their own.
    private static let desktopType = 0
    /// Every Space a window belongs to: current, other and user Spaces.
    private static let allSpaces: Int32 = 0x7

    /// The desktops of the display showing `space`, in order, as "Desktop N"
    /// counts them [F39]. Empty if the call is gone.
    static func desktops(withSpace space: UInt64) -> [UInt64] {
        guard let mainConnection, let copyDisplaySpaces,
              let displays = copyDisplaySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        for display in displays {
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            guard spaces.contains(where: { ($0["id64"] as? UInt64) == space }) else { continue }
            return spaces.compactMap { s in
                (s["type"] as? Int) == desktopType ? s["id64"] as? UInt64 : nil
            }
        }
        return []
    }

    /// The Spaces each window is on now. A window that is gone is on none [F39].
    static func spaces(of windows: [CGWindowID]) -> [CGWindowID: [UInt64]] {
        guard let mainConnection, let copySpacesForWindows else { return [:] }
        let connection = mainConnection()
        var out: [CGWindowID: [UInt64]] = [:]
        for id in windows {
            let list = [NSNumber(value: id)] as CFArray
            out[id] = copySpacesForWindows(connection, allSpaces, list)?.takeRetainedValue() as? [UInt64] ?? []
        }
        return out
    }

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

/// Windows on other Spaces, which an app's Accessibility window list leaves
/// out [F40].
enum RemoteAX {
    private typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let createWithRemoteToken: CreateWithRemoteToken? = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken"
    ).map { unsafeBitCast($0, to: CreateWithRemoteToken.self) }

    /// The token's tag, "coco", that marks it as naming a Cocoa element.
    private static let tokenTag: Int32 = 0x636f636f
    /// How many element ids to try. An app's windows have come out well under
    /// a hundred; the margin is for an app that has made many elements.
    static let maxElementID: UInt64 = 2000

    /// The window element for `window` of `pid`, wherever the window is.
    /// Several elements map to one window id, and only the one whose role is
    /// window can be raised or made main [F40]. Nil if the call is gone, the
    /// app does not answer, or no element matches.
    static func window(pid: pid_t, id window: CGWindowID) -> AXUIElement? {
        guard let createWithRemoteToken else { return nil }
        for elementID in 0..<maxElementID {
            var token = Data(count: 20)
            token.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
                raw.storeBytes(of: 0, toByteOffset: 4, as: Int32.self)
                raw.storeBytes(of: tokenTag, toByteOffset: 8, as: Int32.self)
                raw.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self)
            }
            guard let element = createWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            var id: CGWindowID = 0
            switch _AXUIElementGetWindow(element, &id) {
            case .success:
                guard id == window else { continue }
                if AX.attribute(element, kAXRoleAttribute, as: String.self) == kAXWindowRole { return element }
            case .cannotComplete:
                // The app is not answering; asking two thousand times will not help.
                return nil
            default:
                continue
            }
        }
        return nil
    }
}
