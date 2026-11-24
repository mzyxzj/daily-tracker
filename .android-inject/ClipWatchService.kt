package __PKG__

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 复制链接就能问「要不要整理」的系统级实现。
 *
 * 为什么必须用无障碍服务：Android 10 起普通 App 退到后台就读不到剪贴板，
 * 只有默认输入法和无障碍服务还有这个能力。
 *
 * 这一版针对两个真实翻车点做了加固：
 *
 * 1. 只监听「窗口切换」会漏掉复制动作。B站/抖音的「复制成功」是一个自绘气泡，
 *    多数 ROM 只回 TYPE_WINDOW_CONTENT_CHANGED，甚至只有剪贴板回调。
 *    现在几类事件都监听，并且在 60/260/700ms 各读一次（不同 ROM 写入时机不同）。
 *
 * 2. 小米/OPPO/vivo 会拦「后台读剪贴板」，读到的是空。
 *    以前这里直接 return，用户看到的现象就是「复制了，但什么都不弹」。
 *    现在读不到内容也照弹，只是不带预览——点「整理」App 到前台再读，
 *    前台一定读得到。为了不乱弹，只在内容类 App（抖音/B站/小红书/微信/浏览器…）
 *    里、且刚发生过点击时才走这条路。
 */
class ClipWatchService : AccessibilityService() {

    private var overlay: View? = null
    private var wm: WindowManager? = null
    private var listener: ClipboardManager.OnPrimaryClipChangedListener? = null
    private val handler = Handler(Looper.getMainLooper())

    private var lastText: String = ""
    private var lastAt: Long = 0L
    private var lastCheckAt: Long = 0L
    private var lastBlindAt: Long = 0L
    private var blindPkg: String = ""
    // 剪贴板回调能不能用。能用就不再靠无障碍事件兜底读——
    // Android 12+ 每读一次剪贴板系统都会提示「已粘贴」，多读一次就多烦一次。
    private var clipApiOk: Boolean = false
    // 最近一次停留在内容类 App 的时间。用「最近 8 秒」而不是「当前包名」，
    // 是因为系统分享面板可能把包名切成 systemui，但人显然还在同一条内容上。
    private var recentContentAt: Long = 0L

    override fun onServiceConnected() {
        super.onServiceConnected()
        connected = true
        err = ""
        attach(this)
        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        // 动态设一遍，比只靠 res/xml 可靠：部分 ROM 会忽略 XML 里的 eventTypes。
        try {
            val info = serviceInfo ?: AccessibilityServiceInfo()
            info.eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            info.flags = info.flags or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
            info.notificationTimeout = 80
            serviceInfo = info
        } catch (e: Exception) {
            err = "setServiceInfo: " + e.message
        }
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val l = ClipboardManager.OnPrimaryClipChangedListener {
                // 剪贴板变了就是最直接的信号，立刻读（只读这一次）。
                clipApiOk = true
                checkClip(true, "clip")
            }
            listener = l
            cm.addPrimaryClipChangedListener(l)
        } catch (e: Exception) {
            err = "clipListener: " + e.message
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val e = event ?: return
        val pkg = e.packageName?.toString() ?: ""
        if (pkg.isNotEmpty() && pkg != packageName) {
            lastPkg = pkg
            lastEventAt = System.currentTimeMillis()
            if (isContentApp(pkg)) recentContentAt = lastEventAt
        }
        // 剪贴板回调已经生效，就不再读剪贴板：事件只是噪音，
        // 而每多读一次，Android 12+ 就多弹一次「已粘贴」。
        if (clipApiOk) return
        // 只在内容类 App 里兜底，银行/输入法那种地方连剪贴板都不碰。
        if (!isContentApp(pkg)) return
        val t = e.eventType
        val clickish = t == AccessibilityEvent.TYPE_VIEW_CLICKED ||
            t == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
        val windowish = t == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
            t == AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED
        if (!clickish && !windowish) return
        // 复制之后 ROM 才写剪贴板，300ms 补读一次就够。
        handler.postDelayed({ checkClip(false, "event") }, 320)
    }

    override fun onInterrupt() {}

