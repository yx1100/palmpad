import Foundation
import Wire

/// Wired link to a cabled phone. iPhones are reached through usbmuxd (the service Xcode uses), Android phones with
/// USB debugging on through the adb server. Both turn a local socket into a stream to the phone's TCP port
/// `Wire.usbPort`; packets on it are framed with a 2-byte big-endian length.
final class USBLink {
    private let q = DispatchQueue(label: "mtm.usb")
    private let onPacket: (Data, Peer) -> Void
    private var attached = Set<String>()          // "mux:<device id>" or "adb:<serial>"
    private var streams: [String: Stream] = [:]   // open streams by device

    /// Written, shut down and closed only on its own queue: a late send can never hit a descriptor
    /// number that was reused, and a connect attempt holding up `q` never delays a live session.
    private final class Stream {
        let wq = DispatchQueue(label: "mtm.usb.stream", qos: .userInteractive)
        var fd: Int32
        init(_ fd: Int32) { self.fd = fd }
    }

    init(onPacket: @escaping (Data, Peer) -> Void) { self.onPacket = onPacket }

    func start() {
        q.async {
            self.listenMux()
            self.trackADB()
        }
    }

    // MARK: Devices

    private func attach(_ key: String) {
        guard attached.insert(key).inserted else { return }
        Log.write("usb device attached: \(key)")
        connect(key)
    }

    private func detach(_ key: String) {
        guard attached.remove(key) != nil else { return }
        Log.write("usb device detached: \(key)")
        if let s = streams.removeValue(forKey: key) { s.wq.async { if s.fd >= 0 { shutdown(s.fd, SHUT_RDWR) } } }
    }

    private func listenMux() {
        guard let fd = Self.muxSocket() else {
            q.asyncAfter(deadline: .now() + 2) { self.listenMux() }
            return
        }
        guard Self.sendPlist(fd, ["MessageType": "Listen", "ProgName": "MTM", "ClientVersionString": "mtm"]) else {
            close(fd)
            q.asyncAfter(deadline: .now() + 2) { self.listenMux() }
            return
        }
        Thread { [weak self] in
            while let m = Self.readPlist(fd) { self?.q.async { self?.muxEvent(m) } }
            close(fd)
            self?.q.asyncAfter(deadline: .now() + 2) { self?.listenMux() }   // usbmuxd restarted
        }.start()
    }

    private func muxEvent(_ m: [String: Any]) {
        guard let id = m["DeviceID"] as? Int else { return }
        switch m["MessageType"] as? String {
        case "Attached":
            let props = m["Properties"] as? [String: Any]
            if props?["ConnectionType"] as? String == "USB" { attach("mux:\(id)") }
        case "Detached": detach("mux:\(id)")
        default: break
        }
    }

    /// Only devices on a USB transport count: adb over Wi-Fi would not be a wired link.
    private func trackADB() {
        guard let fd = Self.adbSocket() else {
            Self.startADBServer()
            q.asyncAfter(deadline: .now() + 5) { self.trackADB() }
            return
        }
        guard Self.adbRequest(fd, "host:track-devices-l") else {
            close(fd)
            q.asyncAfter(deadline: .now() + 5) { self.trackADB() }
            return
        }
        Thread { [weak self] in
            while let list = Self.adbMessage(fd) {
                let usb = list.split(separator: "\n").compactMap { line -> String? in
                    let f = line.split(separator: " ")
                    return f.count > 2 && f[1] == "device" && f.contains { $0.hasPrefix("usb:") } ? "adb:" + String(f[0]) : nil
                }
                self?.q.async { self?.adbDevices(Set(usb)) }
            }
            close(fd)
            self?.q.async { self?.adbDevices([]) }   // adb server stopped
            self?.q.asyncAfter(deadline: .now() + 2) { self?.trackADB() }
        }.start()
    }

    private func adbDevices(_ now: Set<String>) {
        for k in attached where k.hasPrefix("adb:") && !now.contains(k) { detach(k) }
        for k in now { attach(k) }
    }

    // MARK: Stream to the phone

