// 科技树：把「规划」里最上层导图的 科技树 分支，变成文化库的唯一来源。
//
// 规则（V4.6 起的硬约束）：
//   · 科技树分支下的直接子节点 = 允许存在的库，顺序也照导图走；
//   · 不在分支里、但有内容的库 → 先隐藏（hidden=1），等导图里出现同名节点再自动放出来；
//   · 不在分支里、且一条内容都没有的库 → 直接删掉；
//   · 任何导入都必须落到某个科技树节点上，不再有「其他」这种兜底库。
//
// 这里只放纯解析 + 库表收敛，不碰 UI，方便单测。

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// 导图里一个科技树节点 = 一个库。
class TechNode {
  final String name; // 健身
  final String icon; // 🏋️
  final String key; // 归一化后的比对键
  final String note; // 导图里挂在这一节下面的问题，当库的一句话说明

  const TechNode({
    required this.name,
    required this.icon,
    required this.key,
    this.note = '',
  });
}

/// 解析结果。没有导图、或导图里还没有 科技树 节点时 [nodes] 为空。
class TechTree {
  final String mapTitle; // 思考
  final String branch; // 科技树（复利）

  /// 按导图顺序排好的节点。
  final List<TechNode> nodes;

  const TechTree({
    this.mapTitle = '',
    this.branch = '',
    this.nodes = const [],
  });

  bool get ok => nodes.isNotEmpty;
}

/// 一次收敛的结果，给侧栏说人话用。
class TechSyncResult {
  final TechTree tree;
  final int created;
  final int shown;
  final int hidden;
  final int removed;

  const TechSyncResult({
    required this.tree,
    this.created = 0,
    this.shown = 0,
    this.hidden = 0,
    this.removed = 0,
  });

  bool get hasTree => tree.ok;
  bool get changed => created + shown + hidden + removed > 0;
}

// ==================== 纯函数 ====================

/// 节点名归一：去空白、去编号、砍掉括号/冒号后面的解释。
///
/// 「健身常态化（降低皮质醇…）」→ 健身常态化
/// 「一、科技树（复利）」→ 科技树
/// 「第二步：定义规则」→ 第二步
String techCleanName(String raw) {
  var s = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  // 去掉行首编号：1. / 1、/ 一、/ ①
  s = s.replaceFirst(RegExp(r'^[0-9一二三四五六七八九十]+[、.．)）]\s*'), '');
  s = s.replaceFirst(RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩]\s*'), '');
  // 括号 / 冒号后面都是解释，不要
  final cut = s.indexOf(RegExp(r'[（(：:]'));
  if (cut > 0) {
    final head = s.substring(0, cut).trim();
    if (head.isNotEmpty) s = head;
  }
  // 尾部标点
  s = s.replaceAll(RegExp(r'[，,。；;、\s]+$'), '');
  return s.trim();
}

/// 比对键：全半角括号、空格、大小写都不敏感。
String techKey(String raw) {
  var s = techCleanName(raw).toLowerCase();
  s = s
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('　', '')
      .replaceAll(RegExp(r'\s+'), '');
  s = s.replaceAll(RegExp(r'[·・\-_/\\|]+'), '');
  return s;
}

/// 库名和节点名是不是同一个东西。
///
/// 先比归一后的全等；再容许一边是另一边的前缀——导图里常写成
/// 「健身常态化」，而库里早就叫「健身」，不该因此判成两个。
bool techNameMatches(String libName, String nodeName) {
  final a = techKey(libName);
  final b = techKey(nodeName);
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  if (a.length >= 2 && b.length >= 2) {
    return a.startsWith(b) || b.startsWith(a);
  }
  return false;
}

/// 兜底库：这些名字不该再存在。命中的库哪怕有内容也先藏起来等归位。
bool isJunkLibName(String raw) {
  final k = techKey(raw);
  return k == '其他' ||
      k == '其他库' ||
      k == '未归类' ||
      k == '未分类' ||
      k == '杂项' ||
      k == '暂存' ||
      k == 'inbox';
}

