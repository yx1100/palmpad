import SwiftUI
import UIKit

@main
struct MTMPhoneApp: App {
    @State private var link = Link()
    @Environment(\.scenePhase) private var scenePhase
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some Scene {
        WindowGroup {
            RootView(link: link)
                .preferredColorScheme(.dark)
                .onAppear {
                    link.onFeedback = { [haptic] in haptic.impactOccurred() }
                    #if DEBUG
                    // Lays out the trackpad screen without a paired Mac (simulator UI checks).
                    if CommandLine.arguments.contains("-previewTrackpad") {
                        link.paired = PairedMac(id: UUID(), name: "于信的MacBook Pro", host: nil)
                        // Status updates at the heartbeat rate: the menu must stay usable even unthrottled.
                        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                            if link.phase == .idle || link.phase == .connecting { link.phase = .connected; link.linkName = "Wi-Fi" }
                            link.rtt = .random(in: 0.002...0.009)
                        }
                        if CommandLine.arguments.contains("-previewLandscape") {
                            (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
                                .requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                            if CommandLine.arguments.contains("-previewFlip") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                    (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
                                        .requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft))
                                }
                            }
                        }
                    }
                    #endif
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
                link.start()
            case .background:
                UIApplication.shared.isIdleTimerDisabled = false
                link.stop()
            default: break
            }
        }
    }
}

struct RootView: View {
    let link: Link

    var body: some View {
        switch link.phase {
        case .pairing, .rejected, .needsPairing: PairingView(link: link)
        default:
            if link.paired == nil { PairingView(link: link) } else { TrackpadScreen(link: link) }
        }
    }
}

// MARK: - Trackpad

/// Full-screen trackpad card with two glass pills either side of the Dynamic Island, as thick as the
/// island and on its axis: status (tap to choose a Mac) and settings (a menu to disconnect or open
/// settings). In landscape they stand upright above and below the island.
struct TrackpadScreen: View {
    let link: Link
    @State private var showSettings = false
    @State private var showMacs = false

