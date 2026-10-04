package app.mtm

import android.content.Context
import android.view.MotionEvent
import android.view.View
import kotlin.math.roundToInt

/** The trackpad card: reports every touch change as an absolute-state frame in 0.01 mm. */
class TouchSurface(ctx: Context, private val link: Link) : View(ctx) {
    private val mmX = 25.4f / resources.displayMetrics.xdpi
    private val mmY = 25.4f / resources.displayMetrics.ydpi
    private val ids = HashMap<Int, LongArray>()             // pointer id → [our id, down time ns]
    private val positions = LinkedHashMap<Int, IntArray>()  // our id → [x, y]
    private val ended = ArrayList<LongArray>()              // [id, x, y, down ns, up ns]
    private var nextId = 0
    private var lastSent = 0L
    private var ticking = false

    override fun onTouchEvent(e: MotionEvent): Boolean {
        val t = e.eventTimeNanos
        val lifting = when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                requestUnbufferedDispatch(e)   // deliver at the digitizer rate, not batched per frame
                link.poke()
                begin(e, e.actionIndex, t); -1
            }
            MotionEvent.ACTION_POINTER_DOWN -> { begin(e, e.actionIndex, t); -1 }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> { finish(e, e.actionIndex, t); e.actionIndex }
            MotionEvent.ACTION_CANCEL -> { for (i in 0 until e.pointerCount) finish(e, i, t); -1 }
            else -> -1
        }
        for (i in 0 until e.pointerCount) {
            if (i == lifting) continue
            val info = ids[e.getPointerId(i)] ?: continue
            positions[info[0].toInt()] = intArrayOf(mm(e.getX(i), mmX), mm(e.getY(i), mmY))
        }
        send(t)
        if (!ticking) {
            ticking = true
            postOnAnimation(tick)
        }
        return true
    }

    private fun begin(e: MotionEvent, i: Int, t: Long) {
        ids[e.getPointerId(i)] = longArrayOf(nextId.toLong(), t)
        nextId = (nextId + 1) and 0xFF
    }

    private fun finish(e: MotionEvent, i: Int, t: Long) {
        val info = ids.remove(e.getPointerId(i)) ?: return
        val id = info[0].toInt()
        positions.remove(id)
        ended += longArrayOf(id.toLong(), mm(e.getX(i), mmX).toLong(), mm(e.getY(i), mmY).toLong(), info[1], t)
    }

    private fun send(t: Long) {
        ended.removeAll { t - it[4] > 150_000_000L }
        link.send(Frame(t / 1000, mm(width.toFloat(), mmX), mm(height.toFloat(), mmY),
            positions.map { (id, p) -> intArrayOf(id, p[0], p[1]) },
            ended.map { intArrayOf(it[0].toInt(), it[1].toInt(), it[2].toInt(), ms(t - it[3]), ms(t - it[4])) }))
        lastSent = System.nanoTime()
    }

    /** While fingers are down or lifts are still being repeated, re-send the state so a lost packet cannot strand a touch. */
    private val tick = object : Runnable {
        override fun run() {
            val now = System.nanoTime()
            ended.removeAll { now - it[4] > 150_000_000L }
            if (positions.isEmpty() && ended.isEmpty()) {
                ticking = false
                return
            }
            if (now - lastSent >= 16_000_000L) send(now)
            postOnAnimation(this)
        }
    }

    private fun mm(px: Float, k: Float) = (px * k * 100).roundToInt().coerceIn(0, 65535)
    private fun ms(ns: Long) = (ns / 1_000_000).toInt().coerceIn(0, 65535)
}
