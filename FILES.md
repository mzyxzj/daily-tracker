# 2.4.0 覆盖清单

整包必须**全量覆盖**：`lib/` + `pubspec.yaml` + `.github/workflows/build.yml`。

> 这一版的核心改动：**帝国模块不再自带假数据，全部数值由「今日」四个模块实时推演**。
> 只覆盖 `lib/empire_data.dart` 与 `lib/empire_page.dart` 即可生效，`main.dart` 无需改动。

| 文件 | 字节 | MD5 |
|---|---|---|
| `pubspec.yaml` | 398 | `db371b7ba40f4ee6440299e48e3816b8` |
| `README.md` | 3,573 | `7b11c7ac84cfd02334a547fb173757aa` |
| `.github/workflows/build.yml` | 5,522 | `1b9488bba4d632454cbb8db0023738c6` |
| `lib/main.dart` | 127,122 | `1f75104bc607e3a49efe889f264def79` |
| `lib/pages_extra.dart` | 138,365 | `b0f000e5b91e1c8b3575c3cefb5712e6` |
| `lib/deepseek_service.dart` | 12,063 | `8a4d9a670b3a9378ceeda3e3ba7d4210` |
| `lib/deepseek_sheet.dart` | 49,888 | `1eb1c3165082764049ec951d98803031` |
| `lib/empire_page.dart` | 71,554 | `f8469e1c5dd19b522e4f2a077c36cce4` |
| `lib/empire_data.dart` | 19,564 | `aaca4183f71cc53fce9777e9181e76c2` |
| `lib/empire_assets.dart` | 137,205 | `c0bdc7208d6cbad2badf89351b5a7042` |

## 覆盖后自检（仓库根目录执行）

```bash
grep -c '^  assets:' pubspec.yaml   # 期望 0（或直接报错），有输出说明 pubspec 没换
grep -c 'buildReal' lib/empire_data.dart   # 期望 ≥ 1，说明帝国引擎是新的
md5sum lib/empire_page.dart lib/empire_data.dart   # 应等于上表
```

## 帝国 ↔ 今日 数据联动（本版新增）

四个「今日」模块 → 帝国数值的映射：

| 今日模块 | 数据表 | 帝国侧效果 |
|---|---|---|
| 日程打卡 | `schedule_records` | 当天全部打卡 → 战争 +50；一卡没打 → 计入混乱/修养判定 |
| 每日状态 | `status_records` | 有记录 → 不计混乱；「复盘/总结/反思」项有内容 → 按时复盘 |
| 战略聚焦 | `focus_items` | 完成一条 → 科技突破 +500；其 multiplier → 科技复利连乘 |
| 今日概览 | 上述三者的汇总 | 决定当天最终是「战争 / 科技突破 / 内政混乱 / 修养生息」 |

逐日结算规则（`EmpireState.buildReal`）：

```
战争：全部打卡 或 按时复盘        +50  × 科技复利
      打卡与复盘同时完成          +100 × 科技复利（额外）
科技突破：完成一条战略聚焦         +500 × 科技复利
内政混乱：一卡没打 且 无状态记录    -100 × 科技复利
修养生息：两者仅发生其一           -10  × 科技复利
下限：繁荣度不低于 0
复利：突破当日生效，逐日连乘，只乘不加（500×1.03×1.02=525.3）
等级：1000 / 5,000 / 25,000 / 125,000 / 625,000 / 3,125,000 / 15,625,000 / 78,125,000 / 390,625,000
```

时间轴从「最早一条记录日」推进到今天，逐日累加；晋阶门槛突破次数即「系统修补 n/5」。

## 为什么改动后数值会立刻变

`EmpirePage._load()` 每次进入「帝国」页都会重新查库（`MainShell` 切页时递增 `reloadToken`，
同时 `EmpirePage.initState` 也会 `_load()`），所以：

1. 在「今日」改了打卡 / 状态 / 聚焦 → 切到「帝国」，繁荣度、等级、乘数、纪事全部重算；
2. 下拉刷新同样重算；
3. 库里一条记录都没有时，仍回落到内置示例数据（右上角标「示例推演」），避免白屏。

## 构建脚本修复（历史）

`Generate Android shell in temp dir` 之前会在 `set -e` 下以 exit 1 静默中断：
`cd "$RUNNER_TEMP"` 之后没切回来，`test -f android/app/...` 检查的是临时目录下的错误路径。
现在全程绝对路径、不再 `cd`：

```bash
SHELL_DIR="$RUNNER_TEMP/shell"
flutter create --project-name daily_tracker --platforms android "$SHELL_DIR"
test -d "$SHELL_DIR/android"
cp -r "$SHELL_DIR/android" "$GITHUB_WORKSPACE/android"
test -f "$GITHUB_WORKSPACE/android/app/build.gradle.kts" || test -f "$GITHUB_WORKSPACE/android/app/build.gradle"
```
