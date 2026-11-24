#!/usr/bin/env python3
# 把「复制即弹」的原生部分注入到 CI 生成的 Android 壳里。
#
# 仓库只放 lib/ + pubspec + 这份注入脚本，Android 工程由 CI 里的
# `flutter create` 生成，所以原生文件必须在生成之后再写进去。
#
# 幂等：重复执行不会重复插入 <service> 或权限。

import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def fail(msg):
    print("INJECT FAILED: " + msg)
    sys.exit(1)


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def write(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)


def main():
    mains = glob.glob(
        os.path.join(ROOT, "android/app/src/main/**/MainActivity.kt"),
        recursive=True,
    )
    if not mains:
        fail("MainActivity.kt not found（是不是漏了 Generate Android shell 这一步？）")
    main_kt = mains[0]
    pkg_dir = os.path.dirname(main_kt)

    src = read(main_kt)
    m = re.search(r"^\s*package\s+([\w.]+)", src, re.M)
    if not m:
        fail("package 声明没找到")
    pkg = m.group(1)
    print("package = " + pkg)
    print("dir     = " + pkg_dir)

    for name in ("MainActivity.kt", "ClipWatchService.kt"):
        body = read(os.path.join(HERE, name)).replace("__PKG__", pkg)
        write(os.path.join(pkg_dir, name), body)
        print("wrote " + name)

    res_xml = os.path.join(ROOT, "android/app/src/main/res/xml/clip_service.xml")
    write(res_xml, """<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeWindowStateChanged|typeWindowContentChanged"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagDefault"
    android:canRetrieveWindowContent="true"
    android:notificationTimeout="300"
    android:description="@string/dt_clip_service_desc" />
""")
    print("wrote res/xml/clip_service.xml")

    strings = os.path.join(ROOT, "android/app/src/main/res/values/dt_strings.xml")
    write(strings, """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="dt_clip_service_desc">复制抖音、B站等分享链接时，在屏幕上方问你要不要整理进「文化」。只读剪贴板里的链接，不看别的内容。</string>
</resources>
""")
    print("wrote res/values/dt_strings.xml")

    manifest = os.path.join(ROOT, "android/app/src/main/AndroidManifest.xml")
    if not os.path.exists(manifest):
        fail("AndroidManifest.xml 不存在")
    mf = read(manifest)
    changed = False

    perms = [
        "android.permission.INTERNET",
    ]
    for perm in perms:
        if perm not in mf:
            tag = '    <uses-permission android:name="%s"/>\n' % perm
            mf = re.sub(r"(<manifest[^>]*>\n)", lambda x: x.group(1) + tag, mf, count=1)
            changed = True
            print("added permission " + perm)

    if 'android:name=".ClipWatchService"' not in mf:
        service = """        <service
            android:name=".ClipWatchService"
            android:exported="true"
            android:label="文化 · 复制即整理"
            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
            <intent-filter>
                <action android:name="android.accessibilityservice.AccessibilityService" />
            </intent-filter>
            <meta-data
                android:name="android.accessibilityservice"
                android:resource="@xml/clip_service" />
        </service>
"""
        if "</application>" not in mf:
            fail("</application> 没找到")
        mf = mf.replace("</application>", service + "    </application>", 1)
        changed = True
        print("added ClipWatchService")

    if "android.intent.action.SEND" not in mf:
        send_filter = """            <intent-filter>
                <action android:name="android.intent.action.SEND" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:mimeType="text/plain" />
            </intent-filter>
"""
        idx = mf.find("</activity>")
        if idx < 0:
            fail("</activity> 没找到")
        mf = mf[:idx] + send_filter + "        " + mf[idx:]
        changed = True
        print("added ACTION_SEND filter")

    if changed:
        write(manifest, mf)
    else:
        print("manifest already patched")

    # 编译前自查：这几行缺一个就会在 build 时才炸。
    check = read(manifest)
    for needle in (".ClipWatchService", "@xml/clip_service"):
        if needle not in check:
            fail("manifest 缺少 " + needle)
    if not os.path.exists(res_xml):
        fail("clip_service.xml 没写成功")
    print("INJECT OK")


if __name__ == "__main__":
    main()
