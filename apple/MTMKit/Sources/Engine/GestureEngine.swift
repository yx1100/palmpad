import Foundation

/// Trackpad gesture recognizer. Pure state machine: feed touch deltas and clock ticks, get actions back.
/// Behaviour follows the Mac's own trackpad settings (`TrackpadSettings`).
public struct GestureEngine: Sendable {
    public var settings: TrackpadSettings
    public var tuning: Tuning

    struct Touch: Sendable { var start: P; var pos: P; var down: Double }

    enum Mode: Equatable, Sendable {
        case idle, pointer, pending, scroll, zoomRotate, drag, dock(DockKind), fluid(closing: Bool), finished
    }

    var touches: [UInt8: Touch] = [:]
    var surface = P(140, 65)
    var mode = Mode.idle
    var modeT = 0.0
    var modeTravel = 0.0
    var base: [UInt8: P] = [:]      // positions when the current classification started
    var lastT = 0.0

    // Current touch sequence (first finger down → last finger up).
    var seqStart = 0.0
    var seqMaxFingers = 0
    var seqTap = true
    var pointerMoving = false

    // Clicks.
    var lastClickT = -10.0
    var clickCount = 0
    var movedSinceClick = true
    var twoTapT: Double?

    // Gesture state.
    var zoomOn = false, rotateOn = false
    var zrBaseD = 0.0, zrBaseAngle = 0.0, zrPrevD = 0.0, zrPrevAngle = 0.0
    var dockProgress = 0.0, dockEmitT = 0.0, dockDirty = false, dockSpread = 0.0
    var dockSamples: [(t: Double, v: Double)] = []
    var scrollSamples: [(t: Double, d: P)] = []   // finger travel in mm, in the scroll direction
    var scrollRail = P(1, 1)   // axes a scroll moves along, chosen from its first travel
    var dragHeld = false
    var dragGraceUntil: Double?
    var momentum: (step: P, t: Double, n: Int, first: Double)?   // points per frame, next frame, frames sent, first step
    var mayBegan = false            // scroll "may begin" sent for two resting fingers
    var ncOpen = false              // we opened Notification Center; a two-finger swipe right closes it
    var fluidProgress = 0.0, fluidEmitT = 0.0
    var fluidSamples: [(t: Double, v: Double)] = []
    var bridge = StallBridge()

    public init(settings: TrackpadSettings = .init(), tuning: Tuning = .init()) {
        self.settings = settings
        self.tuning = tuning
    }

    /// True while timers are pending; the host should call `tick` at display rate until it turns false.
    public var needsTick: Bool { momentum != nil || twoTapT != nil || dragGraceUntil != nil || dockDirty || bridging }

    /// Motion that is carried on while frames are held back (see `StallBridge`).
    var bridging: Bool { mode == .drag || mode == .scroll || (mode == .pointer && pointerMoving) }

    public mutating func handle(_ d: TouchDelta) -> [Action] {
        var out: [Action] = []
        surface = d.surface
        for b in d.began { fingerDown(b, &out) }
        if !d.moved.isEmpty {
            move(d.moved, d.t, &out)
        } else if bridging {
            _ = bridge.real(.zero, frameDT(d.t), d.t)   // a resent frame: the finger is resting
        }
        for e in d.ended { fingerUp(e, &out) }
        lastT = d.t
        return out
    }

