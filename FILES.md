# Empire-V4.3 覆盖清单（4.3.1）

整包必须**全量覆盖**：`lib/` + `pubspec.yaml` + `.github/workflows/build.yml` + `.android-inject/`。

> 这一版是 4.3.0 的修补，三件事：
>
> 1. **清晰度按钮补到独立播放器页**。4.3.0 只加在信息流内嵌播放器，
>    而「在这里看」打开的是 `CulturePlayerPage`（另一套 WebView），那一页看不到按钮。
>    现在右上角常驻一个档位胶囊，不跟浮层一起隐藏。
> 2. **点了「整理」进 App 又弹一次**。App 渲染页面产生的 `WINDOW_CONTENT_CHANGED`
>    落在 15 秒的「内容类 App 上下文」里，于是又读一次剪贴板、又弹。
>    现在：自己包名的事件一律 return；点「整理」/「略过」后 30 秒内不再弹（`consumedAt`）。
> 3. **只在复制外链时弹**。复制动作按置信度分级：
>    「复制链接」= 2（任何 App 都算）；仅「复制」= 1（只在 B站/抖音/小红书等短视频平台算）。
>    微信/QQ 的「复制」是复制聊天文字，不在白名单里。
>
> 数据库不动（仍是 15）；依赖不变。`flutter analyze` 无 error。

| 文件 | 字节 | MD5 |
|---|---|---|
| `pubspec.yaml` | 558 | `5cf71c4ca614c02618cf95c0669afd5b` |
| `README.md` | 32,838 | `147e87bb0eb96f697c185180f6d516bf` |
| `.github/workflows/build.yml` | 9,510 | `8bf57bcb3475baac480584878f35875b` |
| `lib/app_update.dart` | 14,455 | `a931e3cabb03f54bf7d81073af50427b` |
| `lib/content_feed.dart` | 14,941 | `c477ce3b9f98a85a1099be539f3337a1` |
| `lib/content_fetch.dart` | 23,847 | `d4d49bbb91d7c81f4fcd25dfa38d32e0` |
| `lib/content_intake.dart` | 23,270 | `e1546f54fcd91d758601a4b4701710b2` |
| `lib/culture_feed.dart` | 122,808 | `2bb0b8fa5c62427d93f16c7e46105fdc` |
| `lib/culture_page.dart` | 51,430 | `fe3166f67eb69afd8ea792a02828ae82` |
| `lib/deepseek_service.dart` | 12,063 | `8a4d9a670b3a9378ceeda3e3ba7d4210` |
| `lib/deepseek_sheet.dart` | 72,621 | `ccd3d91379d101cfbbc0ada026a813e3` |
| `lib/empire_assets.dart` | 897,977 | `61e06d9173a85e0dc101524597d8acc6` |
| `lib/empire_data.dart` | 19,564 | `aaca4183f71cc53fce9777e9181e76c2` |
| `lib/empire_page.dart` | 71,718 | `9bab00fac714fa2db5694fe15d00041d` |
| `lib/main.dart` | 138,272 | `9aca3c8de3857fb7e2d5b61ca74740d0` |
| `lib/medical_page.dart` | 66,637 | `cac60111718de4e5939b357a29719d6c` |
| `lib/native_clip.dart` | 7,430 | `0b36583f1fd34fff83a2e5020db0f2fa` |
| `lib/pages_extra.dart` | 138,365 | `b0f000e5b91e1c8b3575c3cefb5712e6` |
| `lib/player_target.dart` | 6,481 | `bbfbb1328e00507d5e1d6aec0bcead12` |
| `.android-inject/MainActivity.kt` | 11,262 | `2ace607c46c4d9626f52fe3a3c96e472` |
| `.android-inject/ClipWatchService.kt` | 30,140 | `6d26333b7226dbbb0e3813907f79cc18` |
| `.android-inject/ClipPromptActivity.kt` | 7,346 | `7bb2d5f83cbfafeb33ccab85619b3e22` |
| `.android-inject/ApkProvider.kt` | 1,937 | `7c62fa727307282c4ac3b31494cd6b2b` |
| `.android-inject/patch.py` | 11,142 | `e3187f554e526518c3a1befa50771057` |
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
grep -c 'POST_NOTIFICATIONS' .android-inject/patch.py   # 期望 1
grep -c 'dtDeep' lib/culture_feed.dart             # 期望 ≥ 3
md5sum lib/empire_assets.dart                      # 应等于上表
```
