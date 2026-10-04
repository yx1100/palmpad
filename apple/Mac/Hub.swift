import AppKit
import CryptoKit
import Engine
import Network
import SystemConfiguration
import Wire

struct PairedPhone: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
}

/// Snapshot for the menu bar UI.
struct HubState: Equatable {
    var listening = false
    var device: String?
    /// How the phone reaches us: "Wi-Fi", "手机热点直连", "局域网" (Mac on a wired network) or "有线（USB）".
    var link: String?
    var rtt: Double?
    var paired: [PairedPhone] = []
}

/// Where a packet came from and how to answer: a UDP flow, or the USB stream to a cabled iPhone.
final class Peer: CustomStringConvertible {
    let udp: NWConnection?
    let send: (Data) -> Void
    init(udp: NWConnection) { self.udp = udp; send = { udp.send(content: $0, completion: .idempotent) } }
    init(send: @escaping (Data) -> Void) { udp = nil; self.send = send }
    var description: String { udp.map { "\($0.endpoint)" } ?? "USB" }
}

/// UDP server, pairing, sessions and the touch → gesture → event pipeline. Everything runs on `q`.
final class Hub {
    static let shared = Hub()

    let q = DispatchQueue(label: "mtm.hub", qos: .userInteractive)
    let macID: UUID = {
        if let s = UserDefaults.standard.string(forKey: "macID"), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "macID")
        return id
    }()
    let macName = Host.current().localizedName ?? "Mac"
    /// Called on the main queue.
    var onState: ((HubState) -> Void)?
    /// Asks the user to approve a pairing; called on the main queue, answer on any queue.
    var onPairRequest: ((_ phone: String, _ code: String, _ answer: @escaping (Bool) -> Void) -> Void)?

    private var listener: NWListener?
    private var flows: [ObjectIdentifier: (peer: Peer, last: Double)] = [:]
    private var usb: USBLink?
    private var beacon: (host: String, conn: NWConnection)?
    private var timer: DispatchSourceTimer?
    private var ticker: DispatchSourceTimer?
    private var ticks = 0
    private var pairing: PendingPairing?
    private var candidates: [UInt32: Session] = [:]
    private var active: Session?
    private var engine = GestureEngine()
    private lazy var injector = Injector(queue: q)
    private var activity: NSObjectProtocol?
    private var lastState = HubState()
    private var shownRTT: Double?   // refreshed once a second so the menu stays readable
    /// Gesture shortcuts, switched in the menu bar (off by default); a change reaches the running session too.
    var tipTap: Bool {
        get { UserDefaults.standard.bool(forKey: "tipTap") }
        set {
            UserDefaults.standard.set(newValue, forKey: "tipTap")
            q.async { [self] in
                engine.settings.tipTap = newValue
                if newValue { trackpad.start() } else { trackpad.stop() }
            }
        }
    }
    private lazy var trackpad = BuiltInTrackpad(queue: q) { [weak self] left in self?.injector.perform(.tipTap(left: left)) }
    private var recorder: ((TouchDelta?, [Action]) -> Void)?

    /// Diagnostics: hands each touch frame of the phone session, and every action performed, to `sink` while set.
    func record(_ sink: ((_ frame: TouchDelta?, _ actions: [Action]) -> Void)?) {
        q.async { [self] in recorder = sink }
    }
    private var listenerState = "setup"
    private var bonjour = "none"
    fileprivate var routers: (at: Double, set: Set<String>) = (0, [])

    fileprivate final class Session {
        let sid: UInt32, phoneID: UUID, name: String, phoneNonce: Data, ack: Data, created: Double
        var channel: SecureChannel
        var conn: Peer
        var lastRecv: Double
        var clock = ClockSync()
        var hbClock = ClockSync()   // heartbeats carry send time, frames touch time: keep their offsets apart
        var hbDelays: [Double] = [], frameDelays: [Double] = []   // arrival later than the best seen, for the log
        var tracker = TouchTracker()
        var peerT: UInt64 = 0, peerAt = 0.0
        var rtt: Double?

        init(sid: UInt32, phoneID: UUID, name: String, phoneNonce: Data, ack: Data, channel: SecureChannel, conn: Peer, now: Double) {
            self.sid = sid; self.phoneID = phoneID; self.name = name; self.phoneNonce = phoneNonce; self.ack = ack
            self.channel = channel; self.conn = conn; lastRecv = now; created = now
        }
    }

    private struct PendingPairing {
        let phoneID: UUID, phoneName: String, phonePublic: Data, started: Double
        let key = P256.KeyAgreement.PrivateKey()
        let macNonce = randomBytes(16)
        var phoneNonce: Data?
        var pairKey: Data?
        var code: String?
        var decision: Bool?
        var prompted = false
    }

    // MARK: - Lifecycle

    func start() {
        q.async { [self] in
            startListener()
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.housekeeping() }
            t.resume()
            timer = t
            publish()
            let link = USBLink { [weak self] data, peer in self?.q.async { self?.handle(data, from: peer) } }
            link.start()
            usb = link
            if tipTap { trackpad.start() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.q.async {
                self?.restartListener()
                self?.trackpad.restart()
            }
        }
    }

    private func startListener() {
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do {
            l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Wire.port)!)
        } catch {
            Log.write("listener create failed: \(error)")
            q.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startListener() }
            return
        }
        l.service = NWListener.Service(name: macName, type: Wire.bonjourType, domain: nil,
                                       txtRecord: NWTXTRecord(["id": macID.uuidString]))
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.serviceRegistrationUpdateHandler = { [weak self] change in
            Log.write("bonjour \(change)")
            if case .add = change { self?.bonjour = "registered" } else { self?.bonjour = "removed" }
        }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            listenerState = "\(state)"
            Log.write("listener \(state)")
            switch state {
            case .ready: publish()
            case .failed, .cancelled: q.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restartListener() }
            default: break
            }
        }
        l.start(queue: q)
        listener = l
    }

    private func restartListener() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        beacon?.conn.cancel()
        beacon = nil
        startListener()
    }

    private func accept(_ c: NWConnection) {
        flows[ObjectIdentifier(c)] = (Peer(udp: c), now())
        c.start(queue: q)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                flows[ObjectIdentifier(c)]?.last = now()
                handle(data, from: flows[ObjectIdentifier(c)]?.peer ?? Peer(udp: c))
            }
            if error == nil { receive(c) } else { flows[ObjectIdentifier(c)] = nil; c.cancel() }
        }
    }

    // MARK: - Packets

    private func handle(_ data: Data, from c: Peer) {
        guard let h = Header(packet: data) else { return }
        if h.type.encrypted { return handleSession(data, h, c) }
        guard let (_, m) = Packet.open(data) else { return }
        switch m {
        case let .pairRequest(id, pub, name): pairRequest(id, pub, name, c)
        case let .pairNonce(id, n): pairNonce(id, n, c)
        case let .hello(id, n, _): hello(data, id, n, c)
        default: break
        }
    }

    private func handleSession(_ data: Data, _ h: Header, _ c: Peer) {
        guard let s = active?.sid == h.sid ? active : candidates[h.sid], let m = s.channel.open(data) else { return }
        let t = now()
        s.lastRecv = t
        s.conn = c   // roaming: reply wherever the phone is now
        if s !== active { activate(s) }
        switch m {
        case .frame(let f):
            s.clock.observe(phone: Double(f.t) / 1e6, local: t)
            s.frameDelays.append(t - s.clock.local(Double(f.t) / 1e6))
            let d = s.tracker.apply(f, clock: s.clock)
            recorder?(d, [])
            perform(engine.handle(d))
        case .heartbeat(let hb):
            s.hbClock.observe(phone: Double(hb.t) / 1e6, local: t)
            s.hbDelays.append(t - s.hbClock.local(Double(hb.t) / 1e6))
            s.peerT = hb.t
            s.peerAt = t
            if hb.echoT != 0 { s.rtt = t - Double(hb.echoT) / 1e6 - Double(hb.echoHold) / 1e6 }
        case .bye: end(s)
        default: break
        }
    }

    // MARK: - Pairing

    private func pairRequest(_ id: UUID, _ pub: Data, _ name: String, _ c: Peer) {
        let t = now()
        if let p = pairing, t - p.started < 120 {
            if p.phoneID == id && p.phonePublic == pub { return sendCommit(p, c) }   // retransmission
            if p.prompted && p.decision == nil { return }                          // a prompt is already open
        }
        let p = PendingPairing(phoneID: id, phoneName: name, phonePublic: pub, started: t)
        pairing = p
        Log.write("pair request from \(name) \(id)")
        sendCommit(p, c)
    }

    private func sendCommit(_ p: PendingPairing, _ c: Peer) {
        let pubM = Pairing.publicKey(p.key)
        let commit = Pairing.commitment(macPublic: pubM, phonePublic: p.phonePublic, macNonce: p.macNonce)
        send(Packet.plain(.pairCommit(macID: macID, publicKey: pubM, commitment: commit, name: macName)), c)
    }

    private func pairNonce(_ id: UUID, _ n: Data, _ c: Peer) {
        guard var p = pairing, p.phoneID == id, now() - p.started < 120 else { return }
        if p.phoneNonce == nil {
            guard let shared = try? Pairing.shared(p.key, peer: p.phonePublic) else { return }
            let pubM = Pairing.publicKey(p.key)
            p.phoneNonce = n
            p.pairKey = Pairing.pairKey(shared: shared, phonePublic: p.phonePublic, macPublic: pubM, phoneNonce: n, macNonce: p.macNonce)
            p.code = Pairing.code(phonePublic: p.phonePublic, macPublic: pubM, phoneNonce: n, macNonce: p.macNonce)
        }
        guard p.phoneNonce == n, let key = p.pairKey, let code = p.code else { return }
        if let ok = p.decision {
            send(Packet.plain(.pairDone(accepted: ok, tag: Pairing.doneTag(pairKey: key, accepted: ok))), c)
        } else {
            send(Packet.plain(.pairReveal(nonce: p.macNonce)), c)
            if !p.prompted {
                p.prompted = true
                let name = p.phoneName
                DispatchQueue.main.async { [weak self] in
                    self?.onPairRequest?(name, code) { ok in self?.q.async { self?.decide(id, ok) } }
                }
            }
        }
        pairing = p
    }

    private func decide(_ id: UUID, _ ok: Bool) {
        guard var p = pairing, p.phoneID == id, let key = p.pairKey else { return }
        p.decision = ok
        pairing = p
        Log.write("pair \(ok ? "accepted" : "rejected"): \(p.phoneName)")
        if ok {
            Keychain.save(key, account: id.uuidString)
            var list = Self.loadPaired().filter { $0.id != id }
            list.append(PairedPhone(id: id, name: p.phoneName))
            Self.savePaired(list)
            publish()
        }
    }

    func unpair(_ id: UUID) {
        q.async { [self] in
            Keychain.delete(account: id.uuidString)
            Self.savePaired(Self.loadPaired().filter { $0.id != id })
            if let s = active, s.phoneID == id { end(s) }
            publish()
        }
    }

    static func loadPaired() -> [PairedPhone] {
        guard let d = UserDefaults.standard.data(forKey: "paired") else { return [] }
        return (try? JSONDecoder().decode([PairedPhone].self, from: d)) ?? []
    }

    static func savePaired(_ list: [PairedPhone]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: "paired")
    }

    // MARK: - Sessions

    private func hello(_ data: Data, _ id: UUID, _ nP: Data, _ c: Peer) {
        guard let key = Keychain.load(account: id.uuidString) else {
            // A failed keychain read is not proof the phone was unpaired: stay silent and let it retry.
            if Self.loadPaired().contains(where: { $0.id == id }) { return Log.write("hello ignored: pairing key unreadable for \(id)") }
            Log.write("hello rejected (not paired): \(id) from \(c)")
            return send(Packet.plain(.helloNak(reason: 1)), c)
        }
        guard Handshake.verify(data, pairKey: key) else {
            Log.write("hello rejected (key mismatch): \(id) from \(c)")
            return send(Packet.plain(.helloNak(reason: 1)), c)
        }
        if let s = candidates.values.first(where: { $0.phoneID == id && $0.phoneNonce == nP }) {
            return send(s.ack, c)   // retransmitted HELLO
        }
        let sid = UInt32.random(in: 1 ... .max), nM = randomBytes(16)
        let ack = Handshake.helloAck(sid: sid, phoneID: id, phoneNonce: nP, macNonce: nM, pairKey: key)
        let name = Self.loadPaired().first { $0.id == id }?.name ?? "手机"
        let channel = SecureChannel(key: Handshake.sessionKey(pairKey: key, phoneNonce: nP, macNonce: nM, sid: sid), sid: sid, isMac: true)
        candidates[sid] = Session(sid: sid, phoneID: id, name: name, phoneNonce: nP, ack: ack, channel: channel, conn: c, now: now())
        Log.write("hello ok: \(name) from \(c), sid \(sid)")
        send(ack, c)
    }

    /// A session takes control only after proving its key with an encrypted packet, so a replayed
    /// HELLO cannot kick the current phone off.
    private func activate(_ s: Session) {
        if let old = active { sendSealed(.bye(reason: 1), old); end(old) }
        candidates[s.sid] = nil
        active = s
        engine = GestureEngine(settings: SystemTrackpad.read())
        engine.settings.tipTap = tipTap
        Log.write("session active: \(s.name) sid \(s.sid), settings \(engine.settings)")
        injector.naturalScrolling = engine.settings.naturalScrolling
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "掌控板触控会话")
        publish()
    }

    private func end(_ s: Session) {
        candidates[s.sid] = nil
        guard s === active else { return }
        Log.write("session ended: \(s.name) sid \(s.sid), silent for \(String(format: "%.2f", now() - s.lastRecv)) s")
        perform(engine.reset())
        injector.releaseAll()
        active = nil
        shownRTT = nil
        stopTicker()
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
        publish()
    }

    private func perform(_ actions: [Action]) {
        if let recorder, !actions.isEmpty { recorder(nil, actions) }
        for a in actions {
            if a == .haptic {
                if let s = active { sendSealed(.feedback(kind: 1), s) }
            } else {
                injector.perform(a)
            }
        }
        if engine.needsTick { startTicker() }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: q)
        t.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            perform(engine.tick(now()))
            if !engine.needsTick { stopTicker() }
        }
        t.resume()
        ticker = t
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: - Housekeeping (every 50 ms)

    private func housekeeping() {
        let t = now()
        ticks += 1
        if let s = active {
            if t - s.lastRecv > 1.0 {
                end(s)
            } else {
                let hold = s.peerT == 0 ? 0 : UInt32(min((t - s.peerAt) * 1e6, Double(UInt32.max)))
                sendSealed(.heartbeat(Heartbeat(t: micros(t), echoT: s.peerT, echoHold: hold)), s)
            }
        }
        candidates = candidates.filter { t - $0.value.created < 5 }
        if active == nil, ticks % 20 == 0 { sendBeacon() }
        if ticks % 100 == 0 {
            let busy = Set(([active].compactMap { $0 } + Array(candidates.values)).compactMap { $0.conn.udp.map(ObjectIdentifier.init) })
            for (key, flow) in flows where t - flow.last > 30 && !busy.contains(key) {
                flow.peer.udp?.cancel()
                flows[key] = nil
            }
        }
        if ticks % 20 == 0 { shownRTT = active?.rtt }
        if ticks % 10 == 0 { publish() }
        if ticks % 20 == 0 { writeStatus() }
        if ticks % 200 == 0, let s = active { logLink(s) }
    }

    /// Wi-Fi stalls show up here as a long tail: packets held back while the radio is busy elsewhere.
    private func logLink(_ s: Session) {
        func summary(_ name: String, _ d: [Double]) -> String? {
            guard !d.isEmpty else { return nil }
            let v = d.sorted().map { Int(($0 * 1000).rounded()) }
            func p(_ q: Double) -> Int { v[min(v.count - 1, Int(Double(v.count) * q))] }
            return "\(name) n=\(v.count) p50=\(p(0.5)) p90=\(p(0.9)) p99=\(p(0.99)) max=\(v.last!) ms"
        }
        let parts = [summary("heartbeats", s.hbDelays), summary("frames", s.frameDelays)].compactMap { $0 }
        if !parts.isEmpty { Log.write("link \(linkKind(s)), delay over best: " + parts.joined(separator: "; ")) }
        s.hbDelays.removeAll(keepingCapacity: true)
        s.frameDelays.removeAll(keepingCapacity: true)
    }

    private func writeStatus() {
        Log.status([
            "time": Date().description,
            "postEventAccess": CGPreflightPostEventAccess(),
            "listenEventAccess": CGPreflightListenEventAccess(),
            "accessibilityTrusted": AXIsProcessTrusted(),
            "listener": listenerState,
            "bonjour": bonjour,
            "macName": macName,
            "paired": Self.loadPaired().map(\.name),
            "activeDevice": active?.name ?? "",
            "rttMs": active?.rtt.map { Int(($0 * 1000).rounded()) } ?? -1,
            "candidates": candidates.count,
            "flows": flows.count,
        ])
    }

    /// On a phone's hotspot the phone is our default gateway, so tell it where we are.
    private func sendBeacon() {
        guard let store = SCDynamicStoreCreate(nil, "mtm" as CFString, nil, nil),
              let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = ipv4["Router"] as? String else { return }
        if beacon?.host != router {
            beacon?.conn.cancel()
            let c = NWConnection(host: NWEndpoint.Host(router), port: NWEndpoint.Port(rawValue: Wire.port)!, using: .udp)
            c.start(queue: q)
            beacon = (router, c)
        }
        beacon?.conn.send(content: Packet.plain(.beacon(macID: macID, name: macName)), completion: .idempotent)
    }

    // MARK: - Helpers

    private func send(_ data: Data, _ c: Peer) { c.send(data) }
    private func sendSealed(_ m: Message, _ s: Session) { send(s.channel.seal(m), s.conn) }

    private func publish() {
        var listening = false
        if case .ready? = listener?.state { listening = true }
        let state = HubState(listening: listening, device: active?.name, link: active.map(linkKind), rtt: shownRTT,
                             paired: Self.loadPaired())
        guard state != lastState else { return }
        lastState = state
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }
}