    public mutating func tick(_ now: Double) -> [Action] {
        var out: [Action] = []
        // The built-in trackpad's own glide, a step every 60th of a second: a quick opening for fast flicks,
        // then a steady loss of up to 6.3 points a step that turns into 8% as the steps shrink, easing out near
        // 0.3 points.
        while var m = momentum, now >= m.t {
            out.append(.momentum(dx: m.step.x, dy: m.step.y, phase: m.n == 0 ? .begin : .continue))
            m.n += 1
            let size = m.step.length
            let next = m.n < tuning.momentumOpening
                ? size * (1 - tuning.momentumOpeningLoss * m.first)
                : size - min(size * (1 - tuning.momentumRatio) + tuning.momentumDrag, tuning.momentumDecel)
            if next < tuning.momentumLastStep {
                out.append(.momentum(dx: 0, dy: 0, phase: .end))
                momentum = nil
            } else {
                m.step = m.step * (next / size)
                m.t += tuning.momentumFrame
                momentum = m
            }
        }
        if let t0 = twoTapT, now - t0 > tuning.twoTapWindow {
            twoTapT = nil
            if settings.secondaryClick { rightClick(&out) }
        }
        if let g = dragGraceUntil, now >= g { releaseDrag(&out) }
        if bridging, let b = bridge.predict(lastT: lastT, now: now, tuning: tuning) {
            if mode == .scroll { emitScroll(b.d, b.d.length / b.dt, bridge.until, .changed, &out) }
            else { out.append(pointerMove(b.d, speed: b.d.length / b.dt)) }
        }
        if dockDirty, case .dock(let k) = mode, now - dockEmitT >= tuning.dockMinInterval {
            out.append(.dock(k, progress: dockProgress, phase: .changed, velocity: 0))
            dockEmitT = now
            dockDirty = false
        }
        return out
    }

    /// Ends everything and releases held buttons, e.g. when the phone disconnects.
    public mutating func reset() -> [Action] {
        var out: [Action] = []
        cancelGesture(&out)
        if (momentum?.n ?? 0) > 0 { out.append(.momentum(dx: 0, dy: 0, phase: .stopped)) }
        if dragHeld { out.append(.button(.left, down: false, clicks: 1)) }
        self = GestureEngine(settings: settings, tuning: tuning)
        return out
    }

    // MARK: - Fingers

    mutating func fingerDown(_ b: TouchPoint, _ out: inout [Action]) {
        if let m = momentum {   // touching the surface stops momentum, like the real trackpad
            if m.n > 0 { out.append(.momentum(dx: 0, dy: 0, phase: .stopped)) }
            momentum = nil
        }
        if touches.isEmpty {
            seqStart = b.t; seqMaxFingers = 0; seqTap = true; pointerMoving = false
        }
        touches[b.id] = Touch(start: b.p, pos: b.p, down: b.t)
        let n = touches.count
        seqMaxFingers = max(seqMaxFingers, n)

        if dragGraceUntil != nil, n >= 3, settings.threeFingerDrag {
            dragGraceUntil = nil   // fingers came back in time: keep dragging
            enter(.drag, b.t)
            return
        }
        switch mode {
        case .idle: enter(n == 1 ? .pointer : .pending, b.t)
        case .pointer: enter(.pending, b.t)
        case .pending: base = touches.mapValues(\.pos)
        case .scroll, .zoomRotate, .dock, .fluid:
            if b.t - modeT < tuning.upgradeWindow, modeTravel < tuning.upgradeTravel {
                cancelGesture(&out)
                enter(.pending, b.t)
            }
        case .drag, .finished: break
        }
        // Two resting fingers: the real trackpad announces a possible scroll right away.
        if n == 2, mode == .pending, settings.scroll, !mayBegan {
            mayBegan = true
            out.append(.scroll(dx: 0, dy: 0, phase: .mayBegin))
        }
    }

    mutating func fingerUp(_ e: TouchPoint, _ out: inout [Action]) {
        guard let tc = touches.removeValue(forKey: e.id) else { return }
        if (e.p - tc.start).length > tuning.tapMaxTravel { seqTap = false }
        let n = touches.count
        if n == 0 { sequenceEnd(e.t, &out); return }
        switch mode {
        case .pending:
            if n == 1 {
                tipTap(tc, e, &out)
                enter(.pointer, e.t)
            } else {
                base = touches.mapValues(\.pos)
            }
        case .scroll:
            if n < 2 { endScroll(e.t, &out); enter(.finished, e.t) }
        case .zoomRotate:
            if n < 2 { endZoomRotate(&out); enter(.finished, e.t) }
        case .dock:
            if n < 2 { endDock(e.t, &out); enter(.finished, e.t) }
        case .fluid:
            if n < 2 { endFluid(e.t, &out); enter(.finished, e.t) }
        case .idle, .pointer, .drag, .finished: break
        }
    }

