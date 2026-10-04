package app.mtm

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Bundle
import android.provider.Settings
import android.text.TextUtils
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.RoundedCorner
import android.view.View
import android.view.ViewGroup
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.ScrollView
import android.widget.TextView
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Full-screen trackpad card with two small buttons at the ends of the camera's edge, where the status bar keeps its
 * clock and battery: status (light and link type; tap to choose a Mac) and settings (disconnect, settings).
 */
class MainActivity : Activity() {
    private lateinit var link: Link
    private lateinit var surface: TouchSurface
    private lateinit var trackpad: TrackpadLayout
    private lateinit var cardFrame: FrameLayout
    private lateinit var dot: View
    private lateinit var status: TextView
    private lateinit var hint: TextView
    private lateinit var pairing: ScrollView
    private lateinit var macList: LinearLayout
    private lateinit var message: TextView
    private var ui = Link.Ui(Link.Phase.IDLE, null, emptyList(), null, null)

    private val card = 0xFF1C1C1E.toInt()
    private val pillColor = 0xFF2C2C2E.toInt()
    private val medium: Typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    private val rim = 0xFF3A3A3C.toInt()
    private val grey = 0xFF8E8E93.toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            display?.supportedModes?.maxByOrNull { it.refreshRate }?.let { preferredDisplayModeId = it.modeId }
        }
        link = Link(this, ::render) { surface.performHapticFeedback(HapticFeedbackConstants.CONFIRM) }
        surface = TouchSurface(this, link)
        trackpad = buildTrackpad()
        pairing = buildPairing()
        setContentView(FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(trackpad, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
            addView(pairing, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        })
        window.insetsController?.apply {
            hide(WindowInsets.Type.systemBars())
            systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        testOrientation(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        testOrientation(intent)
    }

    /** Layout checks from adb on debug builds: am start ... --ei orientation 0|8 (landscape / reverse landscape). */
    private fun testOrientation(intent: Intent) {
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0 && intent.hasExtra("orientation")) {
            requestedOrientation = intent.getIntExtra("orientation", requestedOrientation)
        }
    }

    override fun onResume() {
        super.onResume()
        warnThreeFingerGestures()
        if (checkSelfPermission(LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED) link.start()
        else requestPermissions(arrayOf(LOCAL_NETWORK), 1)
    }

    override fun onPause() {
        super.onPause()
        link.stop()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) link.start()
        else message.text = "需要「附近设备」权限才能在本地网络中找到 Mac。"
    }

    // MARK: trackpad screen

    private fun buildTrackpad(): TrackpadLayout {
        hint = TextView(this).apply { setTextColor(grey); textSize = 16f; gravity = Gravity.CENTER }
        cardFrame = FrameLayout(this).apply {
            background = GradientDrawable().apply { setColor(card) }
            clipToOutline = true
            addView(surface, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
            addView(hint, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.CENTER))
        }
        dot = View(this).apply { background = GradientDrawable().apply { shape = GradientDrawable.OVAL } }
        status = pillText()
        val statusPill = pill(dot to dp(7), status).apply { setOnClickListener { pickMac() } }
        val settingsPill = pill(icon(R.drawable.ic_settings) to dp(16), pillText().apply { text = "设置" }).apply {
            contentDescription = "设置"
            setOnClickListener { showMenu(this) }
        }
        return TrackpadLayout(this, cardFrame, statusPill, settingsPill).apply { touchTarget = surface }
    }

    /** A capsule holding a small icon and a word; `TrackpadLayout` sizes and places it. */
    private fun pill(icon: Pair<View, Int>, text: TextView) = LinearLayout(this).apply {
        gravity = Gravity.CENTER
        background = pressable(GradientDrawable().apply { setColor(pillColor); cornerRadius = dp(TrackpadLayout.CHIP_H) / 2f })
        addView(icon.first, LinearLayout.LayoutParams(icon.second, icon.second).apply { marginEnd = dp(6) })
        addView(text, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
    }

    private fun pillText() = TextView(this).apply {
        setTextColor(Color.WHITE); textSize = 14f; typeface = medium; maxLines = 1; includeFontPadding = false
    }

    private fun icon(res: Int) = ImageView(this).apply {
        setImageResource(res)
        imageTintList = ColorStateList.valueOf(Color.WHITE)
        scaleType = ImageView.ScaleType.FIT_CENTER
    }

    /** Settings panel: which Mac and how it is connected on top, set apart from the actions below. */
    private fun showMenu(anchor: View) {
        lateinit var popup: PopupWindow
        fun text(s: String, size: Float, color: Int, face: Typeface = Typeface.DEFAULT) = TextView(this).apply {
            text = s; textSize = size; setTextColor(color); typeface = face
            maxLines = 1; ellipsize = TextUtils.TruncateAt.END; includeFontPadding = false
        }
        fun row(res: Int, label: String, action: () -> Unit) = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), 0, dp(16), 0)
            background = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), null, ColorDrawable(Color.WHITE))
            addView(icon(res), LinearLayout.LayoutParams(dp(20), dp(20)))
            addView(text(label, 15f, Color.WHITE), LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { marginStart = dp(14) })
            setOnClickListener { popup.dismiss(); action() }
        }
        val light = View(this).apply {
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(dotColor(ui)) }
        }
        val state = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            addView(light, LinearLayout.LayoutParams(dp(7), dp(7)).apply { marginEnd = dp(6) })
            addView(text(stateLine(ui), 13f, grey))
        }
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(14))
            addView(text("当前 Mac", 12f, grey))
            addView(text(ui.pairedName ?: "未配对", 17f, Color.WHITE, medium), LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { topMargin = dp(6) })
            addView(state, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { topMargin = dp(6) })
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 0, 0, dp(6))
            addView(header)
            addView(View(context).apply { setBackgroundColor(rim) }, LinearLayout.LayoutParams(MATCH_PARENT, 1))
            addView(row(R.drawable.ic_power, if (ui.phase == Link.Phase.OFF) "重新连接" else "断开连接") { link.toggleConnection() },
                LinearLayout.LayoutParams(MATCH_PARENT, dp(48)).apply { topMargin = dp(6) })
            addView(row(R.drawable.ic_settings, "设置与配对") { showSettings() }, LinearLayout.LayoutParams(MATCH_PARENT, dp(48)))
        }
        // Measured up front: with an unknown height Android assumes it fits below and clips it at the screen edge.
        content.measure(View.MeasureSpec.makeMeasureSpec(dp(248), View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED)
        val w = dp(248)
        val h = content.measuredHeight
        popup = PopupWindow(content, w, h, true).apply {
            setBackgroundDrawable(GradientDrawable().apply { setColor(pillColor); cornerRadius = dp(20).toFloat() })
            elevation = dp(16).toFloat()
            setIsLaidOutInScreen(true)   // place in screen coordinates, even beside the camera strip
        }
        // Opens beside the button on the trackpad's side: below it in portrait (lined up with its outer end),
        // next to it in landscape (lined up with its bottom).
        val a = screenRect(anchor)
        val c = screenRect(cardFrame)
        val g = dp(8)
        val outerX = if (a.centerX() > c.centerX()) a.right - w else a.left
        val (x, y) = when {
            a.bottom <= c.top -> outerX to a.bottom + g
            a.top >= c.bottom -> outerX to a.top - g - h
            a.right <= c.left -> a.right + g to max(g, a.bottom - h)
            else -> a.left - g - w to max(g, a.bottom - h)
        }
        popup.showAtLocation(trackpad, Gravity.NO_GRAVITY, x, y)
    }

    private fun screenRect(v: View): Rect {
        val p = IntArray(2).also(v::getLocationOnScreen)
        return Rect(p[0], p[1], p[0] + v.width, p[1] + v.height)
    }

    private var gestureWarned = false

    /** HyperOS three-finger gestures (screenshot, split screen) fire over the trackpad too and clash with the Mac's. */
    private fun warnThreeFingerGestures() {
        val prefs = getSharedPreferences("mtm", MODE_PRIVATE)
        if (gestureWarned || prefs.getBoolean("hideGestureWarning", false)) return
        fun sys(key: String) = runCatching { Settings.System.getString(contentResolver, key) }.getOrNull()
        if (sys("enable_three_gesture") != "1") return
        val names = mapOf("screen_shot" to "截屏", "partial_screen_shot" to "局部截屏", "split_ltr" to "分屏", "split_rtl" to "分屏")
        val used = listOf("three_gesture_down" to "下滑", "three_gesture_up" to "上滑", "three_gesture_long_press" to "长按",
            "three_gesture_horizontal_ltr" to "横滑")
            .mapNotNull { (key, how) -> sys(key)?.takeIf { it.isNotEmpty() && it != "none" }?.let { "三指$how：${names[it] ?: "已设置快捷功能"}" } }
            .distinct()
        gestureWarned = true
        AlertDialog.Builder(this)
            .setTitle("三指手势冲突")
            .setMessage("小米的三指手势已开启" + (if (used.isEmpty()) "。" else "：\n" + used.joinToString("\n")) +
                "\n\n在触控区里用三指操作时，手机会同时执行这些手势，和 Mac 的三指拖移、切换桌面冲突。" +
                "建议在手机「设置」里搜索「三指」，关闭三指手势。")
            .setPositiveButton("去设置") { _, _ -> startActivity(android.content.Intent(Settings.ACTION_SETTINGS)) }
            .setNeutralButton("不再提醒") { _, _ -> prefs.edit().putBoolean("hideGestureWarning", true).apply() }
            .setNegativeButton("知道了", null)
            .show()
    }

    private fun stateLine(u: Link.Ui) = when (u.phase) {
        Link.Phase.CONNECTED -> listOfNotNull(u.linkName, u.rttMs?.let { "往返 $it 毫秒" }).joinToString(" · ")
        Link.Phase.OFF -> "已断开"
        Link.Phase.REPLACED -> "已被其他设备接管"
        else -> "正在连接…"
    }

    private fun dotColor(u: Link.Ui) = when (u.phase) {
        Link.Phase.CONNECTED -> if ((u.rttMs ?: 0) < 30) 0xFF30D158.toInt() else 0xFFFFD60A.toInt()
        Link.Phase.OFF, Link.Phase.REPLACED -> grey
        else -> 0xFFFF9F0A.toInt()
    }

    // MARK: pairing screen

    private fun buildPairing(): ScrollView {
        message = TextView(this).apply { setTextColor(grey); textSize = 15f; gravity = Gravity.CENTER; setPadding(0, dp(8), 0, dp(8)) }
        macList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(72), dp(24), dp(24))
            addView(TextView(context).apply {
                text = "连接到 Mac"; setTextColor(Color.WHITE); textSize = 30f; typeface = Typeface.DEFAULT_BOLD
            })
            addView(TextView(context).apply {
                text = "在 Mac 上运行掌控板，并让手机和 Mac 连接同一 Wi-Fi，或让 Mac 连接这台手机的热点。"
                setTextColor(grey); textSize = 15f; gravity = Gravity.CENTER; setPadding(0, dp(14), 0, dp(20))
            })
            addView(message, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            addView(macList, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }
        return ScrollView(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(column)
        }
    }

    private fun macRow(m: Link.MacInfo) = TextView(this).apply {
        text = m.name
        setTextColor(Color.WHITE); textSize = 17f; typeface = Typeface.DEFAULT_BOLD
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(22), 0, dp(22), 0)
        background = pressable(GradientDrawable().apply { setColor(card); cornerRadius = dp(28).toFloat(); setStroke(dp(1), rim) })
        layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, dp(56)).apply { topMargin = dp(10) }
        setOnClickListener { link.pair(m) }
    }

    // MARK: state

    private fun render(u: Link.Ui) {
        ui = u
        val showPairing = u.pairedName == null ||
            u.phase in setOf(Link.Phase.PAIRING, Link.Phase.REJECTED, Link.Phase.NEEDS_PAIRING)
        pairing.visibility = if (showPairing) View.VISIBLE else View.GONE
        message.text = when (u.phase) {
            Link.Phase.PAIRING -> u.code?.let { "确认码  ${it.take(3)} ${it.drop(3)}\n\n请核对 Mac 上的确认码一致后，在 Mac 上点「允许」。" }
                ?: "正在配对，等待 Mac 响应…"
            Link.Phase.REJECTED -> "Mac 拒绝了配对请求。"
            Link.Phase.NEEDS_PAIRING -> "这台 Mac 已不再信任本机，请重新配对。"
            else -> if (u.macs.isEmpty()) "正在查找 Mac…" else ""
        }
        message.textSize = if (u.phase == Link.Phase.PAIRING && u.code != null) 22f else 15f
        macList.removeAllViews()
        if (u.phase != Link.Phase.PAIRING) u.macs.forEach { macList.addView(macRow(it)) }

        status.text = when (u.phase) {
            Link.Phase.CONNECTED -> if (u.linkName == "热点直连") "热点" else u.linkName ?: "已连接"
            Link.Phase.OFF -> "已断开"
            Link.Phase.REPLACED -> "已接管"
            else -> "连接中"
        }
        (dot.background as GradientDrawable).setColor(dotColor(u))
        hint.text = when (u.phase) {
            Link.Phase.CONNECTED -> ""
            Link.Phase.OFF -> "已断开\n在「设置」菜单中重新连接"
            Link.Phase.REPLACED -> "已被其他设备接管\n触摸这里重新连接"
            else -> "正在连接 ${u.pairedName ?: "Mac"}…"
        }
    }

    private fun pickMac() {
        val macs = ui.macs
        if (macs.isEmpty()) {
            AlertDialog.Builder(this).setTitle("选择 Mac")
                .setMessage("正在查找 Mac…\n\nMac 需要运行掌控板，并与手机连接同一 Wi-Fi，或连接这台手机的热点。")
                .setPositiveButton("好", null).show()
            return
        }
        AlertDialog.Builder(this)
            .setTitle("选择 Mac")
            .setItems(macs.map { if (it.name == ui.pairedName) "✓  ${it.name}" else it.name }.toTypedArray()) { _, i ->
                if (macs[i].name != ui.pairedName) link.pair(macs[i])
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun showSettings() {
        val lines = listOfNotNull(
            "当前 Mac：${ui.pairedName ?: "无"}",
            ui.linkName?.let { "连接方式：$it" },
            ui.rttMs?.let { "往返延迟：$it 毫秒" },
            "版本：${packageManager.getPackageInfo(packageName, 0).versionName}",
        )
        AlertDialog.Builder(this)
            .setTitle("设置")
            .setMessage(lines.joinToString("\n"))
            .setNegativeButton("取消配对") { _, _ ->
                AlertDialog.Builder(this).setMessage("与这台 Mac 取消配对？之后需要在 Mac 上重新确认才能连接。")
                    .setPositiveButton("取消配对") { _, _ -> link.forget() }
                    .setNegativeButton("保留", null).show()
            }
            .setPositiveButton("完成", null)
            .show()
    }

    private fun pressable(shape: Drawable) = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), shape, null)
    private fun dp(v: Int) = (v * resources.displayMetrics.density).roundToInt()

    companion object {
        const val LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
    }
}

