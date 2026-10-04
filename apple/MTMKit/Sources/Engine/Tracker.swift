import Foundation
import Wire

/// Maps phone timestamps onto the local clock: local = phone + offset.
/// The offset is the minimum observed (arrival − phone) over a sliding window,
/// so converted times keep the phone's jitter-free spacing and never lie in the future.
public struct ClockSync: Sendable {
    var window: [(t: Double, off: Double)] = []   // monotonic deque: offsets increase front to back
    public private(set) var offset: Double?
    let span: Double

    public init(span: Double = 10) { self.span = span }

    public mutating func observe(phone: Double, local: Double) {
        let off = local - phone
        while let last = window.last, last.off >= off { window.removeLast() }
        window.append((local, off))
        while let first = window.first, first.t < local - span, window.count > 1 { window.removeFirst() }
        offset = window.first!.off
    }

    public func local(_ phone: Double) -> Double { phone + (offset ?? 0) }
}

public struct TouchPoint: Sendable, Equatable {
    public var id: UInt8, p: P, t: Double
    public init(_ id: UInt8, _ p: P, _ t: Double) { self.id = id; self.p = p; self.t = t }
}

/// One frame's worth of touch changes, in local time and millimetres.
public struct TouchDelta: Sendable, Equatable {
    public var t: Double
    public var surface: P
    public var began: [TouchPoint] = []
    public var moved: [UInt8: P] = [:]
    public var ended: [TouchPoint] = []
    public init(t: Double, surface: P) { self.t = t; self.surface = surface }
}

/// Turns absolute-state frames (which may be lost or repeated) into touch begin/move/end events.
public struct TouchTracker: Sendable {
    var known: [UInt8: P] = [:]
    var endedUntil: [UInt8: Double] = [:]   // ids already ended, remembered for a while to ignore repeats

    public init() {}

    public mutating func apply(_ f: Frame, clock: ClockSync) -> TouchDelta {
        let t = clock.local(Double(f.t) / 1e6)
        var d = TouchDelta(t: t, surface: P(Double(f.width) / 100, Double(f.height) / 100))
        endedUntil = endedUntil.filter { $0.value > t }

        for e in f.ended where endedUntil[e.id] == nil {
            let p = P(Double(e.x) / 100, Double(e.y) / 100)
            let up = t - Double(e.upAgo) / 1000
            if known[e.id] == nil {
                d.began.append(TouchPoint(e.id, p, t - Double(e.downAgo) / 1000))  // whole touch fell between frames
            } else {
                d.moved[e.id] = p
            }
            d.ended.append(TouchPoint(e.id, p, up))
            known[e.id] = nil
            endedUntil[e.id] = t + 1
        }
        var seen = Set<UInt8>()
        for c in f.active where endedUntil[c.id] == nil {
            seen.insert(c.id)
            let p = P(Double(c.x) / 100, Double(c.y) / 100)
            if let old = known[c.id] {
                if old != p { d.moved[c.id] = p }
            } else {
                d.began.append(TouchPoint(c.id, p, t))
            }
            known[c.id] = p
        }
        for (id, p) in known where !seen.contains(id) {   // end report lost for too long
            d.ended.append(TouchPoint(id, p, t))
            known[id] = nil
            endedUntil[id] = t + 1
        }
        return d
    }
}
