import Foundation

/// Wire format shared with the Android client. See PROTOCOL.md at the repo root.
public enum Wire {
    public static let port: UInt16 = 47800
    /// TCP port the iPhone listens on for the USB link (reached through usbmuxd); 2-byte length framing.
    public static let usbPort: UInt16 = 47801
    public static let bonjourType = "_mtm._udp"
    public static let headerSize = 12
    static let magic: UInt8 = 0x4D
    static let version: UInt8 = 1
}

public enum MsgType: UInt8, Sendable {
    case beacon = 0x01
    case pairRequest = 0x10, pairCommit = 0x11, pairNonce = 0x12, pairReveal = 0x13, pairDone = 0x14
    case hello = 0x20, helloAck = 0x21, helloNak = 0x22
    case frame = 0x30, heartbeat = 0x31, feedback = 0x33, bye = 0x3F

    public var encrypted: Bool { rawValue >= 0x30 }
}

public enum WireError: Error { case truncated, malformed }

public struct Header: Equatable, Sendable {
    public var type: MsgType
    public var sid: UInt32
    public var seq: UInt32

    public init(type: MsgType, sid: UInt32 = 0, seq: UInt32 = 0) {
        self.type = type; self.sid = sid; self.seq = seq
    }

    public var bytes: Data {
        var w = Writer()
        w.u8(Wire.magic); w.u8(Wire.version); w.u8(type.rawValue); w.u8(0)
        w.u32(sid); w.u32(seq)
        return w.data
    }

    /// Parses the header of a packet; nil for foreign or unknown packets.
    public init?(packet: Data) {
        var r = Reader(packet)
        guard let m = try? r.u8(), m == Wire.magic,
              let v = try? r.u8(), v == Wire.version,
              let raw = try? r.u8(), let t = MsgType(rawValue: raw),
              (try? r.u8()) != nil,
              let sid = try? r.u32(), let seq = try? r.u32() else { return nil }
        self.init(type: t, sid: sid, seq: seq)
    }
}

public struct Frame: Equatable, Sendable {
    public struct Contact: Equatable, Sendable {
        public var id: UInt8, x: UInt16, y: UInt16
        public init(id: UInt8, x: UInt16, y: UInt16) { self.id = id; self.x = x; self.y = y }
    }
    public struct Ended: Equatable, Sendable {
        public var id: UInt8, x: UInt16, y: UInt16
        /// Milliseconds between the touch going down / up and `t`.
        public var downAgo: UInt16, upAgo: UInt16
        public init(id: UInt8, x: UInt16, y: UInt16, downAgo: UInt16, upAgo: UInt16) {
            self.id = id; self.x = x; self.y = y; self.downAgo = downAgo; self.upAgo = upAgo
        }
    }
    /// Phone monotonic clock, microseconds.
    public var t: UInt64
    /// Surface size in 0.01 mm.
    public var width: UInt16, height: UInt16
    public var active: [Contact]
    public var ended: [Ended]

    public init(t: UInt64, width: UInt16, height: UInt16, active: [Contact], ended: [Ended]) {
        self.t = t; self.width = width; self.height = height; self.active = active; self.ended = ended
    }
}

public struct Heartbeat: Equatable, Sendable {
    public var t: UInt64, echoT: UInt64, echoHold: UInt32
    public init(t: UInt64, echoT: UInt64, echoHold: UInt32) { self.t = t; self.echoT = echoT; self.echoHold = echoHold }
}

public enum Message: Equatable, Sendable {
    case beacon(macID: UUID, name: String)
    case pairRequest(phoneID: UUID, publicKey: Data, name: String)
    case pairCommit(macID: UUID, publicKey: Data, commitment: Data, name: String)
    case pairNonce(phoneID: UUID, nonce: Data)
    case pairReveal(nonce: Data)
    case pairDone(accepted: Bool, tag: Data)
    case hello(phoneID: UUID, nonce: Data, tag: Data)
    case helloAck(phoneID: UUID, phoneNonce: Data, macNonce: Data, tag: Data)
    case helloNak(reason: UInt8)
    case frame(Frame)
    case heartbeat(Heartbeat)
    case feedback(kind: UInt8)
    case bye(reason: UInt8)

    public var type: MsgType {
        switch self {
        case .beacon: .beacon
        case .pairRequest: .pairRequest
        case .pairCommit: .pairCommit
        case .pairNonce: .pairNonce
        case .pairReveal: .pairReveal
        case .pairDone: .pairDone
        case .hello: .hello
        case .helloAck: .helloAck
        case .helloNak: .helloNak
        case .frame: .frame
        case .heartbeat: .heartbeat
        case .feedback: .feedback
        case .bye: .bye
        }
    }