    mutating func sequenceEnd(_ t: Double, _ out: inout [Action]) {
        let tap = seqTap && t - seqStart <= tuning.tapMaxDuration && (mode == .pointer || mode == .pending)
        switch mode {
        case .scroll: endScroll(t, &out)
        case .zoomRotate: endZoomRotate(&out)
        case .dock: endDock(t, &out)
        case .fluid: endFluid(t, &out)
        case .drag: dragGraceUntil = t + tuning.dragGrace
        case .idle, .pointer, .pending, .finished: break
        }
        mode = .idle
        if mayBegan {   // fingers left without scrolling
            mayBegan = false
            out.append(.scroll(dx: 0, dy: 0, phase: .ended))
        }
        if tap { self.tap(seqMaxFingers, t, &out) }
    }

    mutating func enter(_ m: Mode, _ t: Double) {
        mode = m
        modeT = t
        modeTravel = 0
        base = touches.mapValues(\.pos)
        bridge = StallBridge()
    }

    // MARK: - Movement

    mutating func move(_ moved: [UInt8: P], _ t: Double, _ out: inout [Action]) {
        var sum = P.zero
        for (id, p) in moved {
            guard var tc = touches[id] else { continue }
            sum = sum + (p - tc.pos)
            tc.pos = p
            touches[id] = tc
            if (p - tc.start).length > tuning.tapMaxTravel { seqTap = false }
        }
        guard !touches.isEmpty else { return }
        let d = sum / Double(touches.count)     // centroid movement
        let dt = frameDT(t)
        modeTravel += d.length

        switch mode {
        case .pointer:
            guard let tc = touches.values.first else { break }
            if !pointerMoving, (tc.pos - tc.start).length >= tuning.pointerSlop {
                pointerMoving = true
                if dragGraceUntil != nil { releaseDrag(&out) }
            }
            if pointerMoving { movedSinceClick = true; emitPointer(d, dt, t, &out) }
        case .pending: classify(t, &out)
        case .scroll:
            let rest = bridge.real(d, dt, t)
            if rest != .zero { emitScroll(rest, d.length / dt, t, .changed, &out) }
        case .zoomRotate: zoomRotate(&out)
        case .drag: emitPointer(d, dt, t, &out)
        case .dock(let k): dockMove(k, d, t, &out)
        case .fluid(let closing): fluidMove(closing, d, t, &out)
        case .idle, .finished: break
        }
    }