    var body: some View {
        GeometryReader { geo in
            let l = TrackpadLayout(size: geo.size, orientation: TrackpadLayout.orientation)
            ZStack(alignment: .topLeading) {
                Color.black
                TouchSurface(link: link, card: l.card, radius: l.radius)
                cardHint.allowsHitTesting(false)
                    .frame(width: l.card.width, height: l.card.height)
                    .offset(x: l.card.minX, y: l.card.minY)
                Button { showMacs = true } label: {
                    StatusPill(link: link, vertical: l.vertical).pill(l.first)
                }
                .buttonStyle(.plain)
                .position(x: l.first.midX, y: l.first.midY)
                // Nothing in this menu reads the latency: a menu whose content changes while it is open
                // drops taps on its items.
                Menu {
                    Section(link.paired?.name ?? "") {
                        Button(link.phase == .off ? "重新连接" : "断开连接", systemImage: "power") { link.toggleConnection() }
                        Button("设置与配对", systemImage: "gearshape") { showSettings = true }
                    }
                } label: {
                    PillStack(vertical: l.vertical) {
                        Image(systemName: "gearshape.fill")
                        Text("设置")
                    }
                    .pill(l.second)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("设置")
                .position(x: l.second.midX, y: l.second.midY)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .sheet(isPresented: $showSettings) { SettingsSheet(link: link) }
        .sheet(isPresented: $showMacs) { MacPicker(link: link) }
    }

    @ViewBuilder private var cardHint: some View {
        switch link.phase {
        case .connected: EmptyView()
        case .off: hint("已断开", "在「设置」菜单中重新连接")
        case .replaced: hint("已被其他设备接管", "触摸这里重新连接")
        default: hint("正在连接 \(link.paired?.name ?? "Mac")…", "")
        }
    }

    private func hint(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            if !detail.isEmpty { Text(detail).font(.subheadline) }
        }
        .foregroundStyle(.secondary)
    }
}

/// Status light and link. The light turns yellow on a slow round trip; this is the only view that reads
/// the latency, so its refresh stays here.
struct StatusPill: View {
    let link: Link
    let vertical: Bool

    var body: some View {
        PillStack(vertical: vertical) {
            Circle().fill(color).frame(width: 7, height: 7)
            ForEach(words, id: \.self) { Text($0) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(link.paired?.name ?? "Mac")，\(words.joined(separator: " "))")
    }

    private var words: [String] {
        switch link.phase {
        case .connected:
            [link.linkName == "热点直连" ? "热点" : link.linkName ?? "已连接"]
        case .off: ["已断开"]
        case .replaced: ["已接管"]
        default: ["连接中"]
        }
    }

    private var color: Color {
        switch link.phase {
        case .connected: (link.rtt ?? 0) < 0.03 ? .green : .yellow
        case .off, .replaced: .gray
        default: .orange
        }
    }
}

/// Pill content along the pill's axis: a row in portrait, a column in landscape.
struct PillStack<Content: View>: View {
    let vertical: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 6))
        stack { content }
            .font(.system(size: vertical ? 11 : 13, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.white)
    }
}

extension View {
    func pill(_ r: CGRect) -> some View {
        frame(width: r.width, height: r.height)
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// The scene's interface orientation, observed. A turn from one landscape to the other keeps the
/// screen size, so a size-driven layout alone would leave the pills on the old side.
@Observable
final class InterfaceOrientation {
    static let shared = InterfaceOrientation()
    private(set) var value: UIInterfaceOrientation = .portrait
    @ObservationIgnored private var token: NSKeyValueObservation?

    private init() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        value = scene.effectiveGeometry.interfaceOrientation
        token = scene.observe(\.effectiveGeometry) { [weak self] scene, _ in
            let o = scene.effectiveGeometry.interfaceOrientation
            DispatchQueue.main.async { if self?.value != o { self?.value = o } }
        }
    }
}

/// Screen geometry. The card is inset by the same margin on every side except the one holding the
/// Dynamic Island, and its corners are concentric with the display's; the pills flank the island.
struct TrackpadLayout {
    static let margin: CGFloat = 8
    static let gap: CGFloat = 10   // pill to island
    // ponytail: iPhone 17 Dynamic Island metrics; other models would read them from safe-area insets.
    static let island = CGSize(width: 126, height: 37)
    static let islandInset: CGFloat = 11
    static let displayRadius = (UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 55

    static var orientation: UIInterfaceOrientation { InterfaceOrientation.shared.value }

    let card: CGRect, radius: CGFloat, first: CGRect, second: CGRect, vertical: Bool

    init(size: CGSize, orientation: UIInterfaceOrientation) {
        let m = Self.margin, g = Self.gap, w = size.width, h = size.height
        let t = Self.island.height, half = Self.island.width / 2
        let band = Self.islandInset + t + m   // clear of the island
        switch orientation {
        case .landscapeRight, .landscapeLeft:   // island on the left / right edge
            let left = orientation == .landscapeRight
            let x = left ? Self.islandInset : w - Self.islandInset - t, len: CGFloat = 80
            first = CGRect(x: x, y: h / 2 - half - g - len, width: t, height: len)
            second = CGRect(x: x, y: h / 2 + half + g, width: t, height: len)
            card = CGRect(x: left ? band : m, y: m, width: w - band - m, height: h - 2 * m)
            vertical = true
        default:
            let len: CGFloat = 96
            first = CGRect(x: w / 2 - half - g - len, y: Self.islandInset, width: len, height: t)
            second = CGRect(x: w / 2 + half + g, y: Self.islandInset, width: len, height: t)
            card = CGRect(x: m, y: band, width: w - 2 * m, height: h - band - m)
            vertical = false
        }
        radius = max(Self.displayRadius - m, 12)
    }
}

struct SettingsSheet: View {
    let link: Link
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("当前 Mac") {
                    LabeledContent("名称", value: link.paired?.name ?? "无")
                    if let r = link.rtt { LabeledContent("往返延迟", value: "\(Int((r * 1000).rounded())) 毫秒") }
                    if let l = link.linkName { LabeledContent("连接方式", value: l) }
                }
                Section {
                    Button("取消与这台 Mac 的配对", role: .destructive) {
                        link.forgetMac()
                        dismiss()
                    }
                } footer: {
                    Text("取消配对后，需要在 Mac 上重新确认才能再次连接。")
                }
                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Lists Macs found on this network or hotspot; choosing another one pairs with it.
struct MacPicker: View {
    let link: Link
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if link.macs.isEmpty {
                        HStack { ProgressView(); Text("正在查找 Mac…").foregroundStyle(.secondary) }
                    }
                    ForEach(link.macs) { m in
                        Button {
                            if m.id != link.paired?.id { link.pair(with: m) }
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "laptopcomputer")
                                Text(m.name).foregroundStyle(.primary)
                                Spacer()
                                if m.id == link.paired?.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                } footer: {
                    Text("Mac 需要运行掌控板，并与手机连接同一 Wi-Fi，或连接这台手机的个人热点。选择其他 Mac 会与它重新配对。")
                }
            }
            .navigationTitle("选择 Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Pairing

struct PairingView: View {
    let link: Link

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                    .padding(.top, 48)
                Text("连接到 Mac").font(.largeTitle.bold())
                Text("在 Mac 上运行掌控板，并让手机和 Mac 连接同一 Wi-Fi，或让 Mac 连接这台手机的个人热点。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    if link.macs.isEmpty {
                        HStack(spacing: 10) { ProgressView(); Text("正在查找 Mac…").foregroundStyle(.secondary) }
                            .padding(.vertical, 12)
                    }
                    ForEach(link.macs) { m in
                        Button { link.pair(with: m) } label: {
                            HStack {
                                Image(systemName: "laptopcomputer")
                                Text(m.name).font(.headline)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .overlay { prompt }
    }

    @ViewBuilder private var prompt: some View {
        switch link.phase {
        case .pairing(let code?):
            card("确认码", code.prefix(3) + " " + code.suffix(3), "请核对 Mac 上显示的确认码一致后，在 Mac 上点「允许」。")
        case .pairing(nil): card("正在配对", "", "等待 Mac 响应…")
        case .rejected: card("配对未完成", "", "Mac 拒绝了配对请求。")
        case .needsPairing: card("需要重新配对", "", "这台 Mac 已不再信任本机，请重新选择 Mac 配对。")
        default: EmptyView()
        }
    }

    private func card(_ title: String, _ big: String, _ note: String) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.headline)
            if !big.isEmpty { Text(big).font(.system(size: 44, weight: .semibold, design: .monospaced)) }
            Text(note).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
        .padding(32)
    }
}
