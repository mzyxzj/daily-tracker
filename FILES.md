# Empire-V4.2 覆盖清单（4.2.0）

整包必须**全量覆盖**：`lib/` + `pubspec.yaml` + `.github/workflows/build.yml` + `.android-inject/`。

> 这一版修三件「点了没用 / 根本没有」的事，另外补了应用内升级：
>
> 1. **复制即弹：悬浮窗改用透明 Activity**。一加 13T 上自检显示「弹过悬浮条 25 秒前」，
>    但屏幕什么都没有——ColorOS/氧OS 上 `addView` 成功、窗口不可见。
>    现在改 `ClipPromptActivity`（真实窗口，12 秒自动消失，复制时先振动），
>    起不来会把原因写进自检的「底层报错」。
>
> 2. **滑到就播**。视频条目在流里直接挂 WebView，划到即自动播放、划走暂停回收；
>    关键是不让 WebView 要求用户手势，否则自动播放被静默拦掉。
>
> 3. **全屏真的能全屏**。B站自带的全屏按钮在 WebView 里无效（缺少 onShowCustomView 宿主实现），
>    换成播放器右下角的 Flutter 全屏：横屏 + 沉浸 + 收起浮层，返回键先退全屏。
>
> 4. **应用内升级**。侧栏「检查更新」→ 读 Release → 就地下载 → 系统安装器覆盖安装，
>    不用再卸载重装导数据。
>
> 数据库不动（仍是 15）；新增依赖 `webview_flutter_android`（为了关掉手势限制）。
> 80 个测试全绿。
>
> 覆盖文件：`lib/app_update.dart`（新）、`lib/culture_feed.dart`、`lib/native_clip.dart`、
> `pubspec.yaml`、`README.md`、`FILES.md`、`.android-inject/`（6 个文件，
> 新增 `ClipPromptActivity.kt` / `ApkProvider.kt`）。

| 文件 | 字节 | MD5 |
|---|---|---|
| `pubspec.yaml` | 558 | `5fc1d51289906cc6d9134445dbff80e1` |
| `README.md` | 28,064 | `c69995ec854ac711f4087f49767c9d9c` |
| `.github/workflows/build.yml` | 9,510 | `8bf57bcb3475baac480584878f35875b` |
| `lib/main.dart` | 138,272 | `9aca3c8de3857fb7e2d5b61ca74740d0` |
| `lib/culture_page.dart` | 51,430 | `fe3166f67eb69afd8ea792a02828ae82` |
| `lib/culture_feed.dart` | 109,665 | `a25018f75f890d5b4ac1013bbd5d783a` |
| `lib/content_fetch.dart` | 23,847 | `d4d49bbb91d7c81f4fcd25dfa38d32e0` |
| `lib/content_feed.dart` | 14,941 | `c477ce3b9f98a85a1099be539f3337a1` |
| `lib/content_intake.dart` | 23,270 | `e1546f54fcd91d758601a4b4701710b2` |
| `lib/native_clip.dart` | 5,921 | `df17a3904bf6195a7bc50340b026bf28` |
| `lib/player_target.dart` | 6,481 | `bbfbb1328e00507d5e1d6aec0bcead12` |
| `lib/app_update.dart` | 14,455 | `a931e3cabb03f54bf7d81073af50427b` |
| `lib/deepseek_service.dart` | 12,063 | `8a4d9a670b3a9378ceeda3e3ba7d4210` |
| `lib/deepseek_sheet.dart` | 72,621 | `ccd3d91379d101cfbbc0ada026a813e3` |
| `lib/empire_page.dart` | 71,718 | `9bab00fac714fa2db5694fe15d00041d` |
| `lib/empire_data.dart` | 19,564 | `aaca4183f71cc53fce9777e9181e76c2` |
| `lib/empire_assets.dart` | 897,977 | `61e06d9173a85e0dc101524597d8acc6` |
| `lib/pages_extra.dart` | 138,365 | `b0f000e5b91e1c8b3575c3cefb5712e6` |
| `lib/medical_page.dart` | 66,637 | `cac60111718de4e5939b357a29719d6c` |
| `.android-inject/MainActivity.kt` | 9,945 | `8c64574d15106326d703fa389f51a881` |
| `.android-inject/ClipWatchService.kt` | 15,968 | `7384ba7330204a0a613c07c814ab76f8` |
| `.android-inject/ClipPromptActivity.kt` | 6,307 | `c6095c4dce6736b8be9ca84300dedfc2` |
| `.android-inject/ApkProvider.kt` | 1,937 | `7c62fa727307282c4ac3b31494cd6b2b` |
| `.android-inject/patch.py` | 10,757 | `e9e6fcd46518f66385d2d76c87206083` |
| `.android-inject/dt-release.jks` | 2,704 | `4ad915351096720f929147c9554d725a` |

## 领地渲染图（L01→L09）

| 等级 | 名称 | 画面 |
|---|---|---|
| L01 | 破败营地 | 破帐篷、断裂木栅、冷灰烬堆、枯树，焦土板块 |
| L02 | 边境村落 | 茅草木屋、水车溪流、干草堆、木制瞭望塔 |
| L03 | 坚固小镇 | 石砌城墙四角塔、木筋屋、鹅卵石集市广场、尖顶礼拜堂 |
| L04 | 繁华城邦 | 密集街区、双尖塔大教堂、穹顶行会厅、运河双桥、喷泉广场 |
| L05 | 巍峨王都 | 同心棱堡、镀金金字塔顶主堡、大台阶、凯旋门、高架引水桥 |
| L06 | 不朽帝国 | 青铜肋架＋氧化青玻璃巨构、巨型拱门、坐姿战神像、熔炉火光、高架铁轨 |
| L07 | 天空之城 | 浮空巨岩、水晶尖塔、瀑布坠入虚空、锁链卫星岛、云带 |
| L08 | 神域 | 三重同心浮空柱廊、中央穹顶光柱、光环、镜面水池 |
| L09 | 永恒之境 | 悖论台阶、黑曜方尖碑、三环如时针、悬浮平台、星座细线 |

九张统一：三分之四俯视 32°、左上单主光、哑光黏土模型质感、纯白背景离屏渲染，
再由 `tools/gen_realm.py` 抠底 → 羽化 → 768×768 WebP(q80) → base64 常量。
合计 602,976 B WebP / 803,980 B base64。

## 换图流程（以后要重做美术）

```bash
# 1. 把九张渲染图命名为 l01.png … l09.png 放进一个目录（纯色背景即可）
python tools/gen_realm.py <图片目录> --size 768 --quality 80
# 2. 脚本会整块重写 empire_assets.dart 中 REALM_ASSETS_BEGIN/END 之间的内容
```

脚本会自动：四角采样背景色 → 洪水填充抠图（容差按边框亮度跨度自适应）→
抹掉右下角水印 → 按不透明区域裁剪 → 缩放到 84% 画布 → 边框羽化 → WebP。

## 覆盖后自检

```bash
grep -c '^  assets:' pubspec.yaml                  # 期望 0
grep -c '_kRealmL09Webp' lib/empire_assets.dart    # 期望 2（常量定义 + map 引用）
grep -c 'buildReal' lib/empire_data.dart           # 期望 ≥ 1
md5sum lib/empire_assets.dart                      # 应等于上表
```