    public var body: Data {
        var w = Writer()
        switch self {
        case let .beacon(id, name): w.uuid(id); w.str(name)
        case let .pairRequest(id, key, name): w.uuid(id); w.lp(key); w.str(name)
        case let .pairCommit(id, key, commit, name): w.uuid(id); w.lp(key); w.raw(commit); w.str(name)
        case let .pairNonce(id, n): w.uuid(id); w.raw(n)
        case let .pairReveal(n): w.raw(n)
        case let .pairDone(ok, tag): w.u8(ok ? 1 : 0); w.raw(tag)
        case let .hello(id, n, tag): w.uuid(id); w.raw(n); w.raw(tag)
        case let .helloAck(id, np, nm, tag): w.uuid(id); w.raw(np); w.raw(nm); w.raw(tag)
        case let .helloNak(r): w.u8(r)
        case let .frame(f):
            w.u64(f.t); w.u16(f.width); w.u16(f.height)
            w.u8(UInt8(f.active.count))
            for c in f.active { w.u8(c.id); w.u16(c.x); w.u16(c.y) }
            w.u8(UInt8(f.ended.count))
            for e in f.ended { w.u8(e.id); w.u16(e.x); w.u16(e.y); w.u16(e.downAgo); w.u16(e.upAgo) }
        case let .heartbeat(h): w.u64(h.t); w.u64(h.echoT); w.u32(h.echoHold)
        case let .feedback(k): w.u8(k)
        case let .bye(r): w.u8(r)
        }
        return w.data
    }

    public static func decode(_ type: MsgType, _ body: Data) throws -> Message {
        var r = Reader(body)
        let m: Message
        switch type {
        case .beacon: m = .beacon(macID: try r.uuid(), name: try r.str())
        case .pairRequest: m = .pairRequest(phoneID: try r.uuid(), publicKey: try r.lp(), name: try r.str())
        case .pairCommit:
            m = .pairCommit(macID: try r.uuid(), publicKey: try r.lp(), commitment: try r.raw(32), name: try r.str())
        case .pairNonce: m = .pairNonce(phoneID: try r.uuid(), nonce: try r.raw(16))
        case .pairReveal: m = .pairReveal(nonce: try r.raw(16))
        case .pairDone: m = .pairDone(accepted: try r.u8() == 1, tag: try r.raw(16))
        case .hello: m = .hello(phoneID: try r.uuid(), nonce: try r.raw(16), tag: try r.raw(16))
        case .helloAck:
            m = .helloAck(phoneID: try r.uuid(), phoneNonce: try r.raw(16), macNonce: try r.raw(16), tag: try r.raw(16))
        case .helloNak: m = .helloNak(reason: try r.u8())
        case .frame:
            let t = try r.u64(), w = try r.u16(), h = try r.u16()
            var active: [Frame.Contact] = []
            for _ in 0..<Int(try r.u8()) { active.append(.init(id: try r.u8(), x: try r.u16(), y: try r.u16())) }
            var ended: [Frame.Ended] = []
            for _ in 0..<Int(try r.u8()) {
                ended.append(.init(id: try r.u8(), x: try r.u16(), y: try r.u16(), downAgo: try r.u16(), upAgo: try r.u16()))
            }
            m = .frame(Frame(t: t, width: w, height: h, active: active, ended: ended))
        case .heartbeat: m = .heartbeat(Heartbeat(t: try r.u64(), echoT: try r.u64(), echoHold: try r.u32()))
        case .feedback: m = .feedback(kind: try r.u8())
        case .bye: m = .bye(reason: try r.u8())
        }
        guard r.remaining == 0 else { throw WireError.malformed }
        return m
    }
}

public enum Packet {
    /// Header + plaintext body, for the unencrypted message types.
    public static func plain(_ m: Message, sid: UInt32 = 0, seq: UInt32 = 0) -> Data {
        Header(type: m.type, sid: sid, seq: seq).bytes + m.body
    }

    /// Decodes an unencrypted packet.
    public static func open(_ packet: Data) -> (Header, Message)? {
        guard let h = Header(packet: packet), !h.type.encrypted,
              let m = try? Message.decode(h.type, packet.dropFirst(Wire.headerSize)) else { return nil }
        return (h, m)
    }
}

public struct Writer {
    public private(set) var data = Data()
    public init() {}
    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xFF)) }
    public mutating func u32(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { data.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    public mutating func u64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { data.append(UInt8((v >> UInt64(s)) & 0xFF)) } }
    public mutating func raw(_ d: Data) { data.append(d) }
    public mutating func str(_ s: String) {
        var b = Data(s.utf8)
        while b.count > 255 { b.removeLast() }  // ponytail: may cut a multi-byte char; names are display-only
        lp(b)
    }
    public mutating func lp(_ d: Data) { u8(UInt8(d.count)); raw(d) }
    public mutating func uuid(_ u: UUID) { withUnsafeBytes(of: u.uuid) { data.append(contentsOf: $0) } }
}

public struct Reader {
    let b: [UInt8]
    var i = 0
    public init(_ d: Data) { b = [UInt8](d) }
    public var remaining: Int { b.count - i }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n <= remaining else { throw WireError.truncated }
        defer { i += n }
        return b[i..<i + n]
    }
    public mutating func u8() throws -> UInt8 { try take(1).first! }
    public mutating func u16() throws -> UInt16 { try take(2).reduce(0) { $0 << 8 | UInt16($1) } }
    public mutating func u32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    public mutating func u64() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
    public mutating func raw(_ n: Int) throws -> Data { Data(try take(n)) }
    public mutating func lp() throws -> Data { try raw(Int(try u8())) }
    public mutating func str() throws -> String { String(decoding: try lp(), as: UTF8.self) }
    public mutating func uuid() throws -> UUID {
        let s = try take(16)
        var u: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &u) { $0.copyBytes(from: s) }
        return UUID(uuid: u)
    }
}