    mutating func classify(_ t: Double, _ out: inout [Action]) {
        let ids = touches.keys.sorted()
        let cur = ids.map { touches[$0]!.pos }
        let b = ids.map { base[$0] ?? touches[$0]!.pos }
        let T = centroid(cur) - centroid(b)

        switch ids.count {
        case 2:
            // Fingers sliding in from the right edge land one after the other (90 ms apart on the built-in
            // trackpad), so where each one first touched counts, not where it was when the other one landed.
            // Such a pair, or any pair while Notification Center is open, waits until its direction is clear.
            let edge = settings.notificationCenterEdge && ids.allSatisfy { touches[$0]!.start.x > surface.x - tuning.edgeZone }
            if edge || ncOpen {
                if T.length < tuning.edgeTravel { return }
                if abs(T.x) > abs(T.y), edge && T.x < 0 || ncOpen && T.x > 0 {
                    return beginFluid(closing: T.x > 0, abs(T.x) / tuning.ncScale, t, &out)
                }
            }
            let dNow = (cur[1] - cur[0]).length, dBase = (b[1] - b[0]).length
            let arc = abs(angleDiff(angle(cur[1] - cur[0]), angle(b[1] - b[0]))) * dNow / 2
            let pinch = settings.zoom && abs(dNow - dBase) > tuning.pinchStart
            let rot = settings.rotate && arc > tuning.rotateStart
            if (pinch || rot) && max(abs(dNow - dBase), arc) > T.length {
                settleMayBegin(&out)
                ncOpen = false
                enter(.zoomRotate, t)
                zoomOn = false; rotateOn = false
                zrBaseD = dBase; zrPrevD = dBase
                zrBaseAngle = angle(b[1] - b[0]); zrPrevAngle = zrBaseAngle
                zoomRotate(&out)
            } else if settings.scroll, T.length > tuning.scrollStart {
                mayBegan = false   // superseded by "began"
                ncOpen = false
                enter(.scroll, t)
                scrollSamples = []
                emitScroll(T, 0, t, .began, &out)
            }
        case 3:
            if settings.threeFingerDrag {
                // The thumb or a fourth finger may still be landing (up to ~130 ms later on the built-in trackpad):
                // pressing the button now would turn a pinch or four-finger swipe into a drag.
                let settled = t - (touches.values.map(\.down).max() ?? t)
                if T.length > tuning.dragStart, settled >= tuning.upgradeWindow {
                    settleMayBegin(&out)
                    ncOpen = false
                    enter(.drag, t)
                    dragHeld = true
                    out.append(.button(.left, down: true, clicks: 1))   // no haptic: the real trackpad gives none here
                    out.append(pointerMove(T, speed: T.length / settled))
                }
            } else {
                swipe(T, fingers: 3, t, &out)
            }
        case 4...:
            // Swipes barely change the spread (at most a quarter of their travel on the built-in trackpad), while
            // pinching the thumb and three fingers moves their centre too, often about as far as the spread changes.
            // The real trackpad starts the pinch after 1.2–1.7 mm with progress ±0.02 and follows from there; the
            // Dock needs that sign: a pinch that begins at exactly 0 never opens Launchpad.
            let spread = meanSpread(cur) - meanSpread(b)
            if settings.pinchLaunch, abs(spread) > tuning.spreadStart, abs(spread) > T.length * tuning.pinchShare {
                enter(.dock(.pinch), t)
                dockSpread = meanSpread(cur)
                beginDock(.pinch, spread > 0 ? 0.02 : -0.02, t, &out)
            } else {
                swipe(T, fingers: ids.count, t, &out)
            }
        default: break
        }
    }

    mutating func swipe(_ T: P, fingers: Int, _ t: Double, _ out: inout [Action]) {
        guard T.length > tuning.swipeStart else { return }
        if abs(T.x) > abs(T.y) {
            let use: TrackpadSettings.SwipeUse = fingers == 3
                ? settings.threeFingerHorizontal
                : (settings.fourFingerHorizontal ? .spaces : .off)
            switch use {
            case .spaces:
                enter(.dock(.horizontal), t)
                beginDock(.horizontal, -T.x / tuning.dockScaleH, t, &out)
            case .pages:
                settleMayBegin(&out)
                out.append(.navigate(back: T.x > 0))
                enter(.finished, t)
            case .off:
                settleMayBegin(&out)
                enter(.finished, t)
            }
        } else {
            let on = fingers == 3 ? settings.threeFingerVertical : settings.fourFingerVertical
            if on, T.y < 0 || settings.appExpose {
                enter(.dock(.vertical), t)
                beginDock(.vertical, T.y / tuning.dockScaleV, t, &out)
            } else {
                settleMayBegin(&out)
                enter(.finished, t)
            }
        }
    }

    /// A gesture other than scrolling took over two resting fingers.
    mutating func settleMayBegin(_ out: inout [Action]) {
        guard mayBegan else { return }
        mayBegan = false
        out.append(.scroll(dx: 0, dy: 0, phase: .cancelled))
    }

    // MARK: - Pointer, clicks, drag

    func frameDT(_ t: Double) -> Double { min(max(t - lastT, 0.004), 0.05) }

    mutating func emitPointer(_ d: P, _ dt: Double, _ t: Double, _ out: inout [Action]) {
        let rest = bridge.real(d, dt, t)
        if rest != .zero { out.append(pointerMove(rest, speed: d.length / dt)) }
    }

    /// Gain grows linearly with finger speed (mm/s), as measured on the built-in trackpad (M1 recording).
    func pointerMove(_ d: P, speed: Double) -> Action {
        let gain = min(tuning.pointerBase + tuning.pointerSlope * speed, tuning.pointerMax) * settings.trackingSpeed
        return .move(dx: d.x * gain, dy: d.y * gain)
    }

