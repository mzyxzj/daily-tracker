// 文化模块（Culture）
// 对应宪法导图里的「文化建设」，与「规划」同级：
//   1. 内容引进：针对聚焦过的维度建库，条目至少能存链接、能打开，
//      卡片按 B 站横版 / 抖音竖版两种流呈现，库内搜索 10 秒内定位。
//   2. 再创作：把一条内容转成「工具包」——目标 + 可勾选步骤 + 模板正文，
//      可复制 Markdown、可分享，形成能直接用的东西。
//   3. 流量算法：维护优质源（UP 主 / 站点）并按权重排序，
//      给「今日 3 条」直达入口，内置 WebView 让内容在 App 内看完。
//
// 设计约束：不引入图片缓存/网络请求层，封面用 URL 直连 + 渐变兜底；
// 所有写操作走 sqflite，页面只做展示与轻状态。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

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

/// 从链接推断平台。只做域名匹配，不联网。
String cultureDetectPlatform(String url) {
  final u = url.toLowerCase();
  if (u.contains('bilibili.com') || u.contains('b23.tv')) return 'B站';
  if (u.contains('douyin.com') || u.contains('iesdouyin.com')) return '抖音';
  if (u.contains('youtube.com') || u.contains('youtu.be')) return 'YouTube';
  if (u.contains('xiaohongshu.com') || u.contains('xhslink.com')) return '小红书';
  if (u.contains('mp.weixin.qq.com')) return '公众号';
  if (u.contains('zhihu.com')) return '知乎';
  if (u.contains('github.com')) return 'GitHub';
  if (u.contains('weibo.com')) return '微博';
  if (u.contains('twitter.com') || u.contains('x.com/')) return 'X';
  if (u.contains('notion.')) return 'Notion';
  return url.trim().isEmpty ? '' : '网页';
}

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
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_culture_items_lib ON culture_items(lib_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_culture_kits_lib ON culture_kits(lib_id)');
  }

  /// 首次进入：把内置库落库；之后从「战略聚焦」里出现过的维度补库。
  /// 用户手动删掉的维度会写进 culture_hidden_dims，不再自动复活。
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
      'created_at': now,
      'updated_at': now,
    });
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

class CulturePage extends StatefulWidget {
  final Database db;
  const CulturePage({super.key, required this.db});
  @override
  State createState() => _CulturePageState();
}

class _CulturePageState extends State<CulturePage> {
  int _tab = 0; // 0 内容引进 1 再创作 2 流量算法
  int _view = 0; // 0 卡片流 1 竖版流 2 紧凑列表
  int? _libId;
  String _kw = '';
  int _filter = 0; // 0 全部 1 未看 2 收藏 3 看过
  bool _searchOpen = false;

  List _libs = [];
  List _items = [];
  List _kits = [];
  List _sources = [];
  bool _loading = true;

  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future _boot() async {
    await _restoreUi();
    await _reload(syncLibs: true);
  }

  Future _restoreUi() async {
    final raw = await CultureDb._getState(widget.db, 'culture_ui_state');
    if (raw == null || raw.isEmpty) return;
    try {
      final m = jsonDecode(raw) as Map;
      _tab = (m['tab'] as num?)?.toInt() ?? 0;
      _view = (m['view'] as num?)?.toInt() ?? 0;
      _libId = (m['libId'] as num?)?.toInt();
      _filter = (m['filter'] as num?)?.toInt() ?? 0;
    } catch (_) {}
  }

  Future _saveUi() async {
    await CultureDb._setState(
      widget.db,
      'culture_ui_state',
      jsonEncode({'tab': _tab, 'view': _view, 'libId': _libId, 'filter': _filter}),
    );
  }

  Future _reload({bool syncLibs = false}) async {
    try {
      final db = widget.db;
      if (syncLibs) await CultureDb.syncLibrariesFromFocus(db);
      final libs = await db.query('culture_libraries',
          orderBy: 'sort_order ASC, id ASC');
      final items = await db.query('culture_items', orderBy: 'id DESC');
      final kits = await db.query('culture_kits', orderBy: 'updated_at DESC');
      final sources =
          await db.query('culture_sources', orderBy: 'weight DESC, id ASC');
      await CultureDb.refreshSignals(db);
      if (!mounted) return;
      setState(() {
        _libs = libs;
        _items = items;
        _kits = kits;
        _sources = sources;
        _loading = false;
        if (_libId != null && !_libs.any((l) => l['id'] == _libId)) {
          _libId = null;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List get _libItems {
    var list = _items.where((e) {
      if (_libId != null && e['lib_id'] != _libId) return false;
      return cultureMatches(e as Map, _kw);
    }).toList();
    if (_filter == 1) list = list.where((e) => (e['state'] as num?)?.toInt() == 0).toList();
    if (_filter == 2) list = list.where((e) => ((e['fav'] as num?)?.toInt() ?? 0) == 1).toList();
    if (_filter == 3) list = list.where((e) => (e['state'] as num?)?.toInt() == 2).toList();
    return cultureSortItems(list);
  }

  Map? _libOf(int? id) {
    for (final l in _libs) {
      if (l['id'] == id) return Map<String, dynamic>.from(l as Map);
    }
    return null;
  }

  // ---------- 动作 ----------

  Future _openItem(Map item) async {
    final db = widget.db;
    final url = cultureNormalizeUrl('${item['url'] ?? ''}');
    if (url.isEmpty) {
      _editItem(item);
      return;
    }
    await CultureDb.touchItem(db, item['id'] as int);
    await _reload();
    if (!mounted) return;
    final canEmbed = Platform.isAndroid || Platform.isIOS;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CultureBrowserPage(
        db: db,
        itemId: item['id'] as int,
        title: '${item['title'] ?? ''}',
        url: url,
        embed: canEmbed,
        onChanged: _reload,
      ),
    ));
    _reload();
  }

  Future _addItem({int? libId}) async {
    if (_libs.isEmpty) {
      await _newLib();
      return;
    }
    final id = libId ?? _libId ?? (_libs.first['id'] as int);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CultureItemSheet(
        db: widget.db,
        libs: _libs,
        libId: id,
        onSaved: _reload,
      ),
    );
    _reload();
  }

  Future _editItem(Map item) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CultureItemSheet(
        db: widget.db,
        libs: _libs,
        libId: item['lib_id'] as int? ?? 0,
        item: item,
        onSaved: _reload,
      ),
    );
    _reload();
  }

