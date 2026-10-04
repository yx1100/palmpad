import CryptoKit
import Foundation

/// Numeric-comparison pairing with a commitment (same shape as Bluetooth SSP). See PROTOCOL.md.
public enum Pairing {
    public static func publicKey(_ k: P256.KeyAgreement.PrivateKey) -> Data { k.publicKey.derRepresentation }

    public static func shared(_ k: P256.KeyAgreement.PrivateKey, peer der: Data) throws -> Data {
        let secret = try k.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(derRepresentation: der))
        return secret.withUnsafeBytes { Data($0) }
    }

    public static func commitment(macPublic: Data, phonePublic: Data, macNonce: Data) -> Data {
        sha256("mtm-commit", macPublic, phonePublic, macNonce)
    }

    public static func code(phonePublic: Data, macPublic: Data, phoneNonce: Data, macNonce: Data) -> String {
        let h = sha256("mtm-code", phonePublic, macPublic, phoneNonce, macNonce)
        let v = h.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return String(format: "%06u", v % 1_000_000)
    }

    public static func pairKey(shared: Data, phonePublic: Data, macPublic: Data, phoneNonce: Data, macNonce: Data) -> Data {
        hmac(shared, "mtm-pair", phonePublic, macPublic, phoneNonce, macNonce)
    }

    public static func doneTag(pairKey: Data, accepted: Bool) -> Data {
        hmac(pairKey, "mtm-pair-done", Data([accepted ? 1 : 0])).prefix(16)
    }
}

public enum Handshake {
    public static func hello(phoneID: UUID, nonce: Data, pairKey: Data) -> Data {
        let head = Header(type: .hello).bytes
        var w = Writer(); w.uuid(phoneID); w.raw(nonce)
        return head + w.data + hmac(pairKey, "mtm-hello", head, w.data).prefix(16)
    }

    public static func helloAck(sid: UInt32, phoneID: UUID, phoneNonce: Data, macNonce: Data, pairKey: Data) -> Data {
        let head = Header(type: .helloAck, sid: sid).bytes
        var w = Writer(); w.uuid(phoneID); w.raw(phoneNonce); w.raw(macNonce)
        return head + w.data + hmac(pairKey, "mtm-hello-ack", head, w.data).prefix(16)
    }

    /// Verifies the trailing 16-byte tag of a HELLO or HELLO_ACK packet.
    public static func verify(_ packet: Data, pairKey: Data) -> Bool {
        guard packet.count > Wire.headerSize + 16, let h = Header(packet: packet),
              h.type == .hello || h.type == .helloAck else { return false }
        let head = packet.prefix(Wire.headerSize)
        let body = packet.dropFirst(Wire.headerSize).dropLast(16)
        let label = h.type == .hello ? "mtm-hello" : "mtm-hello-ack"
        return constantTimeEqual(hmac(pairKey, label, Data(head), Data(body)).prefix(16), packet.suffix(16))
    }

    public static func sessionKey(pairKey: Data, phoneNonce: Data, macNonce: Data, sid: UInt32) -> Data {
        var w = Writer(); w.u32(sid)
        return hmac(pairKey, "mtm-session", phoneNonce, macNonce, w.data).prefix(16)
    }
}

/// AES-128-GCM channel for one session direction pair. Not thread-safe; confine to one queue.
public struct SecureChannel: Sendable {
    public let sid: UInt32
    let key: SymmetricKey
    let sendDir: UInt32, recvDir: UInt32
    public private(set) var sendSeq: UInt32 = 0
    public private(set) var recvSeq: UInt32 = 0

    public init(key: Data, sid: UInt32, isMac: Bool) {
        self.key = SymmetricKey(data: key)
        self.sid = sid
        sendDir = isMac ? 1 : 0
        recvDir = isMac ? 0 : 1
    }

    public mutating func seal(_ m: Message) -> Data {
        sendSeq &+= 1
        let head = Header(type: m.type, sid: sid, seq: sendSeq).bytes
        // Nonce is unique per (key, direction, seq), so sealing cannot fail.
        let box = try! AES.GCM.seal(m.body, using: key, nonce: Self.nonce(sendDir, sid, sendSeq), authenticating: head)
        return head + box.ciphertext + box.tag
    }

    /// Authenticates, replay-checks and decodes an encrypted packet.
    public mutating func open(_ packet: Data) -> Message? {
        guard let h = Header(packet: packet), h.type.encrypted, h.sid == sid, h.seq > recvSeq,
              packet.count >= Wire.headerSize + 16 else { return nil }
        let body = packet.dropFirst(Wire.headerSize)
        guard let box = try? AES.GCM.SealedBox(nonce: Self.nonce(recvDir, sid, h.seq),
                                               ciphertext: body.dropLast(16), tag: body.suffix(16)),
              let plain = try? AES.GCM.open(box, using: key, authenticating: packet.prefix(Wire.headerSize)),
              let m = try? Message.decode(h.type, plain) else { return nil }
        recvSeq = h.seq
        return m
    }

    static func nonce(_ dir: UInt32, _ sid: UInt32, _ seq: UInt32) -> AES.GCM.Nonce {
        var w = Writer(); w.u32(dir); w.u32(sid); w.u32(seq)
        return try! AES.GCM.Nonce(data: w.data)
    }
}

public func randomBytes(_ n: Int) -> Data {
    Data((0..<n).map { _ in UInt8.random(in: .min ... .max) })
}

func sha256(_ label: String, _ parts: Data...) -> Data {
    var h = SHA256()
    h.update(data: Data(label.utf8))
    for p in parts { h.update(data: p) }
    return Data(h.finalize())
}

func hmac(_ key: Data, _ label: String, _ parts: Data...) -> Data {
    var h = HMAC<SHA256>(key: SymmetricKey(data: key))
    h.update(data: Data(label.utf8))
    for p in parts { h.update(data: p) }
    return Data(h.finalize())
}

func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