    mutating func tap(_ fingers: Int, _ t: Double, _ out: inout [Action]) {
        switch fingers {
        case 1:
            ncOpen = false
            if dragGraceUntil != nil { releaseDrag(&out); return }   // tap drops a three-finger drag
            let again = !movedSinceClick && t - lastClickT <= settings.doubleClickInterval
            clickCount = again ? min(clickCount + 1, 3) : 1
            lastClickT = t
            movedSinceClick = false
            out.append(.button(.left, down: true, clicks: clickCount))
            out.append(.button(.left, down: false, clicks: clickCount))
        case 2:
            if settings.smartZoom {
                if let t0 = twoTapT, t - t0 <= tuning.twoTapWindow {
                    twoTapT = nil
                    out.append(.smartZoom)
                } else {
                    twoTapT = t   // right click fires from tick() unless a second two-finger tap arrives
                }
            } else if settings.secondaryClick {
                rightClick(&out)
            }
        case 3 where settings.lookUpTap:
            out.append(.forceClick)
            out.append(.haptic)
        default: break
        }
    }

    /// The finger that just lifted tapped beside one that was already resting and still is.
    mutating func tipTap(_ tc: Touch, _ e: TouchPoint, _ out: inout [Action]) {
        guard settings.tipTap, seqMaxFingers == 2, let rest = touches.values.first,
              tc.down - rest.down >= tuning.tipTapRest, e.t - tc.down <= tuning.tapMaxDuration,
              (e.p - tc.start).length <= tuning.tapMaxTravel else { return }
        let side = e.p - rest.pos
        guard abs(side.y) <= abs(side.x) * tuning.tipTapSlope else { return }   // well above or below: no side to go by
        seqTap = false   // lifting the resting finger afterwards is not a two-finger tap
        out.append(.tipTap(left: side.x < 0))
    }

    func rightClick(_ out: inout [Action]) {
        out.append(.button(.right, down: true, clicks: 1))
        out.append(.button(.right, down: false, clicks: 1))
    }

    mutating func releaseDrag(_ out: inout [Action]) {
        if dragHeld { out.append(.button(.left, down: false, clicks: 1)) }
        dragHeld = false
        dragGraceUntil = nil
    }

    // MARK: - Scroll

    /// `speed` in mm/s; 0 for the accumulated delta that starts a scroll.
    mutating func emitScroll(_ dmm: P, _ speed: Double, _ t: Double, _ phase: ScrollPhase, _ out: inout [Action]) {
        let sign = settings.naturalScrolling ? 1.0 : -1.0
        let gain = min(tuning.scrollBase + tuning.scrollSlope * max(speed - tuning.scrollKnee, 0), tuning.scrollMax)
        // Like the built-in trackpad, a scroll that starts clearly along one axis stays on it: a vertical stroke
        // drifts sideways, and a page that cannot scroll sideways would stretch and spring back.
        if phase == .began {
            let r = tuning.scrollRail
            scrollRail = abs(dmm.y) > abs(dmm.x) * r ? P(0, 1) : abs(dmm.x) > abs(dmm.y) * r ? P(1, 0) : P(1, 1)
        }
        var m = P(dmm.x * scrollRail.x, dmm.y * scrollRail.y) * sign
        if !settings.horizontalScroll { m.x = 0 }
        let s = m * gain
        scrollSamples.append((t, m))
        scrollSamples.removeAll { $0.t < t - 2 * tuning.velocityWindow }
        out.append(.scroll(dx: s.x, dy: s.y, phase: phase))
    }

    mutating func endScroll(_ t: Double, _ out: inout [Action]) {
        out.append(.scroll(dx: 0, dy: 0, phase: .ended))
        guard settings.momentum else { return }
        let recent = scrollSamples.filter { $0.t >= t - tuning.velocityWindow }
        guard let first = recent.first else { return }
        let span = max(t - first.t, 1.0 / 120)
        // The built-in trackpad starts momentum from the finger speed, with more gain than scrolling has:
        // a quick flick starts it at about 25 points per mm of finger travel.
        let fingers = recent.reduce(P.zero) { $0 + $1.d } / span
        var v = fingers * min(tuning.momentumBase + tuning.momentumSlope * fingers.length, tuning.momentumMax)
        if v.length > tuning.momentumStartMax { v = v * (tuning.momentumStartMax / v.length) }
        if v.length > tuning.momentumMinSpeed { momentum = (v * tuning.momentumFrame, t + tuning.momentumFrame, 0, v.length * tuning.momentumFrame) }
    }

