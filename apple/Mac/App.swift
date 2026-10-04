import AppKit
import CoreWLAN
import ServiceManagement

@main
enum Main {
    static let delegate = AppDelegate()

    static func main() {
        // `Palmpad -summarize <recording.jsonl>` prints what the diagnostics window would show for it;
        // with `-timeline` also each gesture and when it was recognised, macOS's in the left column.
        if let i = CommandLine.arguments.firstIndex(of: "-summarize"), i + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            for s in Diagnostics.summary(of: url, settings: Diagnostics.engineSettings()) {
                print(s.text)
                guard CommandLine.arguments.contains("-timeline") else { continue }
                for e in s.timeline {
                    print(String(format: "%8.2f  ", e.t) + (e.system ? e.r.rawValue : "\t\t掌控板 " + e.r.rawValue))
                }
            }
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

/// Menu bar UI in plain AppKit. The menu is rebuilt only when it opens; while it is open only the
/// status line's text changes, so hovering the other rows is never interrupted.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let header = StatusHeaderView()
    private var state = HubState()
    private let diagnostics = DiagnosticsPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        refresh()

        Hub.shared.onState = { [weak self] s in
            self?.state = s
            self?.diagnostics.model.phone = s.device
            self?.refresh()
        }
        Hub.shared.onPairRequest = { name, code, answer in
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "允许「\(name)」控制这台 Mac？"
            alert.informativeText = "请确认手机上显示的确认码与下面一致：\n\n\(code.prefix(3)) \(code.suffix(3))"
            alert.addButton(withTitle: "允许")
            alert.addButton(withTitle: "拒绝")
            answer(alert.runModal() == .alertFirstButtonReturn)
        }
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
        Hub.shared.start()
    }

    private func refresh() {
        header.update(state)
        let symbol = state.device == nil ? "hand.point.up.left" : "hand.point.up.left.fill"
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "掌控板")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium, scale: .large)) else { return }
        image.size = NSSize(width: image.size.width * 16 / image.size.height, height: 16)   // 16 pt tall, proportional width
        statusItem.button?.image = image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem()
        status.view = header
        menu.addItem(status)
        refresh()
        menu.addItem(NSMenuItem(title: Self.wifiLine(), action: nil, keyEquivalent: ""))

        if !CGPreflightPostEventAccess() { menu.addItem(item("授予辅助功能权限…", #selector(grantAccess))) }
        menu.addItem(.separator())

        let paired = NSMenu()
        if state.paired.isEmpty { paired.addItem(NSMenuItem(title: "无", action: nil, keyEquivalent: "")) }
        for p in state.paired {
            let i = item("移除「\(p.name)」", #selector(unpair(_:)))
            i.representedObject = p.id
            paired.addItem(i)
        }
        menu.addItem(submenu("已配对设备", paired))

        let shortcuts = NSMenu()
        let on = item("启用", #selector(toggleTipTap))
        on.state = Hub.shared.tipTap ? .on : .off
        shortcuts.addItem(on)
        shortcuts.addItem(.separator())
        for line in ["一指按住，左侧轻点：⌘W", "一指按住，右侧轻点：⌘Q"] {
            shortcuts.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
        }
        menu.addItem(submenu("手势快捷键", shortcuts))

        menu.addItem(item("手势诊断…", #selector(openDiagnostics)))

        let login = item("登录时启动", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("退出掌控板", #selector(quit)))
    }

    /// The Mac's own Wi-Fi channel: AWDL visits channels 149 and 6, so a network on 149 stalls far less.
    private static func wifiLine() -> String {
        guard let c = CWWiFiClient.shared().interface()?.wlanChannel() else { return "Wi-Fi：未连接" }
        let width = [CWChannelWidth.width20MHz: "20", .width40MHz: "40", .width80MHz: "80", .width160MHz: "160"][c.channelWidth]
        let band = [CWChannelBand.band2GHz: "2.4 GHz", .band5GHz: "5 GHz", .band6GHz: "6 GHz"][c.channelBand]
        return "Wi-Fi：\(c.channelNumber) 信道" + (width.map { " · \($0) MHz" } ?? "") + (band.map { "（\($0)）" } ?? "")
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    // MARK: - Actions

    @objc private func grantAccess() {
        CGRequestPostEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func unpair(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { Hub.shared.unpair(id) }
    }

    @objc private func openDiagnostics() { diagnostics.show() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleTipTap() { Hub.shared.tipTap.toggle() }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }
}

/// Two-line status block at the top of the menu. While the menu is open only its labels and badge
/// colour change, so the menu itself is never rebuilt under the pointer.
final class StatusHeaderView: NSView {
    private let badge = NSView(frame: NSRect(x: 14, y: 10, width: 26, height: 26))
    private let icon = NSImageView(frame: NSRect(x: 5, y: 5, width: 16, height: 16))
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 46))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 13
        icon.contentTintColor = .white
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        badge.addSubview(icon)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 50, y: 23, width: 188, height: 17)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 50, y: 7, width: 188, height: 14)
        for label in [title, detail] {
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ s: HubState) {
        let ms = s.rtt.map { Int(($0 * 1000).rounded()) }
        let color: NSColor
        switch (s.listening, s.device, ms) {
        case (false, _, _):
            title.stringValue = "网络未就绪"
            detail.stringValue = "正在重试…"
            color = .systemOrange
        case (true, nil, _):
            title.stringValue = "未连接"
            detail.stringValue = s.paired.isEmpty ? "在手机上打开掌控板进行配对" : "在手机上打开掌控板即可连接"
            color = .tertiaryLabelColor
        case let (true, device?, ms):
            title.stringValue = device
            detail.stringValue = [s.link, ms.map { "往返 \($0) 毫秒" }].compactMap { $0 }.joined(separator: " · ")
            color = (ms ?? 0) < 15 ? .systemGreen : (ms ?? 0) < 40 ? .systemYellow : .systemOrange
        }
        icon.image = NSImage(systemSymbolName: s.device == nil ? "iphone" : "iphone.radiowaves.left.and.right",
                             accessibilityDescription: nil)
        badge.layer?.backgroundColor = color.cgColor
    }
}
