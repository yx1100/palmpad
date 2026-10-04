import CoreGraphics
import Engine
import Foundation
import Synchronization

/// Tip taps on the Mac's own trackpad. MultitouchSupport reports the raw contacts and a second engine spots tip
/// taps among them; everything else stays with macOS. Contact frames are handled on the hub queue.
final class BuiltInTrackpad {
    private let q: DispatchQueue
    private let onTipTap: (_ left: Bool) -> Void
    private var engine = GestureEngine()
    private var token: Int32 = 0
    private var frames = ContactFrames(size: .zero)
    /// Shared with the event tap: native clicks to drop after a tip tap, and the last moment a button was down (∞ while held).
    private let clicks = Mutex((dropUntil: 0.0, buttonAt: -10.0))
    private var tap: CFMachPort?     // main thread
    private var dropping = false     // main thread: a dropped button-down still owes its button-up

    init(queue: DispatchQueue, onTipTap: @escaping (_ left: Bool) -> Void) {
        q = queue
        self.onTipTap = onTipTap
        engine.settings.tipTap = true
    }

    func start() {
        guard token == 0 else { return }
        var w = 0.0, h = 0.0
        token = MTMStartMultitouch({ [weak self] _, contacts in
            let t = now()
            self?.q.async { self?.frame(contacts, t) }
        }, &w, &h)
        frames = ContactFrames(size: P(w, h))
        Log.write(token == 0 ? "trackpad tip taps unavailable" : "trackpad tip taps on, sensor \(w) × \(h) mm")
        if token != 0 { DispatchQueue.main.async { self.enableTap(true) } }
    }

    func stop() {
        guard token != 0 else { return }
        MTMStopMultitouch(token)
        token = 0
        frames = ContactFrames(size: frames.size)
        engine = GestureEngine(settings: engine.settings)
        DispatchQueue.main.async { self.enableTap(false) }
    }

    /// MultitouchSupport stops reporting after sleep.
    func restart() {
        guard token != 0 else { return }
        stop()
        start()
    }

    private func frame(_ contacts: [[NSNumber]], _ t: Double) {
        let d = frames.delta(contacts, t)
        let tapMax = engine.tuning.tapMaxDuration
        for case let .tipTap(left) in engine.handle(d) {
            // A button pressed during the tap is a click next to a resting finger, not a tip tap.
            let pressed = clicks.withLock { s in
                guard t - s.buttonAt > tapMax else { return true }
                s.dropUntil = t + 0.1   // with tap to click on, macOS clicks for the tap about 10 ms after it lifts
                return false
            }
            Log.write("trackpad tip tap \(left ? "left" : "right")" + (pressed ? ", ignored: button pressed" : ""))
            if !pressed { onTipTap(left) }
        }
    }

    // MARK: Native clicks (main thread)

    private func enableTap(_ on: Bool) {
        if on, tap == nil {
            let mask = [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
                .reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: { _, type, event, info in
                Unmanaged<BuiltInTrackpad>.fromOpaque(info!).takeUnretainedValue().filter(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            guard let tap else { return Log.write("trackpad tip taps: event tap unavailable") }
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
    }

    /// Drops the click macOS adds for the tapping finger, and notes real presses for `frame`.
    private func filter(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        let t = now()
        switch type {
        case .leftMouseDown, .rightMouseDown:
            let drop = clicks.withLock { s in
                if t < s.dropUntil { return true }
                s.buttonAt = .infinity
                return false
            }
            if drop {
                dropping = true
                Log.write("trackpad tip tap: dropped the native click")
                return nil
            }
        case .leftMouseUp, .rightMouseUp:
            if dropping {
                dropping = false
                return nil
            }
            clicks.withLock { $0.buttonAt = t }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default: break
        }
        return Unmanaged.passUnretained(e)
    }
}

/// MultitouchSupport contact frames as touch deltas. Contacts in the make-touch (3) and touching (4) states are
/// down; positions arrive normalized with y up.
struct ContactFrames {
    let size: P
    private var known: [UInt8: P] = [:]

    init(size: P) { self.size = size }

    mutating func delta(_ contacts: [[NSNumber]], _ t: Double) -> TouchDelta {
        var d = TouchDelta(t: t, surface: size)
        var seen = Set<UInt8>()
        for c in contacts where c[1].intValue == 3 || c[1].intValue == 4 {
            let id = UInt8(truncatingIfNeeded: c[0].intValue)
            let p = P(c[2].doubleValue * size.x, (1 - c[3].doubleValue) * size.y)
            seen.insert(id)
            if let old = known[id] { if old != p { d.moved[id] = p } } else { d.began.append(TouchPoint(id, p, t)) }
            known[id] = p
        }
        for (id, p) in known where !seen.contains(id) {
            d.ended.append(TouchPoint(id, p, t))
            known[id] = nil
        }
        return d
    }
}
