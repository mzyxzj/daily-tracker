# Empire-V4.1 覆盖清单（4.1.0）

整包必须**全量覆盖**：`lib/` + `pubspec.yaml` + `.github/workflows/build.yml` + `.android-inject/`。

> 这一版只修两个「明明做了却没生效」，结构不动：
>
> 1. **站内播放真的在站内**。4.0 把 `m.bilibili.com/video/BV…` 塞进 WebView，那是
>    手机浏览器落地页，满屏「打开App，流畅又高清」，点一下就跳出去。
>    现在先翻译成平台自己的播放器页（`lib/player_target.dart`）：
>    B站走 `blackboard/html5mobileplayer.html` → `player.bilibili.com` → 桌面版三级兜底；
>    抖音走 `open.douyin.com/player/video`。短链先跟 302 拿 BV / aweme id。
>    加载完探 DOM 有没有 `<video>`，没有自动换源；跳 App 的 scheme 全部拦下。
>
> 2. **复制即弹真的会弹**。三个原因都堵了：
>    ① 服务被 ROM 停了但开关还是「开」→ 分开看 enabled / connected，三态显示；
>    ② 只监听窗口切换，漏掉 content-changed / 剪贴板回调 → `typeAllMask` + 双路；
>    ③ 系统不让后台读剪贴板 → 读不到内容也照弹，点「整理」App 到前台再读。
>    侧边栏状态卡点进去是**自检面板**（服务在不在跑、最近读到剪贴板是多久前、
>    底层报错、「试一下」立刻弹条验证）。
>
> 数据库不动（仍是 15），无新增依赖。80 个测试全绿。
>
> 覆盖文件：`lib/player_target.dart`（新）、`lib/culture_feed.dart`、
> `lib/native_clip.dart`、`lib/main.dart`、`pubspec.yaml`、`README.md`、`FILES.md`、
> `.android-inject/`（4 个文件，含固定签名密钥）。其余文件未改，可沿用旧包。

| 文件 | 字节 | MD5 |
|---|---|---|
| `pubspec.yaml` | 426 | `d8b6fe69742893bda97111b059abc3c5` |
| `README.md` | 25,677 | `fedb1e43fe0a93bfea8e6d42cbbfb4ef` |
| `.github/workflows/build.yml` | 7,165 | `6f2f5db50001ffed63fc2dc2e4cd2e55` |
| `lib/main.dart` | 138,272 | `9aca3c8de3857fb7e2d5b61ca74740d0` |
| `lib/culture_page.dart` | 51,430 | `fe3166f67eb69afd8ea792a02828ae82` |
| `lib/culture_feed.dart` | 98,801 | `e17c13098e5e465463fc5a63a00e205f` |
| `lib/content_fetch.dart` | 23,847 | `d4d49bbb91d7c81f4fcd25dfa38d32e0` |
| `lib/content_feed.dart` | 14,941 | `c477ce3b9f98a85a1099be539f3337a1` |
| `lib/content_intake.dart` | 23,270 | `e1546f54fcd91d758601a4b4701710b2` |
| `lib/native_clip.dart` | 5,896 | `add40db1975d0b306a1801d6a2ade950` |
| `lib/player_target.dart` | 6,481 | `bbfbb1328e00507d5e1d6aec0bcead12` |
| `lib/deepseek_service.dart` | 12,063 | `8a4d9a670b3a9378ceeda3e3ba7d4210` |
| `lib/deepseek_sheet.dart` | 72,621 | `ccd3d91379d101cfbbc0ada026a813e3` |
| `lib/empire_page.dart` | 71,718 | `9bab00fac714fa2db5694fe15d00041d` |
| `lib/empire_data.dart` | 19,564 | `aaca4183f71cc53fce9777e9181e76c2` |
| `lib/empire_assets.dart` | 897,977 | `61e06d9173a85e0dc101524597d8acc6` |
| `lib/pages_extra.dart` | 138,365 | `b0f000e5b91e1c8b3575c3cefb5712e6` |
| `lib/medical_page.dart` | 66,637 | `cac60111718de4e5939b357a29719d6c` |
| `.android-inject/MainActivity.kt` | 6,547 | `91a263608d1cb2f4220860019ee83e17` |
| `.android-inject/ClipWatchService.kt` | 18,412 | `947c5af56e0c913a1747d6b645bdc9af` |
| `.android-inject/patch.py` | 7,949 | `52a23e41bd8c09e8455d4c404d15ce89` |
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
