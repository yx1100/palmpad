package app.mtm

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import android.security.keystore.KeyProperties
import android.security.keystore.KeyProtection
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.io.DataInputStream
import java.security.KeyPair
import java.security.KeyStore
import java.util.UUID
import java.util.concurrent.Executor
import javax.crypto.SecretKey
import javax.crypto.spec.SecretKeySpec

/**
 * Discovery, pairing and the encrypted UDP session with the Mac.
 * All state lives on the "mtm-net" thread; UI updates are posted to the main thread.
 */
class Link(private val ctx: Context, private val onUi: (Ui) -> Unit, private val onFeedback: () -> Unit) {
    enum class Phase { IDLE, PAIRING, REJECTED, NEEDS_PAIRING, CONNECTING, CONNECTED, REPLACED, OFF }
    data class MacInfo(val id: UUID, val name: String, val host: InetAddress)
    /** linkName: "Wi-Fi", "热点直连" when the Mac is on this phone's hotspot, or "有线" over the cable. */
    data class Ui(val phase: Phase, val code: String?, val macs: List<MacInfo>, val pairedName: String?, val rttMs: Int?,
                  val linkName: String? = null)

    private val thread = HandlerThread("mtm-net", Process.THREAD_PRIORITY_URGENT_DISPLAY).apply { start() }
    private val net = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    private val prefs = ctx.getSharedPreferences("mtm", Context.MODE_PRIVATE)
    private val phoneId: UUID = prefs.getString("phoneId", null)?.let(UUID::fromString)
        ?: UUID.randomUUID().also { prefs.edit().putString("phoneId", it.toString()).apply() }
    private val phoneName: String = Settings.Global.getString(ctx.contentResolver, Settings.Global.DEVICE_NAME)
        ?: android.os.Build.MODEL

    private var socket: DatagramSocket? = null
    private var usbServer: ServerSocket? = null
    private var usb: Socket? = null       // the Mac over the cable, through adb
    private var viaUsb = false            // the session runs over `usb`
    private var running = false
    private var paused = false            // another phone took over; resume on touch
    private var userOff = false           // power button: stays off until pressed again
    private var wifiNetwork: Network? = null
    private var ui = Ui(Phase.IDLE, null, emptyList(), prefs.getString("macName", null), null)
    private val found = HashMap<UUID, MacInfo>()
    private var macId: UUID? = prefs.getString("macId", null)?.let(UUID::fromString)
    private var macHost: String? = prefs.getString("macHost", null)
    private var pairKey: SecretKey? = null
    private var helloNonce = Crypto.random(16)
    private var channel: Channel? = null
    private var peer: InetAddress? = null
    private var lastRecv = 0L
    private var peerT = 0L
    private var peerAt = 0L
    private var rttShownAt = 0L           // the UI gets one latency sample a second
    private var ticks = 0
    private var pairing: Flow? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private val infoCallbacks = ArrayList<NsdManager.ServiceInfoCallback>()
    private val resolving = HashSet<String>()
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null

    private class Flow(val host: InetAddress) {
        val keys: KeyPair = Crypto.keyPair()
        val nonce: ByteArray = Crypto.random(16)
        val started = SystemClock.uptimeMillis()
        var macId: UUID? = null
        var macName = ""
        var macPublic: ByteArray? = null
        var commitment: ByteArray? = null
        var pairKey: ByteArray? = null
    }

    // MARK: lifecycle (any thread)

