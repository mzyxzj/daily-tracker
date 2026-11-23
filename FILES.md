# Empire-V2.1 覆盖清单（2.6.0）

整包必须**全量覆盖**：`lib/` + `pubspec.yaml` + `.github/workflows/build.yml`。

> 本版把「文化建设」做成和「规划」同级的模块：底部导航第 6 个 tab「文化」，
> 新增 `lib/culture_page.dart`（约 2,900 行）。
>
> 1. **内容引进**：按「战略聚焦」维度自动建库（首次落 6 个内置库，删掉的进黑名单
>    不复活）；条目至少能存链接、能打开；横版卡 / 竖版流 / 紧凑列表三种呈现；
>    搜索 + 未看/收藏/看过筛选 + 收藏与最近打开排序，库内 10 秒定位。
> 2. **再创作**：内容一键转工具包（目标 + 可勾选步骤 + 模板正文），可复制 Markdown、
>    可分享，进度可追踪。
> 3. **流量算法**：优质源权重排序 + 一键直达；「今日 3 条」按权重/收藏/未读、各库轮流取；
>    WebView 应用内浏览，被拦时回退系统浏览器。
>
> 数据库 10 → **11**，新增 4 张表（库 / 条目 / 工具包 / 优质源），老库自动补齐。
> 新依赖：`url_launcher ^6.3.0`、`webview_flutter ^4.10.0`。
>
> 覆盖文件：`lib/culture_page.dart`、`lib/main.dart`、`pubspec.yaml`、`README.md`、`FILES.md`。

| 文件 | 字节 | MD5 |
|---|---|---|
| `pubspec.yaml` | 448 | `61f3a6088bd988d6b2e156a65bc7f8df` |
| `README.md` | 10,140 | `4ea1084b0064a9dcdd7019fe291ed4c5` |
| `.github/workflows/build.yml` | 5,522 | `1b9488bba4d632454cbb8db0023738c6` |
| `lib/main.dart` | 132,076 | `5df7944c838536b215182c63011ec037` |
| `lib/pages_extra.dart` | 138,365 | `b0f000e5b91e1c8b3575c3cefb5712e6` |
| `lib/deepseek_service.dart` | 12,063 | `8a4d9a670b3a9378ceeda3e3ba7d4210` |
| `lib/deepseek_sheet.dart` | 72,621 | `ccd3d91379d101cfbbc0ada026a813e3` |
| `lib/empire_page.dart` | 71,718 | `9bab00fac714fa2db5694fe15d00041d` |
| `lib/empire_data.dart` | 19,564 | `aaca4183f71cc53fce9777e9181e76c2` |
| `lib/empire_assets.dart` | 897,977 | `61e06d9173a85e0dc101524597d8acc6` |
| `lib/culture_page.dart` | 107,012 | `70fe8d8f236120b11b58fc6a782263a6` |

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