  Future _newLib() async {
    final ctrl = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setD) => AlertDialog(
          title: const Text('新建资源库', style: TextStyle(fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '库名称（建议用聚焦维度）',
                  hintText: '例：AI / 健身 / 摄影',
                  errorText: err,
                  isDense: true,
                ),
                onChanged: (_) {
                  if (err != null) setD(() => err = null);
                },
              ),
              const SizedBox(height: 10),
              const Text(
                '库会按这个名称归类内容。以后在「今日 · 战略聚焦」里新增维度，这里也会自动出现同名库。',
                style: TextStyle(fontSize: 11.5, height: 1.5, color: kCultureSub),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                if (ctrl.text.trim().isEmpty) {
                  setD(() => err = '名字不能为空');
                  return;
                }
                Navigator.pop(dctx, true);
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final db = widget.db;
    final name = ctrl.text.trim();
    final same = await db.query('culture_libraries',
        where: 'name = ?', whereArgs: [name], limit: 1);
    if (same.isNotEmpty) {
      // 手动建同名：解除黑名单，恢复这个库
      final raw = await CultureDb._getState(widget.db, 'culture_hidden_dims');
      if (raw != null && raw.isNotEmpty) {
        try {
          final hidden = (jsonDecode(raw) as List).map((e) => '$e').toSet()..remove(name);
          await CultureDb._setState(
              widget.db, 'culture_hidden_dims', jsonEncode(hidden.toList()));
        } catch (_) {}
      }
      if (mounted) setState(() => _libId = same.first['id'] as int);
      return;
    }
    await db.insert('culture_libraries', {
      'name': name,
      'icon': '📚',
      'note': '',
      'source': 'manual',
      'sort_order': _libs.length,
      'created_at': DateTime.now().toIso8601String(),
    });
    await _reload();
    if (mounted && _libs.isNotEmpty) {
      setState(() => _libId = _libs.last['id'] as int);
    }
  }

  Future _libMenu(Map lib) async {
    final act = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _sheetShell(
        title: '${lib['icon'] ?? ''} ${lib['name']}',
        children: [
          _sheetAction(Icons.edit_outlined, '重命名 / 改备注', 'rename'),
          _sheetAction(Icons.add_link, '往这个库加内容', 'add'),
          _sheetAction(Icons.delete_outline, '删除这个库', 'delete', danger: true),
        ],
      ),
    );
    if (act == null) return;
    if (act == 'add') {
      _addItem(libId: lib['id'] as int);
    } else if (act == 'rename') {
      final nameCtrl = TextEditingController(text: '${lib['name']}');
      final noteCtrl = TextEditingController(text: '${lib['note'] ?? ''}');
      final ok = await showDialog<bool>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('编辑库', style: TextStyle(fontSize: 16)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: '名称', isDense: true)),
            const SizedBox(height: 10),
            TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(labelText: '备注', isDense: true)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(dctx, true), child: const Text('保存')),
          ],
        ),
      );
      if (ok == true && nameCtrl.text.trim().isNotEmpty) {
        final db = widget.db;
        await db.update(
            'culture_libraries',
            {'name': nameCtrl.text.trim(), 'note': noteCtrl.text.trim()},
            where: 'id = ?',
            whereArgs: [lib['id']]);
        _reload();
      }
    } else if (act == 'delete') {
      final cnt = _items.where((e) => e['lib_id'] == lib['id']).length;
      final ok = await showDialog<bool>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('删除这个库？', style: TextStyle(fontSize: 16)),
          content: Text(
            '「${lib['name']}」下面有 $cnt 条内容，会一起删掉，不能撤销。\n'
            '如果这个库是从战略聚焦维度自动建的，删掉后不会自动复活。',
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (ok == true) {
        final db = widget.db;
        await CultureDb.deleteLibrary(db, lib['id'] as int);
        if (_libId == lib['id']) _libId = null;
        _reload();
      }
    }
  }

  Future _openKit(Map kit) async {
    final db = widget.db;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CultureKitPage(db: db, kitId: kit['id'] as int),
    ));
    _reload();
  }

  Future _newKit() async {
    final db = widget.db;
    final id = await db.insert('culture_kits', {
      'title': '未命名工具包',
      'lib_id': _libId ?? 0,
      'item_id': 0,
      'goal': '',
      'steps': jsonEncode([
        {'text': '第一步', 'done': false}
      ]),
      'body': '',
      'tags': '',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await _reload();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CultureKitPage(db: db, kitId: id),
    ));
    _reload();
  }

  Future _addSource([Map? src]) async {
    final nameCtrl = TextEditingController(text: '${src?['name'] ?? ''}');
    final urlCtrl = TextEditingController(text: '${src?['url'] ?? ''}');
    final noteCtrl = TextEditingController(text: '${src?['note'] ?? ''}');
    var weight = (src?['weight'] as num?)?.toInt() ?? 3;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setD) => AlertDialog(
          title: Text(src == null ? '添加优质源' : '编辑优质源',
              style: const TextStyle(fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                      labelText: '名字（UP 主 / 站点 / 专栏）', isDense: true)),
              const SizedBox(height: 10),
              TextField(
                  controller: urlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                      labelText: '主页或直达链接', isDense: true)),
              const SizedBox(height: 10),
              TextField(
                  controller: noteCtrl,
                  decoration:
                      const InputDecoration(labelText: '为什么值得看', isDense: true)),
              const SizedBox(height: 14),
              Row(children: [
                const Text('权重', style: TextStyle(fontSize: 12.5)),
                const SizedBox(width: 8),
                Expanded(
                  child: Slider(
                    value: weight.toDouble(),
                    min: 1,
                    max: 5,
                    divisions: 4,
                    label: '$weight',
                    activeColor: kCultureAccent,
                    onChanged: (v) => setD(() => weight = v.round()),
                  ),
                ),
                Text('$weight 星',
                    style: const TextStyle(fontSize: 12, color: kCultureSub)),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(dctx, true), child: const Text('保存')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (nameCtrl.text.trim().isEmpty) return;
    final db = widget.db;
    final url = cultureNormalizeUrl(urlCtrl.text);
    final data = {
      'name': nameCtrl.text.trim(),
      'url': url,
      'platform': cultureDetectPlatform(url),
      'weight': weight,
      'note': noteCtrl.text.trim(),
    };
    if (src == null) {
      data['created_at'] = DateTime.now().toIso8601String();
      await db.insert('culture_sources', data);
    } else {
      await db.update('culture_sources', data,
          where: 'id = ?', whereArgs: [src['id']]);
    }
    _reload();
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FB),
      appBar: AppBar(
        toolbarHeight: 50,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        titleSpacing: 16,
        title: Row(children: [
          const Text('📚 文化',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: kCultureSoft,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '${_items.length} 条 · ${_kits.length} 个包',
              style: const TextStyle(
                  fontSize: 10.5,
                  color: kCultureAccent,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ]),
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search, size: 22),
            onPressed: () {
              setState(() {
                _tab = 0;
                _searchOpen = !_searchOpen;
                if (!_searchOpen) {
                  _kw = '';
                  _searchCtrl.clear();
                }
              });
            },
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) {
              if (v == 'lib') _newLib();
              if (v == 'source') _addSource();
              if (v == 'help') _showHelp();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'lib', child: Text('新建资源库', style: TextStyle(fontSize: 13))),
              PopupMenuItem(value: 'source', child: Text('添加优质源', style: TextStyle(fontSize: 13))),
              PopupMenuItem(value: 'help', child: Text('这一页怎么用', style: TextStyle(fontSize: 13))),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              _tabBar(),
              if (_tab == 0 && _searchOpen) _searchBar(),
              Expanded(
                child: _tab == 0
                    ? _inflowBody()
                    : _tab == 1
                        ? _kitsBody()
                        : _algoBody(),
              ),
            ]),
      floatingActionButton: _tab == 2
          ? FloatingActionButton.extended(
              backgroundColor: kCultureAccent,
              onPressed: () => _addSource(),
              icon: const Icon(Icons.add_link, size: 18),
              label: const Text('优质源', style: TextStyle(fontSize: 12.5)),
            )
          : FloatingActionButton.extended(
              backgroundColor: kCultureAccent,
              onPressed: _tab == 0 ? () => _addItem() : _newKit,
              icon: const Icon(Icons.add, size: 18),
              label: Text(_tab == 0 ? '存一条' : '新建工具包',
                  style: const TextStyle(fontSize: 12.5)),
            ),
    );
  }

  Widget _tabBar() {
    const labels = ['内容引进', '再创作', '流量算法'];
    const icons = [Icons.video_library_outlined, Icons.build_outlined, Icons.alt_route];
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Row(
        children: List.generate(labels.length, (i) {
          final on = _tab == i;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() => _tab = i);
                _saveUi();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                margin: EdgeInsets.only(right: i == 2 ? 0 : 6),
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: on ? kCultureAccent : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icons[i],
                        size: 15, color: on ? Colors.white : kCultureSub),
                    const SizedBox(width: 4),
                    Text(labels[i],
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: on ? Colors.white : kCultureSub,
                        )),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _searchBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: TextField(
        controller: _searchCtrl,
        autofocus: true,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: '标题 / 标签 / 来源 / 备注，输入即筛',
          hintStyle: const TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8)),
          prefixIcon: const Icon(Icons.search, size: 18, color: kCultureSub),
          suffixIcon: _kw.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _kw = '');
                  },
                ),
          isDense: true,
          filled: true,
          fillColor: const Color(0xFFF1F5F9),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: BorderSide.none),
        ),
        onChanged: (v) => setState(() => _kw = v),
      ),
    );
  }

  // ---------- 内容引进 ----------

  Widget _inflowBody() {
    final items = _libItems;
    return Column(children: [
      _libStrip(),
      _filterRow(items.length),
      Expanded(
        child: items.isEmpty
            ? _emptyInflow()
            : (_view == 1 ? _shortsGrid(items) : _cardsList(items)),
      ),
    ]);
  }

  Widget _libStrip() {
    final total = _items.length;
    return Container(
      height: 44,
      color: Colors.white,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _libChip(
            label: '全部',
            count: total,
            selected: _libId == null,
            onTap: () {
              setState(() => _libId = null);
              _saveUi();
            },
            onLongPress: null,
          ),
          for (final l in _libs)
            _libChip(
              label: '${l['icon'] ?? ''} ${l['name']}'.trim(),
              count: _items.where((e) => e['lib_id'] == l['id']).length,
              selected: _libId == l['id'],
              onTap: () {
                setState(() => _libId == l['id'] ? _libId = null : _libId = l['id'] as int);
                _saveUi();
              },
              onLongPress: () => _libMenu(Map<String, dynamic>.from(l as Map)),
            ),
          GestureDetector(
            onTap: _newLib,
            child: Container(
              margin: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kCultureLine),
              ),
              child: const Row(children: [
                Icon(Icons.add, size: 15, color: kCultureSub),
                SizedBox(width: 2),
                Text('库', style: TextStyle(fontSize: 11.5, color: kCultureSub)),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _libChip({
    required String label,
    required int count,
    required bool selected,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        margin: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: selected ? kCultureAccent : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? kCultureAccent : kCultureLine),
        ),
        child: Row(children: [
          Text(label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Colors.white : kCultureInk,
              )),
          const SizedBox(width: 4),
          Text('$count',
              style: TextStyle(
                fontSize: 10.5,
                color: selected ? Colors.white70 : const Color(0xFF94A3B8),
              )),
        ]),
      ),
    );
  }

  Widget _filterRow(int count) {
    const labels = ['全部', '未看', '收藏', '看过'];
    final lib = _libOf(_libId);
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
      child: Row(children: [
        Expanded(
          child: Text(
            lib == null ? '全部内容' : '${lib['name']} · ${lib['note'] ?? ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: kCultureSub),
          ),
        ),
        for (var i = 0; i < labels.length; i++)
          GestureDetector(
            onTap: () {
              setState(() => _filter = i);
              _saveUi();
            },
            child: Container(
              margin: const EdgeInsets.only(left: 5),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _filter == i ? kCultureSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(labels[i],
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: _filter == i ? FontWeight.w700 : FontWeight.w400,
                    color: _filter == i ? kCultureAccent : kCultureSub,
                  )),
            ),
          ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: '切换呈现方式',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          icon: Icon(
            _view == 0
                ? Icons.view_agenda_outlined
                : _view == 1
                    ? Icons.grid_view_rounded
                    : Icons.view_list_outlined,
            size: 18,
            color: kCultureSub,
          ),
          onPressed: () {
            setState(() => _view = (_view + 1) % 3);
            _saveUi();
          },
        ),
        Text(
          _kw.isNotEmpty ? '$count 条命中' : '$count 条',
          style: const TextStyle(fontSize: 10.5, color: Color(0xFF94A3B8)),
        ),
      ]),
    );
  }

  Widget _emptyInflow() {
    final lib = _libOf(_libId);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(color: kCultureSoft, shape: BoxShape.circle),
            child: const Icon(Icons.video_library_outlined, color: kCultureAccent, size: 30),
          ),
          const SizedBox(height: 14),
          Text(
            lib == null ? '还没有内容' : '「${lib['name']}」还是空的',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kCultureInk),
          ),
          const SizedBox(height: 6),
          const Text(
            '把看到的好东西扔进来：链接 + 一句话标题就够了。\n'
            '库会按聚焦维度自动对齐，找的时候先搜关键词。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.7, color: kCultureSub),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: kCultureAccent),
            onPressed: () => _addItem(),
            icon: const Icon(Icons.add_link, size: 18),
            label: const Text('存第一条'),
          ),
        ]),
      ),
    );
  }

  Widget _cardsList(List items) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 90),
      itemCount: items.length,
      itemBuilder: (ctx, i) => _itemCard(items[i] as Map),
    );
  }

  /// B 站式横版卡：16:9 封面 + 两行标题 + 平台 / 时长 / 状态。
  Widget _itemCard(Map item) {
    final platform = '${item['platform'] ?? ''}';
    final color = culturePlatformColor(platform);
    final title = '${item['title'] ?? ''}';
    final read = (item['state'] as num?)?.toInt() ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kCultureLine),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openItem(item),
        onLongPress: () => _itemMenu(item),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: 128,
            height: 84,
            child: _cover(item, color, title, radius: 0),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    title.isEmpty ? '（无标题）' : title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                      color: read == 2 ? const Color(0xFF94A3B8) : kCultureInk,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(children: [
                    if (platform.isNotEmpty) _platformTag(platform, color),
                    if ('${item['duration'] ?? ''}'.isNotEmpty) ...[
                      const SizedBox(width: 5),
                      Text('${item['duration']}',
                          style: const TextStyle(fontSize: 10, color: kCultureSub)),
                    ],
                    const Spacer(),
                    if ((item['fav'] as num?)?.toInt() == 1)
                      const Icon(Icons.star, size: 13, color: Color(0xFFF59E0B)),
                    if (read == 2)
                      const Padding(
                        padding: EdgeInsets.only(left: 3),
                        child: Icon(Icons.check_circle, size: 13, color: Color(0xFF22C55E)),
                      ),
                  ]),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// 抖音式竖版流：两列 9:16，封面占主体，标题压两行。
  Widget _shortsGrid(List items) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 90),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.62,
      ),
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final item = items[i] as Map;
        final platform = '${item['platform'] ?? ''}';
        final color = culturePlatformColor(platform);
        final title = '${item['title'] ?? ''}';
        return GestureDetector(
          onTap: () => _openItem(item),
          onLongPress: () => _itemMenu(item),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kCultureLine),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: _cover(item, color, title, radius: 0)),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title.isEmpty ? '（无标题）' : title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, height: 1.3, fontWeight: FontWeight.w600, color: kCultureInk)),
                  const SizedBox(height: 4),
                  Row(children: [
                    if (platform.isNotEmpty) _platformTag(platform, color),
                    const Spacer(),
                    if ((item['fav'] as num?)?.toInt() == 1)
                      const Icon(Icons.star, size: 12, color: Color(0xFFF59E0B)),
                  ]),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _cover(Map item, Color color, String title, {double radius = 10}) {
    final cover = '${item['cover'] ?? ''}'.trim();
    final widget = cover.isEmpty
        ? _coverFallback(color, title)
        : Image.network(
            cover,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _coverFallback(color, title),
            loadingBuilder: (ctx, child, p) =>
                p == null ? child : _coverFallback(color, title),
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(fit: StackFit.expand, children: [
        widget,
        if ('${item['duration'] ?? ''}'.isNotEmpty)
          Positioned(
            right: 5,
            bottom: 5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.62),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('${item['duration']}',
                  style: const TextStyle(fontSize: 9.5, color: Colors.white)),
            ),
          ),
      ]),
    );
  }

  Widget _coverFallback(Color color, String title) {
    final t = title.trim();
    final first = t.isEmpty ? '·' : t.substring(0, 1);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withOpacity(0.92), color.withOpacity(0.55)],
        ),
      ),
      child: Center(
        child: Text(first,
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: Colors.white.withOpacity(0.9),
            )),
      ),
    );
  }

  Widget _platformTag(String platform, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(platform,
          style: TextStyle(fontSize: 9.5, color: color, fontWeight: FontWeight.w700)),
    );
  }

  Future _itemMenu(Map item) async {
    final act = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _sheetShell(
        title: '${item['title'] ?? ''}',
        children: [
          _sheetAction(Icons.open_in_new, '打开', 'open'),
          _sheetAction(
              (item['fav'] as num?)?.toInt() == 1 ? Icons.star : Icons.star_border,
              (item['fav'] as num?)?.toInt() == 1 ? '取消收藏' : '收藏',
              'fav'),
          _sheetAction(
              (item['state'] as num?)?.toInt() == 2 ? Icons.undo : Icons.check_circle_outline,
              (item['state'] as num?)?.toInt() == 2 ? '标记为未看' : '标记已看完',
              'read'),
          _sheetAction(Icons.build_outlined, '转成工具包（再创作）', 'kit'),
          _sheetAction(Icons.edit_outlined, '编辑这条', 'edit'),
          if ('${item['url'] ?? ''}'.isNotEmpty)
            _sheetAction(Icons.copy, '复制链接', 'copy'),
          _sheetAction(Icons.delete_outline, '删除', 'delete', danger: true),
        ],
      ),
    );
    if (act == null) return;
    final db = widget.db;
    switch (act) {
      case 'open':
        _openItem(item);
        break;
      case 'fav':
        await db.update('culture_items',
            {'fav': (item['fav'] as num?)?.toInt() == 1 ? 0 : 1},
            where: 'id = ?', whereArgs: [item['id']]);
        _reload();
        break;
      case 'read':
        await db.update('culture_items',
            {'state': (item['state'] as num?)?.toInt() == 2 ? 0 : 2,
             'updated_at': DateTime.now().toIso8601String()},
            where: 'id = ?', whereArgs: [item['id']]);
        _reload();
        break;
      case 'kit':
        final id = await CultureDb.createKitFromItem(db, item);
        await _reload();
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => CultureKitPage(db: db, kitId: id),
        ));
        _reload();
        break;
      case 'edit':
        _editItem(item);
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: '${item['url']}'));
        if (mounted) _toast('链接已复制');
        break;
      case 'delete':
        final ok = await _confirm('删除这条？', '「${item['title']}」会从库里移除，不能撤销。');
        if (ok) {
          await db.delete('culture_items', where: 'id = ?', whereArgs: [item['id']]);
          _reload();
        }
        break;
    }
  }

  // ---------- 再创作 ----------

  Widget _kitsBody() {
    if (_kits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(color: kCultureSoft, shape: BoxShape.circle),
              child: const Icon(Icons.build_outlined, color: kCultureAccent, size: 30),
            ),
            const SizedBox(height: 14),
            const Text('还没有工具包',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kCultureInk)),
            const SizedBox(height: 6),
            const Text(
              '看到值得留下的内容，在内容库里长按 →「转成工具包」。\n'
              '工具包 = 目标 + 可勾选步骤 + 模板正文，最后能直接复制走。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, height: 1.7, color: kCultureSub),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => setState(() => _tab = 0),
              icon: const Icon(Icons.video_library_outlined, size: 18),
              label: const Text('去内容库挑一条'),
            ),
          ]),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 90),
      itemCount: _kits.length,
      itemBuilder: (ctx, i) => _kitCard(_kits[i] as Map),
    );
  }

  Widget _kitCard(Map kit) {
    final steps = cultureParseSteps(kit['steps'] as String?);
    final done = steps.where((e) => e['done'] == true).length;
    final pct = steps.isEmpty ? 0.0 : done / steps.length;
    final lib = _libOf((kit['lib_id'] as num?)?.toInt());
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kCultureLine),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openKit(kit),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(color: kCultureSoft, shape: BoxShape.circle),
                child: const Icon(Icons.build, size: 15, color: kCultureAccent),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${kit['title'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w700, color: kCultureInk)),
              ),
              if (lib != null)
                Text('${lib['icon'] ?? ''} ${lib['name']}',
                    style: const TextStyle(fontSize: 10.5, color: kCultureSub)),
            ]),
            if ('${kit['goal'] ?? ''}'.trim().isNotEmpty) ...[
              const SizedBox(height: 7),
              Text('${kit['goal']}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, height: 1.5, color: kCultureSub)),
            ],
            const SizedBox(height: 9),
            Row(children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct,
                    minHeight: 5,
                    backgroundColor: const Color(0xFFF1F5F9),
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF22C55E)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('$done/${steps.length}',
                  style: const TextStyle(fontSize: 10.5, color: kCultureSub)),
              const SizedBox(width: 6),
              Text(_ago('${kit['updated_at'] ?? ''}'),
                  style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
            ]),
          ]),
        ),
      ),
    );
  }

  // ---------- 流量算法 ----------

  Widget _algoBody() {
    final today = culturePickToday(_libs, _items, _sources);
    return ListView(padding: const EdgeInsets.fromLTRB(12, 10, 12, 90), children: [
      Container(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0E7490), Color(0xFF155E75)],
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.alt_route, size: 17, color: Colors.white),
            SizedBox(width: 6),
            Text('直达优质资源',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
          ]),
          const SizedBox(height: 7),
          Text(
            '别在推荐流里刮彩票。把真正好的源钉在这里，权重越高越靠前；'
            '每天只从这里取 ${today.isEmpty ? 3 : today.length} 条，看完就关。',
            style: const TextStyle(fontSize: 11.5, height: 1.65, color: Color(0xFFCFFAFE)),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      Row(children: [
        const Text('今日 3 条',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: kCultureInk)),
        const SizedBox(width: 6),
        const Text('按权重 / 收藏 / 没看过的，各库轮流取',
            style: TextStyle(fontSize: 10.5, color: kCultureSub)),
        const Spacer(),
        TextButton(
          onPressed: _reload,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('换一批', style: TextStyle(fontSize: 11)),
        ),
      ]),
      const SizedBox(height: 6),
      if (today.isEmpty)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kCultureLine),
          ),
          child: const Text(
            '内容库还是空的。先去「内容引进」存两条，这里才会给你排今天该看的。',
            style: TextStyle(fontSize: 11.5, height: 1.6, color: kCultureSub),
          ),
        )
      else
        for (final it in today) _todayCard(it),
      const SizedBox(height: 18),
      Row(children: [
        const Text('优质源',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: kCultureInk)),
        const SizedBox(width: 6),
        Text('${_sources.length} 个', style: const TextStyle(fontSize: 10.5, color: kCultureSub)),
      ]),
      const SizedBox(height: 8),
      if (_sources.isEmpty)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kCultureLine),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('还没有钉住任何源。',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: kCultureInk)),
            const SizedBox(height: 5),
            const Text(
              '把你反复回去看的那几个人 / 站点加进来：名字 + 主页链接 + 权重。'
              '以后想学东西，直接点「直达」，不从首页开始。',
              style: TextStyle(fontSize: 11.5, height: 1.6, color: kCultureSub),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: kCultureAccent),
              onPressed: () => _addSource(),
              icon: const Icon(Icons.add_link, size: 17),
              label: const Text('添加第一个'),
            ),
          ]),
        )
      else
        for (final s in _sources) _sourceRow(Map<String, dynamic>.from(s as Map)),
    ]);
  }

  Widget _todayCard(Map item) {
    final platform = '${item['platform'] ?? ''}';
    final color = culturePlatformColor(platform);
    final lib = _libOf((item['lib_id'] as num?)?.toInt());
    return GestureDetector(
      onTap: () => _openItem(item),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kCultureLine),
        ),
        child: Row(children: [
          Container(width: 3, height: 34, decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${item['title'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600, color: kCultureInk)),
              const SizedBox(height: 3),
              Text(
                '${lib?['name'] ?? ''} · ${platform.isEmpty ? '网页' : platform}'
                '${'${item['duration'] ?? ''}'.isEmpty ? '' : ' · ${item['duration']}'}',
                style: const TextStyle(fontSize: 10.5, color: kCultureSub),
              ),
            ]),
          ),
          const Icon(Icons.play_circle_fill, size: 24, color: kCultureAccent),
        ]),
      ),
    );
  }

  Widget _sourceRow(Map s) {
    final color = culturePlatformColor('${s['platform'] ?? ''}');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kCultureLine),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
        child: Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
                color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
            child: Icon(Icons.public, size: 16, color: color),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: GestureDetector(
              onTap: () {
                final u = cultureNormalizeUrl('${s['url'] ?? ''}');
                if (u.isNotEmpty) {
                  _openExternalOrEmbed(u, '${s['name'] ?? ''}');
                } else {
                  _addSource(s);
                }
              },
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${s['name'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600, color: kCultureInk)),
                const SizedBox(height: 2),
                Row(children: [
                  for (var i = 0; i < 5; i++)
                    Icon(i < ((s['weight'] as num?)?.toInt() ?? 3)
                            ? Icons.star
                            : Icons.star_border,
                        size: 11,
                        color: const Color(0xFFF59E0B)),
                  const SizedBox(width: 5),
                  if ('${s['note'] ?? ''}'.isNotEmpty)
                    Expanded(
                      child: Text('${s['note']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10, color: kCultureSub)),
                    ),
                ]),
              ]),
            ),
          ),
          IconButton(
            tooltip: '直达',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.north_east, size: 17, color: kCultureAccent),
            onPressed: () {
              final u = cultureNormalizeUrl('${s['url'] ?? ''}');
              if (u.isEmpty) {
                _toast('这个源还没填链接');
                return;
              }
              _openExternalOrEmbed(u, '${s['name'] ?? ''}');
            },
          ),
          IconButton(
            tooltip: '编辑',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.more_horiz, size: 17, color: kCultureSub),
            onPressed: () async {
              final act = await showModalBottomSheet<String>(
                context: context,
                backgroundColor: Colors.transparent,
                builder: (_) => _sheetShell(title: '${s['name'] ?? ''}', children: [
                  _sheetAction(Icons.edit_outlined, '编辑', 'edit'),
                  _sheetAction(Icons.delete_outline, '删除', 'delete', danger: true),
                ]),
              );
              if (act == 'edit') {
                _addSource(s);
              } else if (act == 'delete') {
                final ok = await _confirm('删除这个源？', '只删记录，不影响已存的内容。');
                if (ok) {
                  final db = widget.db;
                  await db.delete('culture_sources', where: 'id = ?', whereArgs: [s['id']]);
                  _reload();
                }
              }
            },
          ),
        ]),
      ),
    );
  }

  Future _openExternalOrEmbed(String url, String title) async {
    final db = widget.db;
    final canEmbed = Platform.isAndroid || Platform.isIOS;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CultureBrowserPage(
        db: db,
        itemId: 0,
        title: title,
        url: url,
        embed: canEmbed,
      ),
    ));
  }

  // ---------- 通用小组件 ----------

  Widget _sheetShell({String? title, required List<Widget> children}) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (title != null && title.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kCultureSub)),
            ),
          ...children,
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _sheetAction(IconData icon, String label, String value, {bool danger = false}) {
    final color = danger ? const Color(0xFFDC2626) : kCultureInk;
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 19, color: color),
      title: Text(label, style: TextStyle(fontSize: 13, color: color)),
      onTap: () => Navigator.pop(context, value),
    );
  }

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: Text(body, style: const TextStyle(fontSize: 13, height: 1.6)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return r == true;
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 12.5)),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  void _showHelp() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _sheetShell(title: '文化这一栏在解决什么', children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
            _HelpLine('内容引进', '别再从推荐流里碰运气。按聚焦维度建库，一条内容 = 链接 + 一句话，找的时候搜关键词，10 秒拿到。'),
            _HelpLine('再创作', '看完不等于留下。把内容转成工具包：目标、步骤、模板正文，勾着做完，能复制能分享。'),
            _HelpLine('流量算法', '把真正好的源钉住并排权重，每天只从里面取 3 条，用内置浏览器看完就走，不跳去别的 App。'),
            SizedBox(height: 6),
            Text('长按库名可以改名 / 删除；长按内容可以收藏、标记看完、转工具包。',
                style: TextStyle(fontSize: 11.5, height: 1.6, color: kCultureSub)),
          ]),
        ),
      ]),
    );
  }

  String _ago(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return DateFormat('MM-dd').format(t);
  }
}

