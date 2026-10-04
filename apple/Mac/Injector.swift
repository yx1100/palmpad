import CoreGraphics
import Engine
import Foundation

/// Turns engine actions into macOS events. Confined to the hub queue.
final class Injector {
    /// How each gesture family reaches WindowServer; decided per macOS version by the M1 diagnostics.
    enum Route { case hid, keys }
    var gestureRoute = Route.hid
    var dockRoute = Route.hid
    var naturalScrolling = true

    private let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.localEventsSuppressionInterval = 0   // default 0.25 s would freeze the built-in trackpad after each event
        return s
    }()
    private var leftDown = false, rightDown = false
    private var scrollRemainder = CGPoint.zero
    private var lineRemainder = CGPoint.zero   // glide points not yet sent as a line
    private var pendingDockEnds: [DispatchWorkItem] = []
    private let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    func perform(_ a: Action) {
        switch a {
        case let .move(dx, dy): move(dx, dy)
        case let .button(b, down, clicks): button(b, down, clicks)
        case let .scroll(dx, dy, phase): scroll(dx, dy, phase: phase.cg, momentum: 0)
        case let .momentum(dx, dy, phase): scroll(dx, dy, phase: 0, momentum: phase.cg, option: phase.option)
        case let .magnify(v, phase): magnify(v, phase)
        case let .rotate(v, phase): rotate(v, phase)
        case .smartZoom: smartZoom()
        case let .navigate(back): navigate(back)
        case let .dock(kind, progress, phase, velocity): dock(kind, progress, phase, velocity)
        case let .notificationCenter(progress, phase, velocity, closing): notificationCenter(progress, phase, velocity, closing: closing)
        case .forceClick: forceClick()
        case let .hotkey(h): _ = MTMPostSymbolicHotKey(h == .lookUp ? 70 : 163)
        case .haptic: break   // handled by the hub (sent to the phone)
        case let .tipTap(left): key(left ? 13 : 12, flags: .maskCommand)   // ⌘W / ⌘Q
        }
    }

    /// Lifts any held button, e.g. when the phone vanishes mid-drag.
    func releaseAll() {
        if leftDown { button(.left, false, 1) }
        if rightDown { button(.right, false, 1) }
    }

    // MARK: Pointer

    private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func move(_ dx: Double, _ dy: Double) {
        let from = cursor
        let to = clamp(CGPoint(x: from.x + dx, y: from.y + dy), from: from)
        let type: CGEventType = leftDown ? .leftMouseDragged : rightDown ? .rightMouseDragged : .mouseMoved
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to,
                              mouseButton: rightDown && !leftDown ? .right : .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        e.post(tap: .cghidEventTap)
    }

    private func button(_ b: MouseButton, _ down: Bool, _ clicks: Int) {
        let type: CGEventType = switch (b, down) {
        case (.left, true): .leftMouseDown
        case (.left, false): .leftMouseUp
        case (.right, true): .rightMouseDown
        case (.right, false): .rightMouseUp
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: cursor,
                              mouseButton: b == .left ? .left : .right) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e.post(tap: .cghidEventTap)
        if b == .left { leftDown = down } else { rightDown = down }
    }

    private func clamp(_ p: CGPoint, from: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let rects = ids.map(CGDisplayBounds)
        if rects.contains(where: { $0.contains(p) }) { return p }
        guard let r = rects.first(where: { $0.contains(from) }) ?? rects.first else { return p }
        return CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
    }

    // MARK: Scroll

    private func scroll(_ dx: Double, _ dy: Double, phase: Int64, momentum: Int64, option: Int64 = 0) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)
        else { return }
        // Point deltas are integers. While the fingers move, carry the fraction to the next event. A glide step is
        // rounded away from zero, as the built-in trackpad does (0.3 points goes out as 1); its exact size goes in
        // field 176, which apps with precise scrolling follow.
        if phase == 1 || phase == 128 || momentum != 0 { scrollRemainder = .zero }
        let x = dx + scrollRemainder.x, y = dy + scrollRemainder.y
        let px = momentum != 0 ? x.rounded(.awayFromZero) : x.rounded(.towardZero)
        let py = momentum != 0 ? y.rounded(.awayFromZero) : y.rounded(.towardZero)
        scrollRemainder = momentum != 0 ? .zero : CGPoint(x: x - px, y: y - py)
        if phase == 4 || phase == 8 { scrollRemainder = .zero }
        // Line deltas: a glide step under 6 points adds up until it makes a line, as on the built-in trackpad,
        // instead of counting as a whole line by itself.
        var fixed = (x: px / 10, y: py / 10), line = (x: lines(px), y: lines(py))
        if momentum == 1 { lineRemainder = .zero }
        if momentum != 0, abs(py) < 6, abs(px) < 6 {
            lineRemainder.x += dx; lineRemainder.y += dy
            let full = abs(lineRemainder.y) >= 10 || abs(lineRemainder.x) >= 10
            fixed = full ? (lineRemainder.x / 10, lineRemainder.y / 10) : (0, 0)
            line = full ? (lines(lineRemainder.x), lines(lineRemainder.y)) : (0, 0)
            if full { lineRemainder = .zero }
        }

        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(py))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(px))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed.y)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed.x)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: line.y)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: line.x)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        if option != 0 {
            e.setIntegerValueField(CGEventField(rawValue: 173)!, value: option)
            // 176: the unrounded step in tenths, in the device's direction (opposite to content with natural scrolling).
            e.setDoubleValueField(CGEventField(rawValue: 176)!, value: dy / 10 * (naturalScrolling ? -1 : 1))
        }
        e.setIntegerValueField(CGEventField(rawValue: 137)!, value: naturalScrolling ? 1 : 0)   // directionInvertedFromDevice
        e.post(tap: .cgSessionEventTap)
    }

    /// Line deltas for apps that ignore pixel deltas: 10 points per line, at least one line for any motion.
    private func lines(_ points: Double) -> Int64 {
        let l = points / 10
        return l == 0 ? 0 : abs(l) < 1 ? (l > 0 ? 1 : -1) : Int64(l)
    }

    // MARK: Gestures
    // Formats recorded from the built-in trackpad on macOS 27 (M1): WindowServer reads the attached
    // IOHIDEvent; the legacy CGEvent fields are filled in as well, exactly as the real events carry them.

    private func magnify(_ v: Double, _ phase: Phase) {
        guard gestureRoute == .hid else {
            if phase == .changed { zoomKeys(v) }
            return
        }
        // IOHIDEvent Scale (7), Z = magnification; NSEvent sees subtype 8 (zoom).
        postGesture(29, hidType: 7, phase: phase, fields: [HID.field(7, 2): NSNumber(value: v)],
                    legacy: [110: 8, 113: v, 114: v, 116: v, 118: v])
    }

    private func rotate(_ degrees: Double, _ phase: Phase) {
        guard gestureRoute == .hid else { return }
        // IOHIDEvent Rotation (5), Z in radians; the legacy fields carry degrees.
        postGesture(29, hidType: 5, phase: phase, fields: [HID.field(5, 2): NSNumber(value: degrees * .pi / 180)],
                    legacy: [110: 5, 113: degrees, 114: degrees, 116: degrees, 118: degrees])
    }

    private func smartZoom() {
        guard gestureRoute == .hid else { return }
        postGesture(29, hidType: 22, phase: nil, fields: [:], legacy: [110: 22])
    }

    private func navigate(_ back: Bool) {
        guard gestureRoute == .hid else {
            key(back ? 33 : 30, flags: .maskCommand)   // ⌘[ / ⌘]
            return
        }
        // ponytail: not recorded in M1 (three-finger page swipes are off on this Mac); IOHIDSwipeMask left = 4, right = 8.
        let dir = back ? 4 : 8
        postGesture(29, hidType: 16, phase: .began, fields: [HID.field(16, 0): NSNumber(value: dir)], legacy: [110: 16, 115: Double(dir)])
        postGesture(29, hidType: 16, phase: .ended, fields: [:], legacy: [110: 16])
    }

    @discardableResult
    private func postGesture(_ cgType: UInt32, hidType: UInt32, phase: Phase?, fields: [UInt32: NSNumber],
                             legacy: [Int: Double], children: [[AnyHashable: Any]]? = nil,
                             tap: CGEventTapLocation = .cghidEventTap) -> CGEvent? {
        let options = phase.map { $0.hid << 24 } ?? 0
        let hidFields = Dictionary(uniqueKeysWithValues: fields.map { (NSNumber(value: $0.key), $0.value) })
        guard let e = MTMCreateHIDEvent(cgType, hidType, options, hidFields, children) else { return nil }
        if let p = phase {
            e.setIntegerValueField(CGEventField(rawValue: 132)!, value: Int64(p.hid))
            e.setIntegerValueField(CGEventField(rawValue: 134)!, value: Int64(p.hid))
        }
        for (f, v) in legacy {
            let field = CGEventField(rawValue: UInt32(f))!
            // Subtype, motion, phase, flavor, stage and behavior are integers; the rest are floats.
            if [110, 123, 132, 134, 138, 143, 144].contains(f) { e.setIntegerValueField(field, value: Int64(v)) }
            else { e.setDoubleValueField(field, value: v) }
        }
        e.location = cursor
        e.post(tap: tap)
        return e
    }

    private func velocityChild(_ v: Double) -> [[AnyHashable: Any]] {
        let n = NSNumber(value: v)
        return [["type": 9, "options": 0,
                 "fields": [NSNumber(value: HID.field(9, 0)): n, NSNumber(value: HID.field(9, 1)): n,
                            NSNumber(value: HID.field(9, 2)): NSNumber(value: 0.0)]]]
    }

    // MARK: Dock swipes (CG type 30)

    private func dock(_ kind: DockKind, _ progress: Double, _ phase: Phase, _ velocity: Double) {
        if phase == .began { pendingDockEnds.forEach { $0.cancel() }; pendingDockEnds = [] }
        guard dockRoute == .hid else {
            if phase == .ended { dockKeys(kind, progress) }
            return
        }
        // Recorded with natural scrolling on: swipes report progress against the finger direction,
        // pinches do not. Velocity is in progress per second, with the same sign as progress for swipes and
        // the opposite one for pinches: a pinch ended with a quick flick is otherwise read as flicked back.
        let flip = kind != .pinch && naturalScrolling ? -1.0 : 1.0
        let velocityFlip = kind == .pinch ? -1.0 : flip
        let motion: Int = switch kind { case .horizontal: 1; case .vertical: 2; case .pinch: 3 }
        let ending = phase == .ended || phase == .cancelled
        guard let e = postGesture(30, hidType: 23, phase: phase,
                                  fields: [HID.field(23, 1): NSNumber(value: motion), HID.field(23, 5): NSNumber(value: 3),
                                           HID.field(23, 2): NSNumber(value: progress * flip)],
                                  legacy: [110: 23, 123: Double(motion), 124: progress * flip],
                                  children: ending ? velocityChild(velocity * velocityFlip) : nil, tap: .cgSessionEventTap)
        else {
            if phase == .ended { dockKeys(kind, progress) }
            return
        }
        if ending { resendLater(e) }
    }

    /// WindowServer sometimes drops the end under load and the transition sticks; resend it.
    private func resendLater(_ e: CGEvent) {
        for delay in [0.2, 0.5] {
            let item = DispatchWorkItem { e.post(tap: .cgSessionEventTap) }
            pendingDockEnds.append(item)
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func dockKeys(_ kind: DockKind, _ progress: Double) {
        guard abs(progress) > 0.3 else { return }
        let hotkey: Int32 = switch kind {
        case .horizontal: progress > 0 ? 81 : 79          // move right / left a space
        case .vertical: progress < 0 ? 32 : 33            // Mission Control / application windows
        case .pinch: progress < 0 ? 160 : 36              // Launchpad / show desktop
        }
        _ = MTMPostSymbolicHotKey(hotkey)
    }

    // MARK: Notification Center (CG type 31, IOHIDEvent FluidTouchGesture 27)

    private func notificationCenter(_ progress: Double, _ phase: Phase, _ velocity: Double, closing: Bool) {
        let motion = closing ? 1.0 : 9.0   // recorded: 9 swiping in from the edge, 1 swiping it away
        let ending = phase == .ended || phase == .cancelled
        let sent = postGesture(31, hidType: 27, phase: phase,
                               fields: [HID.field(27, 1): NSNumber(value: Int(motion)), HID.field(27, 2): NSNumber(value: progress),
                                        HID.field(27, 5): NSNumber(value: 1)],
                               legacy: [110: 27, 123: motion, 124: progress, 138: 1],
                               children: ending ? velocityChild(velocity) : nil, tap: .cgSessionEventTap)
        if sent == nil, phase == .ended, !closing, progress > 0.3 { _ = MTMPostSymbolicHotKey(163) }
    }

    // MARK: Force click (IOHIDEvent Force 32 between mouse down and up)

    /// Replays the shape of a recorded force click: press, stage 1 ramp, deep press into stage 2, release.
    private func forceClick() {
        guard gestureRoute == .hid, MTMCreateHIDEvent(29, 32, 0, [:], nil) != nil else {
            _ = MTMPostSymbolicHotKey(70)   // Look Up
            return
        }
        button(.left, true, 1)
        var steps: [(stage: Int, sp: Double, pressure: Double, phase: Phase)] = [(1, 0, 0, .began)]
        steps += stride(from: 0.2, through: 1.0, by: 0.2).map { (1, $0, $0 * 0.4, .changed) }
        steps += stride(from: 0.1, through: 0.6, by: 0.1).map { (2, $0, 0, .changed) }
        steps += Array(repeating: (2, 0.6, 0, .changed), count: 10)   // hold ~80 ms in the deep press
        steps += [(1, 1, 0.2, .changed), (1, 0.5, 0.1, .changed), (0, 0, 0, .ended)]
        for (i, s) in steps.enumerated() {
            queue.asyncAfter(deadline: .now() + Double(i) * 0.008) { [self] in
                postGesture(29, hidType: 32, phase: s.phase,
                            fields: [HID.field(32, 0): NSNumber(value: 5), HID.field(32, 1): NSNumber(value: s.pressure),
                                     HID.field(32, 2): NSNumber(value: s.stage), HID.field(32, 3): NSNumber(value: s.sp)],
                            legacy: [110: 32, 143: Double(s.stage), 144: 5, 148: s.sp, 139: s.sp, 119: s.sp,
                                     113: s.pressure, 114: s.pressure, 116: s.pressure, 118: s.pressure])
                if i == steps.count - 1 { button(.left, false, 1) }
            }
        }
    }

    // MARK: Keys

    private var zoomDebt = 0.0
    private func zoomKeys(_ v: Double) {
        zoomDebt += v
        while abs(zoomDebt) >= 0.15 {
            key(zoomDebt > 0 ? 24 : 27, flags: .maskCommand)   // ⌘= / ⌘-
            zoomDebt -= zoomDebt > 0 ? 0.15 : -0.15
        }
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cgSessionEventTap)
        }
    }
}

enum HID {
    static func field(_ type: UInt32, _ index: UInt32) -> UInt32 { type << 16 | index }
}

extension Phase {
    /// IOHIDEventPhaseBits.
    var hid: UInt32 {
        switch self { case .began: 1; case .changed: 2; case .ended: 4; case .cancelled: 8 }
    }
}

extension ScrollPhase {
    /// CGScrollPhase.
    var cg: Int64 {
        switch self { case .began: 1; case .changed: 2; case .ended: 4; case .cancelled: 8; case .mayBegin: 128 }
    }
}

extension MomentumPhase {
    /// CGMomentumScrollPhase.
    var cg: Int64 {
        switch self { case .begin: 1; case .continue: 2; case .end, .stopped: 3 }
    }
    /// Field 173 of the built-in trackpad's momentum events: the phase again, with 16 added to an end that came
    /// by itself rather than from a touch. Without it apps glide on by themselves after the last step.
    var option: Int64 {
        switch self { case .begin: 1; case .continue: 2; case .end: 19; case .stopped: 3 }
    }
}
