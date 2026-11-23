# Empire-V2.1 覆盖清单（2.7.0）

整包必须**全量覆盖**：`lib/` + `pubspec.yaml` + `.github/workflows/build.yml`。

> 本版在文化模块基础上加了「医疗」，和「规划 / 文化」同级（底部第 7 个 tab）。
> 新增 `lib/medical_page.dart`（约 1,500 行）。
>
> 1. **血条**：顶部常驻前额叶电量，最近值 / 今日最低 / 急救次数 / 治疗次数 / 7 日最低柱图；
>    <15% 变红并给急救入口。
> 2. **预防**：防电量过低 / 防暴食 / 防恐慌式学习，每条「触发信号 + 3 动作」，当天可打卡。
> 3. **急救**：<15% 四步（放空 / 停高耗能 / 不提提议 / 只做最低日程）+ 暴食止损 +
>    恐慌熬夜止损；全屏急救模式一次一步，决策次数为 0。
> 4. **治疗**：8 种恢复手段，按「恢复 ÷ 耗时」和当前电量排序，记录实际恢复量。
> 5. **分级**：四档电量对应的允许 / 禁止娱乐，可编辑，当前档位高亮。
>
> 数据库 11 → **12**，新增 4 张表；医疗信号写入 `ui_states`。
> 无新增依赖。
>
> 覆盖文件：`lib/medical_page.dart`、`lib/main.dart`、`pubspec.yaml`、`README.md`、`FILES.md`。

| 文件 | 字节 | MD5 |
|---|---|---|
| `pubspec.yaml` | 448 | `4f573b30babea68566eb8951dc7a77ec` |
| `README.md` | 13,270 | `7a95a40e94b2925b998d7715f9ebfeb0` |
| `.github/workflows/build.yml` | 5,522 | `1b9488bba4d632454cbb8db0023738c6` |
| `lib/main.dart` | 132,496 | `a51d261082107f65476f3b6c6aaf3fb8` |
| `lib/pages_extra.dart` | 138,365 | `b0f000e5b91e1c8b3575c3cefb5712e6` |
| `lib/deepseek_service.dart` | 12,063 | `8a4d9a670b3a9378ceeda3e3ba7d4210` |
| `lib/deepseek_sheet.dart` | 72,621 | `ccd3d91379d101cfbbc0ada026a813e3` |
| `lib/empire_page.dart` | 71,718 | `9bab00fac714fa2db5694fe15d00041d` |
| `lib/empire_data.dart` | 19,564 | `aaca4183f71cc53fce9777e9181e76c2` |
| `lib/empire_assets.dart` | 897,977 | `61e06d9173a85e0dc101524597d8acc6` |
| `lib/culture_page.dart` | 107,012 | `70fe8d8f236120b11b58fc6a782263a6` |
| `lib/medical_page.dart` | 75,361 | `8fc3fecf1cf221a470dba620b5e619f5` |

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
