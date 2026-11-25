# Empire-V4.6 覆盖清单（4.6.0）

整包必须**全量覆盖**：`lib/` + `pubspec.yaml` + `.github/workflows/build.yml` + `.android-inject/`。

> 这一版把「库」收紧到规划里的科技树，原生部分没有改动：
>
> 1. **新文件 `lib/culture_techtree.dart`**：从 `mindmaps.root_json` 里找 `科技树` 分支，
>    取它的直接子节点当库（顺序照导图）；节点名做归一，允许「健身 / 健身常态化」前缀匹配。
>    同时负责库表收敛：树上的保留/补建，树外空库删除，树外有内容的隐藏（`hidden=1`）。
> 2. **新文件 `lib/culture_focus.dart`**：不在科技树里的库的收容页，支持逐条归位、
>    整库并到某节点、连内容删除。
> 3. `lib/culture_feed.dart`：信息流只读 `hidden=0` 的库与这些库的条目；
>    侧栏「新建库」换成「同步科技树」；新增隐藏库入口；导入前统一走 `_ensureTree()`。
> 4. `lib/culture_library.dart`：长按菜单补「编辑 / 换个库 / 删掉这条」；隐藏库顶部加提示条。
> 5. `lib/culture_page.dart` / `lib/content_intake.dart` / `lib/main.dart`：
>    导入三处都不再默认落第一个库或「其他」，必须选科技树节点。
> 6. 数据库 15 → **16**：`culture_libraries` 补 `hidden` / `tree_key` 两列。
> 7. 版本号 4.5.0+16 → 4.6.0+17；依赖不变；`.android-inject/` 与 4.5.0 完全一致。
> 8. 测试 93 条全绿；`flutter analyze` 无 error（只剩既有 info）。

| 文件 | 字节 | MD5 |
|---|---|---|
| `pubspec.yaml` | 558 | `5d6a9c80e95393a2dc42d76aff334f4b` |
| `README.md` | 41,982 | `90d224a1e0c4eed3df6f2312ea0668f5` |
| `.github/workflows/build.yml` | 9,510 | `8bf57bcb3475baac480584878f35875b` |
| `lib/app_update.dart` | 14,455 | `a931e3cabb03f54bf7d81073af50427b` |
| `lib/content_feed.dart` | 14,941 | `c477ce3b9f98a85a1099be539f3337a1` |
| `lib/content_fetch.dart` | 23,847 | `d4d49bbb91d7c81f4fcd25dfa38d32e0` |
| `lib/content_intake.dart` | 24,009 | `2a32372206f7d35d0e717b34681c04e9` |
| `lib/culture_feed.dart` | 131,499 | `b3345bfe052d3555f5a41c049d3b3696` |
| `lib/culture_focus.dart` | 10,445 | `26a4bef8170b5c0f5b8cd9e1fe1067f7` |
| `lib/culture_library.dart` | 47,563 | `31bea4b29cde74c39c072a53b4a8b1e1` |
| `lib/culture_page.dart` | 53,655 | `f8cbd2497bd420f68bbd41973506bbf2` |
| `lib/culture_techtree.dart` | 11,834 | `35eb78ffc982fcd9d06f24b021d86d69` |
| `lib/deepseek_service.dart` | 12,063 | `8a4d9a670b3a9378ceeda3e3ba7d4210` |
| `lib/deepseek_sheet.dart` | 72,621 | `ccd3d91379d101cfbbc0ada026a813e3` |
| `lib/empire_assets.dart` | 897,977 | `61e06d9173a85e0dc101524597d8acc6` |
| `lib/empire_data.dart` | 19,564 | `aaca4183f71cc53fce9777e9181e76c2` |
| `lib/empire_page.dart` | 71,718 | `9bab00fac714fa2db5694fe15d00041d` |
| `lib/main.dart` | 139,051 | `8330950f464e65b5cb5ca3455b04adbc` |
| `lib/medical_page.dart` | 66,637 | `cac60111718de4e5939b357a29719d6c` |
| `lib/native_clip.dart` | 7,430 | `0b36583f1fd34fff83a2e5020db0f2fa` |
| `lib/pages_extra.dart` | 138,365 | `b0f000e5b91e1c8b3575c3cefb5712e6` |
| `lib/player_target.dart` | 6,822 | `89994578d532502da9d6ceac81320087` |
| `.android-inject/MainActivity.kt` | 11,262 | `2ace607c46c4d9626f52fe3a3c96e472` |
| `.android-inject/ClipWatchService.kt` | 30,140 | `6d26333b7226dbbb0e3813907f79cc18` |
| `.android-inject/ClipPromptActivity.kt` | 7,346 | `7bb2d5f83cbfafeb33ccab85619b3e22` |
| `.android-inject/ApkProvider.kt` | 1,937 | `7c62fa727307282c4ac3b31494cd6b2b` |
| `.android-inject/patch.py` | 11,142 | `e3187f554e526518c3a1befa50771057` |
| `.android-inject/dt-release.jks` | 2,704 | `4ad915351096720f929147c9554d725a` |

## 覆盖后自检

```bash
grep -c '^  assets:' pubspec.yaml                  # 期望 0
grep -c '_kRealmL09Webp' lib/empire_assets.dart    # 期望 2（常量定义 + map 引用）
grep -c 'buildReal' lib/empire_data.dart           # 期望 ≥ 1
grep -c 'POST_NOTIFICATIONS' .android-inject/patch.py   # 期望 1
grep -c '科技树' lib/culture_techtree.dart          # 期望 ≥ 1
grep -c 'hidden = 0' lib/culture_feed.dart         # 期望 ≥ 1
md5sum lib/culture_techtree.dart                   # 应等于上表
```
