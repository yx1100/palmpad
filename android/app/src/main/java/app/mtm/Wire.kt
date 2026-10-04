package app.mtm

import java.io.ByteArrayOutputStream
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Wire format shared with the Swift side. See PROTOCOL.md at the repo root. */
object Wire {
    const val PORT = 47800
    const val USB_PORT = 47801   // loopback TCP the Mac reaches through adb; 2-byte length framing
    const val SERVICE = "_mtm._udp"
    const val HEADER = 12

    const val BEACON = 0x01
    const val PAIR_REQUEST = 0x10
    const val PAIR_COMMIT = 0x11
    const val PAIR_NONCE = 0x12
    const val PAIR_REVEAL = 0x13
    const val PAIR_DONE = 0x14
    const val HELLO = 0x20
    const val HELLO_ACK = 0x21
    const val HELLO_NAK = 0x22
    const val FRAME = 0x30
    const val HEARTBEAT = 0x31
    const val FEEDBACK = 0x33
    const val BYE = 0x3F

    fun header(type: Int, sid: Long = 0, seq: Long = 0): ByteArray =
        Writer().u8(0x4D).u8(1).u8(type).u8(0).u32(sid).u32(seq).bytes()

    fun plain(type: Int, body: ByteArray): ByteArray = header(type) + body
}

class Header(val type: Int, val sid: Long, val seq: Long) {
    val encrypted get() = type >= 0x30

    companion object {
        fun parse(p: ByteArray): Header? {
            if (p.size < Wire.HEADER || p[0] != 0x4D.toByte() || p[1] != 1.toByte()) return null
            val r = Reader(p, 4)
            return Header(p[2].toInt() and 0xFF, r.u32(), r.u32())
        }
    }
}

/** active: [id, x, y]; ended: [id, x, y, downAgo, upAgo]. Coordinates in 0.01 mm, ages in ms. */
class Frame(val t: Long, val w: Int, val h: Int, val active: List<IntArray>, val ended: List<IntArray>) {
    fun body(): ByteArray {
        val w = Writer().u64(t).u16(this.w).u16(h).u8(active.size)
        for (c in active) w.u8(c[0]).u16(c[1]).u16(c[2])
        w.u8(ended.size)
        for (e in ended) w.u8(e[0]).u16(e[1]).u16(e[2]).u16(e[3]).u16(e[4])
        return w.bytes()
    }
}

class Writer {
    private val out = ByteArrayOutputStream()
    fun u8(v: Int) = apply { out.write(v and 0xFF) }
    fun u16(v: Int) = apply { u8(v shr 8); u8(v) }
    fun u32(v: Long) = apply { for (s in 24 downTo 0 step 8) u8((v shr s).toInt()) }
    fun u64(v: Long) = apply { for (s in 56 downTo 0 step 8) u8((v shr s).toInt()) }
    fun raw(b: ByteArray) = apply { out.write(b) }
    fun lp(b: ByteArray) = apply { u8(b.size); raw(b) }
    fun str(s: String) = apply { lp(s.toByteArray().let { if (it.size > 255) it.copyOf(255) else it }) }
    fun uuid(u: UUID) = apply { u64(u.mostSignificantBits); u64(u.leastSignificantBits) }
    fun bytes(): ByteArray = out.toByteArray()
}

class Reader(private val b: ByteArray, private var i: Int = 0) {
    private fun take(n: Int): ByteArray {
        require(n <= b.size - i) { "truncated" }
        return b.copyOfRange(i, i + n).also { i += n }
    }
    fun u8(): Int = take(1)[0].toInt() and 0xFF
    fun u16(): Int = (u8() shl 8) or u8()
    fun u32(): Long = (u16().toLong() shl 16) or u16().toLong()
    fun u64(): Long = (u32() shl 32) or u32()
    fun raw(n: Int): ByteArray = take(n)
    fun lp(): ByteArray = take(u8())
    fun str(): String = String(lp())
    fun uuid(): UUID = UUID(u64(), u64())
}

/** Pairing and session crypto, byte-for-byte identical to Crypto.swift. */
object Crypto {
    private val rng = SecureRandom()

    fun random(n: Int) = ByteArray(n).also { rng.nextBytes(it) }
    fun hmacKey(raw: ByteArray): SecretKey = SecretKeySpec(raw, "HmacSHA256")

