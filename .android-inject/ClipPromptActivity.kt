package __PKG__

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 「复制就弹」的提示卡。
 *
 * 为什么不用悬浮窗（TYPE_APPLICATION_OVERLAY / TYPE_ACCESSIBILITY_OVERLAY）：
 * 一加 / ColorOS / 部分 HyperOS 上 addView 明明成功，窗口却不可见（被系统的
 * 悬浮窗管控吞掉），日志里一切正常、用户什么都看不到——就是这个 Activity 存在的原因。
 *
 * Activity 是一等公民窗口：只要 App 有「显示在其他应用上层」权限（Android 10+
 * 允许它从后台启动 Activity），就会真的盖在 B站/抖音 上面。
 *
 * 交互：默认 12 秒自动消失；点空白处消失；「整理」把链接交给 MainActivity，
 * 「略过」直接关掉。
 */
class ClipPromptActivity : Activity() {

    private val handler = Handler(Looper.getMainLooper())
    private val dismiss = Runnable { finish() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 透明浮在别的 App 上，不抢焦点，不产生任务切换动画。
        window.setBackgroundDrawableResource(android.R.color.transparent)
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL)
        window.setDimAmount(0.0f)
        try {
            window.attributes = window.attributes.apply {
                gravity = Gravity.TOP
            }
        } catch (e: Exception) {
        }

        val text = intent?.getStringExtra(MainActivity.EXTRA_TEXT) ?: ""
        val blind = intent?.getBooleanExtra(MainActivity.EXTRA_READ_CLIP, false) ?: false
        val plat = intent?.getStringExtra(EXTRA_PLATFORM) ?: ""

        setContentView(buildCard(text, blind, plat))
        handler.postDelayed(dismiss, 12000)
    }

    override fun onDestroy() {
        handler.removeCallbacks(dismiss)
        super.onDestroy()
    }

    private fun buildCard(text: String, blind: Boolean, plat: String): View {
        val root = FrameLayout(this)
        root.setBackgroundColor(Color.parseColor("#33000000"))
        // 点空白处 = 略过
        root.setOnClickListener { finish() }

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(11), dp(8), dp(11))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#F21E293B"))
                cornerRadius = dp(18).toFloat()
                setStroke(dp(1), Color.parseColor("#33FFFFFF"))
            }
            // 卡片自己吃掉点击，避免点按钮时把整个弹窗关掉
            isClickable = true
        }

        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }

        val head = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 14f
            setText(if (blind) "复制了内容 · 要整理进「文化」吗？" else "这条要整理进「文化」吗？")
        }
        val sub = TextView(this).apply {
            setTextColor(Color.parseColor("#94A3B8"))
            textSize = 10.5f
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            setPadding(0, dp(3), 0, 0)
            if (blind) {
                setText("系统不让后台读剪贴板 · 点「整理」后自动接上")
            } else {
                val brief = text.replace("\n", " ").trim()
                val cut = if (brief.length > 40) brief.substring(0, 40) + "…" else brief
                setText(if (plat.isEmpty()) cut else "$plat · $cut")
            }
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
        go.setOnClickListener { openIntake(text, blind) }
        no.setOnClickListener { finish() }

        card.addView(col)
        card.addView(go)
        card.addView(no)

        val lp = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        )
        lp.setMargins(dp(10), statusBarHeight() + dp(10), dp(10), 0)
        lp.gravity = Gravity.TOP
        root.addView(card, lp)
        return root
    }

    private fun openIntake(text: String, blind: Boolean) {
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
        }
        finish()
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun statusBarHeight(): Int {
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else dp(24)
    }

    companion object {
        const val EXTRA_PLATFORM = "dt_platform"
    }
}
