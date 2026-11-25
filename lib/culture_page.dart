// 文化模块（Culture）的数据层与表单。
//
// 4.0 起界面全部收进 culture_feed.dart：
//   一进来就是全屏推荐流（上下滑），内容引进 / 分级 / 库 / 再创作
//   收在右侧可隐藏的侧边栏里，不再有 tab。
//
// 这个文件只留：
//   - CultureDb：表结构、迁移、分级/库/条目的读写、工具包骨架；
//   - CultureItemSheet：手动添加/编辑一条内容；
//   - CultureKitPage：工具包的步骤勾选与正文编辑。
//
// 设计约束：不引入图片缓存/网络请求层，封面用 URL 直连 + 渐变兜底。

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

import 'content_fetch.dart';
import 'culture_feed.dart';

// ==================== 常量与纯函数 ====================

const Color kCultureInk = Color(0xFF1E293B);
const Color kCultureSub = Color(0xFF64748B);
const Color kCultureLine = Color(0xFFE2E8F0);
const Color kCultureAccent = Color(0xFF0E7490); // 青，区别于规划的玫红
const Color kCultureSoft = Color(0xFFECFEFF);

/// 内置库：只在库表为空时落一次，对应导图里已经存在的聚焦维度。
const List<Map<String, String>> kCultureBuiltinLibs = [
  {'name': '健身', 'icon': '🏋️', 'note': '训练、饮食、恢复'},
  {'name': '家庭', 'icon': '🏠', 'note': '陪伴、沟通、家务'},
  {'name': 'AI', 'icon': '🤖', 'note': '工具、工作流、行业'},
  {'name': '炼心', 'icon': '🧘', 'note': '胆量、底气、不依赖'},
  {'name': '摄影', 'icon': '📷', 'note': '人像、构图、后期'},
  {'name': '其他', 'icon': '🗂️', 'note': '还没归类的先放这里'},
];

const List<String> kCultureKinds = ['视频', '文章', '课程', '工具', '文档'];
/// 内置分级：四档电量对应的允许 / 禁止娱乐。只在表为空时落一次。
const List<Map<String, dynamic>> kCultureBuiltinGrades = [
  {
    'tier': 1,
    'name': '绿灯区',
    'min_b': 60,
    'max_b': 100,
    'allow': '长视频 / 游戏 / 深度学习 / 正经社交',
    'forbid': '别熬过 12 点（这条永远生效）',
    'note': '血条够，难的事放这一档做',
  },
  {
    'tier': 2,
    'name': '黄灯区',
    'min_b': 30,
    'max_b': 59,
    'allow': '短内容 / 轻运动 / 整理桌面',
    'forbid': '开新坑 / 做重大决定 / 吵架',
    'note': '还能推，但别加负载',
  },
  {
    'tier': 3,
    'name': '橙灯区',
    'min_b': 15,
    'max_b': 29,
    'allow': '音乐 / 散步 / 洗澡 / 发呆',
    'forbid': '短视频 / 游戏 / 学习 / 刷购物',
    'note': '省电模式，只维持秩序',
  },
  {
    'tier': 4,
    'name': '红灯区',
    'min_b': 0,
    'max_b': 14,
    'allow': '躺下 / 闭眼 / 喝水 / 洗漱',
    'forbid': '一切屏幕 / 任何提议 / 任何决策',
    'note': '只执行最低限度日程',
  },
];

/// 档位颜色：按上界取色，和医疗页血条保持一致。
Color cultureGradeColor(int maxB) {
  if (maxB >= 60) return const Color(0xFF15803D);
  if (maxB >= 30) return const Color(0xFFCA8A04);
  if (maxB >= 15) return const Color(0xFFEA580C);
  return const Color(0xFFDC2626);
}


/// 从链接推断平台。只做域名匹配，不联网。
String cultureDetectPlatform(String url) => contentDetectPlatform(url);

/// 平台主色，做封面兜底和标签色。
Color culturePlatformColor(String platform) {
  switch (platform) {
    case 'B站':
      return const Color(0xFFFB7299);
    case '抖音':
      return const Color(0xFF111827);
    case 'YouTube':
      return const Color(0xFFEF4444);
    case '小红书':
      return const Color(0xFFFF2442);
    case '公众号':
      return const Color(0xFF22C55E);
    case '知乎':
      return const Color(0xFF3B82F6);
    case 'GitHub':
      return const Color(0xFF475569);
    case '微博':
      return const Color(0xFFF97316);
    case 'X':
      return const Color(0xFF111827);
    case 'Notion':
      return const Color(0xFF334155);
    default:
      return const Color(0xFF64748B);
  }
}

/// 补协议头；顺手去掉首尾空白与常见跟踪参数外的多余空格。
String cultureNormalizeUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  s = s.replaceAll(RegExp(r'\s+'), '');
  if (s.startsWith('//')) s = 'https:$s';
  if (!s.contains('://')) s = 'https://$s';
  return s;
}

/// 10 秒定位用的匹配：标题、标签、来源、备注、平台都算。
bool cultureMatches(Map item, String kw) {
  if (kw.trim().isEmpty) return true;
  final k = kw.trim().toLowerCase();
  final hay = [
    item['title'],
    item['tags'],
    item['note'],
    item['platform'],
    item['author'],
    item['url'],
  ].map((e) => '${e ?? ''}'.toLowerCase()).join(' ');
  return hay.contains(k);
}