/// 库里没存过 icon 时按名字猜一个，别再一律 📚。
String techIconFor(String name) {
  const table = <String, String>{
    '健身': '🏋️',
    '训练': '🏋️',
    '家庭': '🏠',
    '家人': '🏠',
    'ai': '🤖',
    '炼心': '🧘',
    '心态': '🧘',
    '摄影': '📷',
    '复盘': '🪞',
    '激励': '🔥',
    '内容引进': '📥',
    '学习': '📖',
    '阅读': '📚',
    '写作': '✍️',
    '编程': '💻',
    '英语': '🗣️',
    '工作': '💼',
    '财务': '💰',
    '理财': '💰',
    '健康': '🫀',
    '医疗': '🩺',
    '音乐': '🎵',
    '旅行': '✈️',
    '审美': '🎨',
  };
  return table[techKey(name)] ?? '🧩';
}

/// 从一张导图里挑出 科技树 分支，并把直接子节点变成库定义。
TechTree techTreeFromRoot(Map root, {String mapTitle = ''}) {
  final rootText = '${root['text'] ?? root['title'] ?? ''}'.trim();
  // 根节点本身就叫 科技树 的情况
  if (rootText.contains('科技树')) {
    return TechTree(
      mapTitle: mapTitle.isEmpty ? rootText : mapTitle,
      branch: rootText,
      nodes: _nodesOf(root),
    );
  }
  final hit = _findBranch(root);
  if (hit == null) return TechTree(mapTitle: mapTitle);
  return TechTree(
    mapTitle: mapTitle.isEmpty ? rootText : mapTitle,
    branch: '${hit['text'] ?? hit['title'] ?? '科技树'}'.trim(),
    nodes: _nodesOf(hit),
  );
}

Map? _findBranch(Map node) {
  final kids = node['children'];
  if (kids is List) {
    for (final c in kids) {
      if (c is! Map) continue;
      final t = '${c['text'] ?? c['title'] ?? ''}';
      if (t.contains('科技树')) return c;
      final deep = _findBranch(c);
      if (deep != null) return deep;
    }
  }
  return null;
}

List<TechNode> _nodesOf(Map branch) {
  final out = <TechNode>[];
  final seen = <String>{};
  final kids = branch['children'];
  if (kids is! List) return out;
  for (final c in kids) {
    if (c is! Map) continue;
    final raw = '${c['text'] ?? c['title'] ?? ''}';
    final name = techCleanName(raw);
    if (name.isEmpty) continue;
    final key = techKey(name);
    // 太长的多半是整句描述，不是节点名
    if (key.isEmpty || key.length > 24 || seen.contains(key)) continue;
    seen.add(key);
    // 这个节点下面挂的问题，正好当库的说明
    var note = '';
    final gc = c['children'];
    if (gc is List && gc.isNotEmpty) {
      final first = gc.first;
      if (first is Map) note = techCleanName('${first['text'] ?? first['title'] ?? ''}');
    }
    out.add(TechNode(
      name: name,
      icon: techIconFor(name),
      key: key,
      note: note,
    ));
  }
  return out;
}

// ==================== 库表收敛 ====================

Future<void> _ensureCols(Database db) async {
  try {
    final info = await db.rawQuery('PRAGMA table_info(culture_libraries)');
    final names = info.map((r) => '${r['name']}').toSet();
    if (!names.contains('hidden')) {
      await db.execute(
          'ALTER TABLE culture_libraries ADD COLUMN hidden INTEGER DEFAULT 0');
    }
    if (!names.contains('tree_key')) {
      await db.execute(
          "ALTER TABLE culture_libraries ADD COLUMN tree_key TEXT DEFAULT ''");
    }
  } catch (_) {}
}

/// 读最上层导图里的 科技树。按更新时间倒序找，第一个带 科技树 分支的为准。
Future<TechTree> loadTechTree(Database db) async {
  List rows;
  try {
    rows = await db.query('mindmaps', orderBy: 'updated_at DESC, id DESC');
  } catch (_) {
    try {
      rows = await db.query('mindmaps', orderBy: 'id DESC');
    } catch (_) {
      return const TechTree();
    }
  }
  for (final r in rows) {
    Map root;
    try {
      final raw = r['root_json'];
      if (raw is! String || raw.trim().isEmpty) continue;
      root = jsonDecode(raw) as Map;
    } catch (_) {
      continue;
    }
    final tree = techTreeFromRoot(root, mapTitle: '${r['title'] ?? ''}');
    if (tree.ok) return tree;
  }
  return const TechTree();
}

