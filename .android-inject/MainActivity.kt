package __PKG__

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 和 Flutter 的桥：
 *   daily_tracker/clip         -> getInitial / isEnabled / status / test
 *                                 / openSettings / openOverlaySettings / readClip
 *   daily_tracker/clip_events  -> 运行中收到分享或悬浮条带进来的链接时推给 Dart
 *
 * 进 App 的三种方式都收口到 consumeIntent：
 *   1. 系统分享面板选本 App（ACTION_SEND，text/plain）；
 *   2. 无障碍服务弹出的悬浮条点「整理」；
 *   3. 直接点开 http(s) 链接（ACTION_VIEW）。
 *
 * 还有一种特殊情况：悬浮条是「盲弹」的（系统不给服务读剪贴板），
 * 这时 Intent 只带 EXTRA_READ_CLIP=true，正文要等 App 真正拿到焦点后再读——
 * 前台 App 读剪贴板一定成功，这就是绕开 ROM 限制的那一步。
 */
class MainActivity : FlutterActivity() {

    private var eventSink: EventChannel.EventSink? = null
    private var pendingText: String = ""
    private var pendingReadClip: Boolean = false
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

    override fun onResume() {
        super.onResume()
        // 盲弹进来时读剪贴板。放在 onResume（Activity 已可见）最稳，
        // 比 onWindowFocusChanged 早一步，冷启动也能在 Flutter 起来前读到。
        if (!pendingReadClip) return
        pendingReadClip = false
        val text = readClipSafe()
        if (text.isNotEmpty()) emit(text)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || !pendingReadClip) return
        pendingReadClip = false
        val text = readClipSafe()
        if (text.isEmpty()) return
        emit(text)
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
        if (intent.getBooleanExtra(EXTRA_READ_CLIP, false)) {
            // 盲弹进来的：先记下来，等拿到焦点再读。
            pendingReadClip = true
        }
        text = text.trim()
        if (text.isEmpty()) return
        emit(text)
    }

    private fun emit(text: String) {
        val t = text.trim()
        if (t.isEmpty() || t == lastHandled) return
        lastHandled = t
        val sink = eventSink
        if (sink != null) {
            sink.success(t)
        } else {
            pendingText = t
        }
    }

    private fun readClipSafe(): String {
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
                "status" -> result.success(ClipWatchService.status(this))
                "test" -> result.success(ClipWatchService.test())
                "readClip" -> result.success(readClipSafe())
                "notifyReady" -> result.success(ClipWatchService.canNotify(this))
                "requestNotify" -> result.success(requestNotifyPermission())
                "openSettings" -> result.success(openAccessibilitySettings())
                "openOverlaySettings" -> result.success(openOverlaySettings())
                else -> result.notImplemented()
            }
        }

        // App 自身的事：版本号、装新包、开外链。
        MethodChannel(messenger, "daily_tracker/app").setMethodCallHandler { call, result ->
            when (call.method) {
                "version" -> {
                    val pi = packageManager.getPackageInfo(packageName, 0)
                    val m = HashMap<String, Any>()
                    m["name"] = pi.versionName ?: ""
                    m["code"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        pi.longVersionCode
                    } else {
                        @Suppress("DEPRECATION")
                        pi.versionCode.toLong()
                    }
                    result.success(m)
                }
                "canInstall" -> result.success(canInstallApk())
                "openInstallSettings" -> result.success(openInstallSettings())
                "installApk" -> {
                    val name = call.argument<String>("name") ?: ""
                    result.success(installApk(name))
                }
                "openUrl" -> {
                    val u = call.argument<String>("url") ?: ""
                    result.success(openUrl(u))
                }
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

    /// 装新包：系统安装器只认 content://，且要「安装未知应用」权限。
    private fun installApk(name: String): Boolean {
        return try {
            if (name.isEmpty() || name.contains('/') || name.contains("..")) return false
            val f = File(cacheDir, name)
            if (!f.exists()) return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                // 没授权就先带用户去开，回来再点一次即可。
                openInstallSettings()
                return false
            }
            val i = Intent(Intent.ACTION_VIEW)
            i.setDataAndType(ApkProvider.uriFor(packageName, name),
                "application/vnd.android.package-archive")
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun canInstallApk(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                packageManager.canRequestPackageInstalls()
            } else {
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun openInstallSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val i = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:" + packageName))
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun openUrl(url: String): Boolean {
        if (!url.startsWith("http")) return false
        return try {
            val i = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
            true
        } catch (e: Exception) {
            false
        }
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

    /**
     * 通知权限（Android 13+ 是运行时权限）。
     *
     * 为什么需要：ColorOS 会静默拦「后台弹出界面」，startActivity 不报错也不显示。
     * 这时唯一的兜底是发通知 —— 但没授权的话通知会被直接丢弃，用户还是什么都看不到。
     */
    private fun requestNotifyPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        return try {
            val granted = checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
            if (granted) return false
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 2001)
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
        const val EXTRA_READ_CLIP = "dt_read_clip"
    }
}