    // MARK: - Zoom and rotate

    mutating func zoomRotate(_ out: inout [Action]) {
        let ids = touches.keys.sorted()
        guard ids.count >= 2 else { return }
        let a = touches[ids[0]]!.pos, b = touches[ids[1]]!.pos
        let d = (b - a).length, ang = angle(b - a)
        if settings.zoom {
            if !zoomOn, abs(d - zrBaseD) > tuning.pinchStart { zoomOn = true; out.append(.magnify(0, .began)) }
            // Magnification is linear in the change of finger distance, as on the built-in trackpad.
            if zoomOn, d != zrPrevD { out.append(.magnify((d - zrPrevD) * tuning.magnifyPerMM, .changed)) }
        }
        if settings.rotate {
            if !rotateOn, abs(angleDiff(ang, zrBaseAngle)) * d / 2 > tuning.rotateStart {
                rotateOn = true
                out.append(.rotate(0, .began))
            }
            // Surface y points down, so a visually counterclockwise turn decreases the angle.
            let r = -angleDiff(ang, zrPrevAngle) * 180 / .pi
            if rotateOn, r != 0 { out.append(.rotate(r, .changed)) }
        }
        zrPrevD = d
        zrPrevAngle = ang
    }

    mutating func endZoomRotate(_ out: inout [Action]) {
        if zoomOn { out.append(.magnify(0, .ended)) }
        if rotateOn { out.append(.rotate(0, .ended)) }
        zoomOn = false; rotateOn = false
    }

    // MARK: - Dock swipes

    mutating func beginDock(_ k: DockKind, _ progress: Double, _ t: Double, _ out: inout [Action]) {
        settleMayBegin(&out)
        ncOpen = false
        dockProgress = progress
        dockSamples = [(t, progress)]
        dockEmitT = t
        dockDirty = false
        out.append(.dock(k, progress: progress, phase: .began, velocity: 0))
    }

    mutating func dockMove(_ k: DockKind, _ d: P, _ t: Double, _ out: inout [Action]) {
        switch k {
        case .horizontal: dockProgress += -d.x / tuning.dockScaleH
        case .vertical: dockProgress += d.y / tuning.dockScaleV
        case .pinch:
            let s = meanSpread(Array(touches.values.map(\.pos)))
            dockProgress += (s - dockSpread) / tuning.dockScalePinch
            dockSpread = s
        }
        dockSamples.append((t, dockProgress))
        dockSamples.removeAll { $0.t < t - tuning.velocityWindow }
        if t - dockEmitT >= tuning.dockMinInterval {
            out.append(.dock(k, progress: dockProgress, phase: .changed, velocity: 0))
            dockEmitT = t
            dockDirty = false
        } else {
            dockDirty = true
        }
    }

    mutating func endDock(_ t: Double, _ out: inout [Action]) {
        guard case .dock(let k) = mode else { return }
        var v = 0.0
        if let first = dockSamples.first, let last = dockSamples.last, last.t > first.t {
            v = (last.v - first.v) / (last.t - first.t)
        }
        // Moving back towards the start at release means "never mind", as on the real trackpad.
        let phase: Phase = v * dockProgress < 0 ? .cancelled : .ended
        out.append(.dock(k, progress: dockProgress, phase: phase, velocity: v))
        dockDirty = false
    }

    mutating func cancelGesture(_ out: inout [Action]) {
        switch mode {
        case .scroll: out.append(.scroll(dx: 0, dy: 0, phase: .cancelled))
        case .zoomRotate:
            if zoomOn { out.append(.magnify(0, .cancelled)) }
            if rotateOn { out.append(.rotate(0, .cancelled)) }
            zoomOn = false; rotateOn = false
        case .dock(let k):
            out.append(.dock(k, progress: dockProgress, phase: .cancelled, velocity: 0))
            dockDirty = false
        case .fluid(let closing):
            out.append(.notificationCenter(progress: fluidProgress, phase: .cancelled, velocity: 0, closing: closing))
        default: break
        }
    }