/// 库内排序：收藏 > 未看 > 打开次数 > 最近打开。
/// 目标是「打开库就能看到最该看的那几条」，而不是按添加时间倒序。
List<Map> cultureSortItems(List rows) {
  final list = rows.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  int ts(String? s) {
    if (s == null || s.isEmpty) return 0;
    return DateTime.tryParse(s)?.millisecondsSinceEpoch ?? 0;
  }

  list.sort((a, b) {
    final fa = (a['fav'] as num?)?.toInt() ?? 0;
    final fb = (b['fav'] as num?)?.toInt() ?? 0;
    if (fa != fb) return fb - fa;
    final sa = (a['state'] as num?)?.toInt() ?? 0;
    final sb = (b['state'] as num?)?.toInt() ?? 0;
    final ua = sa == 2 ? 0 : 1;
    final ub = sb == 2 ? 0 : 1;
    if (ua != ub) return ub - ua;
    final oa = (a['open_count'] as num?)?.toInt() ?? 0;
    final ob = (b['open_count'] as num?)?.toInt() ?? 0;
    if (oa != ob) return ob - oa;
    final ta = ts(a['last_open_at'] as String?);
    final tb = ts(b['last_open_at'] as String?);
    if (ta != tb) return tb - ta;
    return ts(a['created_at'] as String?) - ts(b['created_at'] as String?);
  });
  return list;
}

/// 工具包导出成 Markdown：粘到任何笔记里都能直接用。
String cultureKitMarkdown(Map kit, List steps) {
  final b = StringBuffer();
  b.writeln('# ${kit['title'] ?? '工具包'}');
  final goal = '${kit['goal'] ?? ''}'.trim();
  if (goal.isNotEmpty) {
    b.writeln();
    b.writeln('> $goal');
  }
  if (steps.isNotEmpty) {
    b.writeln();
    b.writeln('## 步骤');
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i] as Map;
      final done = s['done'] == true || s['done'] == 1;
      b.writeln('${done ? '- [x]' : '- [ ]'} ${s['text'] ?? ''}');
      if (i == steps.length - 1) b.writeln();
    }
  }
  final body = '${kit['body'] ?? ''}'.trim();
  if (body.isNotEmpty) {
    b.writeln();
    b.writeln('## 正文');
    b.writeln(body);
  }
  final tags = '${kit['tags'] ?? ''}'.trim();
  if (tags.isNotEmpty) {
    b.writeln();
    b.writeln('标签：$tags');
  }
  return b.toString().trimRight();
}

List cultureParseSteps(String? raw) {
  if (raw == null || raw.trim().isEmpty) return [];
  try {
    final d = jsonDecode(raw);
    if (d is List) {
      return d
          .whereType<Map>()
          .map((e) => {
                'text': '${e['text'] ?? ''}',
                'done': e['done'] == true || e['done'] == 1,
              })
          .where((e) => '${e['text']}'.trim().isNotEmpty)
          .toList();
    }
  } catch (_) {}
  return [];
}

/// 今日 3 条：优先高权重源所属平台 + 未看 + 收藏，库之间轮流取，避免全是一个库。
List<Map> culturePickToday(List libs, List items, List sources, {int limit = 3}) {
  final weightByPlatform = <String, int>{};
  for (final s in sources) {
    final p = '${s['platform'] ?? ''}';
    final w = (s['weight'] as num?)?.toInt() ?? 3;
    if (p.isEmpty) continue;
    weightByPlatform[p] = math.max(weightByPlatform[p] ?? 0, w);
  }
  final pool = items
      .map((e) => Map<String, dynamic>.from(e as Map))
      .where((e) => ((e['state'] as num?)?.toInt() ?? 0) != 2)
      .toList();
  int score(Map e) {
    var s = 0;
    s += ((e['fav'] as num?)?.toInt() ?? 0) * 50;
    s += (weightByPlatform['${e['platform'] ?? ''}'] ?? 0) * 6;
    s += math.min((e['open_count'] as num?)?.toInt() ?? 0, 5) * 2;
    return s;
  }

  pool.sort((a, b) => score(b) - score(a));

  final picked = <Map>[];
  final usedLib = <int>{};
  for (final e in pool) {
    if (picked.length >= limit) break;
    final lib = (e['lib_id'] as num?)?.toInt() ?? 0;
    if (usedLib.contains(lib)) continue;
    picked.add(e);
    usedLib.add(lib);
  }
  for (final e in pool) {
    if (picked.length >= limit) break;
    if (!picked.any((p) => p['id'] == e['id'])) picked.add(e);
  }
  return picked;
}

// ==================== 数据访问 ====================

/// 文化模块所有建表 / 读写集中在这里，页面层不写 SQL。
/// 版本 11 引入；老库通过 AppDatabase.onUpgrade 调 [CultureDb.ensureTables] 补齐。
class CultureDb {
  /// 对外（culture_feed / 主壳）用的状态读写。私有版本留给本文件。
  static Future<String?> getState(Database db, String key) => _getState(db, key);

  static Future<void> setState(Database db, String key, String val) =>
      _setState(db, key, val);

  static Future<String?> _getState(Database db, String key) async {
    try {
      final rows =
          await db.query('ui_states', where: 'state_key = ?', whereArgs: [key]);
      if (rows.isNotEmpty) return rows.first['state_val'] as String;
    } catch (_) {}
    return null;
  }

