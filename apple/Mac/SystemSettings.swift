import AppKit
import Engine

/// Reads the Mac's own trackpad preferences so the phone behaves like the built-in trackpad.
enum SystemTrackpad {
    static func read() -> TrackpadSettings {
        let tp = UserDefaults(suiteName: "com.apple.AppleMultitouchTrackpad")
        let dock = UserDefaults(suiteName: "com.apple.dock")
        func int(_ d: UserDefaults?, _ key: String, _ fallback: Int) -> Int {
            (d?.object(forKey: key) as? NSNumber)?.intValue ?? fallback
        }
        var s = TrackpadSettings()
        s.secondaryClick = int(tp, "TrackpadRightClick", 1) != 0
        s.threeFingerDrag = int(tp, "TrackpadThreeFingerDrag", 0) != 0
        s.smartZoom = int(tp, "TrackpadTwoFingerDoubleTapGesture", 1) != 0
        s.lookUpTap = int(tp, "TrackpadThreeFingerTapGesture", 0) == 2
        s.notificationCenterEdge = int(tp, "TrackpadTwoFingerFromRightEdgeSwipeGesture", 3) == 3
        s.threeFingerHorizontal = switch int(tp, "TrackpadThreeFingerHorizSwipeGesture", 2) {
        case 1: .pages
        case 2: .spaces
        default: .off
        }
        s.threeFingerVertical = int(tp, "TrackpadThreeFingerVertSwipeGesture", 2) == 2
        s.fourFingerHorizontal = int(tp, "TrackpadFourFingerHorizSwipeGesture", 2) == 2
        s.fourFingerVertical = int(tp, "TrackpadFourFingerVertSwipeGesture", 2) == 2
        s.appExpose = int(dock, "showAppExposeGestureEnabled", 0) != 0
        s.pinchLaunch = int(tp, "TrackpadFourFingerPinchGesture", 2) == 2 || int(tp, "TrackpadFiveFingerPinchGesture", 2) == 2
        s.zoom = int(tp, "TrackpadPinch", 1) != 0
        s.rotate = int(tp, "TrackpadRotate", 1) != 0
        s.scroll = int(tp, "TrackpadScroll", 1) != 0
        s.horizontalScroll = int(tp, "TrackpadHorizScroll", 1) != 0
        s.momentum = int(tp, "TrackpadMomentumScroll", 1) != 0
        s.naturalScrolling = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
        // "Tracking speed" slider 0…3 (default 1) → gain multiplier.
        let scaling = UserDefaults.standard.object(forKey: "com.apple.trackpad.scaling") as? Double ?? 1
        s.trackingSpeed = 0.5 + 0.5 * scaling
        s.doubleClickInterval = NSEvent.doubleClickInterval
        return s
    }
}
