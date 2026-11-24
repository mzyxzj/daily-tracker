# Empire-V4.0 覆盖清单（4.0.0）

整包必须**全量覆盖**：`lib/` + `pubspec.yaml` + `.github/workflows/build.yml` + `.android-inject/`。

> 这一版把「内容引进 / 流量算法 / 分级」三件合成一件：
> 1. **首页就是流**：竖向全屏一屏一条，上下滑；没有 tab、没有宫格、不用先选库。
>    顶部电量胶囊点一下切换「只看这一档 / 看全部」。
> 2. **侧边栏**（右上角滑块或右边缘滑出）：复制即弹状态、电量、引进、分级、库、
>    工具包、最近存的，一屏全在。**优质源已删掉。**
> 3. **内置播放器**：全屏 WebView + 沉浸模式（注入 CSS 隐藏推荐流/评论/侧栏）+
>    登录入口（同 WebView 打开平台登录页，cookie 持久）。
> 4. **再创作 = DeepSeek**：正文 + 我的笔记 → 步骤 / 模板 / 清单 / 别照搬的部分，
>    流式输出，可存成工具包。
> 5. **复制即弹**：`.android-inject/` 里的无障碍服务在屏幕上方弹「整理 / 略过」，
>    点整理直接带链接进 App。没开权限时有分享面板 / 前台读取两条兜底。
>
> 数据库 14 → **15**：`culture_items` 增 `content_text`，老库 ALTER，不丢数据。
> 无新增依赖，`url_launcher` 已移除。69 个测试全绿。
>
> 覆盖文件：`lib/culture_feed.dart`（新）、`lib/content_feed.dart`（新）、
> `lib/native_clip.dart`（新）、`lib/culture_page.dart`、`lib/main.dart`、
> `lib/content_intake.dart`、`pubspec.yaml`、`README.md`、`FILES.md`、
> `.github/workflows/build.yml`、`.android-inject/`（3 个文件）。

| 文件 | 字节 | MD5 |
|---|---|---|
| `pubspec.yaml` | 426 | `f915efe7e3731cfbb8eea2eeafbb234f` |
| `README.md` | 20,875 | `19568333922700cca3c7e0c9c06e52fe` |
| `.github/workflows/build.yml` | 5,968 | `d93149eb806ffdb1383547d14650ac71` |
| `lib/main.dart` | 137,818 | `6c38f5a63dc21b5485a6011254edc0f7` |
| `lib/culture_page.dart` | 51,430 | `fe3166f67eb69afd8ea792a02828ae82` |
| `lib/culture_feed.dart` | 88,090 | `d1c0c872c5f2bc7f7a70c5ceeee3c87b` |
| `lib/content_fetch.dart` | 23,847 | `d4d49bbb91d7c81f4fcd25dfa38d32e0` |
| `lib/content_feed.dart` | 14,941 | `c477ce3b9f98a85a1099be539f3337a1` |
| `lib/content_intake.dart` | 23,270 | `e1546f54fcd91d758601a4b4701710b2` |
| `lib/native_clip.dart` | 2,304 | `83c6053c0ad7da02b2d2fdd135e46f1c` |
| `lib/deepseek_service.dart` | 12,063 | `8a4d9a670b3a9378ceeda3e3ba7d4210` |
| `lib/deepseek_sheet.dart` | 72,621 | `ccd3d91379d101cfbbc0ada026a813e3` |
| `lib/empire_page.dart` | 71,718 | `9bab00fac714fa2db5694fe15d00041d` |
| `lib/empire_data.dart` | 19,564 | `aaca4183f71cc53fce9777e9181e76c2` |
| `lib/empire_assets.dart` | 897,977 | `61e06d9173a85e0dc101524597d8acc6` |
| `lib/pages_extra.dart` | 138,365 | `b0f000e5b91e1c8b3575c3cefb5712e6` |
| `lib/medical_page.dart` | 66,637 | `cac60111718de4e5939b357a29719d6c` |
| `.android-inject/MainActivity.kt` | 4,453 | `950782a1728c6157be7117dfbaa7bda2` |
| `.android-inject/ClipWatchService.kt` | 8,083 | `71b9f44873357278e133539535d4cc27` |
| `.android-inject/patch.py` | 4,936 | `df5f39d2c8463bfa01763e0df964f46d` |

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