/// 把库表收敛到科技树上。每次进「文化」都跑，代价是两条 SELECT，不值当省。
Future<TechSyncResult> syncLibrariesToTechTree(Database db) async {
  await _ensureCols(db);
  final tree = await loadTechTree(db);
  if (!tree.ok) {
    // 导图里还没长到科技树这一步：什么都不动，免得把库删光。
    return TechSyncResult(tree: tree);
  }

  final libs = await db.query('culture_libraries');
  final counts = <int, int>{};
  try {
    final rows = await db.rawQuery(
        'SELECT lib_id, COUNT(*) c FROM culture_items GROUP BY lib_id');
    for (final r in rows) {
      final id = (r['lib_id'] as num?)?.toInt() ?? 0;
      counts[id] = (r['c'] as num?)?.toInt() ?? 0;
    }
  } catch (_) {}

  final now = DateTime.now().toIso8601String();
  final used = <int>{};
  var created = 0, shown = 0;

  for (var i = 0; i < tree.nodes.length; i++) {
    final n = tree.nodes[i];
    Map? hit;
    for (final l in libs) {
      final id = (l['id'] as num?)?.toInt() ?? 0;
      if (id == 0 || used.contains(id)) continue;
      if (techNameMatches('${l['name'] ?? ''}', n.name)) {
        hit = l;
        break;
      }
    }
    if (hit == null) {
      await db.insert('culture_libraries', {
        'name': n.name,
        'icon': n.icon,
        'note': n.note,
        'source': 'tree',
        'tree_key': n.key,
        'hidden': 0,
        'sort_order': i,
        'created_at': now,
      });
      created++;
      continue;
    }
    final id = (hit['id'] as num?)?.toInt() ?? 0;
    used.add(id);
    final wasHidden = ((hit['hidden'] as num?)?.toInt() ?? 0) == 1;
    final upd = <String, Object?>{
      'sort_order': i,
      'hidden': 0,
      'tree_key': n.key,
      'source': 'tree',
    };
    // 旧库的 icon 是空/兜底 📚 时换成科技树给的
    final icon = '${hit['icon'] ?? ''}'.trim();
    if (icon.isEmpty || icon == '📚') upd['icon'] = n.icon;
    if ('${hit['note'] ?? ''}'.trim().isEmpty && n.note.isNotEmpty) {
      upd['note'] = n.note;
    }
    await db.update('culture_libraries', upd, where: 'id = ?', whereArgs: [id]);
    if (wasHidden) shown++;
  }

  var hidden = 0, removed = 0;
  for (final l in libs) {
    final id = (l['id'] as num?)?.toInt() ?? 0;
    if (id == 0 || used.contains(id)) continue;
    final n = counts[id] ?? 0;
    if (n == 0) {
      // 没有内容的库直接删——空库留着只会占视线。
      await db.delete('culture_libraries', where: 'id = ?', whereArgs: [id]);
      removed++;
      continue;
    }
    if (((l['hidden'] as num?)?.toInt() ?? 0) != 1) hidden++;
    await db.update(
      'culture_libraries',
      {'hidden': 1, 'tree_key': ''},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  return TechSyncResult(
    tree: tree,
    created: created,
    shown: shown,
    hidden: hidden,
    removed: removed,
  );
}

/// 侧栏 / 导入只认这些库。
Future<List<Map<String, dynamic>>> visibleLibs(Database db) async {
  final rows = await db.query('culture_libraries',
      where: 'hidden = 0', orderBy: 'sort_order ASC, id ASC');
  return rows.map((e) => Map<String, dynamic>.from(e)).toList();
}

/// 不在科技树里、但还有内容的库。
Future<List<Map<String, dynamic>>> hiddenLibs(Database db) async {
  final rows = await db.query('culture_libraries',
      where: 'hidden = 1', orderBy: 'sort_order ASC, id ASC');
  return rows.map((e) => Map<String, dynamic>.from(e)).toList();
}

/// 删库（含条目）。空库在下次 sync 时也会被自动清掉，这里用于用户手动确认删除。
Future<void> purgeLibrary(Database db, int id) async {
  await db.delete('culture_items', where: 'lib_id = ?', whereArgs: [id]);
  await db.delete('culture_libraries', where: 'id = ?', whereArgs: [id]);
}
