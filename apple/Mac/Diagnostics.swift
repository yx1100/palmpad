import AppKit
import Engine

/// A gesture as recognised in a recording, by macOS or by MTM's engine.
enum Recognized: String, CaseIterable {
    case tipLeft = "左侧轻点", tipRight = "右侧轻点", click = "点按", rightClick = "右键", drag = "拖移"
    case scroll = "双指滚动", zoom = "双指缩放", rotate = "双指旋转", smartZoom = "智能缩放", notificationCenter = "通知中心"
    case spaces = "四指左右滑", missionControl = "四指上推", appExpose = "四指下拉", pinchIn = "捏合", spread = "张开"
    case pages = "翻页", forceClick = "用力点按"
}

/// One gesture to record, check and inject on its own. `id` names the recording file and its step marker.
struct GestureCheck: Identifiable {
    let id: String, title: String, detail: String
    let expected: Set<Recognized>
    var tests: [(name: String, frames: [[Action]])] = []

    static func find(_ id: String) -> GestureCheck? { all.first { $0.id == id } }

    static let all: [GestureCheck] = [
        GestureCheck(id: "tipTap", title: "一指按住，另一指轻点（⌘W、⌘Q）",
                     detail: "先点一下桌面空白处，让访达在最前面，这样 ⌘W、⌘Q 不会关掉别的应用。一根手指按住不动，另一根手指在它左侧、右侧各轻点几次。",
                     expected: [.tipLeft, .tipRight]),
        GestureCheck(id: "pointer", title: "单指移动与轻点", detail: "用一根手指移动光标，慢速和快速各来几次，再轻点几下。",
                     expected: [.click]),
        GestureCheck(id: "scroll", title: "双指滚动",
                     detail: "在网页或文稿上两指上下滚动：先慢慢滚，再快速轻扫后立即抬手，让页面借惯性继续滑动。", expected: [.scroll]),
        GestureCheck(id: "pinch", title: "双指缩放", detail: "在 Safari 网页或「预览」图片上两指张开放大，再捏合缩小。", expected: [.zoom],
                     tests: [("放大", ramp(.magnify(0, .began), .magnify(0.03, .changed), .magnify(0, .ended))),
                             ("缩小", ramp(.magnify(0, .began), .magnify(-0.03, .changed), .magnify(0, .ended)))]),
        GestureCheck(id: "rotate", title: "双指旋转", detail: "在「地图」或「预览」图片上两指按住后转动。", expected: [.rotate],
                     tests: [("旋转", ramp(.rotate(0, .began), .rotate(3, .changed), .rotate(0, .ended)))]),
        GestureCheck(id: "smartZoom", title: "智能缩放", detail: "在 Safari 网页上两指轻点两下放大，再轻点两下恢复。", expected: [.smartZoom],
                     tests: [("智能缩放", [[.smartZoom]])]),
        GestureCheck(id: "notificationCenter", title: "通知中心", detail: "两指从右边缘向左轻扫打开通知中心，再向右轻扫关闭。",
                     expected: [.notificationCenter], tests: [("通知中心", notificationCenterFrames)]),
        GestureCheck(id: "drag", title: "三指拖移",
                     detail: "三指按住一个窗口的标题栏拖动，松开后再放下，来回几次。需要在系统设置里开启三指拖移。", expected: [.drag]),
        GestureCheck(id: "spaces", title: "四指左右滑（切换空间）", detail: "四指向左轻扫，再向右轻扫回来。", expected: [.spaces],
                     tests: [("右侧空间", dock(.horizontal, 1)), ("左侧空间", dock(.horizontal, -1))]),
        GestureCheck(id: "missionControl", title: "四指上推（调度中心）", detail: "四指向上推打开调度中心，再按 Esc 退出。",
                     expected: [.missionControl], tests: [("调度中心", dock(.vertical, -1))]),
        GestureCheck(id: "appExpose", title: "四指下拉（App Exposé）", detail: "四指向下拉显示当前应用的所有窗口，再按 Esc 退出。",
                     expected: [.appExpose], tests: [("App Exposé", dock(.vertical, 1))]),
        GestureCheck(id: "launchpad", title: "捏合与张开（启动台、显示桌面）",
                     detail: "拇指和三指捏合打开启动台，再张开退出；接着拇指和三指张开显示桌面，再捏合恢复。", expected: [.pinchIn, .spread],
                     tests: [("启动台", dock(.pinch, -1)), ("显示桌面", dock(.pinch, 1))]),
        GestureCheck(id: "navigate", title: "三指左右轻扫（翻页）",
                     detail: "需要在系统设置里把「在页面之间轻扫」设为三指。在 Safari 里三指向左、向右轻扫翻页。", expected: [.pages],
                     tests: [("后退", [[.navigate(back: true)]]), ("前进", [[.navigate(back: false)]])]),
        GestureCheck(id: "forceClick", title: "用力点按（查询）",
                     detail: "在网页的一个单词上用力按下，直到弹出查询窗口，然后按 Esc 关闭。手机感知不到按压力度，只能在触控板上录制。",
                     expected: [.forceClick], tests: [("查询", [[.forceClick]])]),
    ]
}

