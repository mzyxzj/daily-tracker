package __PKG__

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 和 Flutter 的桥：
 *   daily_tracker/clip         -> getInitial / isEnabled / openSettings / openOverlaySettings
 *   daily_tracker/clip_events  -> 运行中收到分享或悬浮窗带进来的链接时推给 Dart
 *
 * 进 App 的三种方式都收口到 consumeIntent：
 *   1. 系统分享面板选本 App（ACTION_SEND，text/plain）；
 *   2. 无障碍服务弹出的悬浮窗点「整理」；
 *   3. 直接点开 http(s) 链接（ACTION_VIEW）。
 */
class MainActivity : FlutterActivity() {

    private var eventSink: EventChannel.EventSink? = null
    private var pendingText: String = ""
    private var lastHandled: String = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        consumeIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeIntent(intent)
    }

    private fun consumeIntent(intent: Intent?) {
        if (intent == null) return
        var text = ""
        when (intent.action) {
            Intent.ACTION_SEND -> {
                text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: ""
                if (text.isBlank()) {
                    @Suppress("DEPRECATION")
                    val u: Uri? = intent.getParcelableExtra(Intent.EXTRA_STREAM)
                    if (u != null) text = u.toString()
                }
            }
            Intent.ACTION_VIEW -> text = intent.dataString ?: ""
            else -> text = intent.getStringExtra(EXTRA_TEXT) ?: ""
        }
        text = text.trim()
        if (text.isEmpty()) return
        if (text == lastHandled) return
        lastHandled = text
        val sink = eventSink
        if (sink != null) {
            sink.success(text)
        } else {
            pendingText = text
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "daily_tracker/clip").setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitial" -> {
                    val t = pendingText
                    pendingText = ""
                    result.success(t)
                }
                "isEnabled" -> result.success(ClipWatchService.isEnabled(this))
                "openSettings" -> result.success(openAccessibilitySettings())
                "openOverlaySettings" -> result.success(openOverlaySettings())
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "daily_tracker/clip_events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    if (pendingText.isNotEmpty() && events != null) {
                        events.success(pendingText)
                        pendingText = ""
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            }
        )
    }

    private fun openAccessibilitySettings(): Boolean {
        return try {
            val i = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun openOverlaySettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return try {
            val i = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:" + packageName)
            )
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
            true
        } catch (e: Exception) {
            false
        }
    }

    companion object {
        const val EXTRA_TEXT = "dt_clip_text"
    }
}
