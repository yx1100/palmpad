import CryptoKit
import Foundation
import Network
import Observation
import Wire

struct MacInfo: Identifiable, Hashable {
    let id: UUID
    var name: String
    var endpoint: NWEndpoint
}

struct PairedMac: Codable, Equatable {
    var id: UUID
    var name: String
    var host: String?
}

/// Discovery, pairing and the encrypted UDP session with the Mac. UI state lives on the main queue,
/// networking on `q`.
@Observable
final class Link {
    enum Phase: Equatable { case idle, pairing(code: String?), rejected, needsPairing, connecting, connected, replaced, off }

    var phase = Phase.idle
    var macs: [MacInfo] = []
    var paired: PairedMac? = Link.loadPaired()
    var rtt: Double?
    /// How this phone reaches the Mac: "Wi-Fi", "热点直连" (the Mac is on this phone's hotspot) or "有线".
    var linkName: String?
    var onFeedback: (() -> Void)?

    @ObservationIgnored let phoneID: UUID = {
        if let s = UserDefaults.standard.string(forKey: "phoneID"), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "phoneID")
        return id
    }()
    @ObservationIgnored private let q = DispatchQueue(label: "mtm.link", qos: .userInteractive)
    // Everything below is touched on `q` only.
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var beaconListener: NWListener?
    @ObservationIgnored private var usbListener: NWListener?
    @ObservationIgnored private var usb: NWConnection?   // the Mac over the cable, via usbmuxd
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var found: [UUID: MacInfo] = [:]
    @ObservationIgnored private var tries: [String: NWConnection] = [:]
    @ObservationIgnored private var conn: NWConnection?
    @ObservationIgnored private var channel: SecureChannel?
    @ObservationIgnored private var mac: PairedMac?
    @ObservationIgnored private var pairKey: Data?
    @ObservationIgnored private var helloNonce = randomBytes(16)
    @ObservationIgnored private var lastRecv = 0.0
    @ObservationIgnored private var peerT: UInt64 = 0
    @ObservationIgnored private var peerAt = 0.0
    @ObservationIgnored private var rttShownAt = 0.0   // the UI gets one latency sample a second
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var running = false
    @ObservationIgnored private var paused = false   // after another phone took over; resumes on touch
    @ObservationIgnored private var userOff = false  // power button: stays off until pressed again
    @ObservationIgnored private var pairing: Flow?

    private struct Flow {
        let conn: NWConnection
        let key = P256.KeyAgreement.PrivateKey()
        let nonce = randomBytes(16)
        let started = uptime()
        var macID: UUID?, macName = "", macPublic: Data?, commitment: Data?, pairKey: Data?
    }

    static let params: NWParameters = {
        let p = NWParameters.udp
        p.serviceClass = .interactiveVoice
        p.prohibitedInterfaceTypes = [.cellular]
        return p
    }()

    // MARK: - Lifecycle (called from the main queue)

    func start() {
        let current = paired
        q.async { [self] in
            guard !running else { return }   // back from Control Center etc.: the session never stopped
            running = true
            mac = current
            pairKey = current.flatMap { Keychain.load(account: "mac-\($0.id.uuidString)") }
            setPhase(pairKey == nil ? .idle : .connecting)
            startBrowser()
            startBeaconListener()
            startUSBListener()
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] _ in self?.q.async { self?.networkChanged() } }
            m.start(queue: q)
            pathMonitor = m
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.housekeeping() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        q.async { [self] in
            guard running else { return }
            running = false
            if let c = conn, var ch = channel { transmit(ch.seal(.bye(reason: 0)), c) }
            disconnect()
            usb?.cancel(); usb = nil
            usbListener?.cancel(); usbListener = nil
            browser?.cancel(); browser = nil
            beaconListener?.cancel(); beaconListener = nil
            pathMonitor?.cancel(); pathMonitor = nil
            timer?.cancel(); timer = nil
            pairing?.conn.cancel(); pairing = nil
        }
    }

    /// Power button: hand the Mac back (other phones may take over), or reconnect.
    func toggleConnection() {
        q.async { [self] in
            if userOff {
                userOff = false
                paused = false
                setPhase(pairKey == nil ? .idle : .connecting)
                attemptConnect()
            } else {
                if let c = conn, var ch = channel { transmit(ch.seal(.bye(reason: 0)), c) }
                disconnect()
                userOff = true
                setPhase(.off)
            }
        }
    }

    /// Touching the surface while disconnected retries at once (also resumes after a takeover).
    func poke() {
        q.async { [self] in
            guard channel == nil, pairKey != nil, !userOff else { return }
            paused = false
            setPhase(.connecting)
            attemptConnect()
        }
    }

    func send(_ frame: Frame) {
        q.async { [self] in
            guard let c = conn, var ch = channel else { return }
            transmit(ch.seal(.frame(frame)), c)
            channel = ch
        }
    }

    func pair(with m: MacInfo) {
        q.async { [self] in
            pairing?.conn.cancel()
            let c = NWConnection(to: m.endpoint, using: Self.params)
            c.start(queue: q)
            receive(c)
            pairing = Flow(conn: c)
            setPhase(.pairing(code: nil))
            sendPairing()
        }
    }

    func forgetMac() {
        q.async { [self] in
            if let m = mac { Keychain.delete(account: "mac-\(m.id.uuidString)") }
            disconnect()
            mac = nil
            pairKey = nil
            Self.savePaired(nil)
            DispatchQueue.main.async { self.paired = nil; self.phase = .idle }
        }
    }

    // MARK: - Discovery

    private func startBrowser() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Wire.bonjourType, domain: nil), using: Self.params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for r in results {
                guard case let .bonjour(txt) = r.metadata, let s = txt["id"], let id = UUID(uuidString: s),
                      case let .service(name, _, _, _) = r.endpoint else { continue }
                discovered(MacInfo(id: id, name: name, endpoint: r.endpoint))
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.q.asyncAfter(deadline: .now() + 1) { self?.startBrowser() } }
        }
        b.start(queue: q)
        browser = b
    }

    /// On our hotspot the Mac cannot find us by Bonjour reliably, so it sends beacons to its gateway: us.
    private func startBeaconListener() {
        let p = NWParameters.udp
        p.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: p, on: NWEndpoint.Port(rawValue: Wire.port)!) else { return }
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: q)
            c.receiveMessage { [weak self] data, _, _, _ in
                defer { c.cancel() }
                guard let self, let data, let (_, m) = Packet.open(data), case let .beacon(id, name) = m,
                      case let .hostPort(host, _) = c.endpoint else { return }
                discovered(MacInfo(id: id, name: name, endpoint: .hostPort(host: host, port: NWEndpoint.Port(rawValue: Wire.port)!)))
            }
        }
        l.start(queue: q)
        beaconListener = l
    }

    /// When the phone is cabled to the Mac, the Mac reaches this port through usbmuxd. A session over
    /// the cable replaces a wireless one and falls back to Wi-Fi when the cable is pulled.
    private func startUSBListener() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let p = NWParameters(tls: nil, tcp: tcp)
        p.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: p, on: NWEndpoint.Port(rawValue: Wire.usbPort)!) else { return }
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            usb?.cancel()
            usb = c
            c.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !userOff, let key = pairKey else { return }
                    helloNonce = randomBytes(16)
                    transmit(Handshake.hello(phoneID: phoneID, nonce: helloNonce, pairKey: key), c)
                case .failed, .cancelled:
                    if usb === c { usb = nil }
                    if conn === c {
                        disconnect()
                        setPhase(.connecting)
                        attemptConnect()
                    }
                default: break
                }
            }
            c.start(queue: q)
            receiveFramed(c)
        }
        l.start(queue: q)
        usbListener = l
    }

    /// End of stream (cable pulled, Mac quit) cancels the connection, so the session falls back to Wi-Fi at once.
    private func receiveFramed(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] head, _, _, error in
            guard let self else { return }
            guard let head, head.count == 2, error == nil else { return c.cancel() }
            let n = Int(head[head.startIndex]) << 8 | Int(head[head.startIndex + 1])
            c.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] body, _, _, error in
                guard let self else { return }
                guard let body, body.count == n, error == nil else { return c.cancel() }
                handle(body, from: c)
                receiveFramed(c)
            }
        }
    }

    /// UDP datagrams go as they are; the USB stream needs a length prefix.
    private func transmit(_ data: Data, _ c: NWConnection) {
        if c === usb {
            c.send(content: Data([UInt8(data.count >> 8), UInt8(data.count & 0xFF)]) + data, completion: .idempotent)
        } else {
            c.send(content: data, completion: .idempotent)
        }
    }

    private func discovered(_ m: MacInfo) {
        let isNew = found[m.id]?.endpoint != m.endpoint
        found[m.id] = m
        let list = found.values.sorted { $0.name < $1.name }
        DispatchQueue.main.async { self.macs = list }
        if isNew, m.id == mac?.id, channel == nil { attemptConnect() }
    }

    private func networkChanged() {
        guard running else { return }
        if channel != nil { return }   // a live session survives; liveness handles real breaks
        tries.values.forEach { $0.cancel() }
        tries = [:]
        attemptConnect()
    }

    // MARK: - Session

    /// Sends HELLO to every known address of the paired Mac; the first HELLO_ACK wins.
    private func attemptConnect() {
        guard running, !paused, !userOff, channel == nil, let mac, let key = pairKey else { return }
        var endpoints: [NWEndpoint] = []
        if let m = found[mac.id] { endpoints.append(m.endpoint) }
        if let h = mac.host { endpoints.append(.hostPort(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: Wire.port)!)) }
        let hello = Handshake.hello(phoneID: phoneID, nonce: helloNonce, pairKey: key)
        if let u = usb, u.state == .ready { transmit(hello, u) }   // the cable wins when present
        for ep in endpoints {
            let k = "\(ep)"
            if tries[k] == nil {
                let c = NWConnection(to: ep, using: Self.params)
                c.start(queue: q)
                receive(c)
                tries[k] = c
            }
            tries[k]?.send(content: hello, completion: .idempotent)
        }
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { handle(data, from: c) }
            if error == nil, c.state != .cancelled { receive(c) }
        }
    }

    private func handle(_ data: Data, from c: NWConnection) {
        guard let h = Header(packet: data) else { return }
        if h.type.encrypted {
            guard c === conn, var ch = channel, let m = ch.open(data) else { return }
            channel = ch
            lastRecv = uptime()
            switch m {
            case .heartbeat(let hb):
                peerT = hb.t
                peerAt = lastRecv
                if hb.echoT != 0, lastRecv - rttShownAt >= 1 {
                    let r = lastRecv - Double(hb.echoT) / 1e6 - Double(hb.echoHold) / 1e6
                    rttShownAt = lastRecv
                    DispatchQueue.main.async { self.rtt = r }
                }
            case .feedback: DispatchQueue.main.async { self.onFeedback?() }
            case .bye(let reason):
                disconnect()
                if reason == 1 { paused = true; setPhase(.replaced) } else { setPhase(.connecting) }
            default: break
            }
            return
        }
        guard let (hdr, m) = Packet.open(data) else { return }
        switch m {
        case let .helloAck(id, nP, nM, _):
            let upgrade = c === usb && conn !== usb   // cable plugged in during a wireless session
            guard channel == nil || upgrade, id == phoneID, nP == helloNonce, let key = pairKey,
                  Handshake.verify(data, pairKey: key) else { return }
            // The same HELLO can be answered over both paths; keep the sequence numbers of that session.
            if channel?.sid != hdr.sid {
                let sk = Handshake.sessionKey(pairKey: key, phoneNonce: nP, macNonce: nM, sid: hdr.sid)
                channel = SecureChannel(key: sk, sid: hdr.sid, isMac: false)
            }
            if let old = conn, old !== c { old.cancel() }
            conn = c
            for (k, t) in tries where t !== c { t.cancel(); tries[k] = nil }
            tries = [:]
            lastRecv = uptime()
            peerT = 0
            heartbeat()   // proves the key, which makes this session the Mac's active one
            // Remember the Mac's network address; the cable's far end is only this phone's usbmux relay.
            if c !== usb, case let .hostPort(host, _)? = c.currentPath?.remoteEndpoint, var m = mac {
                m.host = "\(host)"
                mac = m
                Self.savePaired(m)
            }
            // Personal Hotspot clients hang off a bridge interface; everything else here is Wi-Fi.
            let name = c.currentPath?.availableInterfaces.first?.name ?? ""
            let kind = c === usb ? "有线" : name.hasPrefix("bridge") || name.hasPrefix("ap") ? "热点直连" : "Wi-Fi"
            DispatchQueue.main.async { self.linkName = kind }
            setPhase(.connected)
        case .helloNak:
            if channel == nil { setPhase(.needsPairing) }   // a refused cable upgrade leaves a live session alone
        case let .pairCommit(id, pub, commit, name):
            guard var f = pairing, f.conn === c, f.macPublic == nil else { return }
            f.macID = id; f.macName = name; f.macPublic = pub; f.commitment = commit
            pairing = f
            sendPairing()
        case let .pairReveal(nM):
            guard var f = pairing, f.conn === c, f.pairKey == nil, let pubM = f.macPublic,
                  Pairing.commitment(macPublic: pubM, phonePublic: Pairing.publicKey(f.key), macNonce: nM) == f.commitment,
                  let shared = try? Pairing.shared(f.key, peer: pubM) else { return }
            let pubP = Pairing.publicKey(f.key)
            f.pairKey = Pairing.pairKey(shared: shared, phonePublic: pubP, macPublic: pubM, phoneNonce: f.nonce, macNonce: nM)
            pairing = f
            setPhase(.pairing(code: Pairing.code(phonePublic: pubP, macPublic: pubM, phoneNonce: f.nonce, macNonce: nM)))
        case let .pairDone(accepted, tag):
            guard let f = pairing, f.conn === c, let key = f.pairKey, let id = f.macID,
                  tag == Pairing.doneTag(pairKey: key, accepted: accepted) else { return }
            var host: String?
            if case let .hostPort(h, _)? = c.currentPath?.remoteEndpoint { host = "\(h)" }
            pairing = nil
            c.cancel()
            guard accepted else { return setPhase(.rejected) }
            let m = PairedMac(id: id, name: f.macName, host: host)
            Keychain.save(key, account: "mac-\(id.uuidString)")
            Self.savePaired(m)
            disconnect()
            mac = m
            pairKey = key
            paused = false
            DispatchQueue.main.async { self.paired = m }
            setPhase(.connecting)
            attemptConnect()
        default: break
        }
    }

    private func sendPairing() {
        guard let f = pairing else { return }
        let m: Message = f.macPublic == nil
            ? .pairRequest(phoneID: phoneID, publicKey: Pairing.publicKey(f.key), name: "iPhone")
            : .pairNonce(phoneID: phoneID, nonce: f.nonce)   // also polls for the Mac user's decision
        f.conn.send(content: Packet.plain(m), completion: .idempotent)
    }

    private func heartbeat() {
        guard let c = conn, var ch = channel else { return }
        let t = uptime()
        let hold = peerT == 0 ? 0 : UInt32(min((t - peerAt) * 1e6, Double(UInt32.max)))
        transmit(ch.seal(.heartbeat(Heartbeat(t: UInt64(t * 1e6), echoT: peerT, echoHold: hold))), c)
        channel = ch
    }

    private func disconnect() {
        if conn !== usb { conn?.cancel() }
        conn = nil
        channel = nil
        tries.values.forEach { $0.cancel() }
        tries = [:]
        helloNonce = randomBytes(16)
        rttShownAt = 0
        DispatchQueue.main.async { self.rtt = nil }
    }

    private func housekeeping() {
        ticks += 1
        let t = uptime()
        if channel != nil {
            if t - lastRecv > 1.0 {
                disconnect()
                setPhase(.connecting)
            } else {
                heartbeat()
            }
        } else if ticks % 10 == 0 {
            attemptConnect()
        }
        if let f = pairing {
            if t - f.started > 120 {
                f.conn.cancel()
                pairing = nil
                setPhase(.idle)
            } else if ticks % 10 == 0 {
                sendPairing()
            }
        }
    }

    // MARK: - Helpers

    private func setPhase(_ p: Phase) { DispatchQueue.main.async { self.phase = p } }

    static func loadPaired() -> PairedMac? {
        UserDefaults.standard.data(forKey: "pairedMac").flatMap { try? JSONDecoder().decode(PairedMac.self, from: $0) }
    }

    static func savePaired(_ m: PairedMac?) {
        UserDefaults.standard.set(m.flatMap { try? JSONEncoder().encode($0) }, forKey: "pairedMac")
    }
}

func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