/**
 * Places the card and the two buttons. The buttons sit at the two ends of the edge that holds the camera, where the
 * status bar keeps its clock and battery, so the single camera stays alone in the middle; they keep [MARGIN] from the
 * screen's rounded corners. The camera's edge follows rotation through the window insets, which change even on a 180°
 * turn that brings no configuration change. The card keeps [MARGIN] from every other edge; its corners follow the
 * display's.
 */
class TrackpadLayout(ctx: Context, private val card: View, private val first: View, private val second: View) : ViewGroup(ctx) {
    private enum class Edge { TOP, LEFT, RIGHT, BOTTOM }

    private var insets: WindowInsets? = null
    private val cardRect = Rect()
    private val firstRect = Rect()
    private val secondRect = Rect()

    init {
        addView(card); addView(first); addView(second)
    }

    override fun onApplyWindowInsets(i: WindowInsets): WindowInsets {
        insets = i
        // Beside a side camera the buttons stand upright, icon over word, so they take a narrow strip.
        val upright = edge(i) == Edge.LEFT || edge(i) == Edge.RIGHT
        for (b in listOf(first, second)) {
            b as LinearLayout
            b.orientation = if (upright) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
            (b.getChildAt(0).layoutParams as LinearLayout.LayoutParams).apply {
                marginEnd = if (upright) 0 else dp(6)
                rightMargin = marginEnd   // the resolved side margin, else the old one lingers
                bottomMargin = if (upright) dp(4) else 0
            }
            (b.getChildAt(1) as TextView).textSize = if (upright) 11f else 14f
        }
        requestLayout()
        return i
    }

