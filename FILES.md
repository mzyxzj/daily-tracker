# Empire-V4.6.1 覆盖清单（4.6.1）

整包必须**全量覆盖**：`lib/` + `pubspec.yaml` + `.github/workflows/build.yml` + `.android-inject/`。

> 这一版只修「检查更新报 403」，其余全部沿用 4.6.0：
>
> 1. **`lib/app_update.dart`**：更新检查改成两条通道。先问 `api.github.com`（信息全，但匿名每小时只有 60 次，常见 403）；失败就退到 `github.com/<repo>/releases/latest` 的 302 跳转，从 `Location` 里取 tag，直接拼 `/releases/download/<tag>/app-release.apk`。第二条是普通网页请求，不吃限流，代价是没有说明和体积。
> 2. 错误文案分档：正文含 `rate limit` → 「接口被限流（403，匿名每小时 60 次）」；404 → 「仓库里还没有 Release」；其余带状态码。弹窗里多一段解释为什么会 403。
> 3. 抽出 `updateErrorHint()` / `tagFromReleaseLocation()` 两个纯函数，新增 `test/update_test.dart` 7 条。
> 4. 版本号 4.6.0+17 → **4.6.1+18**；原生注入、数据库（v16）、科技树规则一行没改。
> 5. 测试 100 条全绿；`flutter analyze` 无 error。

| 文件 | 字节 | MD5 |
|---|---|---|
| `pubspec.yaml` | 558 | `e00f9a720d752fef9ed2a65cec06389a` |
| `README.md` | 43,992 | `9acbe8d3240e8bf72fe9cefacb5794b8` |
| `.github/workflows/build.yml` | 9,510 | `8bf57bcb3475baac480584878f35875b` |
| `lib/app_update.dart` | 18,672 | `0c18c3df1a51e5588059dd4b94e3063f` |
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
grep -c '^  assets:' pubspec.yaml                        # 期望 0
grep -c 'releases/latest' lib/app_update.dart            # 期望 ≥ 2（API 与网页两条通道）
grep -c 'tagFromReleaseLocation' lib/app_update.dart     # 期望 2（定义 + 调用）
grep -c '科技树' lib/culture_techtree.dart                # 期望 ≥ 1
grep -n '^version' pubspec.yaml                          # 期望 4.6.1+18
md5sum lib/app_update.dart                               # 应等于上表
```