  static Future<void> _setState(Database db, String key, String val) async {
    try {
      await db.insert('ui_states', {'state_key': key, 'state_val': val},
          conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {}
  }

  static Future<void> ensureTables(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS culture_libraries ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        "name TEXT NOT NULL, "
        "icon TEXT DEFAULT '', "
        "note TEXT DEFAULT '', "
        "source TEXT DEFAULT 'manual', "
        'sort_order INTEGER DEFAULT 0, '
        'created_at TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS culture_items ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'lib_id INTEGER NOT NULL, '
        'title TEXT NOT NULL, '
        "url TEXT DEFAULT '', "
        "platform TEXT DEFAULT '', "
        "kind TEXT DEFAULT '视频', "
        "tags TEXT DEFAULT '', "
        "note TEXT DEFAULT '', "
        "cover TEXT DEFAULT '', "
        "duration TEXT DEFAULT '', "
        'fav INTEGER DEFAULT 0, '
        'state INTEGER DEFAULT 0, '
        'open_count INTEGER DEFAULT 0, '
        "last_open_at TEXT DEFAULT '', "
        'created_at TEXT NOT NULL, '
        'updated_at TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS culture_kits ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'title TEXT NOT NULL, '
        'lib_id INTEGER DEFAULT 0, '
        'item_id INTEGER DEFAULT 0, '
        "goal TEXT DEFAULT '', "
        "steps TEXT DEFAULT '', "
        "body TEXT DEFAULT '', "
        "tags TEXT DEFAULT '', "
        'created_at TEXT NOT NULL, '
        'updated_at TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS culture_sources ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'name TEXT NOT NULL, '
        "url TEXT DEFAULT '', "
        "platform TEXT DEFAULT '', "
        'weight INTEGER DEFAULT 3, '
        "note TEXT DEFAULT '', "
        'created_at TEXT NOT NULL)');
    // v14：内容引进要 Auto 带封面/标题/作者，还要挂「分级标签」。
    // 老库直接 ALTER，保留原有条目。
    await _ensureColumn(db, 'culture_items', 'grade_tier', 'INTEGER DEFAULT 0');
    await _ensureColumn(db, 'culture_items', 'author', "TEXT DEFAULT ''");
    await _ensureColumn(db, 'culture_items', 'ext_id', "TEXT DEFAULT ''");
    await _ensureColumn(db, 'culture_items', 'from_share', 'INTEGER DEFAULT 0');
    // v15：内置播放器「取正文」抓到的文字存这里，生成工具包时直接复用。
    await _ensureColumn(db, 'culture_items', 'content_text', "TEXT DEFAULT ''");
    // v16：库必须挂在「科技树」节点上。hidden=1 先藏起来，等节点出现再放出来。
    await _ensureColumn(db, 'culture_libraries', 'hidden', 'INTEGER DEFAULT 0');
    await _ensureColumn(db, 'culture_libraries', 'tree_key', "TEXT DEFAULT ''");
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_culture_items_lib ON culture_items(lib_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_culture_items_url ON culture_items(url)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_culture_kits_lib ON culture_kits(lib_id)');
    await db.execute('CREATE TABLE IF NOT EXISTS culture_grades ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'tier INTEGER DEFAULT 0, '
        "name TEXT NOT NULL, "
        'min_b INTEGER DEFAULT 0, '
        'max_b INTEGER DEFAULT 100, '
        "allow TEXT DEFAULT '', "
        "forbid TEXT DEFAULT '', "
        "note TEXT DEFAULT '', "
        'sort_order INTEGER DEFAULT 0)');

    await _seedGrades(db);
  }

  /// SQLite 没有 ADD COLUMN IF NOT EXISTS，先看 PRAGMA 再补，避免老库升级报错。
  static Future<void> _ensureColumn(
      Database db, String table, String column, String def) async {
    try {
      final info = await db.rawQuery('PRAGMA table_info($table)');
      if (info.any((r) => '${r['name']}' == column)) return;
      await db.execute('ALTER TABLE $table ADD COLUMN $column $def');
    } catch (_) {}
  }

  /// 分级种子的三条路：已种过 → 不动；医疗旧表有数据 → 原样迁过来（保留用户改过的内容）；
  /// 都没有 → 落内置四档。
  static Future<void> _seedGrades(Database db) async {
    final seeded = await _getState(db, 'culture_grades_seeded');
    if (seeded == '1') return;
    var count = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM culture_grades')) ??
        0;
    if (count == 0) {
      try {
        final old = await db.query('medical_grades',
            orderBy: 'sort_order ASC, tier ASC');
        for (var i = 0; i < old.length; i++) {
          final g = old[i];
          await db.insert('culture_grades', {
            'tier': g['tier'] ?? i + 1,
            'name': g['name'] ?? '第 ${i + 1} 档',
            'min_b': g['min_b'] ?? 0,
            'max_b': g['max_b'] ?? 100,
            'allow': g['allow'] ?? '',
            'forbid': g['forbid'] ?? '',
            'note': g['note'] ?? '',
            'sort_order': g['sort_order'] ?? i,
          });
          count++;
        }
      } catch (_) {}
    }
    if (count == 0) {
      for (var i = 0; i < kCultureBuiltinGrades.length; i++) {
        final g = kCultureBuiltinGrades[i];
        await db.insert('culture_grades', {
          'tier': g['tier'],
          'name': g['name'],
          'min_b': g['min_b'],
          'max_b': g['max_b'],
          'allow': g['allow'],
          'forbid': g['forbid'],
          'note': g['note'],
          'sort_order': i,
        });
      }
    }
    await _setState(db, 'culture_grades_seeded', '1');
  }

  /// 新增或更新一档。返回 id。
  static Future<int> saveGrade(Database db, Map<String, dynamic> data,
      {int? id}) async {
    final row = {
      'tier': data['tier'] ?? 0,
      'name': data['name'] ?? '',
      'min_b': data['min_b'] ?? 0,
      'max_b': data['max_b'] ?? 100,
      'allow': data['allow'] ?? '',
      'forbid': data['forbid'] ?? '',
      'note': data['note'] ?? '',
      'sort_order': data['sort_order'] ?? 0,
    };
    if (id == null) return db.insert('culture_grades', row);
    await db.update('culture_grades', row, where: 'id = ?', whereArgs: [id]);
    return id;
  }

  /// 删除一档；至少保留一档，避免整页空掉。
  static Future<bool> deleteGrade(Database db, int id) async {
    final rows = await db.query('culture_grades');
    if (rows.length <= 1) return false;
    await db.delete('culture_grades', where: 'id = ?', whereArgs: [id]);
    return true;
  }

  /// 恢复内置四档：按名字补回缺的，不动已存在的、也不动用户自己加的。
  static Future<int> restoreGrades(Database db) async {
    final existing = await db.query('culture_grades');
    final names = existing.map((e) => '${e['name']}').toSet();
    var added = 0;
    var order = existing.length;
    for (var i = 0; i < kCultureBuiltinGrades.length; i++) {
      final g = kCultureBuiltinGrades[i];
      if (names.contains('${g['name']}')) continue;
      await saveGrade(db, {
        'tier': g['tier'],
        'name': g['name'],
        'min_b': g['min_b'],
        'max_b': g['max_b'],
        'allow': g['allow'],
        'forbid': g['forbid'],
        'note': g['note'],
        'sort_order': order++,
      });
      added++;
    }
    return added;
  }

  /// 老逻辑：从「战略聚焦」里补库。
  ///
  /// V4.6 起页面不再调用它——库只能从「规划 → 科技树」长出来，
  /// 否则又会出现一堆没人管的库。留着只给老数据迁移/测试用。
  static Future<int> syncLibrariesFromFocus(Database db) async {
    var added = 0;
    final seededRaw = await _getState(db, 'culture_seeded');
    final libs = await db.query('culture_libraries');
    if ((seededRaw == null || seededRaw.isEmpty) && libs.isEmpty) {
      final now = DateTime.now().toIso8601String();
      for (var i = 0; i < kCultureBuiltinLibs.length; i++) {
        final b = kCultureBuiltinLibs[i];
        await db.insert('culture_libraries', {
          'name': b['name'],
          'icon': b['icon'],
          'note': b['note'],
          'source': 'builtin',
          'sort_order': i,
          'created_at': now,
        });
        added++;
      }
      await _setState(db, 'culture_seeded', '1');
    }

    final hidden = <String>{};
    final hiddenRaw = await _getState(db, 'culture_hidden_dims');
    if (hiddenRaw != null && hiddenRaw.isNotEmpty) {
      try {
        hidden.addAll((jsonDecode(hiddenRaw) as List).map((e) => '$e'));
      } catch (_) {}
    }

    final dims = await db.rawQuery(
        "SELECT DISTINCT title FROM focus_items WHERE TRIM(title) <> ''");
    final existing = <String>{};
    for (final r in await db.query('culture_libraries')) {
      existing.add('${r['name']}'.trim());
    }
    var order = existing.length;
    for (final d in dims) {
      final name = '${d['title']}'.trim();
      if (name.isEmpty || existing.contains(name) || hidden.contains(name)) {
        continue;
      }
      await db.insert('culture_libraries', {
        'name': name,
        'icon': '🎯',
        'note': '来自战略聚焦维度',
        'source': 'focus',
        'sort_order': order++,
        'created_at': DateTime.now().toIso8601String(),
      });
      existing.add(name);
      added++;
    }
    return added;
  }

  /// 删除库：连同条目一起删（二次确认里会说清楚）。维度名进黑名单。
  static Future<void> deleteLibrary(Database db, int id) async {
    final rows =
        await db.query('culture_libraries', where: 'id = ?', whereArgs: [id]);
    if (rows.isNotEmpty) {
      final name = '${rows.first['name']}'.trim();
      final hidden = <String>{};
      final raw = await _getState(db, 'culture_hidden_dims');
      if (raw != null && raw.isNotEmpty) {
        try {
          hidden.addAll((jsonDecode(raw) as List).map((e) => '$e'));
        } catch (_) {}
      }
      hidden.add(name);
      await _setState(db, 'culture_hidden_dims', jsonEncode(hidden.toList()));
    }
    await db.delete('culture_items', where: 'lib_id = ?', whereArgs: [id]);
    await db.delete('culture_libraries', where: 'id = ?', whereArgs: [id]);
  }

  /// 同库同链接不重复落库。
  static Future<int> addItem(Database db, Map<String, dynamic> data) async {
    final url = cultureNormalizeUrl('${data['url'] ?? ''}');
    if (url.isNotEmpty) {
      final same = await db.query('culture_items',
          where: 'lib_id = ? AND url = ?',
          whereArgs: [data['lib_id'], url],
          limit: 1);
      if (same.isNotEmpty) return same.first['id'] as int;
    }
    final now = DateTime.now().toIso8601String();
    return db.insert('culture_items', {
      'lib_id': data['lib_id'],
      'title': data['title'],
      'url': url,
      'platform':
          '${data['platform'] ?? ''}'.isNotEmpty ? data['platform'] : cultureDetectPlatform(url),
      'kind': data['kind'] ?? '视频',
      'tags': data['tags'] ?? '',
      'note': data['note'] ?? '',
      'cover': data['cover'] ?? '',
      'duration': data['duration'] ?? '',
      'fav': data['fav'] ?? 0,
      'state': data['state'] ?? 0,
      'open_count': 0,
      'last_open_at': '',
      'grade_tier': data['grade_tier'] ?? 0,
      'author': data['author'] ?? '',
      'ext_id': data['ext_id'] ?? '',
      'from_share': data['from_share'] ?? 0,
      'created_at': now,
      'updated_at': now,
    });
  }

  /// 全库按链接找一条（不限库），用于「这条是不是已经引进过」。
  static Future<Map?> findItemByUrl(Database db, String rawUrl) async {
    final url = cultureNormalizeUrl(rawUrl);
    if (url.isEmpty) return null;
    final rows = await db.query('culture_items',
        where: 'url = ?', whereArgs: [url], limit: 1);
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  /// 已经处理过的链接记 60 条，避免同一条反复弹「要不要引进」。
  static Future<bool> isSeenUrl(Database db, String rawUrl) async {
    final url = cultureNormalizeUrl(rawUrl);
    if (url.isEmpty) return true;
    final raw = await _getState(db, 'content_seen_urls');
    if (raw == null || raw.isEmpty) return false;
    try {
      return (jsonDecode(raw) as List).map((e) => '$e').contains(url);
    } catch (_) {
      return false;
    }
  }

  static Future<void> addSeenUrl(Database db, String rawUrl) async {
    final url = cultureNormalizeUrl(rawUrl);
    if (url.isEmpty) return;
    final raw = await _getState(db, 'content_seen_urls');
    final list = <String>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        list.addAll((jsonDecode(raw) as List).map((e) => '$e'));
      } catch (_) {}
    }
    list.remove(url);
    list.insert(0, url);
    if (list.length > 60) list.removeRange(60, list.length);
    await _setState(db, 'content_seen_urls', jsonEncode(list));
  }

  /// 剪贴板自动识别开关，存在 ui_states 里，主壳每轮读一次。
  static Future<bool> isClipEnabled(Database db) async {
    final v = await _getState(db, 'content_clip_enabled');
    return v != '0';
  }

  static Future<void> setClipEnabled(Database db, bool on) async {
    await _setState(db, 'content_clip_enabled', on ? '1' : '0');
  }

  /// 只改分级标签：列表里的「⋯ → 设置分级」用它。
  static Future<void> updateItemGrade(Database db, int id, int tier) async {
    await db.update(
        'culture_items',
        {'grade_tier': tier, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [id]);
  }

  /// 打开一次就记一次，作为「最近看过的」排序依据。
  static Future<void> touchItem(Database db, int id) async {
    final now = DateTime.now().toIso8601String();
    await db.rawUpdate(
        'UPDATE culture_items SET open_count = open_count + 1, '
        'last_open_at = ?, updated_at = ?, '
        'state = CASE WHEN state = 0 THEN 1 ELSE state END WHERE id = ?',
        [now, now, id]);
  }

  /// 把内容转成工具包：默认给一个能立刻动手的三步骨架。
  static Future<int> createKitFromItem(Database db, Map item, {String? title}) async {
    final now = DateTime.now().toIso8601String();
    final t = title ??
        '${item['title'] ?? '内容'} · 行动工具包';
    final steps = [
      {'text': '看完并标出 3 个能直接用的点', 'done': false},
      {'text': '把这 3 点改写成自己的话（不超过 100 字）', 'done': false},
      {'text': '套用到本周一个真实场景，记下结果', 'done': false},
    ];
    return db.insert('culture_kits', {
      'title': t,
      'lib_id': item['lib_id'] ?? 0,
      'item_id': item['id'] ?? 0,
      'goal': '把《${item['title'] ?? ''}》变成我能复用的东西，而不是看完就忘。',
      'steps': jsonEncode(steps),
      'body': '',
      'tags': item['tags'] ?? '',
      'created_at': now,
      'updated_at': now,
    });
  }

  /// 文化信号写入 ui_states，帝国页以后可以直接读，不必再查文化表。
  static Future<void> refreshSignals(Database db) async {
    try {
      final libs = await db.rawQuery('SELECT COUNT(*) c FROM culture_libraries');
      final items = await db.rawQuery('SELECT COUNT(*) c FROM culture_items');
      final unread = await db.rawQuery(
          'SELECT COUNT(*) c FROM culture_items WHERE state = 0');
      final read = await db.rawQuery(
          'SELECT COUNT(*) c FROM culture_items WHERE state = 2');
      final kits = await db.rawQuery('SELECT COUNT(*) c FROM culture_kits');
      final kitDone = await db.query('culture_kits');
      var doneSteps = 0, allSteps = 0;
      for (final k in kitDone) {
        final st = cultureParseSteps(k['steps'] as String?);
        allSteps += st.length;
        doneSteps += st.where((e) => e['done'] == true).length;
      }
      final c = (Map r) => (r['c'] as num?)?.toInt() ?? 0;
      await _setState(db, 'culture_lib_count', '${c(libs.first)}');
      await _setState(db, 'culture_item_count', '${c(items.first)}');
      await _setState(db, 'culture_unread_count', '${c(unread.first)}');
      await _setState(db, 'culture_read_count', '${c(read.first)}');
      await _setState(db, 'culture_kit_count', '${c(kits.first)}');
      await _setState(
          db,
          'culture_kit_progress',
          allSteps == 0 ? '0' : (doneSteps / allSteps).toStringAsFixed(3));
    } catch (_) {}
  }
}

// ==================== 页面主体 ====================

/// 文化模块的入口。真正的界面在 culture_feed.dart：
/// 一进来就是全屏推荐流，引进 / 分级 / 库 / 再创作全部收在右侧侧边栏里，
/// 不再有 tab，也不用一层层点开。
class CulturePage extends StatelessWidget {
  final Database db;
  final int reloadToken;
  const CulturePage({super.key, required this.db, this.reloadToken = 0});

  @override
  Widget build(BuildContext context) =>
      CultureFeedPage(db: db, reloadToken: reloadToken);
}

// ==================== 添加 / 编辑内容 ====================

class CultureItemSheet extends StatefulWidget {
  final Database db;
  final List libs;
  final List grades;
  final int libId;
  final Map? item;
  final Future Function()? onSaved;
  const CultureItemSheet({
    super.key,
    required this.db,
    required this.libs,
    required this.libId,
    this.grades = const [],
    this.item,
    this.onSaved,
  });
  @override
  State createState() => _CultureItemSheetState();
}

class _CultureItemSheetState extends State<CultureItemSheet> {
  late TextEditingController _title;
  late TextEditingController _url;
  late TextEditingController _tags;
  late TextEditingController _note;
  late TextEditingController _cover;
  late TextEditingController _duration;
  late TextEditingController _author;
  late int _libId;
  late int _tier;
  late String _kind;
  bool _pasteBusy = false;
  String? _err;

  List get _gradesForSheet => widget.grades;

  @override
  void initState() {
    super.initState();
    final it = widget.item;
    _title = TextEditingController(text: '${it?['title'] ?? ''}');
    _url = TextEditingController(text: '${it?['url'] ?? ''}');
    _tags = TextEditingController(text: '${it?['tags'] ?? ''}');
    _note = TextEditingController(text: '${it?['note'] ?? ''}');
    _cover = TextEditingController(text: '${it?['cover'] ?? ''}');
    _duration = TextEditingController(text: '${it?['duration'] ?? ''}');
    _author = TextEditingController(text: '${it?['author'] ?? ''}');
    _tier = (it?['grade_tier'] as num?)?.toInt() ?? 0;
    // 分级可能被删过，下拉框的 value 必须能在 items 里找到，否则会断言失败。
    if (!widget.grades.any((g) => (g['tier'] as num?)?.toInt() == _tier)) _tier = 0;
    _kind = '${it?['kind'] ?? '视频'}';
    _libId = widget.libId != 0
        ? widget.libId
        : (it?['lib_id'] as int?) ?? 0;
    // 编辑老条目时，它原来的库可能已经被藏起来了：不退回第一个库，
    // 让用户明确选一个科技树节点，避免又把内容塞回「其他」。
    if (!widget.libs.any((l) => l['id'] == _libId)) _libId = 0;
  }

  @override
  void dispose() {
    _title.dispose();
    _url.dispose();
    _tags.dispose();
    _note.dispose();
    _cover.dispose();
    _duration.dispose();
    _author.dispose();
    super.dispose();
  }

  Future _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = (data?.text ?? '').trim();
    if (text.isEmpty) return;
    setState(() => _pasteBusy = true);
    final m = RegExp(r'https?://[^\s]+').firstMatch(text);
    final url = m?.group(0) ?? text;
    setState(() {
      _url.text = url;
      if (_title.text.trim().isEmpty) {
        final rest = text.replaceAll(url, '').trim();
        if (rest.isNotEmpty) _title.text = rest;
      }
      _pasteBusy = false;
    });
  }

  Future _save() async {
    if (_libId == 0) {
      setState(() => _err = widget.libs.isEmpty
          ? '科技树里还没有节点，先去「规划」里加'
          : '先选一个库（只能是科技树里的节点）');
      return;
    }
    final url = cultureNormalizeUrl(_url.text);
    if (_title.text.trim().isEmpty && url.isEmpty) {
      setState(() => _err = '至少给我标题或链接其中一个');
      return;
    }
    final title = _title.text.trim().isEmpty
        ? Uri.tryParse(url)?.host ?? '未命名内容'
        : _title.text.trim();
    final data = {
      'lib_id': _libId,
      'title': title,
      'url': url,
      'platform': cultureDetectPlatform(url),
      'kind': _kind,
      'tags': _tags.text.trim(),
      'note': _note.text.trim(),
      'cover': _cover.text.trim(),
      'duration': _duration.text.trim(),
      'author': _author.text.trim(),
      'grade_tier': _tier,
    };
    if (widget.item == null) {
      await CultureDb.addItem(widget.db, data);
    } else {
      await widget.db.update(
        'culture_items',
        {...data, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [widget.item!['id']],
      );
    }
    await CultureDb.refreshSignals(widget.db);
    if (widget.onSaved != null) await widget.onSaved!();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(widget.item == null ? '存一条内容' : '编辑这条',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton.icon(
              onPressed: _pasteBusy ? null : _paste,
              icon: const Icon(Icons.content_paste, size: 15),
              label: const Text('粘贴', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ]),
          const SizedBox(height: 10),
          if (widget.libs.isEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: const Color(0xFFFECACA)),
              ),
              child: const Text(
                '科技树里还没有节点。先去「规划」→ 最上层导图 → 在「科技树」下面加一节，再回来存。',
                style: TextStyle(fontSize: 11.5, height: 1.5, color: Color(0xFFB91C1C)),
              ),
            )
          else if (widget.item != null &&
              !widget.libs.any((l) => l['id'] == widget.item!['lib_id']))
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: const Color(0xFFFDE68A)),
              ),
              child: const Text(
                '这条原来的库不在科技树里。选一个节点再保存，它就归位了。',
                style: TextStyle(fontSize: 11.5, height: 1.5, color: Color(0xFF92400E)),
              ),
            ),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              labelText: '链接',
              hintText: 'https://…  支持 B站 / 抖音 / 小红书 / 公众号',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_err != null) setState(() => _err = null);
            },
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _title,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              labelText: '标题（找的时候靠它）',
              hintText: '一句话说清这条讲了什么',
              isDense: true,
              errorText: _err,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                value: _libId == 0 ? null : _libId,
                isDense: true,
                hint: const Text('选科技树节点',
                    style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                decoration: const InputDecoration(
                    labelText: '归到哪个库（科技树）',
                    isDense: true,
                    border: OutlineInputBorder()),
                items: [
                  for (final l in widget.libs)
                    DropdownMenuItem(
                      value: l['id'] as int,
                      child: Text('${l['icon'] ?? ''} ${l['name']}',
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                ],
                onChanged: (v) => setState(() => _libId = v ?? _libId),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 106,
              child: DropdownButtonFormField<String>(
                value: _kind,
                isDense: true,
                decoration: const InputDecoration(
                    labelText: '类型', isDense: true, border: OutlineInputBorder()),
                items: [
                  for (final k in kCultureKinds)
                    DropdownMenuItem(
                        value: k, child: Text(k, style: const TextStyle(fontSize: 12.5))),
                ],
                onChanged: (v) => setState(() => _kind = v ?? _kind),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _author,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                    labelText: '作者 / UP 主（可选）',
                    isDense: true,
                    border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 132,
              child: DropdownButtonFormField<int>(
                value: _tier,
                isDense: true,
                decoration: const InputDecoration(
                    labelText: '分级', isDense: true, border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem(value: 0, child: Text('先不标', style: TextStyle(fontSize: 12))),
                  for (final g in _gradesForSheet)
                    DropdownMenuItem(
                      value: (g['tier'] as num?)?.toInt() ?? 0,
                      child: Text('${g['name'] ?? ''}', style: const TextStyle(fontSize: 12)),
                    ),
                ],
                onChanged: (v) => setState(() => _tier = v ?? 0),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _duration,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                    labelText: '时长（可选）',
                    hintText: '12:30',
                    isDense: true,
                    border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _tags,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                    labelText: '标签（空格分隔）',
                    hintText: '增肌 早餐',
                    isDense: true,
                    border: OutlineInputBorder()),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: _note,
            minLines: 2,
            maxLines: 4,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
                labelText: '一句话备注：为什么留它',
                hintText: '例：讲清了胰岛素抵抗和早餐顺序，回头照着做',
                isDense: true,
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 4),
            title: const Text('封面图链接（可选）',
                style: TextStyle(fontSize: 12, color: kCultureSub)),
            children: [
              TextField(
                controller: _cover,
                keyboardType: TextInputType.url,
                style: const TextStyle(fontSize: 12.5),
                decoration: const InputDecoration(
                    hintText: 'https://…jpg  留空就用平台色块',
                    isDense: true,
                    border: OutlineInputBorder()),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: kCultureAccent,
                  padding: const EdgeInsets.symmetric(vertical: 12)),
              onPressed: _save,
              child: Text(widget.item == null ? '存进库' : '保存修改',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
      ),
    );
  }
}

// ==================== 工具包详情（再创作） ====================

class CultureKitPage extends StatefulWidget {
  final Database db;
  final int kitId;
  const CultureKitPage({super.key, required this.db, required this.kitId});
  @override
  State createState() => _CultureKitPageState();
}

class _CultureKitPageState extends State<CultureKitPage> {
  Map? _kit;
  List _steps = [];
  final _titleCtrl = TextEditingController();
  final _goalCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  final _tagCtrl = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _goalCtrl.dispose();
    _bodyCtrl.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  Future _load() async {
    final rows = await widget.db
        .query('culture_kits', where: 'id = ?', whereArgs: [widget.kitId], limit: 1);
    if (rows.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final k = Map<String, dynamic>.from(rows.first);
    setState(() {
      _kit = k;
      _steps = cultureParseSteps(k['steps'] as String?);
      _titleCtrl.text = '${k['title'] ?? ''}';
      _goalCtrl.text = '${k['goal'] ?? ''}';
      _bodyCtrl.text = '${k['body'] ?? ''}';
      _tagCtrl.text = '${k['tags'] ?? ''}';
      _loading = false;
    });
  }

  Future _save() async {
    if (_kit == null) return;
    await widget.db.update(
      'culture_kits',
      {
        'title': _titleCtrl.text.trim().isEmpty ? '未命名工具包' : _titleCtrl.text.trim(),
        'goal': _goalCtrl.text.trim(),
        'body': _bodyCtrl.text,
        'tags': _tagCtrl.text.trim(),
        'steps': jsonEncode(_steps),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [widget.kitId],
    );
    await CultureDb.refreshSignals(widget.db);
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已保存', style: TextStyle(fontSize: 12.5)),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 1),
      ));
    }
  }

  Future _addStep([String text = '']) async {
    final ctrl = TextEditingController(text: text);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('加一步', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 3,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
              hintText: '动词开头，小到一个动作就能做', isDense: true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dctx, true), child: const Text('加')),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      setState(() => _steps.add({'text': ctrl.text.trim(), 'done': false}));
      await _save();
    }
  }

  Future _copyMarkdown() async {
    if (_kit == null) return;
    final md = cultureKitMarkdown({
      'title': _titleCtrl.text,
      'goal': _goalCtrl.text,
      'body': _bodyCtrl.text,
      'tags': _tagCtrl.text,
    }, _steps);
    await Clipboard.setData(ClipboardData(text: md));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Markdown 已复制，可粘到任意笔记', style: TextStyle(fontSize: 12.5)),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future _share() async {
    if (_kit == null) return;
    final md = cultureKitMarkdown({
      'title': _titleCtrl.text,
      'goal': _goalCtrl.text,
      'body': _bodyCtrl.text,
      'tags': _tagCtrl.text,
    }, _steps);
    await Share.share(md, subject: _titleCtrl.text);
  }

  @override
  Widget build(BuildContext context) {
    final done = _steps.where((e) => (e as Map)['done'] == true).length;
    final pct = _steps.isEmpty ? 0.0 : done / _steps.length;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('工具包', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: '复制 Markdown',
            icon: const Icon(Icons.copy_all_outlined, size: 20),
            onPressed: _copyMarkdown,
          ),
          IconButton(
            tooltip: '分享',
            icon: const Icon(Icons.ios_share, size: 20),
            onPressed: _share,
          ),
          TextButton(onPressed: _save, child: const Text('保存', style: TextStyle(fontSize: 13))),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _kit == null
              ? const Center(child: Text('这个工具包已被删除'))
              : ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 40), children: [
                  TextField(
                    controller: _titleCtrl,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                    decoration: const InputDecoration(
                      hintText: '工具包名字',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct,
                          minHeight: 6,
                          backgroundColor: const Color(0xFFE2E8F0),
                          valueColor: const AlwaysStoppedAnimation(Color(0xFF22C55E)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('$done/${_steps.length}',
                        style: const TextStyle(fontSize: 11, color: kCultureSub)),
                  ]),
                  const SizedBox(height: 16),
                  _label('目标 · 做完能得到什么'),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: kCultureSoft,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: const Color(0xFFCFFAFE)),
                    ),
                    child: TextField(
                      controller: _goalCtrl,
                      minLines: 2,
                      maxLines: 4,
                      style: const TextStyle(fontSize: 12.5, height: 1.55, color: Color(0xFF155E75)),
                      decoration: const InputDecoration(
                        hintText: '把这条内容变成我能复用的什么？',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(children: [
                    _label('步骤 · 勾着做完'),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => _addStep(),
                      icon: const Icon(Icons.add, size: 15),
                      label: const Text('加一步', style: TextStyle(fontSize: 11.5)),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  for (var i = 0; i < _steps.length; i++) _stepRow(i),
                  if (_steps.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text('还没有步骤。先写一个「小到不可能失败」的第一步。',
                          style: TextStyle(fontSize: 11.5, color: kCultureSub)),
                    ),
                  const SizedBox(height: 18),
                  _label('正文 · 模板 / 要点 / 原文摘录'),
                  const SizedBox(height: 6),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: kCultureLine),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: TextField(
                      controller: _bodyCtrl,
                      minLines: 6,
                      maxLines: 24,
                      style: const TextStyle(fontSize: 12.5, height: 1.6),
                      decoration: const InputDecoration(
                        hintText: '把「看完就忘」变成「下次直接照抄」：\n'
                            '- 关键结论 3 条\n'
                            '- 我的改写\n'
                            '- 下次遇到什么场景拿出来用',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _tagCtrl,
                    style: const TextStyle(fontSize: 12.5),
                    decoration: const InputDecoration(
                      labelText: '标签',
                      hintText: '空格分隔，方便以后搜',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _copyMarkdown,
                        icon: const Icon(Icons.copy_all_outlined, size: 17),
                        label: const Text('复制 Markdown', style: TextStyle(fontSize: 12.5)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: kCultureAccent),
                        onPressed: _save,
                        icon: const Icon(Icons.check, size: 17),
                        label: const Text('保存', style: TextStyle(fontSize: 12.5)),
                      ),
                    ),
                  ]),
                ]),
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: kCultureSub));

  Widget _stepRow(int i) {
    final s = _steps[i] as Map;
    final done = s['done'] == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(4, 2, 2, 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kCultureLine),
      ),
      child: Row(children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 19, color: done ? const Color(0xFF22C55E) : const Color(0xFFCBD5E1)),
          onPressed: () {
            setState(() => _steps[i] = {'text': s['text'], 'done': !done});
            _save();
          },
        ),
        Expanded(
          child: Text('${s['text']}',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: done ? const Color(0xFF94A3B8) : kCultureInk,
                decoration: done ? TextDecoration.lineThrough : null,
              )),
        ),
        IconButton(
          tooltip: '删除这一步',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 16, color: Color(0xFFCBD5E1)),
          onPressed: () {
            setState(() => _steps.removeAt(i));
            _save();
          },
        ),
      ]),
    );
  }
}

// ==================== 应用内浏览 ====================

/// 内置浏览器：能 WebView 就用 WebView（Android / iOS），
/// 否则（桌面 / WebView 初始化失败）退回系统浏览器，不让流程断掉。
