package app.mtm

import java.io.File
import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPrivateKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Checks the Kotlin wire code against vectors.json, which the Swift tests generate. */
class WireTest {
    private val v: Map<String, String> = Regex("\"(\\w+)\"\\s*:\\s*\"([^\"]*)\"")
        .findAll(File("../../vectors.json").readText()).associate { it.groupValues[1] to it.groupValues[2] }

    private fun hex(key: String): ByteArray = v.getValue(key).chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private val sid get() = v.getValue("sid").toLong()
    private val phoneId get() = UUID.fromString(v.getValue("phoneId"))
    private val pairKey get() = Crypto.hmacKey(hex("pairKey"))
    private val frame = Frame(123_456_789, 14480, 6660,
        listOf(intArrayOf(1, 1000, 2000), intArrayOf(2, 3000, 4000)), listOf(intArrayOf(0, 500, 600, 120, 10)))

    private fun privateKey(key: String) = KeyFactory.getInstance("EC").generatePrivate(
        ECPrivateKeySpec(BigInteger(1, hex(key)), AlgorithmParameters.getInstance("EC")
            .apply { init(ECGenParameterSpec("secp256r1")) }.getParameterSpec(ECParameterSpec::class.java)))

    @Test fun pairingMatchesSwift() {
        val pubP = hex("phonePublic"); val pubM = hex("macPublic"); val nP = hex("phoneNonce"); val nM = hex("macNonce")
        // Java encodes the same key to the same DER that CryptoKit produced.
        assertArrayEquals(pubP, KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(pubP)).encoded)
        assertArrayEquals(hex("shared"), Crypto.shared(privateKey("phonePrivate"), pubM))
        assertArrayEquals(hex("shared"), Crypto.shared(privateKey("macPrivate"), pubP))
        assertArrayEquals(hex("commitment"), Crypto.commitment(pubM, pubP, nM))
        assertEquals(v["code"], Crypto.code(pubP, pubM, nP, nM))
        assertArrayEquals(hex("pairKey"), Crypto.pairKey(hex("shared"), pubP, pubM, nP, nM))
        assertArrayEquals(hex("doneTagAccepted"), Crypto.doneTag(pairKey, true))
    }

    @Test fun sessionMatchesSwift() {
        assertArrayEquals(hex("helloPacket"), Crypto.hello(phoneId, hex("phoneNonce"), pairKey))
        assertTrue(Crypto.verifyHelloAck(hex("helloAckPacket"), pairKey))
        val bad = hex("helloAckPacket").also { it[20] = (it[20].toInt() xor 1).toByte() }
        assertTrue(!Crypto.verifyHelloAck(bad, pairKey))
        assertArrayEquals(hex("sessionKey"), Crypto.sessionKey(pairKey, hex("phoneNonce"), hex("macNonce"), sid))

        val phone = Channel(hex("sessionKey"), sid, isMac = false)
        assertArrayEquals(hex("frameBody"), frame.body())
        assertArrayEquals(hex("framePacket"), phone.seal(Wire.FRAME, frame.body()))

        val (type, body) = phone.open(hex("heartbeatPacket"))!!
        assertEquals(Wire.HEARTBEAT, type)
        val r = Reader(body)
        assertEquals(listOf(1L, 2L, 3L), listOf(r.u64(), r.u64(), r.u32()))
        assertNull("replay must be rejected", phone.open(hex("heartbeatPacket")))
    }

    @Test fun plainPacketsMatchSwift() {
        val beacon = hex("beaconPacket")
        assertEquals(Wire.BEACON, Header.parse(beacon)!!.type)
        val r = Reader(beacon, Wire.HEADER)
        assertEquals(UUID.fromString(v.getValue("macId")), r.uuid())
        assertEquals("Mac", r.str())
        val request = Wire.plain(Wire.PAIR_REQUEST, Writer().uuid(phoneId).lp(hex("phonePublic")).str("Phone").bytes())
        assertArrayEquals(hex("pairRequestPacket"), request)
    }
}
