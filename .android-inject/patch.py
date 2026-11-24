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
import shutil
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
    # 事件类型给全：很多 ROM 复制时只回 typeWindowContentChanged 甚至只回点击事件，
    # 只监听 typeWindowStateChanged 会整片漏掉。服务启动后还会用代码再设一遍。
    write(res_xml, """<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeAllMask"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagDefault|flagRetrieveInteractiveWindows|flagIncludeNotImportantViews"
    android:canRetrieveWindowContent="true"
    android:notificationTimeout="80"
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

    # ---- 固定签名 ----
    # 模板默认 release 用 debug keystore，而 CI 每次 runner 的 debug 都是新生成的，
    # 结果就是「每个版本的签名都不一样」——覆盖安装必失败，卸掉重装就丢数据。
    # 这里放一把固定密钥，以后所有版本同签名，可以直接覆盖升级。
    ks_src = os.path.join(HERE, "dt-release.jks")
    ks_dst = os.path.join(ROOT, "android/app/dt-release.jks")
    if os.path.exists(ks_src):
        shutil.copyfile(ks_src, ks_dst)
        print("wrote app/dt-release.jks")

        gradles = glob.glob(os.path.join(ROOT, "android/app/build.gradle*"))
        gradles = [g for g in gradles if not g.endswith(".kts")] or gradles
        if gradles:
            gp = gradles[0]
            g = read(gp)
            kts = gp.endswith(".kts")
            if "signingConfigs {" not in g:
                if kts:
                    sig = """
    signingConfigs {
        create("rel") {
            storeFile = file("dt-release.jks")
            storePassword = "dt-release-2026"
            keyAlias = "dt"
            keyPassword = "dt-release-2026"
        }
    }
"""
                else:
                    sig = """
    signingConfigs {
        rel {
            storeFile file("dt-release.jks")
            storePassword "dt-release-2026"
            keyAlias "dt"
            keyPassword "dt-release-2026"
        }
    }
"""
                m = re.search(r"android\s*\{\n", g)
                if not m:
                    fail("android { 块没找到，无法注入签名配置")
                g = g[:m.end()] + sig + g[m.end():]
                print("added signingConfigs")

            if kts:
                g = g.replace("signingConfig = signingConfigs.debug",
                              'signingConfig = signingConfigs.getByName("rel")')
            else:
                g = g.replace("signingConfig = signingConfigs.debug",
                              "signingConfig = signingConfigs.rel")
                g = g.replace("signingConfig signingConfigs.debug",
                              "signingConfig signingConfigs.rel")
            write(gp, g)
            if "signingConfigs.rel" not in g and 'signingConfigs.getByName("rel")' not in g:
                print("WARN: build.gradle 里没找到 debug 签名行，release 可能仍用 debug key")
            else:
                print("release signing -> dt-release.jks")
    else:
        print("no dt-release.jks, keep template signing")

    manifest = os.path.join(ROOT, "android/app/src/main/AndroidManifest.xml")
    if not os.path.exists(manifest):
        fail("AndroidManifest.xml 不存在")
    mf = read(manifest)
    changed = False

    perms = [
        "android.permission.INTERNET",
        # 悬浮条优先用「显示在其他应用上层」窗口类型，MIUI/HyperOS 上比
        # 无障碍专属窗口更不容易被拦。没授权时自动退回无障碍窗口，不影响使用。
        "android.permission.SYSTEM_ALERT_WINDOW",
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
