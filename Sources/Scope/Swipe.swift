// Switching Spaces with a synthetic trackpad swipe [F46].
//
// The Dock takes a Dock-swipe gesture event for a three-finger swipe, and a
// swipe with an enormous velocity lands on the next Space at once, with no
// slide. Posted while a slide is still running, one in the other direction
// cancels it, as a real swipe back does.
//
// The event layout is adapted from InstantSpaceSwitcher
// (https://github.com/jurplel/InstantSpaceSwitcher), under its MIT license:
//
//   Copyright (c) 2026 jurplel
//
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the
//   "Software"), to deal in the Software without restriction, including
//   without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to permit
//   persons to whom the Software is furnished to do so, subject to the
//   following conditions:
//
//   The above copyright notice and this permission notice shall be included
//   in all copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
//   NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
//   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
//   USE OR OTHER DEALINGS IN THE SOFTWARE.

import CoreGraphics
import Foundation

/// Toward the Space before the current one in Mission Control's order, or after it.
enum SwipeDirection: Equatable {
    case left, right

    var reversed: SwipeDirection { self == .left ? .right : .left }
}

enum Swipe {
    // Undocumented CGEvent fields of a gesture event.
    private static let eventTypeField = CGEventField(rawValue: 55)!
    private static let gestureHIDType = CGEventField(rawValue: 110)!
    private static let swipeMotion = CGEventField(rawValue: 123)!
    private static let swipeProgress = CGEventField(rawValue: 124)!
    private static let swipePositionX = CGEventField(rawValue: 125)!
    private static let swipePositionY = CGEventField(rawValue: 126)!
    private static let swipeVelocityX = CGEventField(rawValue: 129)!
    private static let swipeVelocityY = CGEventField(rawValue: 130)!
    private static let gesturePhase = CGEventField(rawValue: 132)!
    private static let gesturePhaseAlias = CGEventField(rawValue: 134)!
    private static let zoomDeltaY = CGEventField(rawValue: 138)!
    private static let timestampAlias = CGEventField(rawValue: 169)!

    /// The event types: a gesture, and the Dock control event it carries.
    private static let gestureEvent: Int64 = 29
    private static let dockControlEvent: Int64 = 30
    /// IOHID's Dock-swipe event type, which is also its fluid-touch gesture type.
    private static let dockSwipe: Int64 = 23
    private static let horizontal: Int64 = 1