    // MARK: - Notification Center

    mutating func beginFluid(closing: Bool, _ progress: Double, _ t: Double, _ out: inout [Action]) {
        settleMayBegin(&out)
        enter(.fluid(closing: closing), t)
        fluidProgress = progress
        fluidEmitT = t
        fluidSamples = [(t, progress)]
        out.append(.notificationCenter(progress: progress, phase: .began, velocity: 0, closing: closing))
    }

    mutating func fluidMove(_ closing: Bool, _ d: P, _ t: Double, _ out: inout [Action]) {
        fluidProgress = max(0, fluidProgress + (closing ? d.x : -d.x) / tuning.ncScale)
        fluidSamples.append((t, fluidProgress))
        fluidSamples.removeAll { $0.t < t - tuning.velocityWindow }
        guard t - fluidEmitT >= tuning.dockMinInterval else { return }
        fluidEmitT = t
        out.append(.notificationCenter(progress: fluidProgress, phase: .changed, velocity: 0, closing: closing))
    }

    mutating func endFluid(_ t: Double, _ out: inout [Action]) {
        guard case .fluid(let closing) = mode else { return }
        var v = 0.0
        if let first = fluidSamples.first, let last = fluidSamples.last, last.t > first.t {
            v = (last.v - first.v) / (last.t - first.t)
        }
        out.append(.notificationCenter(progress: fluidProgress, phase: .ended, velocity: v, closing: closing))
        ncOpen = !closing && (fluidProgress > 0.3 || v > 1.5)
    }
}

func centroid(_ ps: [P]) -> P { ps.reduce(P.zero, +) / Double(max(ps.count, 1)) }
func meanSpread(_ ps: [P]) -> Double {
    let c = centroid(ps)
    return ps.reduce(0) { $0 + ($1 - c).length } / Double(max(ps.count, 1))
}
func angle(_ v: P) -> Double { atan2(v.y, v.x) }
/// Smallest signed difference a − b, in (−π, π].
func angleDiff(_ a: Double, _ b: Double) -> Double {
    var d = a - b
    while d > .pi { d -= 2 * .pi }
    while d <= -.pi { d += 2 * .pi }
    return d
}

/// Wi-Fi can hold frames back for 40–100 ms and then deliver them in one burst: the Mac's radio visits
/// the AWDL channel about twice a second while AirDrop, Handoff or Universal Control are on. Instead of
/// freezing and then jumping, pointer and scroll motion carries on at the recent finger velocity,
/// fading out, and the late frames first pay back the travel that was shown ahead of them.
struct StallBridge: Sendable {
    var v = P.zero      // finger velocity, mm/s, smoothed over ~20 ms
    var debt = P.zero   // travel shown ahead of the frames, mm
    var until = 0.0     // time up to which travel has been shown ahead

    /// A real frame's travel; returns the part not shown already.
    mutating func real(_ d: P, _ dt: Double, _ t: Double) -> P {
        v = v + (d / dt - v) * (1 - exp(-dt / 0.02))
        let owed = debt.length
        guard owed > 0 else { return d }
        var rest = d
        let u = debt / owed
        let along = d.x * u.x + d.y * u.y
        if along > 0 {
            let paid = min(along, owed)
            rest = d - u * paid
            debt = debt - u * paid
        }
        if t >= until { debt = .zero }   // caught up: travel shown beyond the finger stays a small overshoot
        return rest
    }

    /// Travel to show for frames overdue at `now`, and the time span it stands for.
    mutating func predict(lastT: Double, now: Double, tuning: Tuning) -> (d: P, dt: Double)? {
        let late = now - lastT
        guard late > tuning.stallAfter else { return nil }
        let from = max(until - lastT, 0), to = min(late, tuning.stallMax)
        guard to > from + 0.001 else { return nil }
        let tau = tuning.stallTau
        let d = v * (tau * (exp(-from / tau) - exp(-to / tau)))
        until = lastT + to
        debt = debt + d
        return (d, to - from)
    }
}
