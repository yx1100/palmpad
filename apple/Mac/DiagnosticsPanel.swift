import AppKit
import SwiftUI

/// One gesture at a time: record it on the built-in trackpad or the phone, see what macOS and MTM recognised,
/// and inject it to check MTM's output. "All gestures" records them one after another, as a full calibration.
@Observable
final class DiagnosticsModel {
    static let everything = "all"
    enum Phase: Equatable { case idle, countdown(Int), recording }
    /// The saved recording of the selected gesture from one source; `steps` is nil while it is being analysed.
    struct Saved { let source: Diagnostics.Source; let url: URL; let date: Date; var steps: [Diagnostics.StepSummary]? }

    var selected = "launchpad" { didSet { reload() } }
    var phase = Phase.idle
    var index = 0
    var elapsed = 0
    var phone: String?   // connected phone, set by the menu bar app
    var saved: [Saved] = []
    var route = Injector.Route.hid { didSet { Diagnostics.shared.route = route } }
    @ObservationIgnored private var timer: Timer?

    var steps: [GestureCheck] { selected == Self.everything ? GestureCheck.all : GestureCheck.all.filter { $0.id == selected } }
    var step: GestureCheck { steps[min(index, steps.count - 1)] }

    func record(_ source: Diagnostics.Source) {
        index = 0
        elapsed = 0
        phase = .countdown(3)
        tick { [weak self] in
            guard let self, case .countdown(let n) = phase else { return }
            if n > 1 { return phase = .countdown(n - 1) }
            Diagnostics.shared.startRecording(selected, from: source)
            Diagnostics.shared.mark(step: 0, key: step.id)
            phase = .recording
            tick { [weak self] in self?.elapsed += 1 }
        }
    }

    func next() {
        guard phase == .recording else { return }
        if index == steps.count - 1 { return finish() }
        index += 1
        Diagnostics.shared.mark(step: index, key: step.id)
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        Diagnostics.shared.stopRecording()
        phase = .idle
        reload()
    }

    /// Lists the selected gesture's recordings and replays each through today's engine, so a recording made
    /// before a fix shows whether the fix took.
    func reload() {
        let gesture = selected
        saved = Diagnostics.Source.allCases.compactMap { source in
            let url = Diagnostics.shared.file(gesture, source)
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return Saved(source: source, url: url, date: date)
        }
        let settings = Diagnostics.engineSettings()
        for i in saved.indices {
            let url = saved[i].url
            DispatchQueue.global(qos: .userInitiated).async {
                let steps = Diagnostics.summary(of: url, settings: settings)
                DispatchQueue.main.async {
                    guard self.selected == gesture, i < self.saved.count, self.saved[i].url == url else { return }
                    self.saved[i].steps = steps
                }
            }
        }
    }

    func cancel() {
        if phase == .recording { return finish() }
        timer?.invalidate()
        timer = nil
        if case .countdown = phase { phase = .idle }
    }