    override fun onUnbind(intent: Intent?): Boolean {
        connected = false
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        super.onDestroy()
        connected = false
        detach(this)
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            listener?.let { cm.removePrimaryClipChangedListener(it) }
        } catch (e: Exception) {
        }
        hideOverlay()
    }

    private fun readClipText(): String {
        return try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            if (!cm.hasPrimaryClip()) return ""
            val clip = cm.primaryClip ?: return ""
            if (clip.itemCount == 0) return ""
            val t = clip.getItemAt(0).coerceToText(this)?.toString()?.trim() ?: ""
            t
        } catch (e: Exception) {
            ""
        }
    }

    private fun checkClip(force: Boolean, reason: String) {
        if (overlay != null) return
        val now = System.currentTimeMillis()
        if (!force && now - lastCheckAt < 150) return
        lastCheckAt = now
        val text = readClipText()

        if (text.isNotEmpty()) {
            lastClipAt = now
            if (text.length > 1200) return
            val share = looksLikeShare(text)
            if (!share) {
                // 不认识平台时，只认「浏览器里复制的一条 http 链接」
                if (!(text.contains("http") && isBrowser(lastPkg))) return
            }
            if (text == lastText && now - lastAt < 20000) return
            lastText = text
            lastAt = now
            showOverlay(text)
            return
        }

        // ---- 读不到内容：大概率被 ROM 的剪贴板保护拦了 ----
        // 只在「刚点了复制」这种时机、且前台是内容类 App 时盲弹，避免乱弹。
        if (reason != "click" && reason != "clip") return
        // 8 秒内还在内容类 App（或刚从里面点出来）才盲弹，别在别处乱弹。
        if (now - recentContentAt > 8000) return
        if (blindPkg == lastPkg && now - lastBlindAt < 60000) return
        blindPkg = lastPkg
        lastBlindAt = now
        err = "clipboard may be blocked by system"
        showOverlay("")
    }

    private fun looksLikeShare(text: String): Boolean {
        if (!text.contains("http")) return false
        val keys = arrayOf(
            "douyin.com", "iesdouyin.com", "bilibili.com", "b23.tv",
            "xhslink.com", "xiaohongshu.com", "zhihu.com", "mp.weixin.qq.com",
            "youtube.com", "youtu.be", "weibo.com", "kuaishou.com"
        )
        for (k in keys) if (text.contains(k, true)) return true
        return text.contains("复制打开") || text.contains("戳链接")
    }

    private fun isBrowser(pkg: String): Boolean {
        val list = arrayOf(
            "com.android.chrome", "com.quark.browser", "com.UCMobile",
            "com.mi.globalbrowser", "com.android.browser", "com.microsoft.emmx",
            "com.tencent.mtt", "com.baidu.searchbox", "org.mozilla.firefox",
            "com.sec.android.app.sbrowser", "com.vivo.browser", "com.oppo.browser",
            "com.huawei.browser", "com.heytap.browser"
        )
        for (p in list) if (pkg == p) return true
        return false
    }

    private fun isContentApp(pkg: String): Boolean {
        val list = arrayOf(
            "tv.danmaku.bili",                 // B站
            "com.ss.android.ugc.aweme",        // 抖音
            "com.ss.android.ugc.aweme.lite",   // 抖音极速版
            "com.ss.android.ugc.live",         // 抖音火山
            "com.xingin.xhs",                  // 小红书
            "com.zhihu.android",               // 知乎
            "com.sina.weibo",                  // 微博
            "com.tencent.mm",                  // 微信（公众号）
            "com.tencent.mobileqq",            // QQ
            "com.smile.gifmaker",              // 快手
            "com.google.android.youtube"       // YouTube
        )
        for (p in list) if (pkg == p) return true
        return isBrowser(pkg)
    }

    private fun platformOf(text: String): String {
        val t = text.toLowerCase()
        return when {
            t.contains("bilibili") || t.contains("b23.tv") -> "B站"
            t.contains("douyin") || t.contains("iesdouyin") -> "抖音"
            t.contains("xiaohongshu") || t.contains("xhslink") -> "小红书"
            t.contains("zhihu") -> "知乎"
            t.contains("weixin") || t.contains("mp.weixin") -> "公众号"
            t.contains("youtu") -> "YouTube"
            t.contains("weibo") -> "微博"
            else -> ""
        }
    }

    private fun showOverlay(text: String) {
        if (overlay != null) return
        val blind = text.isEmpty()
        val plat = if (blind) "" else platformOf(text)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(13), dp(9), dp(8), dp(9))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#F21E293B"))
                cornerRadius = dp(16).toFloat()
                setStroke(dp(1), Color.parseColor("#33FFFFFF"))
            }
        }
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f
            )
        }
        val head = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 13f
            setText(if (blind) "复制了内容 · 要整理进文化吗？" else "这条要整理进「文化」吗？")
        }
        val sub = TextView(this).apply {
            setTextColor(Color.parseColor("#94A3B8"))
            textSize = 10f
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            setPadding(0, dp(2), 0, 0)
            if (blind) {
                setText("系统不让后台读剪贴板 · 点整理后自动接上")
            } else {
                val brief = text.replace("\n", " ").trim()
                val cut = if (brief.length > 28) brief.substring(0, 28) + "…" else brief
                setText(if (plat.isEmpty()) cut else plat + " · " + cut)
            }
        }
        col.addView(head)
        col.addView(sub)

        val go = TextView(this).apply {
            setTextColor(Color.parseColor("#0B0F17"))
            textSize = 12.5f
            setText("整理")
            isClickable = true
            setPadding(dp(14), dp(7), dp(14), dp(7))
            background = GradientDrawable().apply {
                setColor(Color.WHITE)
                cornerRadius = dp(13).toFloat()
            }
        }
        val no = TextView(this).apply {
            setTextColor(Color.parseColor("#94A3B8"))
            textSize = 12f
            setText("略过")
            isClickable = true
            setPadding(dp(9), dp(7), dp(9), dp(7))
        }
        go.setOnClickListener { openApp(text, blind); hideOverlay() }
        no.setOnClickListener { hideOverlay() }

        root.addView(col)
        root.addView(go)
        root.addView(no)

        if (!addOverlayView(root)) return
        overlay = root
        handler.postDelayed({ hideOverlay() }, 10000)
    }

    /// 两种窗口类型都试一遍：
    /// 有「显示在其他应用上层」权限就优先用 APPLICATION_OVERLAY（MIUI 上更稳），
    /// 没有就退回无障碍专属的 ACCESSIBILITY_OVERLAY（不需要额外授权）。
    private fun addOverlayView(v: View): Boolean {
        val types = ArrayList<Int>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && canOverlay()) {
            types.add(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
            types.add(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
        }
        if (types.isEmpty()) types.add(WindowManager.LayoutParams.TYPE_PHONE)
        for (type in types) {
            val lp = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT
            )
            lp.gravity = Gravity.TOP
            lp.x = dp(10)
            lp.y = statusBarHeight() + dp(6)
            try {
                wm?.addView(v, lp)
                lastOverlayAt = System.currentTimeMillis()
                return true
            } catch (e: Exception) {
                err = "addView(type=" + type + "): " + e.message
            }
        }
        return false
    }

    private fun hideOverlay() {
        val v = overlay ?: return
        overlay = null
        try {
            wm?.removeView(v)
        } catch (e: Exception) {
        }
    }

    private fun openApp(text: String, blind: Boolean) {
        try {
            val i = Intent(this, MainActivity::class.java)
            i.action = Intent.ACTION_SEND
            if (text.isNotEmpty()) {
                i.putExtra(MainActivity.EXTRA_TEXT, text)
                i.putExtra(Intent.EXTRA_TEXT, text)
            }
            if (blind) i.putExtra(MainActivity.EXTRA_READ_CLIP, true)
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            startActivity(i)
        } catch (e: Exception) {
            err = "startActivity: " + e.message
        }
    }

    private fun canOverlay(): Boolean {
        return try {
            Settings.canDrawOverlays(this)
        } catch (e: Exception) {
            false
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun statusBarHeight(): Int {
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else dp(24)
    }

    companion object {
        // 给 App 侧自检用：设置里「已开启」不等于服务真的活着。
        @Volatile var connected: Boolean = false
        @Volatile var lastEventAt: Long = 0L
        @Volatile var lastClipAt: Long = 0L
        @Volatile var lastOverlayAt: Long = 0L
        @Volatile var lastPkg: String = ""
        @Volatile var err: String = ""

        // 当前活着的服务实例，App 里点「试一下」时用它弹一条测试。
        @Volatile private var instance: ClipWatchService? = null

        fun attach(s: ClipWatchService) {
            instance = s
        }

        fun detach(s: ClipWatchService) {
            if (instance === s) instance = null
        }

        /// App 里点「试一下」：立刻弹一条示例，验证悬浮条能不能显示。
        fun test(): Boolean {
            val s = instance ?: return false
            s.handler.post { s.showOverlay("B站 · 这是一条测试，点「整理」看看能不能进来") }
            return true
        }

        fun isEnabled(ctx: Context): Boolean {
            return try {
                val cls = ClipWatchService::class.java.name
                val flat = Settings.Secure.getString(
                    ctx.contentResolver,
                    Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                ) ?: return false
                val short = ctx.packageName + "/." + cls.substringAfterLast(".")
                val full = ctx.packageName + "/" + cls
                flat.split(':').any { it.equals(full, true) || it.equals(short, true) }
            } catch (e: Exception) {
                false
            }
        }

        fun canDrawOverlay(ctx: Context): Boolean {
            return try {
                Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(ctx)
            } catch (e: Exception) {
                false
            }
        }

        /// 诊断信息：App 里点开「复制即弹」卡片就能看到，出问题时一眼定位。
        fun status(ctx: Context): Map<String, Any> {
            val now = System.currentTimeMillis()
            fun ago(t: Long): Long = if (t <= 0) -1 else (now - t) / 1000
            val m = HashMap<String, Any>()
            m["enabled"] = isEnabled(ctx)
            m["connected"] = connected
            m["overlayPermission"] = canDrawOverlay(ctx)
            m["lastEventAgo"] = ago(lastEventAt)
            m["lastClipAgo"] = ago(lastClipAt)
            m["lastOverlayAgo"] = ago(lastOverlayAt)
            m["lastPkg"] = lastPkg
            m["error"] = err
            return m
        }
    }
}
