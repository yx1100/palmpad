import CryptoKit
import Foundation
import XCTest
@testable import Wire

final class WireTests: XCTestCase {
    let phoneID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let macID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let frame = Frame(t: 123_456_789, width: 14480, height: 6660,
                      active: [.init(id: 1, x: 1000, y: 2000), .init(id: 2, x: 3000, y: 4000)],
                      ended: [.init(id: 0, x: 500, y: 600, downAgo: 120, upAgo: 10)])

    func testCodecRoundTrip() throws {
        let key = Data(repeating: 7, count: 91), n = Data(repeating: 9, count: 16), tag = Data(repeating: 3, count: 16)
        let all: [Message] = [
            .beacon(macID: macID, name: "Mac 电脑"),
            .pairRequest(phoneID: phoneID, publicKey: key, name: "iPhone"),
            .pairCommit(macID: macID, publicKey: key, commitment: Data(repeating: 5, count: 32), name: "Mac"),
            .pairNonce(phoneID: phoneID, nonce: n), .pairReveal(nonce: n), .pairDone(accepted: true, tag: tag),
            .hello(phoneID: phoneID, nonce: n, tag: tag), .helloAck(phoneID: phoneID, phoneNonce: n, macNonce: n, tag: tag),
            .helloNak(reason: 1), .frame(frame), .heartbeat(Heartbeat(t: 1, echoT: 2, echoHold: 3)),
            .feedback(kind: 1), .bye(reason: 1),
        ]
        for m in all { XCTAssertEqual(try Message.decode(m.type, m.body), m) }
        XCTAssertThrowsError(try Message.decode(.frame, Message.frame(frame).body.dropLast()))
        XCTAssertNil(Header(packet: Data([0x4D, 1, 0x99, 0] + [UInt8](repeating: 0, count: 8))))
    }

    func testPairingAndSession() throws {
        let kp = P256.KeyAgreement.PrivateKey(), km = P256.KeyAgreement.PrivateKey()
        let pubP = Pairing.publicKey(kp), pubM = Pairing.publicKey(km)
        let nP = randomBytes(16), nM = randomBytes(16)
        let sharedP = try Pairing.shared(kp, peer: pubM), sharedM = try Pairing.shared(km, peer: pubP)
        XCTAssertEqual(sharedP, sharedM)
        XCTAssertEqual(Pairing.code(phonePublic: pubP, macPublic: pubM, phoneNonce: nP, macNonce: nM).count, 6)
        let pairKey = Pairing.pairKey(shared: sharedP, phonePublic: pubP, macPublic: pubM, phoneNonce: nP, macNonce: nM)

        let hello = Handshake.hello(phoneID: phoneID, nonce: nP, pairKey: pairKey)
        XCTAssertTrue(Handshake.verify(hello, pairKey: pairKey))
        XCTAssertFalse(Handshake.verify(hello, pairKey: randomBytes(32)))
        var bad = hello; bad[bad.count - 20] ^= 1
        XCTAssertFalse(Handshake.verify(bad, pairKey: pairKey))

        let key = Handshake.sessionKey(pairKey: pairKey, phoneNonce: nP, macNonce: nM, sid: 42)
        var phone = SecureChannel(key: key, sid: 42, isMac: false)
        var mac = SecureChannel(key: key, sid: 42, isMac: true)
        let p1 = phone.seal(.frame(frame))
        XCTAssertEqual(mac.open(p1), .frame(frame))
        XCTAssertNil(mac.open(p1), "replay must be rejected")
        let p2 = phone.seal(.heartbeat(Heartbeat(t: 5, echoT: 0, echoHold: 0)))
        var tampered = p2; tampered[tampered.count - 1] ^= 1
        XCTAssertNil(mac.open(tampered))
        XCTAssertNotNil(mac.open(p2))
        XCTAssertNil(phone.open(phone.seal(.bye(reason: 0))), "own direction must not decrypt")
        XCTAssertEqual(phone.open(mac.seal(.feedback(kind: 1))), .feedback(kind: 1))
    }

    /// Cross-language vectors shared with the Kotlin client. `MTM_WRITE_VECTORS=1 swift test` regenerates them.
    func testVectors() throws {
        let kp = try P256.KeyAgreement.PrivateKey(rawRepresentation: sha256("phone-key"))
        let km = try P256.KeyAgreement.PrivateKey(rawRepresentation: sha256("mac-key"))
        let pubP = Pairing.publicKey(kp), pubM = Pairing.publicKey(km)
        let nP = Data(1...16), nM = Data(17...32)
        let shared = try Pairing.shared(kp, peer: pubM)
        let pairKey = Pairing.pairKey(shared: shared, phonePublic: pubP, macPublic: pubM, phoneNonce: nP, macNonce: nM)
        let sid: UInt32 = 0x0102_0304
        let key = Handshake.sessionKey(pairKey: pairKey, phoneNonce: nP, macNonce: nM, sid: sid)
        var phone = SecureChannel(key: key, sid: sid, isMac: false)
        var mac = SecureChannel(key: key, sid: sid, isMac: true)

        let v: [String: String] = [
            "phonePrivate": kp.rawRepresentation.hex, "macPrivate": km.rawRepresentation.hex,
            "phonePublic": pubP.hex, "macPublic": pubM.hex, "phoneNonce": nP.hex, "macNonce": nM.hex,
            "phoneId": phoneID.uuidString, "macId": macID.uuidString, "sid": String(sid),
            "commitment": Pairing.commitment(macPublic: pubM, phonePublic: pubP, macNonce: nM).hex,
            "code": Pairing.code(phonePublic: pubP, macPublic: pubM, phoneNonce: nP, macNonce: nM),
            "shared": shared.hex, "pairKey": pairKey.hex,
            "doneTagAccepted": Pairing.doneTag(pairKey: pairKey, accepted: true).hex,
            "helloPacket": Handshake.hello(phoneID: phoneID, nonce: nP, pairKey: pairKey).hex,
            "helloAckPacket": Handshake.helloAck(sid: sid, phoneID: phoneID, phoneNonce: nP, macNonce: nM, pairKey: pairKey).hex,
            "sessionKey": key.hex,
            "beaconPacket": Packet.plain(.beacon(macID: macID, name: "Mac")).hex,
            "pairRequestPacket": Packet.plain(.pairRequest(phoneID: phoneID, publicKey: pubP, name: "Phone")).hex,
            "frameBody": Message.frame(frame).body.hex,
            "framePacket": phone.seal(.frame(frame)).hex,
            "heartbeatPacket": mac.seal(.heartbeat(Heartbeat(t: 1, echoT: 2, echoHold: 3))).hex,
        ]
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("vectors.json")
        if ProcessInfo.processInfo.environment["MTM_WRITE_VECTORS"] != nil {
            try JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        }
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: String]
        XCTAssertEqual(stored, v)
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