    override fun onMeasure(widthSpec: Int, heightSpec: Int) {
        val w = MeasureSpec.getSize(widthSpec)
        val h = MeasureSpec.getSize(heightSpec)
        setMeasuredDimension(w, h)
        place(w, h)
        for ((v, r) in listOf(card to cardRect, first to firstRect, second to secondRect)) {
            v.measure(MeasureSpec.makeMeasureSpec(r.width(), MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(r.height(), MeasureSpec.EXACTLY))
        }
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        for ((v, rect) in listOf(card to cardRect, first to firstRect, second to secondRect)) {
            v.layout(rect.left, rect.top, rect.right, rect.bottom)
        }
        // Over the whole screen, so the edges reach the screen's own; Android caps this per edge.
        systemGestureExclusionRects = listOf(Rect(0, 0, r - l, b - t))
    }

    /** Receives touches that start beside the card, such as a swipe in from the screen edge. */
    var touchTarget: View? = null

    override fun onTouchEvent(e: MotionEvent): Boolean {
        val target = touchTarget ?: return false
        if (e.actionMasked == MotionEvent.ACTION_DOWN) requestUnbufferedDispatch(e)
        // The surface fills the card, so card coordinates are its own; beyond its edge they run past its size.
        e.offsetLocation(-cardRect.left.toFloat(), -cardRect.top.toFloat())
        return target.onTouchEvent(e).also { e.offsetLocation(cardRect.left.toFloat(), cardRect.top.toFloat()) }
    }

    private fun edge(i: WindowInsets): Edge {
        val c = i.displayCutout ?: return Edge.TOP
        return when {
            c.safeInsetLeft > 0 -> Edge.LEFT
            c.safeInsetRight > 0 -> Edge.RIGHT
            c.safeInsetBottom > 0 -> Edge.BOTTOM
            else -> Edge.TOP
        }
    }

    private fun place(w: Int, h: Int) {
        val i = insets
        val m = dp(MARGIN)
        val cw = dp(CHIP_W)
        val r = dp(CHIP_H) / 2f
        val corner = (i?.getRoundedCorner(RoundedCorner.POSITION_TOP_LEFT)?.radius ?: 0).toFloat()
        // ponytail: phones report the camera only as a bounding box; its centre is close enough for a punch hole.
        val hole = i?.displayCutout?.boundingRects?.firstOrNull { !it.isEmpty }
        when (i?.let(::edge) ?: Edge.TOP) {
            Edge.TOP, Edge.BOTTOM -> {
                val top = i == null || edge(i) == Edge.TOP
                // On the camera's centre line, at least MARGIN from the screen edge.
                val fromEdge = max(hole?.let { if (top) it.exactCenterY() else h - it.exactCenterY() } ?: 0f, m + r)
                val x = px(cornerInset(corner, fromEdge, m.toFloat(), r))
                val cy = if (top) fromEdge else h - fromEdge
                firstRect.set(x, px(cy - r), x + cw, px(cy + r))
                secondRect.set(w - x - cw, px(cy - r), w - x, px(cy + r))
                if (top) cardRect.set(m, px(cy + r) + m, w - m, h - m) else cardRect.set(m, m, w - m, px(cy - r) - m)
            }
            Edge.LEFT, Edge.RIGHT -> {
                val left = edge(i!!) == Edge.LEFT
                val thick = px(2 * r)
                val len = dp(CHIP_V)
                val top = px(max(corner - r, m.toFloat()))   // round end just clear of the rounded corner
                val x = if (left) m else w - m - thick
                firstRect.set(x, top, x + thick, top + len)
                secondRect.set(x, h - top - len, x + thick, h - top)
                if (left) cardRect.set(m + thick + m, m, w - m, h - m) else cardRect.set(m, m, w - m - thick - m, h - m)
            }
        }
        (card.background as GradientDrawable).cornerRadius = max(corner - m, dp(12f))
        card.invalidateOutline()
    }

    /** How far along an edge a button centred `across` from it must start to stay `m` clear of a corner of radius `c`. */
    private fun cornerInset(c: Float, across: Float, m: Float, r: Float): Float {
        if (across >= c) return m
        val reach = c - m - r
        val d = c - across
        return max(m, c - r - sqrt(max(0f, reach * reach - d * d)))
    }

    private fun dp(v: Float) = v * resources.displayMetrics.density
    private fun dp(v: Int) = dp(v.toFloat()).roundToInt()
    private fun px(v: Float) = v.roundToInt()

    companion object {
        const val MARGIN = 8    // dp, to the screen edges and between the buttons and the card
        const val CHIP_W = 84   // dp
        const val CHIP_H = 32   // dp, also the width of an upright button
        const val CHIP_V = 64   // dp, length of an upright button
    }
}