    private func tick(_ body: @escaping () -> Void) {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { _ in body() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

struct DiagnosticsView: View {
    @Bindable var model: DiagnosticsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("手势", selection: $model.selected) {
                ForEach(GestureCheck.all) { Text($0.title).tag($0.id) }
                Divider()
                Text("全部手势（依次录制）").tag(DiagnosticsModel.everything)
            }
            .disabled(model.phase != .idle)
            recording
            if model.phase == .idle, model.selected != DiagnosticsModel.everything, !model.step.tests.isEmpty { tests }
            if model.phase == .idle { Divider(); recordings }
            Spacer(minLength: 0)
            Divider()
            Button("打开日志文件夹") { NSWorkspace.shared.open(Diagnostics.shared.dir) }
        }
        .padding(20)
        .frame(width: 440, height: 480, alignment: .topLeading)
    }

    @ViewBuilder private var recording: some View {
        let several = model.steps.count > 1
        switch model.phase {
        case .idle:
            Text(several ? "依次完成 \(model.steps.count) 组手势，每组做完点「下一步」或按空格键。" : model.step.detail)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("在触控板上录制") { model.record(.trackpad) }
                Button("在手机上录制") { model.record(.phone) }.disabled(model.phone == nil)
                Text(model.phone.map { "手机：\($0)" } ?? "手机未连接").foregroundStyle(.secondary)
            }
        case .countdown(let n):
            Text("\(n) 秒后开始录制，请把手放到触控板或手机上。").font(.title3)
        case .recording:
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text("正在录制 · \(model.elapsed) 秒").monospacedDigit()
                Spacer()
                if several { Text("第 \(model.index + 1) 组，共 \(model.steps.count) 组").foregroundStyle(.secondary) }
            }
            Text(model.step.title).font(.title3.bold())
            Text(model.step.detail).fixedSize(horizontal: false, vertical: true)
            HStack {
                if several { Button("结束录制") { model.finish() } }
                Spacer()
                Button(model.index == model.steps.count - 1 ? "完成" : "下一步") { model.next() }
                    .keyboardShortcut(.space, modifiers: [])
            }
        }
    }

    /// The latest trackpad and phone recording of the selected gesture, analysed with today's engine.
    private var recordings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.saved.isEmpty { Text("这个手势还没有录制。").foregroundStyle(.secondary) }
                ForEach(model.saved, id: \.url) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(r.source == .trackpad ? "触控板录制" : "手机录制").bold()
                            Text(r.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                            Spacer()
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
                        }
                        if let steps = r.steps {
                            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                                VStack(alignment: .leading, spacing: 2) {
                                    if steps.count > 1 { Text(s.title).font(.callout.bold()) }
                                    if let system = s.system { line("系统识别", system, s.key) }
                                    line(s.system == nil ? "掌控板识别" : "掌控板识别同样的触摸", s.mtm, s.key)
                                }
                            }
                        } else {
                            ProgressView("正在分析…").controlSize(.small)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Counts per gesture; gestures the selected one should not produce are orange (clicks never are: the
    /// buttons of this panel get clicked too).
    private func line(_ who: String, _ counts: [Recognized: Int], _ key: String) -> Text {
        let expected = GestureCheck.find(key)?.expected ?? []
        let parts = Recognized.allCases.compactMap { r in counts[r].map { (r, $0) } }
        guard !parts.isEmpty else { return Text("\(who)：未识别到手势").foregroundStyle(.secondary) }
        return parts.enumerated().reduce(Text("\(who)：")) { text, e in
            let (r, n) = e.element
            let odd = !expected.isEmpty && !expected.contains(r) && r != .click
            return text + Text(e.offset == 0 ? "" : "、") + Text("\(r.rawValue) \(n)").foregroundStyle(odd ? Color.orange : Color.primary)
        }
    }

    private var tests: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("注入测试：2 秒后由掌控板发出这个手势，检查 macOS 有没有响应。").foregroundStyle(.secondary)
            HStack {
                ForEach(model.step.tests, id: \.name) { test in
                    Button(test.name) { Diagnostics.shared.inject(test.frames) }
                }
                Spacer()
                Picker("", selection: $model.route) {
                    Text("IOHIDEvent").tag(Injector.Route.hid)
                    Text("系统快捷键").tag(Injector.Route.keys)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }
}

/// Floating panel that stays visible across Spaces and over Mission Control while recording.
final class DiagnosticsPanel: NSObject, NSWindowDelegate {
    let model = DiagnosticsModel()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 480), styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
            p.title = "掌控板手势诊断"
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.delegate = self
            p.contentView = NSHostingView(rootView: DiagnosticsView(model: model))
            if let screen = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: screen.maxX - p.frame.width - 24, y: screen.maxY - 24))
            }
            panel = p
        }
        model.reload()
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.cancel()   // closing mid-recording still saves what was captured
    }
}
