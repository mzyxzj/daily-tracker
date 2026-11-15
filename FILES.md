# 2.3.0 覆盖清单

整包必须**全量覆盖**：`lib/` + `pubspec.yaml` + `.github/workflows/build.yml`。

> 上一轮 CI 报 `No file or variants found for asset: assets/images/realm_l07.png`。
> 这条错只可能来自 `pubspec.yaml` 里的 `assets:` 声明 —— 说明构建机上的 pubspec 仍是旧版；
> 新版 build.yml 有一道 verify 会在 build 之前就拦下这种情况，所以 build.yml 也还是旧的。
> 换句话说：**lib/ 换了、pubspec.yaml 和 build.yml 没换**。

| 文件 | 字节 | MD5 |
|---|---|---|
| `pubspec.yaml` | 398 | `c219232a092a64bcafcd1e3aac1b1033` |
| `README.md` | 3,573 | `7b11c7ac84cfd02334a547fb173757aa` |
| `.github/workflows/build.yml` | 5,522 | `1b9488bba4d632454cbb8db0023738c6` |
| `lib/main.dart` | 127,122 | `1f75104bc607e3a49efe889f264def79` |
| `lib/pages_extra.dart` | 138,365 | `b0f000e5b91e1c8b3575c3cefb5712e6` |
| `lib/deepseek_service.dart` | 12,063 | `8a4d9a670b3a9378ceeda3e3ba7d4210` |
| `lib/deepseek_sheet.dart` | 49,888 | `1eb1c3165082764049ec951d98803031` |
| `lib/empire_page.dart` | 64,863 | `7b2dec5ed01b0a6793a4aac2b6d813ca` |
| `lib/empire_data.dart` | 12,399 | `000b7726f9d46eea03c3249c74546ba7` |
| `lib/empire_assets.dart` | 137,205 | `c0bdc7208d6cbad2badf89351b5a7042` |

## 覆盖后自检（仓库根目录执行）

```bash
grep -c '^  assets:' pubspec.yaml   # 期望 0（或直接报错），有输出说明 pubspec 没换
grep -c 'Generate Android shell in temp dir' .github/workflows/build.yml   # 期望 1
ls lib/empire_assets.dart lib/empire_data.dart lib/empire_page.dart
md5sum lib/empire_page.dart        # 应等于上表
```

## 构建脚本修复（第 2 轮）

`Generate Android shell in temp dir` 这一步之前会在 `set -e` 下以 exit 1 中断，原因：

```bash
cd "$RUNNER_TEMP"                                   # 切到临时目录
...
test -f android/app/build.gradle.kts || ...          # ❌ 此处已不在 workspace
```

`cd "$RUNNER_TEMP"` 之后没有切回来，于是 `test -f android/app/...` 检查的是
`$RUNNER_TEMP/android/app/...`（不存在，真实路径是 `$RUNNER_TEMP/shell/android/...`），
两个 `test` 都失败，复合命令退出码 1，`set -e` 立即终止整个 step，
所以日志里既没有 `echo` 输出，也看不到任何具体报错。

现在改成全程绝对路径、不再 `cd`：

```bash
SHELL_DIR="$RUNNER_TEMP/shell"
flutter create --project-name daily_tracker --platforms android "$SHELL_DIR"
test -d "$SHELL_DIR/android"
cp -r "$SHELL_DIR/android" "$GITHUB_WORKSPACE/android"
test -f "$GITHUB_WORKSPACE/android/app/build.gradle.kts" || test -f "$GITHUB_WORKSPACE/android/app/build.gradle"
```

## 这一版对构建流程的改动

1. 不再在项目根跑 `flutter create .`，改为在 `$RUNNER_TEMP` 生成 android 壳再拷回 —— 不再重写 `pubspec.yaml`。
2. 新增 `Strip stale asset declarations`：构建前正则剥掉 pubspec 里残留的 `assets:` 段，即使忘了改 pubspec 也不会再因资源缺文件失败。
3. 帝国模块的领地图 / 示例数据已编进 `lib/empire_assets.dart`，不占用 asset bundle。
