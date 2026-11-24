package __PKG__

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.Settings
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 复制链接就问「要不要整理」。
 *
 * 为什么必须用无障碍服务：Android 10 起普通 App 退到后台就读不到剪贴板。
 *
 * === 这一版修的是什么 ===
 *
 * V4.2 之前依赖 `addPrimaryClipChangedListener`：只有剪贴板真的变了才读、才弹。
 * 但 Android 10+ 的这条回调**只在应用有焦点时派发**，无障碍服务在后台收不到。
 * 于是 `clipApiOk` 永远是 false，事件路径读剪贴板又被系统拒绝（返回空），
 * 空内容 + reason="event" 直接 return —— 结果就是「点了复制，什么都不发生」。
 * 一加 13T / ColorOS 上就是这个现象。
 *
 * 现在改成三条互补信号，都不依赖读取剪贴板权限：
 *   1. 点到了文字是「复制链接 / 复制 / Copy」的控件（最关键，B站分享面板就是这个）；
 *   2. 系统 Toast 出现「已复制 / 复制成功」；
 *   3. 窗口内容变化（兜底，延迟 300ms 再试）。
 * 读到内容就带预览弹；读不到（被 ROM 拦）也照弹，点「整理」后 App 到前台再读。
 *
 * === 弹窗三条通道，谁通谁上 ===
 *
 * ColorOS 会静默拦「后台弹出界面」，startActivity 不抛异常也被丢弃。所以：
 *   Activity 起 700ms 后检查 onResume 回执（ClipPromptActivity.shownToken），
 *   没回执就改发通知（通知不需要后台弹窗权限），通知也没权限再退无障碍悬浮窗。
 * 三条都失败才记报错，自检面板能直接看到是哪一条被拦。
 */
class ClipWatchService : AccessibilityService() {

    private var promptShowing: Boolean = false
    private val handler = Handler(Looper.getMainLooper())

    private var lastText: String = ""
    private var lastAt: Long = 0L
    private var lastCheckAt: Long = 0L
    private var lastBlindAt: Long = 0L
    private var blindPkg: String = ""
    private var recentContentAt: Long = 0L
    private var recentContentPkg: String = ""
    private var promptToken: Long = 0L