    /// Retries while the phone is plugged in, since the app only listens while it is open.
    /// Every failed attempt closes its socket; leaking one per second once exhausted the descriptor
    /// table, and the keychain then failed to read pairing keys ("hello rejected (not paired)").
    private func connect(_ key: String) {
        guard attached.contains(key), streams[key] == nil else { return }
        let id = String(key.dropFirst(4))
        guard let fd = key.hasPrefix("adb:") ? Self.openADB(serial: id) : Int(id).flatMap(Self.openMux) else { return retry(key) }
        let s = Stream(fd)
        streams[key] = s
        Log.write("usb stream open to \(key)")
        let peer = Peer { data in
            var framed = Data([UInt8(data.count >> 8), UInt8(data.count & 0xFF)])
            framed.append(data)
            s.wq.async { if s.fd >= 0 { _ = Self.writeAll(s.fd, framed) } }
        }
        Thread { [weak self] in
            while let head = Self.readExact(fd, 2) {
                let n = Int(head[0]) << 8 | Int(head[1])
                guard let body = Self.readExact(fd, n) else { break }
                self?.onPacket(Data(body), peer)
            }
            s.wq.async {
                close(s.fd)
                s.fd = -1
            }
            self?.q.async { [weak self] in
                guard let self else { return }
                if streams[key] === s { streams[key] = nil }
                Log.write("usb stream closed for \(key)")
                retry(key)
            }
        }.start()
    }

    private func retry(_ key: String) { q.asyncAfter(deadline: .now() + 1) { self.connect(key) } }

    private static func receiveTimeout(_ fd: Int32, _ seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: usbmuxd plumbing

    /// A stream to the phone's port, or nil while the app is not listening.
    private static func openMux(_ device: Int) -> Int32? {
        guard let fd = muxSocket() else { return nil }
        receiveTimeout(fd, 2)   // a locked phone can leave the request unanswered: give up and ask again
        let port = Int(Wire.usbPort)
        guard sendPlist(fd, ["MessageType": "Connect", "DeviceID": device, "PortNumber": (port & 0xFF) << 8 | port >> 8,
                             "ProgName": "MTM", "ClientVersionString": "mtm"]),
              (readPlist(fd)?["Number"] as? Int) == 0 else {
            close(fd)
            return nil
        }
        receiveTimeout(fd, 0)
        return fd
    }

    private static func muxSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            "/var/run/usbmuxd".utf8CString.withUnsafeBytes { dst.copyMemory(from: $0) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Header: total length, version 1, message type 8 (plist), tag — all little-endian u32.
    private static func sendPlist(_ fd: Int32, _ dict: [String: Any]) -> Bool {
        guard let body = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return false }
        var d = Data()
        for v in [UInt32(16 + body.count), 1, 8, 1] { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        return writeAll(fd, d + body)
    }

    private static func readPlist(_ fd: Int32) -> [String: Any]? {
        guard let h = readExact(fd, 16) else { return nil }
        let len = Int(UInt32(h[0]) | UInt32(h[1]) << 8 | UInt32(h[2]) << 16 | UInt32(h[3]) << 24)
        guard len >= 16, let body = readExact(fd, len - 16).map({ Data($0) }) else { return nil }
        return try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
    }

    // MARK: adb plumbing

    /// A stream to the phone's port through the adb server, or nil while the app is not listening ("FAIL closed").
    private static func openADB(serial: String) -> Int32? {
        guard let fd = adbSocket() else { return nil }
        receiveTimeout(fd, 2)
        guard adbRequest(fd, "host:transport:\(serial)"), adbRequest(fd, "tcp:\(Wire.usbPort)") else {
            close(fd)
            return nil
        }
        receiveTimeout(fd, 0)
        return fd
    }

    private static func adbSocket() -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(5037).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// A request is a 4-hex-digit length and the text; the answer starts with OKAY or FAIL.
    private static func adbRequest(_ fd: Int32, _ cmd: String) -> Bool {
        let body = Data(cmd.utf8)
        return writeAll(fd, Data(String(format: "%04x", body.count).utf8) + body) && readExact(fd, 4) == Array("OKAY".utf8)
    }

    private static func adbMessage(_ fd: Int32) -> String? {
        guard let h = readExact(fd, 4), let n = Int(String(decoding: h, as: UTF8.self), radix: 16),
              let body = readExact(fd, n) else { return nil }
        return String(decoding: body, as: UTF8.self)
    }

    /// The adb server keeps running once any adb command starts it; after the Mac restarts, nothing may have yet.
    private static func startADBServer() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/share/android-commandlinetools/platform-tools/adb", "/opt/homebrew/bin/adb",
                          "\(home)/Library/Android/sdk/platform-tools/adb", "/usr/local/bin/adb"]
        guard let adb = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["start-server"]
        try? p.run()
    }

    // MARK: Socket I/O

    static func writeAll(_ fd: Int32, _ d: Data) -> Bool {
        d.withUnsafeBytes { p in
            var off = 0
            while off < d.count {
                let n = write(fd, p.baseAddress! + off, d.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    static func readExact(_ fd: Int32, _ n: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n)
        var off = 0
        while off < n {
            let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + off, n - off) }
            if r <= 0 { return nil }
            off += r
        }
        return buf
    }
}