// Synthesized gestures for the injection tests, one frame every 8 ms.
private func ramp(_ begin: Action, _ step: Action, _ end: Action) -> [[Action]] {
    [[begin]] + Array(repeating: [step], count: 30) + [[end]]
}

private func dock(_ k: DockKind, _ target: Double) -> [[Action]] {
    let n = 30
    return [[.dock(k, progress: target / Double(n), phase: .began, velocity: 0)]]
        + (2...n).map { [.dock(k, progress: target * Double($0) / Double(n), phase: .changed, velocity: 0)] }
        + [[.dock(k, progress: target, phase: .ended, velocity: target / 0.1)]]   // a quick finish, as fingers end
}

private let notificationCenterFrames: [[Action]] =
    [[.notificationCenter(progress: 0.03, phase: .began, velocity: 0, closing: false)]]
    + (2...30).map { [.notificationCenter(progress: Double($0) / 30, phase: .changed, velocity: 0, closing: false)] }
    + [[.notificationCenter(progress: 1, phase: .ended, velocity: 5, closing: false)]]

/// Records gestures, summarises recordings and injects synthesized gestures. Recording and injection run on the
/// main thread; `summary(of:settings:)` runs anywhere.
final class Diagnostics {
    static let shared = Diagnostics()
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MTM")
    var route = Injector.Route.hid

    enum Source: String, CaseIterable { case trackpad, phone }

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var mtToken: Int32 = 0
    private var file: FileHandle?
    private let io = DispatchQueue(label: "mtm.record")
    private let injector = Injector(queue: .main)
    private(set) var recordingURL: URL?

    /// The settings MTM's engine runs with, for summaries.
    static func engineSettings() -> TrackpadSettings {
        var s = SystemTrackpad.read()
        s.tipTap = Hub.shared.tipTap
        return s
    }

    // MARK: Recording

    /// Only the latest recording of each gesture and source is kept: a new one overwrites it.
    func file(_ gesture: String, _ source: Source) -> URL {
        dir.appendingPathComponent("diag-\(gesture)-\(source.rawValue).jsonl")
    }