    // 悬浮窗兜底时挂着的 View，别泄漏
    private var overlayView: View? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        connected = true
        err = ""
        attach(this)
        // 动态设一遍，比只靠 res/xml 可靠：部分 ROM 会忽略 XML 里的 eventTypes。
        try {
            val info = serviceInfo ?: AccessibilityServiceInfo()
            info.eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            info.flags = info.flags or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
            info.notificationTimeout = 60
            serviceInfo = info
        } catch (e: Exception) {
            err = "setServiceInfo: " + e.message
        }
        // 剪贴板回调只当加分项：能收到就直接读，收不到也不影响主路径。
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val l = ClipboardManager.OnPrimaryClipChangedListener {
                checkClip(true, "clip")
            }
            cm.addPrimaryClipChangedListener(l)
            clipListener = l
        } catch (e: Exception) {
            err = "clipListener: " + e.message
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val e = event ?: return
        val pkg = e.packageName?.toString() ?: ""
        val now = System.currentTimeMillis()
        if (pkg.isNotEmpty() && pkg != packageName) {
            lastPkg = pkg
            lastEventAt = now
            if (isContentApp(pkg)) {
                recentContentAt = now
                recentContentPkg = pkg
            }
        }
        // 只在自己和「内容类 App 的上下文」里干活；银行/输入法那种地方连剪贴板都不碰。
        //
        // 注意不能只认当前包名：部分 ROM 的分享面板是 systemui 弹出的，
        // 点「复制链接」时事件包名会变成 com.android.systemui，
        // 只看当前包就会漏掉刚在 B站 里点的那一下。所以 15 秒内停留过内容 App 也算。
        val inContent = isContentApp(pkg) || (now - recentContentAt < 15000)
        if (!inContent) return

        val t = e.eventType

        // 信号 1：点的就是这个控件 —— 「复制链接」「复制」「Copy」。
        // B站分享面板、抖音分享面板都是标准按钮，这条在真机上最灵。
        if (t == AccessibilityEvent.TYPE_VIEW_CLICKED) {
            val label = nodeLabel(e.source)
            if (looksLikeCopyAction(label)) {
                lastCopySignalAt = now
                checkClip(true, "click")
                return
            }
        }

        // 信号 2：系统 Toast「已复制」「链接已复制」。
        if (t == AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED) {
            val txt = ArrayList<CharSequence>()
            e.text?.let { txt.addAll(it) }
            if (looksLikeCopiedToast(txt.joinToString(" "))) {
                lastCopySignalAt = now
                // Toast 出现时剪贴板可能刚写，读不到也无所谓，直接盲弹。
                checkClip(true, "toast")
                return
            }
        }

        // 信号 3：内容变化 —— 复制成功的自绘气泡多数 ROM 只回这个。
        if (t == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED ||
            t == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
        ) {
            handler.postDelayed({ checkClip(false, "event") }, 300)
        }
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
            clipListener?.let { cm.removePrimaryClipChangedListener(it) }
        } catch (e: Exception) {
        }
        removeOverlay()
        promptShowing = false
    }

    private fun nodeLabel(node: AccessibilityNodeInfo?): String {
        if (node == null) return ""
        val sb = StringBuilder()
        try {
            node.text?.let { sb.append(it).append(' ') }
            node.contentDescription?.let { sb.append(it).append(' ') }
        } catch (e: Exception) {
        }
        return sb.toString().trim()
    }

    /// 只认短的按钮文字：「复制链接」「复制」「Copy」，避免把正文里出现"复制"的长文本误判。
    private fun looksLikeCopyAction(label: String): Boolean {
        if (label.isEmpty() || label.length > 16) return false
        val s = label.lowercase()
        return s == "复制" || s == "copy" || s.contains("复制链接") ||
            s.contains("复制地址") || s.contains("复制分享") ||
            (s.startsWith("复制") && s.length <= 8) ||
            (s.contains("copy") && s.length <= 12)
    }

    private fun looksLikeCopiedToast(t: String): Boolean {
        if (t.isEmpty() || t.length > 40) return false
        val s = t.lowercase()
        return s.contains("已复制") || s.contains("复制成功") ||
            s.contains("链接已复制") || s.contains("copied") ||
            s.contains("已拷贝")
    }

    private fun readClipText(): String {
        return try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            if (!cm.hasPrimaryClip()) return ""
            val clip = cm.primaryClip ?: return ""
            if (clip.itemCount == 0) return ""
            clip.getItemAt(0).coerceToText(this)?.toString()?.trim() ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    private fun checkClip(force: Boolean, reason: String) {
        if (promptShowing) return
        val now = System.currentTimeMillis()
        if (!force && now - lastCheckAt < 220) return
        lastCheckAt = now
        val text = readClipText()

        if (text.isNotEmpty()) {
            lastClipAt = now
            if (text.length > 1200) return
            if (!looksLikeShare(text)) return
            if (text == lastText && now - lastAt < 20000) return
            lastText = text
            lastAt = now
            showPrompt(text)
            return
        }

        // ---- 读不到内容：ROM 的剪贴板保护拦了 ----
        // 只有「明确点了复制」或「看到复制成功提示」才盲弹；
        // 窗口内容变化这种弱信号不盲弹，否则在 B站 里划两下就弹一次。
        if (reason == "event") return
        if (now - recentContentAt > 15000) return
        if (now - lastBlindAt < 12000) return
        blindPkg = lastPkg
        lastBlindAt = now
        // 盲弹没有正文，但至少能说出平台，用户一眼知道这条是从哪来的。
        showPrompt("", guessPlatform(recentContentPkg))
    }

    private fun guessPlatform(pkg: String): String {
        return when (pkg) {
            "tv.danmaku.bili" -> "B站"
            "com.ss.android.ugc.aweme", "com.ss.android.ugc.aweme.lite",
            "com.ss.android.ugc.live" -> "抖音"
            "com.xingin.xhs" -> "小红书"
            "com.zhihu.android" -> "知乎"
            "com.sina.weibo" -> "微博"
            "com.tencent.mm" -> "公众号"
            "com.smile.gifmaker" -> "快手"
            "com.google.android.youtube" -> "YouTube"
            else -> ""
        }
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
        // Kotlin 2.x 把 toLowerCase() 的弃用提升成编译错误，用 lowercase()。
        val t = text.lowercase()
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

    /// 弹提示卡：先走透明 Activity（体验最好），700ms 内拿不到「已显示」回执就换通道。
    private fun showPrompt(text: String, guessPlat: String = "") {
        if (promptShowing) return
        promptShowing = true
        lastOverlayAt = System.currentTimeMillis()
        promptVia = "activity"
        buzz()

        val token = System.currentTimeMillis()
        promptToken = token
        var launched = false
        try {
            val i = Intent(this, ClipPromptActivity::class.java)
            i.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION
            )
            if (text.isNotEmpty()) {
                i.putExtra(MainActivity.EXTRA_TEXT, text)
                val p = platformOf(text)
                if (p.isNotEmpty()) i.putExtra(ClipPromptActivity.EXTRA_PLATFORM, p)
            } else {
                i.putExtra(MainActivity.EXTRA_READ_CLIP, true)
                if (guessPlat.isNotEmpty()) i.putExtra(ClipPromptActivity.EXTRA_PLATFORM, guessPlat)
            }
            i.putExtra(ClipPromptActivity.EXTRA_TOKEN, token)
            startActivity(i)
            launched = true
            err = ""
        } catch (e: Exception) {
            err = "startPrompt: " + (e.message ?: e.javaClass.simpleName)
        }

        // 回执检查：Activity 真的 onResume 了才算弹成功。
        // ColorOS 的「后台弹出界面」关着时 startActivity 不报错但页面根本不出现，
        // 只有这个回执能识别出来。
        handler.postDelayed({
            if (ClipPromptActivity.shownToken != token) {
                if (launched) err = "后台弹出界面被系统拦（activity 未显示）"
                fallbackPrompt(text, token)
            }
        }, 700)

        handler.postDelayed({ promptShowing = false }, 8000)
    }

    /// Activity 起不来时的兜底：通知 → 无障碍悬浮窗。
    private fun fallbackPrompt(text: String, token: Long) {
        val okNotify = notifyPrompt(text)
        if (okNotify) {
            promptVia = "notification"
            err = ""
            return
        }
        val okOverlay = overlayPrompt(text, token)
        promptVia = if (okOverlay) "overlay" else "none"
        err = if (okOverlay) "" else "提示通道全被拦：开通知权限，或允许「后台弹出界面」"
    }

    /// 通道 2：通知。不需要后台弹窗权限，ColorOS 上最通的一条路。
    private fun notifyPrompt(text: String): Boolean {
        return try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && !nm.areNotificationsEnabled()) {
                return false
            }
            val chId = "dt_clip"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (nm.getNotificationChannel(chId) == null) {
                    val ch = NotificationChannel(
                        chId, "复制即整理", NotificationManager.IMPORTANCE_HIGH
                    )
                    ch.description = "复制分享链接后的整理提醒"
                    ch.enableVibration(true)
                    nm.createNotificationChannel(ch)
                }
            }
            val i = Intent(this, MainActivity::class.java)
            i.action = Intent.ACTION_SEND
            if (text.isNotEmpty()) {
                i.putExtra(MainActivity.EXTRA_TEXT, text)
                i.putExtra(Intent.EXTRA_TEXT, text)
            } else {
                i.putExtra(MainActivity.EXTRA_READ_CLIP, true)
            }
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                flags = flags or PendingIntent.FLAG_IMMUTABLE
            }
            val pi = PendingIntent.getActivity(this, 1001, i, flags)
            val plat = platformOf(text)
            val title = if (plat.isEmpty()) "复制了内容 · 要整理吗？" else "$plat · 要整理进「文化」吗？"
            val body = if (text.isEmpty()) {
                "点开自动读取剪贴板"
            } else {
                text.replace("\n", " ").trim().let { if (it.length > 60) it.substring(0, 60) + "…" else it }
            }
            val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, chId)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
            b.setSmallIcon(android.R.drawable.stat_notify_chat)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setAutoCancel(true)
                .setContentIntent(pi)
                .setPriority(Notification.PRIORITY_HIGH)
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                @Suppress("DEPRECATION")
                b.setDefaults(Notification.DEFAULT_ALL)
            }
            nm.notify(1001, b.build())
            true
        } catch (e: Exception) {
            false
        }
    }

    /// 通道 3：无障碍悬浮窗。TYPE_ACCESSIBILITY_OVERLAY 不需要 SYSTEM_ALERT_WINDOW，
    /// 是服务权限内最"名正言顺"的窗口；有些 ROM 上反而比 Activity 靠谱。
    private fun overlayPrompt(text: String, token: Long): Boolean {
        return try {
            removeOverlay()
            val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val card = buildOverlayCard(text, token)
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_SYSTEM_ALERT
            }
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
            lp.y = statusBarHeight() + dp(8)
            lp.x = 0
            wm.addView(card, lp)
            overlayView = card
            handler.postDelayed({ removeOverlay() }, 9000)
            true
        } catch (e: Exception) {
            err = "overlay: " + (e.message ?: e.javaClass.simpleName)
            false
        }
    }

    private fun removeOverlay() {
        val v = overlayView ?: return
        overlayView = null
        try {
            val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
            wm.removeView(v)
        } catch (e: Exception) {
        }
    }

    private fun buildOverlayCard(text: String, token: Long): View {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(11), dp(8), dp(11))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#F21E293B"))
                cornerRadius = dp(18).toFloat()
                setStroke(dp(1), Color.parseColor("#33FFFFFF"))
            }
        }
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val head = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 14f
            setText(if (text.isEmpty()) "复制了内容 · 要整理进「文化」吗？" else "这条要整理进「文化」吗？")
        }
        val sub = TextView(this).apply {
            setTextColor(Color.parseColor("#94A3B8"))
            textSize = 10.5f
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            setPadding(0, dp(3), 0, 0)
            setText(
                if (text.isEmpty()) "点「整理」后自动接上剪贴板"
                else text.replace("\n", " ").trim().let { if (it.length > 42) it.substring(0, 42) + "…" else it }
            )
        }
        col.addView(head)
        col.addView(sub)

        val go = TextView(this).apply {
            setTextColor(Color.parseColor("#0B0F17"))
            textSize = 13f
            setText("整理")
            isClickable = true
            setPadding(dp(15), dp(8), dp(15), dp(8))
            background = GradientDrawable().apply {
                setColor(Color.WHITE)
                cornerRadius = dp(14).toFloat()
            }
        }
        val no = TextView(this).apply {
            setTextColor(Color.parseColor("#94A3B8"))
            textSize = 12.5f
            setText("略过")
            isClickable = true
            setPadding(dp(10), dp(8), dp(10), dp(8))
        }
        go.setOnClickListener {
            removeOverlay()
            openApp(text, text.isEmpty())
        }
        no.setOnClickListener { removeOverlay() }

        card.addView(col)
        card.addView(go)
        card.addView(no)
        return card
    }

    /// 抖一下：即使视觉被系统吞了，手上也有反馈。
    private fun buzz() {
        try {
            val v = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createOneShot(45, VibrationEffect.DEFAULT_AMPLITUDE))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(45)
            }
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
        @Volatile var lastCopySignalAt: Long = 0L
        @Volatile var lastPkg: String = ""
        @Volatile var err: String = ""
        // 上次提示到底走通了哪条通道：activity / notification / overlay / none
        @Volatile var promptVia: String = ""

        private var clipListener: ClipboardManager.OnPrimaryClipChangedListener? = null

        // 当前活着的服务实例，App 里点「试一下」时用它弹一条测试。
        @Volatile private var instance: ClipWatchService? = null

        fun attach(s: ClipWatchService) {
            instance = s
        }

        fun detach(s: ClipWatchService) {
            if (instance === s) instance = null
        }

        /// App 里点「试一下」：立刻弹一条示例，验证提示卡能不能显示。
        fun test(): Boolean {
            val s = instance ?: return false
            s.handler.post { s.showPrompt("B站 · 这是一条测试，点「整理」看看能不能进来") }
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

        fun canNotify(ctx: Context): Boolean {
            return try {
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) nm.areNotificationsEnabled() else true
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
            m["notifyPermission"] = canNotify(ctx)
            m["lastEventAgo"] = ago(lastEventAt)
            m["lastClipAgo"] = ago(lastClipAt)
            m["lastOverlayAgo"] = ago(lastOverlayAt)
            m["lastCopySignalAgo"] = ago(lastCopySignalAt)
            m["lastPkg"] = lastPkg
            m["promptVia"] = promptVia
            m["error"] = err
            return m
        }
    }
}