    private enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }

    /// The smallest progress the Dock's 16.16 fixed point can carry: nothing
    /// left to animate. Full progress switches too, but flashes the Space left.
    private static let progress = 0.000016
    /// The fling that commits the switch on macOS 27: near the 16.16 maximum.
    private static let flingVelocity = 9999.0
    /// Before macOS 27 the velocity of each event decides the speed; this one
    /// skips the slide, and a multi-step switch multiplies it.
    private static let legacyVelocity = 2000.0
    /// macOS 27 ignores the plain event and needs the raw IOHID payload added.
    private static let needsPayload = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    /// Posts `steps` swipes. Returns false if an event could not be made.
    static func post(_ direction: SwipeDirection, steps: Int) -> Bool {
        for _ in 0..<steps {
            // Three phases: with only two, Mission Control stops working.
            for phase in [Phase.began, .changed, .ended] {
                guard needsPayload ? postModern(phase, direction)
                                   : postLegacy(phase, direction, velocity: legacyVelocity * Double(steps))
                else { return false }
            }
        }
        return true
    }

    /// On macOS 27 right is negative, and the Dock reads the sign through the
    /// natural scrolling preference, so it flips again with that off.
    private static func sign(_ direction: SwipeDirection) -> Double {
        let sign: Double = direction == .right ? -1 : 1
        return naturalScrolling ? sign : -sign
    }

    private static var naturalScrolling: Bool {
        CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString,
                                  kCFPreferencesAnyApplication) as? Bool ?? true
    }

    /// Which way a real swipe went, from the sign of its fling or progress:
    /// the same rule posting uses [F47].
    static func direction(of value: Double) -> SwipeDirection {
        SpaceJump.direction(of: value, natural: needsPayload ? naturalScrolling : false)
    }

    private static func postLegacy(_ phase: Phase, _ direction: SwipeDirection, velocity: Double) -> Bool {
        guard let event = CGEvent(source: nil) else { return false }
        let sign: Double = direction == .right ? 1 : -1
        event.setIntegerValueField(eventTypeField, value: dockControlEvent)
        event.setIntegerValueField(gestureHIDType, value: dockSwipe)
        event.setIntegerValueField(gesturePhase, value: phase.rawValue)
        event.setDoubleValueField(swipeProgress, value: sign * progress)
        event.setIntegerValueField(swipeMotion, value: horizontal)
        event.setDoubleValueField(swipeVelocityX, value: sign * velocity)
        event.setDoubleValueField(swipeVelocityY, value: sign * velocity)
        event.post(tap: .cgSessionEventTap)
        return true
    }

    private static func postModern(_ phase: Phase, _ direction: SwipeDirection) -> Bool {
        let sign = sign(direction)
        guard let event = CGEvent(source: nil) else { return false }
        event.setIntegerValueField(eventTypeField, value: dockControlEvent)
        event.setIntegerValueField(gestureHIDType, value: dockSwipe)
        event.setIntegerValueField(gesturePhase, value: phase.rawValue)
        event.setIntegerValueField(swipeMotion, value: horizontal)
        event.setDoubleValueField(swipeProgress, value: sign * progress)
        // Fields a real trackpad swipe carries.
        event.setIntegerValueField(gesturePhaseAlias, value: phase.rawValue)
        event.setDoubleValueField(zoomDeltaY, value: 3.0)
        event.setDoubleValueField(timestampAlias, value: Double(mach_absolute_time()))
        event.setDoubleValueField(swipePositionX, value: 0.1)
        // Only the ended event carries the fling.
        if phase == .ended { event.setDoubleValueField(swipeVelocityX, value: sign * flingVelocity) }

        guard let augmented = withPayload(event),
              let companion = CGEvent(source: nil)
        else { return false }
        // The Dock ignores a Dock control event without a gesture event after it.
        companion.setIntegerValueField(eventTypeField, value: gestureEvent)
        augmented.post(tap: .cgSessionEventTap)
        companion.post(tap: .cgSessionEventTap)
        return true
    }

    // MARK: The IOHID payload macOS 27 needs

    /// The serialized event's format version, in its first four bytes.
    private static let formatVersion: [UInt8] = [0, 0, 0, 2]
    /// The tag field id the payload is filed under.
    private static let payloadField: UInt16 = 4205
    private static let velocityEventType: UInt32 = 9
    private static let dockPrimaryFlavor: UInt16 = 3

    /// The event re-created from its serialized form with the payload appended.
    private static func withPayload(_ event: CGEvent) -> CGEvent? {
        guard let data = event.data as Data?, data.prefix(4).elementsEqual(formatVersion)
        else { return nil }
        let payload = iohidPayload(event)
        var bytes = data
        bytes.append(contentsOf: [UInt8(payload.count >> 8 & 0xff), UInt8(payload.count & 0xff),
                                  UInt8(payloadField >> 8), UInt8(payloadField & 0xff)])
        bytes.append(payload)
        return CGEvent(withDataAllocator: nil, data: bytes as CFData)
    }

    private static func fixed1616(_ value: Double) -> Int32 {
        let fixed = Int32(clamping: Int64(value * 65536))
        return fixed == 0 && value != 0 ? (value > 0 ? 1 : -1) : fixed
    }

    /// A queue element header, a fluid-touch gesture event and, with any
    /// velocity or on the ended phase, a velocity event: packed, little-endian.
    private static func iohidPayload(_ event: CGEvent) -> Data {
        let phase = event.getIntegerValueField(gesturePhase)
        let velocityX = event.getDoubleValueField(swipeVelocityX)
        let velocityY = event.getDoubleValueField(swipeVelocityY)
        let withVelocity = velocityX != 0 || velocityY != 0 || phase == Phase.ended.rawValue

        var out = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func base(size: UInt32, type: UInt32, options: UInt32, depth: UInt8) {
            put(size); put(type); put(options); put(depth); put(UInt8(0)); put(UInt8(0)); put(UInt8(0))
        }

        var timestamp = event.timestamp
        if timestamp == 0 { timestamp = mach_absolute_time() }
        put(timestamp); put(UInt64(0)); put(UInt32(0)); put(UInt32(0)); put(UInt32(withVelocity ? 2 : 1))

        base(size: 40, type: UInt32(dockSwipe), options: UInt32(truncatingIfNeeded: (phase & 0xff) << 24), depth: 0)
        put(fixed1616(event.getDoubleValueField(swipePositionX)))
        put(fixed1616(event.getDoubleValueField(swipePositionY)))
        put(Int32(0))
        put(UInt32(0))  // swipe mask
        put(UInt16(truncatingIfNeeded: event.getIntegerValueField(swipeMotion)))
        put(dockPrimaryFlavor)
        put(fixed1616(event.getDoubleValueField(swipeProgress)))

        if withVelocity {
            base(size: 28, type: velocityEventType, options: 0, depth: 1)
            put(fixed1616(velocityX)); put(fixed1616(velocityY)); put(Int32(0))
        }
        return out
    }
}