    fun start() = net.post {
        if (running) return@post
        running = true
        pairKey = macId?.let { Keys.load("mac-$it") }
        openSocket()
        startUsbListener()
        startDiscovery()
        watchWifi()
        wifiLock = ctx.getSystemService(WifiManager::class.java)
            .createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "mtm")
            .apply { setReferenceCounted(false); acquire() }
        publish(ui.copy(phase = if (pairKey != null) Phase.CONNECTING else Phase.IDLE))
        net.post(tick)
    }

    fun stop() = net.post {
        if (!running) return@post
        running = false
        channel?.let { sendSession(it.seal(Wire.BYE, byteArrayOf(0))) }
        disconnect()
        socket?.close()
        socket = null
        usbServer?.close()
        usbServer = null
        usb?.let { runCatching { it.close() } }
        usb = null
        val nsd = ctx.getSystemService(NsdManager::class.java)
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        discovery = null
        infoCallbacks.forEach { runCatching { nsd.unregisterServiceInfoCallback(it) } }
        infoCallbacks.clear()
        synchronized(resolving) { resolving.clear() }
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
        wifiCallback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        wifiCallback = null
        cm.bindProcessToNetwork(null)
        wifiLock?.release()
        wifiLock = null
        pairing = null
    }

    /** Power button: hand the Mac back (other phones may take over), or reconnect. */
    fun toggleConnection() = net.post {
        if (userOff) {
            userOff = false
            paused = false
            publish(ui.copy(phase = if (pairKey != null) Phase.CONNECTING else Phase.IDLE))
            attemptConnect()
        } else {
            channel?.let { sendSession(it.seal(Wire.BYE, byteArrayOf(0))) }
            disconnect()
            userOff = true
            publish(ui.copy(phase = Phase.OFF))
        }
    }

    /** Touching the surface while disconnected retries immediately (also resumes after a takeover). */
    fun poke() = net.post {
        if (channel != null || pairKey == null || userOff) return@post
        paused = false
        publish(ui.copy(phase = Phase.CONNECTING))
        attemptConnect()
    }

    fun send(f: Frame) = net.post {
        val ch = channel ?: return@post
        sendSession(ch.seal(Wire.FRAME, f.body()))
    }

    fun pair(m: MacInfo) = net.post {
        pairing = Flow(m.host)
        publish(ui.copy(phase = Phase.PAIRING, code = null))
        sendPairing()
    }

    fun forget() = net.post {
        macId?.let { Keys.delete("mac-$it") }
        disconnect()
        macId = null
        macHost = null
        pairKey = null
        prefs.edit().remove("macId").remove("macName").remove("macHost").apply()
        publish(ui.copy(phase = Phase.IDLE, pairedName = null))
    }

    // MARK: network

    private fun openSocket() {
        socket?.close()
        val s = DatagramSocket(null)
        s.reuseAddress = true
        s.trafficClass = 0xB8   // DSCP EF → Wi-Fi voice queue
        try {
            s.bind(InetSocketAddress(Wire.PORT))   // the Mac's hotspot beacons arrive here
        } catch (e: Exception) {
            s.bind(InetSocketAddress(0))
        }
        socket = s
        Thread({
            val buf = ByteArray(2048)
            while (!s.isClosed) {
                val p = DatagramPacket(buf, buf.size)
                try { s.receive(p) } catch (e: Exception) { break }
                val data = p.data.copyOf(p.length)
                val from = p.address
                net.post { handle(data, from) }
            }
        }, "mtm-rx").apply { priority = Thread.MAX_PRIORITY; start() }
    }

    private fun transmit(bytes: ByteArray, host: InetAddress) {
        try { socket?.send(DatagramPacket(bytes, bytes.size, host, Wire.PORT)) } catch (e: Exception) { }
    }

    /** Session packets go over whichever path the session was set up on. */
    private fun sendSession(bytes: ByteArray) {
        if (viaUsb) sendUsb(bytes) else peer?.let { transmit(bytes, it) }
    }

    /**
     * With USB debugging on and the cable in, the Mac reaches this loopback port through adb, the way it reaches
     * an iPhone through usbmuxd. A session over the cable replaces a wireless one and falls back when it is pulled.
     */
    private fun startUsbListener() {
        val server = runCatching {
            ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(InetAddress.getLoopbackAddress(), Wire.USB_PORT)) }
        }.getOrNull() ?: return
        usbServer = server
        Thread({
            while (!server.isClosed) {
                val s = try { server.accept() } catch (e: Exception) { break }
                s.tcpNoDelay = true
                net.post { usbOpened(s) }
                Thread({ readUsb(s) }, "mtm-usb-rx").apply { priority = Thread.MAX_PRIORITY; start() }
            }
        }, "mtm-usb").start()
    }

    private fun readUsb(s: Socket) {
        try {
            val input = DataInputStream(s.getInputStream())
            while (true) {
                val data = ByteArray(input.readUnsignedShort())
                input.readFully(data)
                net.post { if (s === usb) handleUsb(data) }
            }
        } catch (e: Exception) {
            // end of stream: cable pulled, adb restarted or the Mac quit
        }
        net.post { usbClosed(s) }
    }

    private fun usbOpened(s: Socket) {
        usb?.let { runCatching { it.close() } }
        usb = s
        val key = pairKey
        if (key != null && !userOff) {
            helloNonce = Crypto.random(16)
            sendUsb(Crypto.hello(phoneId, helloNonce, key))
        }
    }

    private fun usbClosed(s: Socket) {
        runCatching { s.close() }
        if (usb !== s) return
        usb = null
        if (viaUsb) {
            disconnect()
            publish(ui.copy(phase = Phase.CONNECTING))
            attemptConnect()
        }
    }

    private fun sendUsb(bytes: ByteArray) {
        val s = usb ?: return
        try {
            s.getOutputStream().write(byteArrayOf((bytes.size shr 8).toByte(), bytes.size.toByte()) + bytes)
        } catch (e: Exception) {
            runCatching { s.close() }   // the reader sees the end and falls back
        }
    }

    private fun handleUsb(data: ByteArray) {
        val h = Header.parse(data) ?: return
        try {
            when {
                h.encrypted -> if (viaUsb) handleSession(data)
                h.type == Wire.HELLO_ACK -> helloAck(h, Reader(data, Wire.HEADER), data, null)
                h.type == Wire.HELLO_NAK -> if (channel == null) publish(ui.copy(phase = Phase.NEEDS_PAIRING))
            }
        } catch (e: Exception) {
            // malformed packet; ignore
        }
    }

    private fun startDiscovery() {
        val nsd = ctx.getSystemService(NsdManager::class.java)
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                synchronized(resolving) { if (!resolving.add(info.serviceName)) return }
                val cb = object : NsdManager.ServiceInfoCallback {
                    override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {}
                    override fun onServiceUpdated(si: NsdServiceInfo) {
                        val id = si.attributes["id"]?.let { runCatching { UUID.fromString(String(it)) }.getOrNull() } ?: return
                        val host = si.hostAddresses.firstOrNull { it is Inet4Address } ?: si.hostAddresses.firstOrNull() ?: return
                        net.post { discovered(MacInfo(id, si.serviceName, host)) }
                    }
                    override fun onServiceLost() {}
                    override fun onServiceInfoCallbackUnregistered() {}
                }
                runCatching { nsd.registerServiceInfoCallback(info, Executor { it.run() }, cb) }
                    .onSuccess { net.post { infoCallbacks += cb } }
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                synchronized(resolving) { resolving.remove(info.serviceName) }
            }
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        nsd.discoverServices(Wire.SERVICE, NsdManager.PROTOCOL_DNS_SD, listener)
        discovery = listener
    }

    /**
     * Keeps traffic on Wi-Fi even when that Wi-Fi has no internet and Android would otherwise prefer
     * cellular. ponytail: process-wide binding; with Wi-Fi and hotspot both on, hotspot peers become unreachable.
     */
    private fun watchWifi() {
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                wifiNetwork = network
                cm.bindProcessToNetwork(network)
                net.post { networkChanged() }
            }
            override fun onLost(network: Network) {
                if (wifiNetwork == network) wifiNetwork = null
                cm.bindProcessToNetwork(null)
                net.post { networkChanged() }
            }
        }
        cm.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), cb)
        wifiCallback = cb
    }

    /** Sockets keep the network they were created on, so reopen after a change. The session survives. */
    private fun networkChanged() {
        if (!running) return
        openSocket()
        if (channel == null) attemptConnect()
    }

    private fun discovered(m: MacInfo) {
        val isNew = found[m.id]?.host != m.host
        found[m.id] = m
        publish(ui.copy(macs = found.values.sortedBy { it.name }))
        if (isNew && m.id == macId && channel == null) attemptConnect()
    }

    // MARK: session

    /** HELLO to every known address of the paired Mac; the first HELLO_ACK wins. */
    private fun attemptConnect() {
        if (!running || paused || userOff || channel != null) return
        val id = macId ?: return
        val key = pairKey ?: return
        val hello = Crypto.hello(phoneId, helloNonce, key)
        sendUsb(hello)   // the cable wins when present
        val hosts = LinkedHashSet<InetAddress>()
        found[id]?.let { hosts += it.host }
        macHost?.let { runCatching { InetAddress.getByName(it) }.getOrNull() }?.let { hosts += it }
        hosts.forEach { transmit(hello, it) }
    }

    private fun handle(data: ByteArray, from: InetAddress) {
        val h = Header.parse(data) ?: return
        try {
            if (h.encrypted) handleSession(data) else handlePlain(h, Reader(data, Wire.HEADER), data, from)
        } catch (e: Exception) {
            // malformed packet from the network; ignore
        }
    }

    private fun handleSession(data: ByteArray) {
        val ch = channel ?: return
        val (type, body) = ch.open(data) ?: return
        lastRecv = SystemClock.uptimeMillis()
        when (type) {
            Wire.HEARTBEAT -> {
                val r = Reader(body)
                val t = r.u64()
                val echoT = r.u64()
                val hold = r.u32()
                peerT = t
                peerAt = System.nanoTime()
                if (echoT != 0L && lastRecv - rttShownAt >= 1000) {
                    rttShownAt = lastRecv
                    publish(ui.copy(rttMs = ((System.nanoTime() / 1000 - echoT - hold) / 1000).toInt()))
                }
            }
            Wire.FEEDBACK -> main.post(onFeedback)
            Wire.BYE -> {
                val replaced = Reader(body).u8() == 1
                disconnect()
                paused = replaced
                publish(ui.copy(phase = if (replaced) Phase.REPLACED else Phase.CONNECTING))
            }
        }
    }

    private fun handlePlain(h: Header, r: Reader, data: ByteArray, from: InetAddress) {
        when (h.type) {
            Wire.BEACON -> discovered(MacInfo(r.uuid(), r.str(), from))
            Wire.HELLO_ACK -> helloAck(h, r, data, from)
            Wire.HELLO_NAK -> if (channel == null) publish(ui.copy(phase = Phase.NEEDS_PAIRING))
            Wire.PAIR_COMMIT -> {
                val f = pairing ?: return
                if (f.macPublic != null || f.host != from) return
                f.macId = r.uuid()
                f.macPublic = r.lp()
                f.commitment = r.raw(32)
                f.macName = r.str()
                sendPairing()
            }
            Wire.PAIR_REVEAL -> {
                val f = pairing ?: return
                val pubM = f.macPublic ?: return
                if (f.pairKey != null) return
                val nM = r.raw(16)
                val pubP = f.keys.public.encoded
                if (!Crypto.commitment(pubM, pubP, nM).contentEquals(f.commitment)) return
                f.pairKey = Crypto.pairKey(Crypto.shared(f.keys.private, pubM), pubP, pubM, f.nonce, nM)
                publish(ui.copy(phase = Phase.PAIRING, code = Crypto.code(pubP, pubM, f.nonce, nM)))
            }
            Wire.PAIR_DONE -> {
                val f = pairing ?: return
                val raw = f.pairKey ?: return
                val id = f.macId ?: return
                val accepted = r.u8() == 1
                if (!Crypto.doneTag(Crypto.hmacKey(raw), accepted).contentEquals(r.raw(16))) return
                pairing = null
                if (!accepted) return publish(ui.copy(phase = Phase.REJECTED, code = null))
                Keys.save("mac-$id", raw)
                disconnect()
                macId = id
                macHost = from.hostAddress
                pairKey = Keys.load("mac-$id")
                paused = false
                prefs.edit().putString("macId", id.toString()).putString("macName", f.macName).putString("macHost", macHost).apply()
                publish(ui.copy(phase = Phase.CONNECTING, code = null, pairedName = f.macName))
                attemptConnect()
            }
        }
    }

    /** `from` is null for an answer over the cable. */
    private fun helloAck(h: Header, r: Reader, data: ByteArray, from: InetAddress?) {
        val id = r.uuid()
        val nP = r.raw(16)
        val nM = r.raw(16)
        val key = pairKey ?: return
        val upgrade = from == null && !viaUsb   // cable plugged in during a wireless session
        if ((channel != null && !upgrade) || id != phoneId || !nP.contentEquals(helloNonce) || !Crypto.verifyHelloAck(data, key)) return
        // The same HELLO can be answered over both paths; keep the sequence numbers of that session.
        if (channel?.sid != h.sid) channel = Channel(Crypto.sessionKey(key, nP, nM, h.sid), h.sid, isMac = false)
        viaUsb = from == null
        peer = from
        lastRecv = SystemClock.uptimeMillis()
        peerT = 0
        heartbeat()   // proves the key, which makes this the Mac's active session
        if (from != null) {
            macHost = from.hostAddress
            prefs.edit().putString("macHost", macHost).apply()
        }
        publish(ui.copy(phase = Phase.CONNECTED, linkName = if (from == null) "有线" else linkName(from)))
    }

    /** Wi-Fi when the Mac is inside our Wi-Fi subnet; otherwise it must be a client of our hotspot. */
    private fun linkName(mac: InetAddress): String {
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
        val lp = wifiNetwork?.let { cm.getLinkProperties(it) } ?: return "热点直连"
        return if (lp.linkAddresses.any { inPrefix(it.address.address, it.prefixLength, mac.address) }) "Wi-Fi" else "热点直连"
    }

    private fun inPrefix(a: ByteArray, prefix: Int, b: ByteArray): Boolean {
        if (a.size != b.size) return false
        var bits = prefix
        for (i in a.indices) {
            if (bits <= 0) break
            val mask = if (bits >= 8) 0xFF else (0xFF shl (8 - bits)) and 0xFF
            if ((a[i].toInt() and mask) != (b[i].toInt() and mask)) return false
            bits -= 8
        }
        return true
    }

    private fun sendPairing() {
        val f = pairing ?: return
        val packet = if (f.macPublic == null) {
            Wire.plain(Wire.PAIR_REQUEST, Writer().uuid(phoneId).lp(f.keys.public.encoded).str(phoneName).bytes())
        } else {
            Wire.plain(Wire.PAIR_NONCE, Writer().uuid(phoneId).raw(f.nonce).bytes())   // also polls for the decision
        }
        transmit(packet, f.host)
    }

    private fun heartbeat() {
        val ch = channel ?: return
        val now = System.nanoTime()
        val hold = if (peerT == 0L) 0L else ((now - peerAt) / 1000).coerceAtMost(0xFFFFFFFFL)
        sendSession(ch.seal(Wire.HEARTBEAT, Writer().u64(now / 1000).u64(peerT).u32(hold).bytes()))
    }

    private fun disconnect() {
        channel = null
        peer = null
        viaUsb = false   // the cable itself stays open for the next attempt
        helloNonce = Crypto.random(16)
        rttShownAt = 0
        publish(ui.copy(rttMs = null))
    }

    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            housekeeping()
            net.postDelayed(this, 50)
        }
    }

    private fun housekeeping() {
        ticks++
        val now = SystemClock.uptimeMillis()
        if (channel != null) {
            if (now - lastRecv > 1000) {
                disconnect()
                publish(ui.copy(phase = Phase.CONNECTING))
            } else {
                heartbeat()
            }
        } else if (ticks % 10 == 0) {
            attemptConnect()
        }
        val f = pairing ?: return
        if (now - f.started > 120_000) {
            pairing = null
            publish(ui.copy(phase = Phase.IDLE, code = null))
        } else if (ticks % 10 == 0) {
            sendPairing()
        }
    }

    private fun publish(u: Ui) {
        ui = u
        main.post { onUi(u) }
    }
}

/** Pairing keys live in the Android Keystore as non-exportable HMAC keys. */
object Keys {
    private fun store() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun save(alias: String, raw: ByteArray) = store().setEntry(
        alias, KeyStore.SecretKeyEntry(SecretKeySpec(raw, "HmacSHA256")),
        KeyProtection.Builder(KeyProperties.PURPOSE_SIGN).build())

    fun load(alias: String): SecretKey? = (store().getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.secretKey

    fun delete(alias: String) = store().deleteEntry(alias)
}
