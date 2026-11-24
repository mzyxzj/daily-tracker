# Empire-V3.0 覆盖清单（3.0.0）

整包必须**全量覆盖**：`lib/` + `pubspec.yaml` + `.github/workflows/build.yml`。

> 这一版把「内容引进 / 流量算法 / 分级」缝成一条流水线：
> 1. **复制就能引进**：抖音 / B站 分享文案整段复制，切回 App 自动问「要不要引进」；
>    封面、标题、作者、时长自动抓（B站 view 接口 → 抖音 iteminfo → og:meta → 分享文案兜底），
>    用户只需要点一个分级标签。
> 2. **按电量推荐**：读医疗页的前额叶电量落档，同档优先、今日聚焦加权、同库最多两条；
>    比当前档更耗电的直接隐藏；红灯区把「别碰什么」摆到最上面。
> 3. **库首页**：库宫格（三图拼贴 + 条数 + 没看数）→ 库内 16:9 海报流 / 9:16 竖版流 /
>    横版卡片流，配分级筛选、搜索、排序，10 秒定位。
>
> 数据库 13 → **14**：`culture_items` 增 `grade_tier / author / ext_id / from_share` 四列，
> 老库用 `PRAGMA table_info` 检查后 ALTER，旧条目与封面不动。
> 新增 `lib/content_fetch.dart`、`lib/content_intake.dart`，无新增第三方依赖（网络走 `dart:io`）。
> 55 个测试全绿（解析 / 元数据 / 落档 / 推荐 / 迁移 / 页面接线）。
>
> 覆盖文件：`lib/culture_page.dart`、`lib/content_fetch.dart`、`lib/content_intake.dart`、
> `lib/main.dart`、`pubspec.yaml`、`README.md`、`FILES.md`。

| 文件 | 字节 | MD5 |
|---|---|---|
| `pubspec.yaml` | 448 | `d14a9fdb68eae54ac76fb0ada6c5c611` |
| `README.md` | 16,519 | `87804c803682c75718ce20b6e2680e17` |
| `.github/workflows/build.yml` | 5,522 | `1b9488bba4d632454cbb8db0023738c6` |
| `lib/main.dart` | 136,673 | `290bc3e50600cf8cf36b8ef5e6d2de64` |
| `lib/pages_extra.dart` | 138,365 | `b0f000e5b91e1c8b3575c3cefb5712e6` |
| `lib/deepseek_service.dart` | 12,063 | `8a4d9a670b3a9378ceeda3e3ba7d4210` |
| `lib/deepseek_sheet.dart` | 72,621 | `ccd3d91379d101cfbbc0ada026a813e3` |
| `lib/empire_page.dart` | 71,718 | `9bab00fac714fa2db5694fe15d00041d` |
| `lib/empire_data.dart` | 19,564 | `aaca4183f71cc53fce9777e9181e76c2` |
| `lib/empire_assets.dart` | 897,977 | `61e06d9173a85e0dc101524597d8acc6` |
| `lib/culture_page.dart` | 163,003 | `d63ff75db469ebb742e05972af44e906` |
| `lib/medical_page.dart` | 66,637 | `cac60111718de4e5939b357a29719d6c` |
| `lib/content_fetch.dart` | 23,847 | `d4d49bbb91d7c81f4fcd25dfa38d32e0` |
| `lib/content_intake.dart` | 23,270 | `e1546f54fcd91d758601a4b4701710b2` |

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
