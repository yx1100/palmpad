import Foundation
import XCTest
import Wire
@testable import Engine

/// Scripted fingers on a 144 × 66 mm surface, one frame every 8 ms.
struct Rig {
    var e: GestureEngine
    var t = 0.0
    var out: [Action] = []
    var pos: [UInt8: P] = [:]
    let surface = P(144, 66)

    init(_ configure: (inout TrackpadSettings) -> Void = { _ in }) {
        var s = TrackpadSettings()
        configure(&s)
        e = GestureEngine(settings: s)
    }

    mutating func down(_ fingers: [UInt8: P], dt: Double = 0.008) {
        t += dt
        var d = TouchDelta(t: t, surface: surface)
        for (id, p) in fingers.sorted(by: { $0.key < $1.key }) { d.began.append(TouchPoint(id, p, t)); pos[id] = p }
        out += e.handle(d)
    }

    /// Moves each finger to `to(id, start, progress)` over `steps` frames.
    mutating func move(steps: Int = 10, dt: Double = 0.008, _ to: (UInt8, P, Double) -> P) {
        let start = pos
        for i in 1...steps {
            t += dt
            var d = TouchDelta(t: t, surface: surface)
            for (id, p0) in start { let p = to(id, p0, Double(i) / Double(steps)); pos[id] = p; d.moved[id] = p }
            out += e.handle(d)
        }
    }

    mutating func move(by v: P, steps: Int = 10) { move(steps: steps) { _, p0, k in p0 + v * k } }

    mutating func up(_ ids: [UInt8]? = nil, dt: Double = 0.008) {
        t += dt
        var d = TouchDelta(t: t, surface: surface)
        for id in ids ?? pos.keys.sorted() { d.ended.append(TouchPoint(id, pos[id]!, t)); pos[id] = nil }
        out += e.handle(d)
    }

    mutating func wait(_ s: Double) {
        let end = t + s
        while t < end { t += 1.0 / 120; out += e.tick(t) }
    }

    mutating func take() -> [Action] { defer { out = [] }; return out }
    /// Output without the scroll "may begin / ended / cancelled" bookkeeping that resting fingers produce.
    mutating func gestures() -> [Action] {
        take().filter {
            if case .scroll(0, 0, let p) = $0, p != .began, p != .changed { return false }
            return true
        }
    }
}

final class EngineTests: XCTestCase {
    let click = [Action.button(.left, down: true, clicks: 1), .button(.left, down: false, clicks: 1)]
    let rightClick = [Action.button(.right, down: true, clicks: 1), .button(.right, down: false, clicks: 1)]

    func testTapClicksAndDoubleClicks() {
        var r = Rig()
        r.down([0: P(50, 30)]); r.up()
        XCTAssertEqual(r.take(), click)
        r.wait(0.1)
        r.down([1: P(50, 30)]); r.up()
        XCTAssertEqual(r.take(), [.button(.left, down: true, clicks: 2), .button(.left, down: false, clicks: 2)])
    }