    fun sha256(label: String, vararg parts: ByteArray): ByteArray {
        val d = MessageDigest.getInstance("SHA-256")
        d.update(label.toByteArray())
        parts.forEach { d.update(it) }
        return d.digest()
    }

    fun hmac(key: SecretKey, label: String, vararg parts: ByteArray): ByteArray {
        val m = Mac.getInstance("HmacSHA256")
        m.init(key)
        m.update(label.toByteArray())
        parts.forEach { m.update(it) }
        return m.doFinal()
    }

    fun keyPair(): KeyPair =
        KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()

    fun shared(own: PrivateKey, peerDer: ByteArray): ByteArray {
        val peer = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(peerDer))
        return KeyAgreement.getInstance("ECDH").apply { init(own); doPhase(peer, true) }.generateSecret()
    }

    fun commitment(macPublic: ByteArray, phonePublic: ByteArray, macNonce: ByteArray) =
        sha256("mtm-commit", macPublic, phonePublic, macNonce)

    fun code(phonePublic: ByteArray, macPublic: ByteArray, phoneNonce: ByteArray, macNonce: ByteArray): String {
        val h = sha256("mtm-code", phonePublic, macPublic, phoneNonce, macNonce)
        val v = (0 until 4).fold(0L) { acc, i -> (acc shl 8) or (h[i].toLong() and 0xFF) }
        return "%06d".format(v % 1_000_000)
    }

    fun pairKey(shared: ByteArray, phonePublic: ByteArray, macPublic: ByteArray, phoneNonce: ByteArray, macNonce: ByteArray) =
        hmac(hmacKey(shared), "mtm-pair", phonePublic, macPublic, phoneNonce, macNonce)

    fun doneTag(pairKey: SecretKey, accepted: Boolean) =
        hmac(pairKey, "mtm-pair-done", byteArrayOf(if (accepted) 1 else 0)).copyOf(16)

    fun hello(phoneId: UUID, nonce: ByteArray, pairKey: SecretKey): ByteArray {
        val head = Wire.header(Wire.HELLO)
        val body = Writer().uuid(phoneId).raw(nonce).bytes()
        return head + body + hmac(pairKey, "mtm-hello", head, body).copyOf(16)
    }

    fun verifyHelloAck(p: ByteArray, pairKey: SecretKey): Boolean {
        if (p.size <= Wire.HEADER + 16) return false
        val tag = hmac(pairKey, "mtm-hello-ack", p.copyOf(Wire.HEADER), p.copyOfRange(Wire.HEADER, p.size - 16)).copyOf(16)
        return MessageDigest.isEqual(tag, p.copyOfRange(p.size - 16, p.size))
    }

    fun sessionKey(pairKey: SecretKey, phoneNonce: ByteArray, macNonce: ByteArray, sid: Long) =
        hmac(pairKey, "mtm-session", phoneNonce, macNonce, Writer().u32(sid).bytes()).copyOf(16)
}

/** AES-128-GCM session channel. Confine to one thread. */
class Channel(key: ByteArray, val sid: Long, isMac: Boolean) {
    private val k = SecretKeySpec(key, "AES")
    private val sendDir = if (isMac) 1L else 0L
    private val recvDir = 1L - sendDir
    private var sendSeq = 0L
    private var recvSeq = 0L

    fun seal(type: Int, body: ByteArray): ByteArray {
        sendSeq += 1
        val head = Wire.header(type, sid, sendSeq)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, k, GCMParameterSpec(128, nonce(sendDir, sendSeq)))
        c.updateAAD(head)
        return head + c.doFinal(body)
    }

    /** Authenticated, replay-checked (type, body), or null. */
    fun open(p: ByteArray): Pair<Int, ByteArray>? {
        val h = Header.parse(p) ?: return null
        if (!h.encrypted || h.sid != sid || h.seq <= recvSeq || p.size < Wire.HEADER + 16) return null
        return try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, k, GCMParameterSpec(128, nonce(recvDir, h.seq)))
            c.updateAAD(p, 0, Wire.HEADER)
            val plain = c.doFinal(p, Wire.HEADER, p.size - Wire.HEADER)
            recvSeq = h.seq
            h.type to plain
        } catch (e: Exception) {
            null
        }
    }

    private fun nonce(dir: Long, seq: Long) = Writer().u32(dir).u32(sid).u32(seq).bytes()
}
