import Foundation

/// Millimetres on the phone surface (y down), or points on the Mac screen, depending on context.
public struct P: Equatable, Sendable {
    public var x: Double, y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = P(0, 0)
    public var length: Double { (x * x + y * y).squareRoot() }
    public static func + (a: P, b: P) -> P { P(a.x + b.x, a.y + b.y) }
    public static func - (a: P, b: P) -> P { P(a.x - b.x, a.y - b.y) }
    public static func * (a: P, k: Double) -> P { P(a.x * k, a.y * k) }
    public static func / (a: P, k: Double) -> P { P(a.x / k, a.y / k) }
}

public enum Phase: Sendable, Equatable { case began, changed, ended, cancelled }
public enum ScrollPhase: Sendable, Equatable { case mayBegin, began, changed, ended, cancelled }
/// `end`: the glide ran its course; `stopped`: a touch cut it short.
public enum MomentumPhase: Sendable, Equatable { case begin, `continue`, end, stopped }
public enum DockKind: Sendable, Equatable { case horizontal, vertical, pinch }
public enum Hotkey: Sendable, Equatable { case notificationCenter, lookUp }
public enum MouseButton: Sendable, Equatable { case left, right }

/// What the engine asks the Mac to do. Distances are in screen points.
public enum Action: Sendable, Equatable {
    case move(dx: Double, dy: Double)
    case button(MouseButton, down: Bool, clicks: Int)
    /// Content-direction deltas (natural scrolling already applied).
    case scroll(dx: Double, dy: Double, phase: ScrollPhase)
    case momentum(dx: Double, dy: Double, phase: MomentumPhase)
    case magnify(Double, Phase)
    /// Degrees, counterclockwise positive.
    case rotate(Double, Phase)
    case smartZoom
    /// Progress is semantic: horizontal + = next space, vertical − = Mission Control, pinch + = spread (show desktop).
    case dock(DockKind, progress: Double, phase: Phase, velocity: Double)
    case navigate(back: Bool)
    /// Two-finger swipe in from the right edge (or back out); progress 0…1 follows the fingers.
    case notificationCenter(progress: Double, phase: Phase, velocity: Double, closing: Bool)
    /// Press, deep press and release at the pointer: Look Up and Quick Look.
    case forceClick
    case hotkey(Hotkey)
    case haptic
    /// A quick tap beside a resting finger (BetterTouchTool's TipTap); `left` is the tapping finger's side.
    /// The Mac turns it into a keyboard shortcut.
    case tipTap(left: Bool)
}

/// Mirror of the Mac's trackpad preferences. Tap to click is always on: the phone cannot sense a press.
public struct TrackpadSettings: Sendable, Equatable {
    public enum SwipeUse: Sendable, Equatable { case off, pages, spaces }

    public var secondaryClick = true
    public var threeFingerDrag = false
    public var smartZoom = true
    /// Look Up by tapping with three fingers ("Look up & data detectors"). Off when it is set to Force Click,
    /// which needs pressure the phone cannot sense.
    public var lookUpTap = false
    public var notificationCenterEdge = true
    public var threeFingerHorizontal = SwipeUse.off
    public var threeFingerVertical = false
    public var fourFingerHorizontal = true
    public var fourFingerVertical = true
    public var appExpose = true
    public var pinchLaunch = true
    public var zoom = true
    public var rotate = true
    public var scroll = true
    public var horizontalScroll = true
    public var momentum = true
    public var naturalScrolling = true
    /// Multiplier derived from the "Tracking speed" slider.
    public var trackingSpeed = 1.0
    public var doubleClickInterval = 0.5
    /// MTM's own gesture shortcuts, switched in the menu bar; not a Mac trackpad preference.
    public var tipTap = false

    public init() {}
}

/// Thresholds and gains, calibrated against recordings of the built-in trackpad on macOS 27.0 and 27.0.1 (M1).
public struct Tuning: Sendable, Equatable {
    public var tapMaxDuration = 0.25      // s
    public var tapMaxTravel = 2.0         // mm
    public var pointerSlop = 0.5          // mm before the pointer starts moving
    public var scrollStart = 1.0          // mm centroid travel
    public var pinchStart = 1.5           // mm change in finger distance
    public var rotateStart = 2.0          // mm of arc
    public var dragStart = 1.0            // mm, three-finger drag
    public var swipeStart = 3.0           // mm, 3/4-finger swipes
    public var spreadStart = 1.5          // mm, 4/5-finger pinch
    public var pinchShare = 0.5          // 4/5 fingers: a pinch once the spread changes by more than this share of the travel
    public var edgeZone = 6.0             // mm from the right edge
    public var edgeTravel = 4.0           // mm leftwards to open Notification Center
    public var twoTapWindow = 0.3         // s, smart zoom double tap
    public var dragGrace = 0.5            // s, three-finger drag release delay
    public var upgradeWindow = 0.15       // s, extra fingers may still turn a young gesture into another
    public var upgradeTravel = 5.0        // mm
    public var dockScaleH = 66.0          // mm of travel per unit of dock progress
    public var dockScaleV = 66.0
    public var dockScalePinch = 10.0      // mm of mean finger spread per unit
    public var ncScale = 30.0             // mm of travel per unit of Notification Center progress
    public var dockMinInterval = 0.008    // s, WindowServer wants ~one dock event per frame
    // Pointer and scrolling below: fitted to recordings of the built-in trackpad on 2026-10-03.
    public var pointerBase = 2.01         // points per mm at rest, before the tracking-speed multiplier
    public var pointerSlope = 0.117       // extra points per mm for each mm/s of finger speed
    public var pointerMax = 35.3          // (53 points per mm at tracking speed 1.5, reached near 270 mm/s)
    public var scrollBase = 6.0           // points per mm, steady up to scrollKnee
    public var scrollKnee = 300.0         // mm/s
    public var scrollSlope = 0.04         // more points per mm for each mm/s above it
    public var scrollMax = 16.0
    public var scrollRail = 2.0           // a scroll whose first travel is this many times longer along one axis stays on it
    public var magnifyPerMM = 0.0315      // magnification per mm change of finger distance
    public var momentumBase = 5.0         // points per mm of finger speed at lift, where momentum starts:
    public var momentumSlope = 0.05       // more for each mm/s (7 at 40 mm/s, 31 at 630)
    public var momentumMax = 31.5
    public var momentumStartMax = 25000.0 // points/s, the fastest flick recorded
    public var momentumMinSpeed = 60.0    // points/s needed to start momentum
    public var momentumFrame = 1.0 / 60   // s between glide steps, as the built-in trackpad sends them
    public var momentumOpening = 7        // first steps: each this much less than 1 per point of the first step
    public var momentumOpeningLoss = 0.0002 // (a 400-point step loses 8% a step, a slow one keeps its speed)
    public var momentumRatio = 0.918      // then each step is this much of the last
    public var momentumDrag = 0.098       // less this many points,
    public var momentumDecel = 6.3        // losing at most this many points
    public var momentumLastStep = 0.25    // points: the glide ends below this (the exact steps, field 176, not the rounded-up points)
    public var velocityWindow = 0.06      // s of samples used for exit velocity
    public var stallAfter = 0.02          // s without a frame before pointer / scroll motion is carried on
    public var stallTau = 0.04            // s, fade of the carried-on velocity
    public var stallMax = 0.12            // s of carried-on motion at most
    public var tipTapRest = 0.2           // s the other finger must already rest; fingers landing together are a two-finger tap
    public var tipTapSlope = 0.7          // |dy| / |dx| at most (35°): a thumb resting below the tapping finger does not count

    public init() {}
}
