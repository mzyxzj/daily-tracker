package __PKG__

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File

/**
 * 给系统安装器读 APK 用。
 *
 * Android 7 之后 `file://` 直接给安装器会抛 FileUriExposedException，
 * 必须走 content://。这里用几十行自己实现一个只读 provider，
 * 免得为了 FileProvider 去动 Gradle 依赖（模板版本一换就容易崩）。
 *
 * 只开放 cacheDir 下的单层文件，且文件名做校验，杜绝 ../ 穿越。
 */
class ApkProvider : ContentProvider() {

    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val f = resolve(uri) ?: return null
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String = "application/vnd.android.package-archive"

    override fun query(
        uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?
    ): Int = 0

    private fun resolve(uri: Uri): File? {
        val ctx = context ?: return null
        val name = uri.lastPathSegment ?: return null
        if (name.isEmpty() || name.contains('/') || name.contains("..")) return null
        val f = File(ctx.cacheDir, name)
        if (!f.exists() || !f.isFile) return null
        return f
    }

    companion object {
        fun uriFor(pkg: String, name: String): Uri =
            Uri.parse("content://$pkg.apk/$name")
    }
}