extension Hub {
    /// The phone is on its own hotspot when its address is our default router.
    private func linkKind(_ s: Session) -> String {
        let t = now()
        if t - routers.at > 5 { routers = (t, Self.routerAddresses()) }
        guard let c = s.conn.udp else { return "有线（USB）" }
        if case let .hostPort(host, _) = c.endpoint, routers.set.contains(Self.plainAddress("\(host)")) {
            return "手机热点直连"
        }
        return c.currentPath?.usesInterfaceType(.wiredEthernet) == true ? "局域网" : "Wi-Fi"
    }

    static func routerAddresses() -> Set<String> {
        guard let store = SCDynamicStoreCreate(nil, "mtm" as CFString, nil, nil) else { return [] }
        var out = Set<String>()
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let d = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any], let r = d["Router"] as? String {
                out.insert(plainAddress(r))
            }
        }
        return out
    }

    /// "fe80::1%en0" → "fe80::1", "::ffff:10.0.0.1" → "10.0.0.1".
    static func plainAddress(_ s: String) -> String {
        let bare = s.split(separator: "%").first.map(String.init) ?? s
        return bare.lowercased().replacingOccurrences(of: "::ffff:", with: "")
    }
}

func now() -> Double { ProcessInfo.processInfo.systemUptime }
func micros(_ t: Double) -> UInt64 { UInt64(t * 1e6) }