    /// Starts a new JSONL file. A trackpad recording holds the raw contacts and the events macOS makes of them;
    /// a phone recording holds the touch frames of the phone session and the actions MTM performed.
    @discardableResult
    func startRecording(_ gesture: String, from source: Source) -> URL {
        if let url = recordingURL { return url }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = file(gesture, source)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        io.sync { file = try? FileHandle(forWritingTo: url) }
        recordingURL = url

        var meta: [String: Any] = ["k": "meta", "source": source.rawValue, "gesture": gesture,
                                   "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                   "settings": "\(Self.engineSettings())"]
        switch source {
        case .phone:
            Hub.shared.record { [weak self] frame, actions in
                if let frame { self?.write(Self.encode(frame)) }
                if !actions.isEmpty { self?.write(["k": "act", "t": now(), "a": actions.map { "\($0)" }]) }
            }
        case .trackpad:
            _ = CGRequestListenEventAccess()
            var w = 0.0, h = 0.0
            mtToken = MTMStartMultitouch({ [weak self] ts, contacts in
                self?.write(["k": "mt", "t": now(), "ts": ts, "c": contacts])
            }, &w, &h)
            meta["multitouch"] = mtToken != 0
            meta["width"] = w
            meta["height"] = h
            tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                    eventsOfInterest: .max, callback: { _, type, event, info in
                Unmanaged<Diagnostics>.fromOpaque(info!).takeUnretainedValue().log(type, event)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            if let tap {
                tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                meta["error"] = "event tap unavailable (grant Accessibility / Input Monitoring)"
            }
        }
        write(meta)
        Log.write("recording started: \(url.lastPathComponent)")
        return url
    }

    /// Marks the start of a step so a recording of several gestures can be split by gesture.
    func mark(step: Int, key: String) {
        write(["k": "step", "i": step, "key": key, "t": now()])
    }

    @discardableResult
    func stopRecording() -> URL? {
        guard let url = recordingURL else { return nil }
        Hub.shared.record(nil)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        if mtToken != 0 { MTMStopMultitouch(mtToken) }
        mtToken = 0
        recordingURL = nil
        io.sync {
            try? file?.close()
            file = nil
        }
        Log.write("recording saved: \(url.lastPathComponent)")
        return url
    }

    private func log(_ type: CGEventType, _ e: CGEvent) {
        let raw = type.rawValue
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard (1...6).contains(raw) || raw == 22 || raw >= 29 else { return }   // mouse, scroll, gestures
        var rec: [String: Any] = ["k": "ev", "t": now(), "ts": e.timestamp, "cg": raw,
                                  "x": e.location.x, "y": e.location.y]
        var fields: [String: Any] = [:]
        for i in 0..<200 {
            let f = CGEventField(rawValue: UInt32(i))!
            let n = e.getIntegerValueField(f), d = e.getDoubleValueField(f)
            if d != 0 && d != Double(n) { fields["\(i)"] = d } else if n != 0 { fields["\(i)"] = n }
        }
        rec["f"] = fields
        if raw == 22 || raw >= 29, let hid = MTMDescribeHIDEvent(e) { rec["hid"] = hid }
        write(rec)
    }

    private func write(_ rec: [String: Any]) {
        io.async { [weak self] in
            guard let self, let file, JSONSerialization.isValidJSONObject(rec),
                  let data = try? JSONSerialization.data(withJSONObject: rec) else { return }
            file.write(data + Data([0x0A]))
        }
    }

    /// Points are [id, x, y, t] in mm and seconds; moves are [id, x, y].
    private static func encode(_ d: TouchDelta) -> [String: Any] {
        let points = { (ps: [TouchPoint]) in ps.map { [Double($0.id), $0.p.x, $0.p.y, $0.t] } }
        return ["k": "ph", "t": d.t, "w": d.surface.x, "h": d.surface.y, "b": points(d.began), "e": points(d.ended),
                "m": d.moved.map { [Double($0.key), $0.value.x, $0.value.y] }]
    }

    private static func decode(_ r: [String: Any], _ t: Double) -> TouchDelta {
        var d = TouchDelta(t: t, surface: P(r["w"] as? Double ?? 0, r["h"] as? Double ?? 0))
        let points = { (k: String) in (r[k] as? [[Double]] ?? []).map { TouchPoint(UInt8($0[0]), P($0[1], $0[2]), $0[3]) } }
        d.began = points("b")
        d.ended = points("e")
        for m in r["m"] as? [[Double]] ?? [] { d.moved[UInt8(m[0])] = P(m[1], m[2]) }
        return d
    }

    // MARK: Injection

    /// Posts a synthesized gesture through the injector MTM uses, two seconds from now.
    func inject(_ frames: [[Action]]) {
        injector.gestureRoute = route
        injector.dockRoute = route
        injector.naturalScrolling = SystemTrackpad.read().naturalScrolling
        let inj = injector
        for (i, actions) in frames.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(i) * 0.008) { actions.forEach(inj.perform) }
        }
    }

    // MARK: Summary

    /// What one step of a recording shows: the gestures macOS recognised (trackpad recordings only) and the ones
    /// MTM's engine recognises in the same touches today.
    struct StepSummary {
        let key: String
        let system: [Recognized: Int]?
        let mtm: [Recognized: Int]
        /// Every recognised gesture in time order, seconds from the recording's start; `system` marks macOS's.
        let timeline: [(t: Double, system: Bool, r: Recognized)]

        var title: String { GestureCheck.find(key)?.title ?? key }
        var text: String {
            func list(_ c: [Recognized: Int]) -> String {
                let parts = Recognized.allCases.compactMap { r in c[r].map { "\(r.rawValue) \($0)" } }
                return parts.isEmpty ? "未识别到手势" : parts.joined(separator: "、")
            }
            return "\(title)\n" + (system.map { "  系统：\(list($0))\n" } ?? "") + "  掌控板：\(list(mtm))"
        }
    }

    static func summary(of url: URL, settings: TrackpadSettings) -> [StepSummary] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var size = P.zero, gesture = ""
        var contacts: [(t: Double, c: [[NSNumber]])] = [], deltas: [TouchDelta] = []
        var steps: [(t: Double, key: String)] = []
        var native = NativeLabels(), sawEvents = false
        for line in text.split(separator: "\n") {
            guard let r = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let t = r["t"] as? Double ?? 0
            switch r["k"] as? String {
            case "meta":
                size = P(r["width"] as? Double ?? 0, r["height"] as? Double ?? 0)
                gesture = r["gesture"] as? String ?? ""
            case "step": steps.append((t, r["key"] as? String ?? ""))
            case "mt": contacts.append((t, r["c"] as? [[NSNumber]] ?? []))
            case "ph": deltas.append(decode(r, t))
            case "ev":
                sawEvents = true
                native.add(r["cg"] as? Int ?? 0, r["f"] as? [String: Any] ?? [:], t)
            default: break
            }
        }
        var frames = ContactFrames(size: size)   // the sensor size is only known from the meta record
        deltas += contacts.map { frames.delta($0.c, $0.t) }

