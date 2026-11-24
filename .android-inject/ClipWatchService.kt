package __PKG__

import android.accessibilityservice.AccessibilityService
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
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
 * 流程：监听剪贴板 -> 判断像不像分享链接 -> 顶部悬浮窗「整理 / 略过」
 *      -> 点「整理」带着链接启动 MainActivity。
 *
 * 没有悬浮窗权限时不做任何事（不弹、不崩），此时 App 里仍有两条兜底路径：
 * 系统分享面板选本 App、以及切回 App 时读一次剪贴板。
 */
class ClipWatchService : AccessibilityService() {

    private var overlay: View? = null
    private var wm: WindowManager? = null
    private var listener: ClipboardManager.OnPrimaryClipChangedListener? = null
    private var lastText: String = ""
    private var lastAt: Long = 0L
    private var lastEventAt: Long = 0L

    override fun onServiceConnected() {
        super.onServiceConnected()
        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            listener = ClipboardManager.OnPrimaryClipChangedListener { checkClip() }
            cm.addPrimaryClipChangedListener(listener)
        } catch (e: Exception) {
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 有些 ROM 不回调 clip listener，这里按窗口切换补一次，2 秒节流。
        if (event == null) return
        val t = event.eventType
        if (t != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val now = System.currentTimeMillis()
        if (now - lastEventAt < 2000) return
        lastEventAt = now
        checkClip()
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        super.onDestroy()
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            listener?.let { cm.removePrimaryClipChangedListener(it) }
        } catch (e: Exception) {
        }
        hideOverlay()
    }

    private fun checkClip() {
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            if (!cm.hasPrimaryClip()) return
            val clip = cm.primaryClip ?: return
            if (clip.itemCount == 0) return
            val text = clip.getItemAt(0).coerceToText(this)?.toString()?.trim() ?: return
            if (text.isEmpty() || text.length > 700) return
            if (!looksLikeShare(text)) return
            val now = System.currentTimeMillis()
            if (text == lastText && now - lastAt < 20000) return
            lastText = text
            lastAt = now
            showOverlay(text)
        } catch (e: Exception) {
        }
    }

    private fun looksLikeShare(text: String): Boolean {
        if (!text.contains("http")) return false
        val keys = arrayOf(
            "douyin.com", "iesdouyin.com", "bilibili.com", "b23.tv",
            "xhslink.com", "xiaohongshu.com", "zhihu.com", "mp.weixin.qq.com",
            "youtube.com", "youtu.be", "weibo.com", "github.com"
        )
        for (k in keys) if (text.contains(k, true)) return true
        return text.contains("复制打开") || text.contains("戳链接")
    }

    private fun showOverlay(text: String) {
        if (overlay != null) return
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(9), dp(8), dp(9))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#F21E293B"))
                cornerRadius = dp(16).toFloat()
            }
        }
        val tv = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 12.5f
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            text = "这条要整理进「文化」吗？"
            layoutParams = LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f
            )
        }
        val go = TextView(this).apply {
            setTextColor(Color.parseColor("#0B0F17"))
            textSize = 12f
            text = "整理"
            setPadding(dp(12), dp(6), dp(12), dp(6))
            background = GradientDrawable().apply {
                setColor(Color.WHITE)
                cornerRadius = dp(12).toFloat()
            }
        }
        val no = TextView(this).apply {
            setTextColor(Color.parseColor("#94A3B8"))
            textSize = 12f
            text = "略过"
            setPadding(dp(9), dp(6), dp(9), dp(6))
        }
        tv.setOnClickListener { openApp(text); hideOverlay() }
        go.setOnClickListener { openApp(text); hideOverlay() }
        no.setOnClickListener { hideOverlay() }
        root.addView(tv)
        root.addView(go)
        root.addView(no)

        // TYPE_ACCESSIBILITY_OVERLAY 是无障碍服务专属的窗口类型：
        // 只要用户开了无障碍，就不需要再单独申请「显示在其他应用上层」。
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        )
        lp.gravity = Gravity.TOP
        lp.x = 0
        lp.y = statusBarHeight() + dp(8)

        try {
            wm?.addView(root, lp)
            overlay = root
            root.postDelayed({ hideOverlay() }, 9000)
        } catch (e: Exception) {
            overlay = null
        }
    }

    private fun hideOverlay() {
        val v = overlay ?: return
        overlay = null
        try {
            wm?.removeView(v)
        } catch (e: Exception) {
        }
    }

    private fun openApp(text: String) {
        try {
            val i = Intent(this, MainActivity::class.java)
            i.action = Intent.ACTION_SEND
            i.putExtra(MainActivity.EXTRA_TEXT, text)
            i.putExtra(Intent.EXTRA_TEXT, text)
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            startActivity(i)
        } catch (e: Exception) {
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun statusBarHeight(): Int {
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else dp(24)
    }

    companion object {
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
    }
}