class _HelpLine extends StatelessWidget {
  final String title;
  final String body;
  const _HelpLine(this.title, this.body);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w700, color: kCultureAccent)),
        const SizedBox(height: 3),
        Text(body, style: const TextStyle(fontSize: 11.5, height: 1.6, color: kCultureSub)),
      ]),
    );
  }
}

// ==================== 添加 / 编辑内容 ====================

class CultureItemSheet extends StatefulWidget {
  final Database db;
  final List libs;
  final int libId;
  final Map? item;
  final Future Function()? onSaved;
  const CultureItemSheet({
    super.key,
    required this.db,
    required this.libs,
    required this.libId,
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
  late int _libId;
  late String _kind;
  bool _pasteBusy = false;
  String? _err;

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
    _kind = '${it?['kind'] ?? '视频'}';
    _libId = widget.libId != 0
        ? widget.libId
        : (it?['lib_id'] as int?) ??
            (widget.libs.isNotEmpty ? widget.libs.first['id'] as int : 0);
    if (!widget.libs.any((l) => l['id'] == _libId) && widget.libs.isNotEmpty) {
      _libId = widget.libs.first['id'] as int;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _url.dispose();
    _tags.dispose();
    _note.dispose();
    _cover.dispose();
    _duration.dispose();
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
      setState(() => _err = '先选一个库');
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
                decoration: const InputDecoration(
                    labelText: '归到哪个库', isDense: true, border: OutlineInputBorder()),
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
class CultureBrowserPage extends StatefulWidget {
  final Database db;
  final int itemId;
  final String title;
  final String url;
  final bool embed;
  final Future Function()? onChanged;
  const CultureBrowserPage({
    super.key,
    required this.db,
    required this.itemId,
    required this.title,
    required this.url,
    required this.embed,
    this.onChanged,
  });
  @override
  State createState() => _CultureBrowserPageState();
}

class _CultureBrowserPageState extends State<CultureBrowserPage> {
  WebViewController? _ctrl;
  int _progress = 0;
  bool _failed = false;
  bool _fav = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future _init() async {
    if (widget.itemId != 0) {
      final rows = await widget.db.query('culture_items',
          where: 'id = ?', whereArgs: [widget.itemId], limit: 1);
      if (rows.isNotEmpty) {
        _fav = (rows.first['fav'] as num?)?.toInt() == 1;
        _done = (rows.first['state'] as num?)?.toInt() == 2;
      }
    }
    if (!widget.embed) {
      await _openExternal();
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
    try {
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.white)
        ..setNavigationDelegate(NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame == true && mounted) setState(() => _failed = true);
          },
          onNavigationRequest: (req) {
            // 只拦非 http(s) 的自定义 scheme，交给系统处理
            if (!req.url.startsWith('http')) {
              _openUrl(req.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ))
        ..loadRequest(Uri.parse(widget.url));
      if (mounted) setState(() => _ctrl = c);
    } catch (_) {
      setState(() => _failed = true);
    }
  }

  Future _openExternal() async {
    await _openUrl(widget.url);
    return null;
  }

  Future _openUrl(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return;
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) throw Exception('launch failed');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('系统没有能打开这个链接的应用，已复制到剪贴板',
              style: TextStyle(fontSize: 12.5)),
          behavior: SnackBarBehavior.floating,
        ));
      }
      await Clipboard.setData(ClipboardData(text: url));
    }
  }

  Future _toggleFav() async {
    if (widget.itemId == 0) return;
    _fav = !_fav;
    await widget.db.update('culture_items', {'fav': _fav ? 1 : 0},
        where: 'id = ?', whereArgs: [widget.itemId]);
    if (mounted) setState(() {});
    if (widget.onChanged != null) await widget.onChanged!();
  }

  Future _markDone() async {
    if (widget.itemId == 0) return;
    _done = !_done;
    await widget.db.update(
        'culture_items',
        {'state': _done ? 2 : 1, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [widget.itemId]);
    await CultureDb.refreshSignals(widget.db);
    if (mounted) setState(() {});
    if (widget.onChanged != null) await widget.onChanged!();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title.isEmpty ? '浏览' : widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          Text(Uri.tryParse(widget.url)?.host ?? '',
              maxLines: 1,
              style: const TextStyle(fontSize: 10, color: kCultureSub)),
        ]),
        actions: [
          if (widget.itemId != 0)
            IconButton(
              tooltip: _fav ? '取消收藏' : '收藏',
              icon: Icon(_fav ? Icons.star : Icons.star_border,
                  size: 20, color: _fav ? const Color(0xFFF59E0B) : kCultureSub),
              onPressed: _toggleFav,
            ),
          if (widget.itemId != 0)
            IconButton(
              tooltip: _done ? '标记未看' : '标记看完',
              icon: Icon(_done ? Icons.check_circle : Icons.check_circle_outline,
                  size: 20, color: _done ? const Color(0xFF22C55E) : kCultureSub),
              onPressed: _markDone,
            ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'browser') _openExternal();
              if (v == 'copy') {
                Clipboard.setData(ClipboardData(text: widget.url));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('链接已复制', style: TextStyle(fontSize: 12.5)),
                  behavior: SnackBarBehavior.floating,
                ));
              }
              if (v == 'reload') _ctrl?.reload();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'browser', child: Text('用系统浏览器打开', style: TextStyle(fontSize: 13))),
              PopupMenuItem(value: 'copy', child: Text('复制链接', style: TextStyle(fontSize: 13))),
              PopupMenuItem(value: 'reload', child: Text('重新加载', style: TextStyle(fontSize: 13))),
            ],
          ),
        ],
        bottom: _progress > 0 && _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _progress / 100,
                  minHeight: 2,
                  backgroundColor: const Color(0xFFF1F5F9),
                  valueColor: const AlwaysStoppedAnimation(kCultureAccent),
                ),
              )
            : null,
      ),
      body: _failed
          ? _fallback()
          : _ctrl == null
              ? const Center(child: CircularProgressIndicator())
              : WebViewWidget(controller: _ctrl!),
      bottomNavigationBar: widget.itemId == 0
          ? null
          : SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(top: BorderSide(color: kCultureLine)),
                ),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final rows = await widget.db.query('culture_items',
                            where: 'id = ?', whereArgs: [widget.itemId], limit: 1);
                        if (rows.isEmpty) return;
                        final id = await CultureDb.createKitFromItem(
                            widget.db, Map<String, dynamic>.from(rows.first));
                        if (!mounted) return;
                        await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => CultureKitPage(db: widget.db, kitId: id),
                        ));
                      },
                      icon: const Icon(Icons.build_outlined, size: 16),
                      label: const Text('转成工具包', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: kCultureAccent),
                      onPressed: _openExternal,
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('浏览器打开', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ]),
              ),
            ),
    );
  }

  Widget _fallback() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.public_off, size: 48, color: Color(0xFFCBD5E1)),
          const SizedBox(height: 12),
          const Text('这个站点不让内嵌打开',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: kCultureInk)),
          const SizedBox(height: 6),
          const Text(
            '抖音 / 小红书 / B 站的部分页面会拦截 WebView。\n'
            '点下面按钮用系统浏览器看，链接位置不会丢。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.7, color: kCultureSub),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: kCultureAccent),
            onPressed: _openExternal,
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('用浏览器打开'),
          ),
        ]),
      ),
    );
  }
}