        var engine = GestureEngine(settings: settings), labels = EngineLabels()
        var clock = deltas.first?.t ?? 0
        func tick() {
            clock += 1.0 / 120
            for a in engine.tick(clock) { labels.add(a, clock) }
        }
        for d in deltas {
            while engine.needsTick, clock + 1.0 / 120 < d.t { tick() }
            for a in engine.handle(d) { labels.add(a, d.t) }
            clock = d.t
        }
        for _ in 0..<240 where engine.needsTick { tick() }   // timers left running: right click, drag release

        if steps.isEmpty { steps = [(0, gesture)] }
        let start = deltas.first?.t ?? 0
        return steps.indices.map { i in
            let from = steps[i].t, to = i + 1 < steps.count ? steps[i + 1].t : .infinity
            func count(_ found: [(t: Double, r: Recognized)]) -> [Recognized: Int] {
                found.filter { $0.t >= from && $0.t < to }.reduce(into: [:]) { $0[$1.r, default: 0] += 1 }
            }
            let timeline = (native.found.map { ($0.t, true, $0.r) } + labels.found.map { ($0.t, false, $0.r) })
                .filter { $0.0 >= from && $0.0 < to }.sorted { $0.0 < $1.0 }.map { (t: $0.0 - start, system: $0.1, r: $0.2) }
            return StepSummary(key: steps[i].key, system: sawEvents ? count(native.found) : nil, mtm: count(labels.found),
                               timeline: timeline)
        }
    }
}

/// Gestures in the actions of MTM's engine.
private struct EngineLabels {
    var found: [(t: Double, r: Recognized)] = []
    private var left = false, dragged = false

    mutating func add(_ a: Action, _ t: Double) {
        var r: Recognized?
        switch a {
        case let .dock(k, p, phase, _) where phase == .ended || phase == .cancelled:
            switch k {
            case .horizontal: r = .spaces
            case .vertical: r = p < 0 ? .missionControl : .appExpose
            case .pinch: r = p < 0 ? .pinchIn : .spread
            }
        case .magnify(_, .began): r = .zoom
        case .rotate(_, .began): r = .rotate
        case .smartZoom: r = .smartZoom
        case .scroll(_, _, .began): r = .scroll
        case .notificationCenter(_, .began, _, _): r = .notificationCenter
        case .navigate: r = .pages
        case .forceClick: r = .forceClick
        case let .tipTap(isLeft): r = isLeft ? .tipLeft : .tipRight
        case .button(.right, down: true, clicks: _): r = .rightClick
        case .button(.left, down: true, clicks: _):
            left = true
            dragged = false
        case .move: if left { dragged = true }
        case .button(.left, down: false, clicks: _):
            if left { r = dragged ? .drag : .click }
            left = false
        default: break
        }
        if let r { found.append((t, r)) }
    }
}

/// Gestures in the events macOS made of the built-in trackpad, from the recorded CGEvent fields: 110 subtype,
/// 123 dock motion, 124 progress, 132 phase, 143 force stage, 99 scroll phase. Native dock progress is negative
/// for Mission Control and positive for a pinch in.
private struct NativeLabels {
    var found: [(t: Double, r: Recognized)] = []
    private var motion = 0, progress = 0.0, left = false, dragged = false, forced = false, scrolling = false

    mutating func add(_ cg: Int, _ f: [String: Any], _ t: Double) {
        func int(_ k: String) -> Int { (f[k] as? NSNumber)?.intValue ?? 0 }
        let phase = int("132")
        var r: Recognized?
        switch cg {
        case 1:
            left = true
            dragged = false
            forced = false
        case 6: if left { dragged = true }
        case 2:
            if left, !forced { r = dragged ? .drag : .click }
            left = false
        case 3: r = .rightClick
        case 22:   // a scroll that follows another one quickly starts without a began phase, but always ends
            switch int("99") {
            case 1, 2: scrolling = true
            case 4, 8:
                if scrolling { r = .scroll }
                scrolling = false
            default: break
            }
        case 29:
            switch int("110") {
            case 8 where phase == 1: r = .zoom
            case 5 where phase == 1: r = .rotate
            case 22: r = .smartZoom
            case 16 where phase == 1: r = .pages
            case 32 where int("143") == 2 && !forced:
                forced = true
                r = .forceClick
            default: break
            }
        case 30:
            if phase == 1 {
                motion = int("123")
                progress = 0
            }
            if let p = (f["124"] as? NSNumber)?.doubleValue, p != 0 { progress = p }
            if phase == 4 || phase == 8 {
                switch motion {
                case 1: r = .spaces
                case 2: r = progress < 0 ? .missionControl : .appExpose
                default: r = progress > 0 ? .pinchIn : .spread
                }
            }
        case 31 where phase == 1: r = .notificationCenter
        default: break
        }
        if let r { found.append((t, r)) }
    }
}
