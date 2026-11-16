# 2.5.2 覆盖清单

整包必须**全量覆盖**：`lib/` + `pubspec.yaml` + `.github/workflows/build.yml`。

> 本版两件事：
> 1. **移除「今日联动」看板**（帝国页只留 三维舞台 / 关键参数 / 纪事）。该看板把「战争」
>    与「内政混乱／修养生息」按两个不同维度计数，同一天会被算两次（12+18+14=44 > 42 天），
>    数字差两天容易被当成 bug，所以整块拿掉。
> 2. **领地舞台可拖拽转动**（2.5D 转台，不是真模型）。左右拖拽给画面加透视偏航，
>    同时带一点俯仰，落地投影跟着位移；松手或双击回正。手势只接管横向，
>    纵向仍可滚动页面。只用 `Transform` + 矩阵，不引入 WebView / 3D 依赖，APK 体积不变。
>
> 覆盖文件：`lib/empire_page.dart`、`pubspec.yaml`（+ `FILES.md` 本身）。

| 文件 | 字节 | MD5 |
|---|---|---|
| `pubspec.yaml` | 398 | `86fff89ea41736d1c2c0dfe924807d81` |
| `README.md` | 3,573 | `7b11c7ac84cfd02334a547fb173757aa` |
| `.github/workflows/build.yml` | 5,522 | `1b9488bba4d632454cbb8db0023738c6` |
| `lib/main.dart` | 127,122 | `1f75104bc607e3a49efe889f264def79` |
| `lib/pages_extra.dart` | 138,365 | `b0f000e5b91e1c8b3575c3cefb5712e6` |
| `lib/deepseek_service.dart` | 12,063 | `8a4d9a670b3a9378ceeda3e3ba7d4210` |
| `lib/deepseek_sheet.dart` | 49,888 | `1eb1c3165082764049ec951d98803031` |
| `lib/empire_page.dart` | 71,718 | `9bab00fac714fa2db5694fe15d00041d` |
| `lib/empire_data.dart` | 19,564 | `aaca4183f71cc53fce9777e9181e76c2` |
| `lib/empire_assets.dart` | 897,977 | `61e06d9173a85e0dc101524597d8acc6` |

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
