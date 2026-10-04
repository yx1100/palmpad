import SwiftUI
import UIKit
import Wire

/// The trackpad: reports every touch change as an absolute-state frame in 0.01 mm. It covers the whole screen
/// and draws the card inside, so a swipe that starts on the bezel (into Notification Center) still lands on it.
final class TouchSurfaceView: UIView {
    let card = CALayer()
    var onFrame: ((Frame) -> Void)?
    var onTouchDown: (() -> Void)?

    /// iPhone 17: 460 ppi at 3× scale. The Mac side keeps a sensitivity knob for the rest.
    static let mmPerPoint = 25.4 / (460.0 / 3.0)

    private struct Ended { var id: UInt8, x: UInt16, y: UInt16, down: TimeInterval, up: TimeInterval }
    private var ids: [ObjectIdentifier: (id: UInt8, down: TimeInterval)] = [:]
    private var positions: [UInt8: (x: UInt16, y: UInt16)] = [:]
    private var ended: [Ended] = []
    private var nextID: UInt8 = 0
    private var lastSent: TimeInterval = 0
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        card.backgroundColor = UIColor(white: 0.11, alpha: 1).cgColor
        card.cornerCurve = .continuous
        layer.addSublayer(card)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Keep iOS three-finger editing gestures (undo, copy, paste) out of the way.
    override var canBecomeFirstResponder: Bool { true }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            ids[ObjectIdentifier(t)] = (nextID, t.timestamp)
            nextID &+= 1
        }
        onTouchDown?()
        startDisplayLink()
        update(event, t: touches.map(\.timestamp).max() ?? CACurrentMediaTime())
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        update(event, t: touches.map(\.timestamp).max() ?? CACurrentMediaTime())
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let info = ids.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            let p = t.location(in: self)
            ended.append(Ended(id: info.id, x: mm(p.x), y: mm(p.y), down: info.down, up: t.timestamp))
            positions[info.id] = nil
        }
        update(event, t: touches.map(\.timestamp).max() ?? CACurrentMediaTime())
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func update(_ event: UIEvent?, t: TimeInterval) {
        for touch in event?.allTouches ?? [] {
            guard touch.phase != .ended, touch.phase != .cancelled, let info = ids[ObjectIdentifier(touch)] else { continue }
            let p = touch.location(in: self)
            positions[info.id] = (mm(p.x), mm(p.y))
        }
        send(t)
    }

    private func send(_ t: TimeInterval) {
        ended.removeAll { t - $0.up > 0.15 }
        let frame = Frame(
            t: UInt64(t * 1e6), width: mm(bounds.width), height: mm(bounds.height),
            active: positions.map { .init(id: $0.key, x: $0.value.x, y: $0.value.y) },
            ended: ended.map { .init(id: $0.id, x: $0.x, y: $0.y, downAgo: ms(t - $0.down), upAgo: ms(t - $0.up)) })
        onFrame?(frame)
        lastSent = CACurrentMediaTime()
    }

    // Runs while fingers are down or lift reports are still being repeated: keeps the display (and so
    // touch delivery) at 120 Hz and re-sends the state so a lost packet cannot strand a touch.
    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(onDisplayLink))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func onDisplayLink() {
        let now = CACurrentMediaTime()
        ended.removeAll { now - $0.up > 0.15 }
        if positions.isEmpty && ended.isEmpty {
            displayLink?.invalidate()
            displayLink = nil
        } else if now - lastSent >= 0.016 {
            send(now)
        }
    }

    private func mm(_ v: CGFloat) -> UInt16 { UInt16(clamping: Int((Double(v) * Self.mmPerPoint * 100).rounded())) }
    private func ms(_ s: Double) -> UInt16 { UInt16(clamping: Int((s * 1000).rounded())) }
}

struct TouchSurface: UIViewRepresentable {
    let link: Link
    let card: CGRect
    let radius: CGFloat

    func makeUIView(context: Context) -> TouchSurfaceView {
        let v = TouchSurfaceView()
        v.onFrame = { [link] in link.send($0) }
        v.onTouchDown = { [link] in if link.phase != .connected { link.poke() } }
        return v
    }

    func updateUIView(_ v: TouchSurfaceView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        v.card.frame = card
        v.card.cornerRadius = radius
        CATransaction.commit()
    }
}