    func testPointerMoveIsNotATap() {
        var r = Rig()
        r.down([0: P(50, 30)])
        r.move(by: P(10, 0))
        r.up()
        let out = r.take()
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { if case .move(let dx, _) = $0 { return dx > 0 } else { return false } })
    }

    func testSlowHoldIsNotATap() {
        var r = Rig()
        r.down([0: P(50, 30)]); r.wait(0.4); r.up()
        XCTAssertEqual(r.take(), [])
    }

    func testTwoFingerTapRightClicksAfterSmartZoomWindow() {
        var r = Rig()
        r.down([0: P(50, 30), 1: P(70, 30)]); r.up()
        XCTAssertEqual(r.take(), [.scroll(dx: 0, dy: 0, phase: .mayBegin), .scroll(dx: 0, dy: 0, phase: .ended)])
        r.wait(0.4)
        XCTAssertEqual(r.take(), rightClick)

        var noZoom = Rig { $0.smartZoom = false }
        noZoom.down([0: P(50, 30), 1: P(70, 30)]); noZoom.up()
        XCTAssertEqual(noZoom.gestures(), rightClick)
    }

    func testTwoFingerDoubleTapSmartZooms() {
        var r = Rig()
        r.down([0: P(50, 30), 1: P(70, 30)]); r.up()
        r.wait(0.1)
        r.down([2: P(50, 30), 3: P(70, 30)]); r.up()
        r.wait(0.5)
        XCTAssertEqual(r.gestures(), [.smartZoom])
    }

    func testTwoFingerScrollWithMomentumStoppedByTouch() {
        var r = Rig()
        r.down([0: P(50, 20), 1: P(70, 20)])
        r.move(by: P(0, 20))   // fast flick downwards
        r.up()
        var out = r.take()
        XCTAssertEqual(out.first, .scroll(dx: 0, dy: 0, phase: .mayBegin))
        guard case .scroll(_, let dy0, .began) = out.dropFirst().first else { return XCTFail("\(out)") }
        XCTAssertGreaterThan(dy0, 0, "natural scrolling: content follows the fingers")
        XCTAssertTrue(out.contains { if case .scroll(_, _, .changed) = $0 { return true } else { return false } })
        XCTAssertEqual(out.last, .scroll(dx: 0, dy: 0, phase: .ended))

        r.wait(0.05)
        out = r.take()
        guard case .momentum(_, let dy, .begin) = out.first else { return XCTFail("\(out)") }
        XCTAssertGreaterThan(dy, 0)
        r.down([2: P(60, 30)])
        XCTAssertEqual(r.take().last, .momentum(dx: 0, dy: 0, phase: .stopped))
        XCTAssertFalse(r.e.needsTick)
    }

    func testFlickMomentumFollowsFingerSpeed() {
        var r = Rig()
        r.down([0: P(50, 20), 1: P(70, 20)])
        r.move(by: P(0, 20))   // 250 mm/s: the built-in trackpad starts momentum near 5000 points/s
        r.up()
        _ = r.take()
        r.wait(3)
        let glide = r.take().reduce(0.0) { if case let .momentum(_, dy, _) = $1 { return $0 + dy } else { return $0 } }
        XCTAssertEqual(glide, 1250, accuracy: 250, "about the start speed times the decay time")
    }

    func testVerticalScrollStaysOnItsAxis() {
        var r = Rig()
        r.down([0: P(50, 20), 1: P(70, 20)])
        r.move(by: P(4, 20))   // drifting sideways, as fingers on a phone do
        r.up()
        r.wait(2)
        let sideways = r.gestures().contains {
            switch $0 {
            case let .scroll(dx, _, _), let .momentum(dx, _, _): dx != 0
            default: false
            }
        }
        XCTAssertFalse(sideways)
    }

    func testScrollStoppedBeforeLiftHasNoMomentum() {
        var r = Rig { $0.naturalScrolling = false }
        r.down([0: P(50, 20), 1: P(70, 20)])
        r.move(by: P(0, 10))
        r.wait(0.2)
        r.up()
        r.wait(0.2)
        let out = r.gestures()
        guard case .scroll(_, let dy0, .began) = out.first else { return XCTFail("\(out)") }
        XCTAssertLessThan(dy0, 0, "traditional scrolling inverts")
        XCTAssertFalse(out.contains { if case .momentum = $0 { return true } else { return false } })
    }

    func testPinchZoomsIn() {
        var r = Rig()
        r.down([0: P(60, 30), 1: P(80, 30)])
        r.move { id, p0, k in p0 + P(id == 0 ? -10 * k : 10 * k, 0) }
        r.up()
        let out = r.gestures()
        XCTAssertEqual(out.first, .magnify(0, .began))
        let total = out.reduce(0.0) { if case .magnify(let m, .changed) = $1 { return $0 + m } else { return $0 } }
        XCTAssertEqual(total, 20 * Tuning().magnifyPerMM, accuracy: 0.01, "linear in the change of finger distance")
        XCTAssertEqual(out.last, .magnify(0, .ended))
        XCTAssertFalse(out.contains { if case .scroll = $0 { return true } else { return false } })
    }

    func testRotateCounterclockwiseIsPositive() {
        var r = Rig()
        r.down([0: P(60, 30), 1: P(80, 30)])
        // Visually counterclockwise with y pointing down: the right finger moves up, the left finger down.
        r.move { id, _, k in
            let a = (id == 0 ? Double.pi : 0) - k * 0.6
            return P(70 + 10 * cos(a), 30 + 10 * sin(a))
        }
        r.up()
        let out = r.take()
        let total = out.reduce(0.0) { if case .rotate(let d, .changed) = $1 { return $0 + d } else { return $0 } }
        XCTAssertGreaterThan(total, 20)
    }

    func testThreeFingerDragHoldsButtonThroughGrace() {
        var r = Rig { $0.threeFingerDrag = true }
        r.down([0: P(40, 30), 1: P(50, 30), 2: P(60, 30)])
        r.move(by: P(15, 5), steps: 25)   // the button goes down once no further finger can still be landing
        r.up()
        var out = r.gestures()
        XCTAssertEqual(out.first, .button(.left, down: true, clicks: 1))
        XCTAssertFalse(out.contains(.button(.left, down: false, clicks: 1)))
        r.wait(0.3)
        XCTAssertEqual(r.take(), [])
        r.wait(0.3)
        out = r.take()
        XCTAssertEqual(out, [.button(.left, down: false, clicks: 1)])
    }

    func testThreeFingerDragResumesWithinGrace() {
        var r = Rig { $0.threeFingerDrag = true }
        r.down([0: P(40, 30), 1: P(50, 30), 2: P(60, 30)])
        r.move(by: P(15, 0), steps: 25)
        r.up()
        r.wait(0.2)
        r.down([3: P(40, 30), 4: P(50, 30), 5: P(60, 30)])
        r.move(by: P(15, 0))
        r.up()
        r.wait(1)
        let out = r.take()
        XCTAssertEqual(out.filter { if case .button = $0 { return true } else { return false } },
                       [.button(.left, down: true, clicks: 1), .button(.left, down: false, clicks: 1)])
    }

    func testFourFingerSwipes() {
        var r = Rig()
        let four: [UInt8: P] = [0: P(40, 30), 1: P(55, 30), 2: P(70, 30), 3: P(85, 30)]
        r.down(four)
        r.move(by: P(-40, 0))   // fingers left → next space
        r.up()
        var out = r.gestures()
        guard case .dock(.horizontal, let p0, .began, _) = out.first,
              case .dock(.horizontal, let p1, .ended, let v) = out.last else { return XCTFail("\(out)") }
        XCTAssertGreaterThan(p0, 0); XCTAssertGreaterThan(p1, 0.3); XCTAssertGreaterThan(v, 0)

        r.wait(0.5)
        r.down(four)
        r.move(by: P(0, -30))   // fingers up → Mission Control
        r.up()
        out = r.gestures()
        guard case .dock(.vertical, _, .began, _) = out.first,
              case .dock(.vertical, let p2, .ended, _) = out.last else { return XCTFail("\(out)") }
        XCTAssertLessThan(p2, -0.3)
    }

    func testFourFingerPinchIn() {
        var r = Rig()
        r.down([0: P(40, 20), 1: P(80, 20), 2: P(40, 50), 3: P(80, 50)])
        r.move { _, p0, k in p0 + (P(60, 35) - p0) * (0.6 * k) }
        r.up()
        let out = r.gestures()
        guard case .dock(.pinch, _, .began, _) = out.first,
              case .dock(.pinch, let p, .ended, _) = out.last else { return XCTFail("\(out)") }
        XCTAssertLessThan(p, 0)
    }

    func testThumbPinchIsNotASwipeDown() {
        // The fingers come down further than the thumb goes up: the centre moves about as far as the spread shrinks.
        var r = Rig()
        r.down([0: P(40, 20), 1: P(55, 18), 2: P(70, 20), 3: P(50, 55)])
        r.move { id, p0, k in p0 + P(0, id == 3 ? -8 * k : 10 * k) }
        r.up()
        let out = r.gestures()
        guard case .dock(.pinch, _, .began, _) = out.first else { return XCTFail("\(out)") }
    }

    func testThumbLandingLateIsNotAThreeFingerDrag() {
        var r = Rig { $0.threeFingerDrag = true }
        r.down([0: P(40, 20), 1: P(55, 18), 2: P(70, 20)])
        r.move(steps: 8) { _, p0, k in p0 + P(0, 2 * k) }   // the fingers start moving 64 ms before the thumb lands
        r.down([3: P(50, 55)])
        r.move { id, p0, k in p0 + P(0, id == 3 ? -8 * k : 6 * k) }
        r.up()
        let out = r.gestures()
        XCTAssertFalse(out.contains(.button(.left, down: true, clicks: 1)), "\(out)")
        guard case .dock(.pinch, let p0, .began, _) = out.first else { return XCTFail("\(out)") }
        XCTAssertEqual(p0, -0.02, "progress follows from where the pinch is recognised, without a jump, signed like the pinch")
    }

    func testLateFingersUpgradeScrollToSwipe() {
        var r = Rig()
        r.down([0: P(40, 30), 1: P(55, 30)])
        r.move(steps: 2) { _, p0, k in p0 + P(-2 * k, 0) }   // scroll starts before the others land
        r.down([2: P(70, 30), 3: P(85, 30)])
        r.move(by: P(-40, 0))
        r.up()
        let out = r.take()
        XCTAssertTrue(out.contains(.scroll(dx: 0, dy: 0, phase: .cancelled)))
        XCTAssertTrue(out.contains { if case .dock(.horizontal, _, .began, _) = $0 { return true } else { return false } })
    }

    func testRightEdgeSwipeOpensAndClosesNotificationCenter() {
        var r = Rig()
        r.down([0: P(141, 25), 1: P(141, 40)])
        r.move(by: P(-20, 0))
        r.up()
        var out = r.gestures()
        guard case .notificationCenter(_, .began, _, false) = out.first,
              case .notificationCenter(let p, .ended, let v, false) = out.last else { return XCTFail("\(out)") }
        XCTAssertEqual(p, 20 / Tuning().ncScale, accuracy: 0.05)
        XCTAssertGreaterThan(v, 0)
        XCTAssertFalse(out.contains { if case .scroll = $0 { return true } else { return false } })

        r.wait(0.5)
        r.down([2: P(60, 25), 3: P(60, 40)])   // two fingers anywhere, swiping right, close it again
        r.move(by: P(20, 0))
        r.up()
        out = r.gestures()
        guard case .notificationCenter(_, .began, _, true) = out.first,
              case .notificationCenter(_, .ended, _, true) = out.last else { return XCTFail("\(out)") }

        r.wait(0.5)
        r.down([4: P(60, 25), 5: P(60, 40)])   // now closed: the same swipe scrolls
        r.move(by: P(20, 0))
        r.up()
        XCTAssertTrue(r.gestures().contains { if case .scroll(_, _, .began) = $0 { return true } else { return false } })
    }

    func testEdgeSwipeCountsWhereEachFingerFirstTouched() {
        var r = Rig()
        r.down([0: P(143, 30)])
        r.move(steps: 5) { _, p0, k in p0 + P(-10 * k, 0) }   // the first finger is 10 mm in when the second lands
        r.down([1: P(143, 40)])
        r.move(steps: 4) { _, p0, k in p0 + P(0, 2 * k) }     // starts off downwards: not a scroll yet
        r.move { _, p0, k in p0 + P(-30 * k, 0) }
        r.up()
        XCTAssertTrue(r.gestures().contains { if case .notificationCenter(_, .began, _, false) = $0 { return true } else { return false } })
    }

    func testThreeFingerTapLooksUpOnlyWhenMacUsesTap() {
        var r = Rig { $0.threeFingerDrag = true; $0.lookUpTap = true }
        r.down([0: P(40, 30), 1: P(50, 30), 2: P(60, 30)]); r.up()
        XCTAssertEqual(r.gestures(), [.forceClick, .haptic])
        var forceClick = Rig { $0.threeFingerDrag = true }   // Look Up set to Force Click
        forceClick.down([0: P(40, 30), 1: P(50, 30), 2: P(60, 30)]); forceClick.up()
        XCTAssertEqual(forceClick.gestures(), [])
    }

    func testTipTapBesideRestingFinger() {
        var r = Rig { $0.tipTap = true; $0.smartZoom = false }
        r.down([0: P(60, 30)]); r.wait(0.3)
        r.down([1: P(40, 32)]); r.up([1])             // left of the resting finger
        r.down([2: P(80, 28)], dt: 0.1); r.up([2])    // then right of it
        r.up()
        XCTAssertEqual(r.gestures(), [.tipTap(left: true), .tipTap(left: false)])
        r.down([3: P(60, 30)]); r.down([4: P(40, 30)], dt: 0.05); r.up([4]); r.up()   // landing together: two-finger tap
        XCTAssertEqual(r.gestures(), rightClick)
        r.down([5: P(60, 45)]); r.wait(0.3); r.down([6: P(75, 30)]); r.up([6]); r.up()   // 45° up from a resting thumb
        XCTAssertEqual(r.gestures(), [])

        var off = Rig { $0.smartZoom = false }
        off.down([0: P(60, 30)]); off.wait(0.3)
        off.down([1: P(40, 32)]); off.up([1]); off.up()
        XCTAssertEqual(off.gestures(), [])
    }

    func testResetReleasesHeldButton() {
        var r = Rig { $0.threeFingerDrag = true }
        r.down([0: P(40, 30), 1: P(50, 30), 2: P(60, 30)])
        r.move(by: P(10, 0), steps: 25)
        _ = r.take()
        XCTAssertEqual(r.e.reset(), [.button(.left, down: false, clicks: 1)])
        XCTAssertFalse(r.e.needsTick)
    }

    func testTrackerRecoversTapFromEndedList() {
        var tracker = TouchTracker()
        var clock = ClockSync()
        clock.observe(phone: 100, local: 5)
        // The frames carrying the touch-down were lost; the next one only lists the ended touch.
        let f = Frame(t: 100_000_000, width: 14400, height: 6600, active: [],
                      ended: [.init(id: 9, x: 5000, y: 3000, downAgo: 90, upAgo: 20)])
        let d = tracker.apply(f, clock: clock)
        XCTAssertEqual(d.began.map(\.id), [9]); XCTAssertEqual(d.ended.map(\.id), [9])
        XCTAssertEqual(d.ended[0].t - d.began[0].t, 0.07, accuracy: 1e-9)
        var e = GestureEngine()
        XCTAssertEqual(e.handle(d), [.button(.left, down: true, clicks: 1), .button(.left, down: false, clicks: 1)])
        // A repeat of the same ended entry is ignored.
        XCTAssertEqual(tracker.apply(Frame(t: 100_008_000, width: 14400, height: 6600, active: [], ended: f.ended), clock: clock).ended, [])
    }

    /// One finger rightwards at `speed` mm/s, a frame every 8 ms, stopping at `stopAt`. Frames stamped inside
    /// `held` reach the engine only when it ends, as when Wi-Fi holds them back; ticks run at 120 Hz as on the
    /// Mac. Returns the pointer moves with the local time they were emitted.
    func pointerRun(speed: Double, stopAt: Double = 1, held: Range<Double>? = nil) -> [(t: Double, dx: Double)] {
        var e = GestureEngine()
        var moves: [(t: Double, dx: Double)] = []
        func record(_ a: [Action], _ t: Double) {
            for case let .move(dx, _) in a { moves.append((t, dx)) }
        }
        var d = TouchDelta(t: 0, surface: P(144, 66))
        d.began = [TouchPoint(0, P(20, 30), 0)]
        record(e.handle(d), 0)
        var x = 20.0, tick = 1.0 / 120, late: [TouchDelta] = []
        for i in 1...60 {
            let t = Double(i) * 0.008
            while tick < t { record(e.tick(tick), tick); tick += 1.0 / 120 }
            var f = TouchDelta(t: t, surface: P(144, 66))
            if t < stopAt { x += speed * 0.008; f.moved = [0: P(x, 30)] }
            if held?.contains(t) == true { late.append(f); continue }
            for l in late { record(e.handle(l), t) }
            late = []
            record(e.handle(f), t)
        }
        return moves
    }

    func testPointerCarriesOnThroughWiFiStall() {
        let smooth = pointerRun(speed: 80), stalled = pointerRun(speed: 80, held: 0.2..<0.28)
        let total = smooth.reduce(0) { $0 + $1.dx }, got = stalled.reduce(0) { $0 + $1.dx }
        XCTAssertEqual(got, total, accuracy: total * 0.05, "the late frames settle the shown-ahead travel")
        XCTAssertTrue(stalled.allSatisfy { $0.dx >= 0 }, "never pulled back")
        let during = stalled.map(\.t).filter { $0 >= 0.19 && $0 <= 0.28 }
        let gaps = zip(during, during.dropFirst()).map { $1 - $0 }
        XCTAssertLessThan(gaps.max() ?? 1, 0.025, "the pointer keeps moving while frames are held")
    }

    func testStallOvershootIsSmallWhenFingerStops() {
        let smooth = pointerRun(speed: 80, stopAt: 0.2), stalled = pointerRun(speed: 80, stopAt: 0.2, held: 0.2..<0.3)
        let total = smooth.reduce(0) { $0 + $1.dx }, got = stalled.reduce(0) { $0 + $1.dx }
        XCTAssertGreaterThan(got, total)
        XCTAssertLessThan(got - total, total * 0.2)
        XCTAssertTrue(stalled.allSatisfy { $0.dx >= 0 })
    }

    func testClockSyncUsesMinimumDelay() {
        var c = ClockSync()
        c.observe(phone: 10, local: 110.030)
        c.observe(phone: 10.1, local: 110.105)
        c.observe(phone: 10.2, local: 110.240)
        XCTAssertEqual(c.offset!, 100.005, accuracy: 1e-9)
    }
}
