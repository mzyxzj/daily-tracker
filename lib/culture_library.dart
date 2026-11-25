// 库索引页：把「一个库」当成一本目录来翻，而不是一条一条刷。
//
// 和信息流的分工：
//   - 信息流回答「现在这一刻该看哪一条」，一次只给一条；
//   - 这个页面回答「这个方向我到底收了什么」——包括已经看完的、
//     半年没点开的，全都在这，点开就能看。
//
// 布局照 B站 索引页：顶部排序，往下几行维度筛选 + 标签索引，最后是封面网格。
// 维度换成本地数据真有的东西：平台 / 分级 / 类型 / 状态 / 标签。
//
// 排序即分组：选「最近收录」就按天切段并插分隔线，「打开次数」每 5 次一档，
// 「按分级」按每个分级一档，「按工具包」按是否已整理成工具包分两档。

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'culture_feed.dart';
import 'culture_page.dart';

class CultureLibraryPage extends StatefulWidget {
  /// 写操作（打开 / 收藏 / 标看完）要用；只做只读预览时可以不给。
  final Database? db;
  final Map lib;
  final List grades;

  /// 外层已经查好的条目。给了就先渲染，再异步从库里刷新，
  /// 这样从侧栏点进来不会先闪一下空白。
  final List? items;

  /// 有任何写操作后通知外层重载。
  final Future Function()? onChanged;

  /// 只读预览时可以先把「哪些条目已有工具包」传进来，省一次查询。
  final Set<int>? kitIds;

  const CultureLibraryPage({
    super.key,
    this.db,
    required this.lib,
    this.grades = const [],
    this.items,
    this.onChanged,
    this.kitIds,
  });

  @override
  State<CultureLibraryPage> createState() => _CultureLibraryPageState();
}

class _CultureLibraryPageState extends State<CultureLibraryPage> {
  static const Color _accent = Color(0xFF7DD3FC);

  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  /// 已经生成过工具包的条目 id。用来做「按工具包」分组，不用每张卡再查一次库。
  Set<int> _kitIds = <int>{};

  String _sort = 'recent'; // recent / opened / hot / tier / kit
  String? _plat;
  int? _tier;
  String? _kind;
  String _state = 'all'; // all / unread / opened / done / fav

  /// 标签索引里选中的标签；`#none` 表示「无标签」。
  String? _tag;
  bool _tagOpen = true;

  String _q = '';
  bool _search = false;
  bool _filtersOpen = true;
  final TextEditingController _qCtrl = TextEditingController();

  int get _libId => (widget.lib['id'] as num?)?.toInt() ?? 0;
  String get _libName => '${widget.lib['name'] ?? ''}'.trim();
  String get _libIcon => '${widget.lib['icon'] ?? '📚'}'.trim();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _qCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // 预览/外部传入的工具包 id，省掉一次查询。
    final preKits = widget.kitIds;
    if (preKits != null) _kitIds = preKits;
    // 先把外层传来的条目渲染出来，别让用户对着转圈等一次查询。
    final pre = widget.items;
    if (pre != null && pre.isNotEmpty) {
      final mine = <Map<String, dynamic>>[];
      for (final e in pre) {
        if (e is! Map) continue;
        if (_n(e['lib_id']) != _libId) continue;
        mine.add(Map<String, dynamic>.from(e));
      }
      if (mounted) {
        setState(() {
          _items = mine;
          _loading = false;
        });
      }
    }
    final db = widget.db;
    if (db == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final rows = await db.query('culture_items',
          where: 'lib_id = ?', whereArgs: [_libId], orderBy: 'id DESC');
      // 工具包只要 item_id 一列：「按工具包」分组靠它判断是/否。
      Set<int> kits = <int>{};
      try {
        final kr = await db.query('culture_kits', columns: ['item_id']);
        kits = kr
            .map((e) => _n(e['item_id']))
            .where((i) => i > 0)
            .toSet();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _items = rows
            .map((e) => Map<String, dynamic>.from(e))
            .toList(growable: false);
        _kitIds = kits;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------------- 派生数据 ----------------

  static int _ts(dynamic v) =>
      DateTime.tryParse('${v ?? ''}')?.millisecondsSinceEpoch ?? 0;

  static int _n(dynamic v, [int def = 0]) {
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}'.trim()) ?? def;
  }

  int get _unread => _items.where((e) => _n(e['state']) == 0).length;
  int get _doneCount => _items.where((e) => _n(e['state']) == 2).length;

  /// 平台选项：按常见顺序排，剩下的按出现顺序补在后面。
  List<String> get _platOpts {
    const preferred = ['B站', '抖音', 'YouTube', '小红书', '公众号', '知乎', '微博'];
    final have = <String>{};
    for (final it in _items) {
      final p = '${it['platform'] ?? ''}'.trim();
      if (p.isNotEmpty) have.add(p);
    }
    final out = <String>[];
    for (final p in preferred) {
      if (have.remove(p)) out.add(p);
    }
    out.addAll(have);
    return out;
  }

  List<String> get _kindOpts {
    final have = <String>{};
    for (final it in _items) {
      final k = '${it['kind'] ?? ''}'.trim();
      if (k.isNotEmpty) have.add(k);
    }
    return have.toList();
  }

  // ---------------- 标签 ----------------

  /// 整理面板写的是「标签（空格分隔）」，但用户实际会混用逗号、顿号、
  /// 斜杠，所以一起当分隔符——否则会出现「ai，模型」这种整串假标签。
  static final RegExp _tagSplit = RegExp(r'[\s,，、;；/|+]+');

  /// 一条视频可能有多个标签；去重（忽略大小写），保留首次出现的写法。
  static List<String> _tagsOf(Map it) {
    final raw = '${it['tags'] ?? ''}'.trim();
    if (raw.isEmpty) return const [];
    final seen = <String>{};
    final out = <String>[];
    for (final s in raw.split(_tagSplit)) {
      final t = s.trim();
      if (t.isEmpty) continue;
      // 整段备注被填进标签栏时（超过 14 个字），不当标签，免得索引里出现一整句话。
      if (t.length > 14) continue;
      if (seen.add(t.toLowerCase())) out.add(t);
    }
    return out;
  }

  bool _hasTag(Map it, String tag) {
    final mine = _tagsOf(it);
    if (tag == '#none') return mine.isEmpty;
    final want = tag.toLowerCase();
    for (final t in mine) {
      if (t.toLowerCase() == want) return true;
    }
    return false;
  }

  /// 标签索引：按出现条数从多到少，同数量按名称。全部从现有条目里现算，
  /// 不额外建表——整理时改了标签，回到这一页立刻就是新的。
  List<MapEntry<String, int>> get _tagOpts {
    final count = <String, int>{};
    final label = <String, String>{};
    for (final it in _items) {
      for (final t in _tagsOf(it)) {
        final k = t.toLowerCase();
        count[k] = (count[k] ?? 0) + 1;
        label.putIfAbsent(k, () => t);
      }
    }
    final out = count.entries
        .map((e) => MapEntry(label[e.key]!, e.value))
        .toList()
      ..sort((a, b) {
        final d = b.value.compareTo(a.value);
        return d != 0 ? d : a.key.compareTo(b.key);
      });
    return out;
  }

  int get _noTagCount => _items.where((e) => _tagsOf(e).isEmpty).length;

  /// 有分级数据才显示这一行，免得空库上来一排「0 条」。
  List<Map> get _tierOpts {
    final out = <Map>[];
    for (final g in widget.grades) {
      if (g is! Map) continue;
      final t = _n(g['tier']);
      if (t <= 0) continue;
      if (_items.any((e) => _n(e['grade_tier']) == t)) out.add(g);
    }
    return out;
  }

  List<Map<String, dynamic>> get _view {
    final q = _q.trim().toLowerCase();
    final list = <Map<String, dynamic>>[];
    for (final it in _items) {
      if (_plat != null && '${it['platform'] ?? ''}'.trim() != _plat) continue;
      if (_tier != null && _n(it['grade_tier']) != _tier) continue;
      if (_kind != null && '${it['kind'] ?? ''}'.trim() != _kind) continue;
      if (_tag != null && !_hasTag(it, _tag!)) continue;
      switch (_state) {
        case 'unread':
          if (_n(it['state']) != 0) continue;
          break;
        case 'opened':
          if (_n(it['state']) != 1) continue;
          break;
        case 'done':
          if (_n(it['state']) != 2) continue;
          break;
        case 'fav':
          if (_n(it['fav']) != 1) continue;
          break;
      }
      if (q.isNotEmpty) {
        final hay = '${it['title'] ?? ''} ${it['author'] ?? ''} '
                '${it['note'] ?? ''} ${it['tags'] ?? ''}'
            .toLowerCase();
        if (!hay.contains(q)) continue;
      }
      list.add(it);
    }
    switch (_sort) {
      case 'opened':
        list.sort((a, b) {
          final d = _ts(b['last_open_at']).compareTo(_ts(a['last_open_at']));
          return d != 0 ? d : _n(b['id']).compareTo(_n(a['id']));
        });
        break;
      case 'hot':
        list.sort((a, b) {
          final d = _n(b['open_count']).compareTo(_n(a['open_count']));
          return d != 0 ? d : _n(b['id']).compareTo(_n(a['id']));
        });
        break;
      case 'tier':
        list.sort((a, b) {
          int key(dynamic v) {
            final t = _n(v);
            return t == 0 ? 99 : t;
          }

          final d = key(a['grade_tier']).compareTo(key(b['grade_tier']));
          return d != 0 ? d : _n(b['id']).compareTo(_n(a['id']));
        });
        break;
      case 'kit':
        // 已整理成工具包的在前；组内仍按最近收录排，找起来有线索。
        list.sort((a, b) {
          final ka = _kitIds.contains(_n(a['id'])) ? 1 : 0;
          final kb = _kitIds.contains(_n(b['id'])) ? 1 : 0;
          if (ka != kb) return kb.compareTo(ka);
          final d = _ts(b['created_at']).compareTo(_ts(a['created_at']));
          return d != 0 ? d : _n(b['id']).compareTo(_n(a['id']));
        });
        break;
      default: // recent
        list.sort((a, b) {
          final d = _ts(b['created_at']).compareTo(_ts(a['created_at']));
          return d != 0 ? d : _n(b['id']).compareTo(_n(a['id']));
        });
    }
    return list;
  }

  // ---------------- 分组（排序即分组） ----------------
  //
  // 排序不只是一串排序结果，还要在中间插分隔线：
  //   最近收录 / 最近打开 → 按天分；打开次数 → 每 5 次一档；
  //   按分级 → 每个分级一档；按工具包 → 是 / 否两档。
  // 因为 _view 已经按这个维度排好序，顺着切段就行，不用再排一次。

  static String _2(int v) => v.toString().padLeft(2, '0');

  static String _dayKey(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    final l = d.toLocal();
    return '${l.year}-${_2(l.month)}-${_2(l.day)}';
  }

  String _gradeName(int tier) {
    for (final g in widget.grades) {
      if (g is! Map) continue;
      if (_n(g['tier']) == tier) return '${g['name'] ?? ''}'.trim();
    }
    return '';
  }

  String _groupKey(Map it) {
    switch (_sort) {
      case 'opened':
        return 'd:${_dayKey('${it['last_open_at'] ?? ''}')}';
      case 'hot':
        final n = _n(it['open_count']);
        return 'h:${n <= 0 ? -1 : (n - 1) ~/ 5}';
      case 'tier':
        return 't:${_n(it['grade_tier'])}';
      case 'kit':
        return 'k:${_kitIds.contains(_n(it['id'])) ? 1 : 0}';
      default:
        final at = '${it['created_at'] ?? ''}';
        return 'd:${_dayKey(at)}';
    }
  }

  String _groupTitle(String key) {
    if (key.startsWith('h:')) {
      final i = int.tryParse(key.substring(2)) ?? -1;
      if (i < 0) return '还没打开过';
      final start = i * 5 + 1;
      return '$start–${start + 4} 次';
    }
    if (key.startsWith('t:')) {
      final t = int.tryParse(key.substring(2)) ?? 0;
      if (t == 0) return '未分级';
      final name = _gradeName(t);
      return name.isEmpty ? '$t 级' : name;
    }
    if (key.startsWith('k:')) {
      return key == 'k:1' ? '已整理为工具包' : '还没整理';
    }
    final raw = key.substring(2);
    // 老数据可能没有时间戳：收录维度叫「日期未知」，打开维度才是「还没打开过」。
    if (raw.isEmpty) return _sort == 'opened' ? '还没打开过' : '日期未知';
    final d = DateTime.tryParse(raw);
    if (d == null) return raw;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(DateTime(d.year, d.month, d.day)).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff == 2) return '前天';
    if (diff > 2 && diff <= 6) return '$diff 天前';
    return d.year == now.year ? '${d.month}月${d.day}日' : '${d.year}年${d.month}月${d.day}日';
  }

  /// 组头的第二行：具体日期 + 星期，让「今天」这种相对写法有绝对参照。
  String _groupSub(String key) {
    if (!key.startsWith('d:')) return '';
    final raw = key.substring(2);
    if (raw.isEmpty) return '';
    final d = DateTime.tryParse(raw);
    if (d == null) return '';
    const wd = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final now = DateTime.now();
    final date = d.year == now.year
        ? '${d.month}月${d.day}日'
        : '${d.year}年${d.month}月${d.day}日';
    // 标题已经是日期时不重复，只留星期。
    final title = _groupTitle(key);
    return title.contains('月') ? wd[d.weekday - 1] : '$date · ${wd[d.weekday - 1]}';
  }

  List<_Group> _grouped(List<Map<String, dynamic>> view) {
    final out = <_Group>[];
    var bucket = <Map<String, dynamic>>[];
    String? last;
    void flush() {
      if (bucket.isEmpty || last == null) return;
      out.add(_Group(_groupTitle(last), _groupSub(last), bucket));
      bucket = <Map<String, dynamic>>[];
    }

    for (final it in view) {
      final k = _groupKey(it);
      if (last != null && k != last) flush();
      last = k;
      bucket.add(it);
    }
    flush();
    return out;
  }

  // ---------------- 动作 ----------------

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 12)),
        backgroundColor: const Color(0xFF1B2230),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 18),
        duration: const Duration(milliseconds: 1600),
      ));
  }

  Future<void> _open(Map<String, dynamic> it) async {
    final db = widget.db;
    final url = '${it['url'] ?? ''}'.trim();
    if (url.isEmpty) {
      _snack('这条没有链接，长按可以标记看完或补备注');
      return;
    }
    if (db == null) return;
    await CultureDb.touchItem(db, _n(it['id']));
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CulturePlayerPage(
        db: db,
        item: it,
        onChanged: _load,
      ),
    ));
    await _load();
    await widget.onChanged?.call();
  }

  Future<void> _menu(Map<String, dynamic> it) async {
    final id = _n(it['id']);
    final done = _n(it['state']) == 2;
    final fav = _n(it['fav']) == 1;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kFeedBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (bctx) => SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
                color: Colors.white24, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Text('${it['title'] ?? ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    fontWeight: FontWeight.w700,
                    color: kFeedInk)),
          ),
          const SizedBox(height: 6),
          ListTile(
            dense: true,
            leading: Icon(done ? Icons.replay_circle_filled : Icons.check_circle_outline,
                size: 19, color: Colors.white70),
            title: Text(done ? '标记为未看完' : '标记看完',
                style: const TextStyle(fontSize: 13, color: kFeedInk)),
            onTap: () async {
              Navigator.pop(bctx);
              final db = widget.db;
              if (db == null) return;
              await db.update(
                  'culture_items',
                  {
                    'state': done ? 1 : 2,
                    'updated_at': DateTime.now().toIso8601String(),
                  },
                  where: 'id = ?',
                  whereArgs: [id]);
              _snack(done ? '已恢复为未看完' : '看完的就留在这，不再进信息流');
              await _load();
              await widget.onChanged?.call();
            },
          ),
          ListTile(
            dense: true,
            leading: Icon(fav ? Icons.star : Icons.star_border,
                size: 19,
                color: fav ? const Color(0xFFFBBF24) : Colors.white70),
            title: Text(fav ? '取消收藏' : '收藏',
                style: const TextStyle(fontSize: 13, color: kFeedInk)),
            onTap: () async {
              Navigator.pop(bctx);
              final db = widget.db;
              if (db == null) return;
              await db.update('culture_items', {'fav': fav ? 0 : 1},
                  where: 'id = ?', whereArgs: [id]);
              await _load();
              await widget.onChanged?.call();
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final view = _view;
    return Scaffold(
      backgroundColor: kFeedBg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          _header(),
          if (_search) _searchField(),
          _filters(),
          _statLine(view),
          Expanded(child: _grid(view)),
        ]),
      ),
    );
  }

  Widget _header() {
    final note = '${widget.lib['note'] ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 4, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back, size: 20, color: kFeedInk),
          tooltip: '返回',
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Text(_libIcon, style: const TextStyle(fontSize: 15)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _libName.isEmpty ? '未命名库' : _libName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: kFeedInk),
                  ),
                ),
              ]),
              const SizedBox(height: 3),
              Text(
                '${_items.length} 条 · 未看 $_unread · 看完 $_doneCount'
                '${note.isEmpty ? '' : ' · $note'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9.5, color: Colors.white30),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () {
            setState(() {
              _search = !_search;
              if (!_search) {
                _qCtrl.clear();
                _q = '';
              }
            });
          },
          icon: Icon(_search ? Icons.close : Icons.search,
              size: 19, color: Colors.white54),
          tooltip: _search ? '关闭搜索' : '搜这个库',
        ),
      ]),
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(children: [
          const Icon(Icons.search, size: 15, color: Colors.white30),
          const SizedBox(width: 7),
          Expanded(
            child: TextField(
              controller: _qCtrl,
              autofocus: true,
              onChanged: (v) => setState(() => _q = v),
              style: const TextStyle(fontSize: 12.5, color: kFeedInk),
              cursorColor: _accent,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '搜标题 / 作者 / 备注 / 标签',
                hintStyle: TextStyle(fontSize: 12, color: Colors.white24),
              ),
            ),
          ),
          if (_q.isNotEmpty)
            GestureDetector(
              onTap: () {
                _qCtrl.clear();
                setState(() => _q = '');
              },
              child: const Icon(Icons.cancel, size: 14, color: Colors.white30),
            ),
        ]),
      ),
    );
  }

  Widget _filters() {
    final tiers = _tierOpts;
    final kinds = _kindOpts;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 0),
      child: Column(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: _chipRow(
              label: '排序',
              opts: const {
                'recent': '最近收录',
                'opened': '最近打开',
                'hot': '打开次数',
                'tier': '按分级',
                'kit': '按工具包',
              },
              sel: _sort,
              wrap: true,
              onPick: (v) => setState(() => _sort = v),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _filtersOpen = !_filtersOpen),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 2, 8),
              child: Row(children: [
                Text(_filtersOpen ? '收起' : '筛选',
                    style: const TextStyle(fontSize: 10, color: Colors.white38)),
                Icon(_filtersOpen ? Icons.expand_less : Icons.expand_more,
                    size: 15, color: Colors.white38),
              ]),
            ),
          ),
        ]),
        if (_filtersOpen) ...[
          if (_platOpts.length > 1)
            _chipRow(
              label: '平台',
              opts: {
                '': '全部',
                for (final p in _platOpts) p: p,
              },
              sel: _plat ?? '',
              onPick: (v) => setState(() => _plat = v.isEmpty ? null : v),
            ),
          if (tiers.length > 1)
            _chipRow(
              label: '分级',
              opts: {
                '': '全部',
                for (final g in tiers) '${_n(g['tier'])}': '${g['name'] ?? ''}',
              },
              sel: _tier == null ? '' : '$_tier',
              onPick: (v) => setState(() => _tier = v.isEmpty ? null : int.tryParse(v)),
            ),
          if (kinds.length > 1)
            _chipRow(
              label: '类型',
              opts: {
                '': '全部',
                for (final k in kinds) k: k,
              },
              sel: _kind ?? '',
              onPick: (v) => setState(() => _kind = v.isEmpty ? null : v),
            ),
          _chipRow(
            label: '状态',
            opts: const {
              'all': '全部',
              'unread': '未看',
              'opened': '看过',
              'done': '已看完',
              'fav': '收藏',
            },
            sel: _state,
            onPick: (v) => setState(() => _state = v),
          ),
          _tagIndex(),
        ],
      ]),
    );
  }

  Widget _chipRow({
    required String label,
    required Map<String, String> opts,
    required String sel,
    required ValueChanged<String> onPick,
    bool wrap = false,
  }) {
    final chips = opts.entries.map((o) {
      final on = o.key == sel;
      return GestureDetector(
        onTap: () => onPick(o.key),
        child: Container(
          margin: EdgeInsets.only(right: wrap ? 0 : 6),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
          decoration: BoxDecoration(
            color: on ? _accent.withOpacity(0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: on
                    ? _accent.withOpacity(0.42)
                    : Colors.white.withOpacity(0.08)),
          ),
          child: Text(
            o.value,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.1,
              fontWeight: on ? FontWeight.w700 : FontWeight.w400,
              color: on ? _accent : Colors.white54,
            ),
          ),
        ),
      );
    }).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 32,
          child: Padding(
            padding: EdgeInsets.only(top: wrap ? 5 : 0),
            child: Text(label,
                style: const TextStyle(fontSize: 10, color: Colors.white30)),
          ),
        ),
        Expanded(
          // 排序有 5 项，390 宽一行放不下；横滑会把最后一项藏起来，
          // 而它本身就是「按什么分组」的开关，看不见等于没有。这一行改换行。
          child: wrap
              ? Wrap(spacing: 6, runSpacing: 7, children: chips)
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: chips),
                ),
        ),
      ]),
    );
  }

  /// 标签索引：不给标签单独建表，直接从每条自己的 tags 字段现算。
  /// 一条视频有多个标签就会出现在多个标签下面；没填的归到「无标签」。
  /// 用 Wrap 排，一行放不下自动换行（标签多的库会是好几行）。
  Widget _tagIndex() {
    final tags = _tagOpts;
    final noTag = _noTagCount;
    if (tags.isEmpty && noTag == 0) return const SizedBox.shrink();
    final total = tags.length + (noTag > 0 ? 1 : 0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _tagOpen = !_tagOpen),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              const SizedBox(
                width: 32,
                child: Text('标签',
                    style: TextStyle(fontSize: 10, color: Colors.white30)),
              ),
              Text('$total 个索引',
                  style: const TextStyle(fontSize: 10, color: Colors.white38)),
              if (_tag != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => setState(() => _tag = null),
                  child: Text('清除',
                      style: TextStyle(fontSize: 10, color: _accent)),
                ),
              ],
              const Spacer(),
              Icon(_tagOpen ? Icons.expand_less : Icons.expand_more,
                  size: 15, color: Colors.white30),
            ]),
          ),
        ),
        if (_tagOpen)
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (noTag > 0) _tagChip('无标签', noTag, '#none'),
            for (final t in tags) _tagChip(t.key, t.value, t.key),
          ]),
      ]),
    );
  }

  Widget _tagChip(String label, int n, String key) {
    final on = _tag == key;
    return GestureDetector(
      onTap: () => setState(() => _tag = on ? null : key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
        decoration: BoxDecoration(
          color:
              on ? _accent.withOpacity(0.16) : Colors.white.withOpacity(0.035),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
              color: on
                  ? _accent.withOpacity(0.45)
                  : Colors.white.withOpacity(0.07)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  height: 1.15,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                  color: on ? _accent : Colors.white60)),
          const SizedBox(width: 4),
          Text('$n',
              style: TextStyle(
                  fontSize: 9,
                  color: on ? _accent.withOpacity(0.85) : Colors.white24)),
        ]),
      ),
    );
  }

  Widget _statLine(List<Map<String, dynamic>> view) {
    final hidden = _items.length - view.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: Row(children: [
        Text(
          view.length == _items.length
              ? '共 ${view.length} 条'
              : '${view.length} / ${_items.length} 条',
          style: const TextStyle(fontSize: 10, color: Colors.white38),
        ),
        if (hidden > 0) ...[
          const SizedBox(width: 6),
          Text('（筛掉 $hidden 条）',
              style: const TextStyle(fontSize: 9.5, color: Colors.white24)),
        ],
        const Spacer(),
        const Icon(Icons.touch_app_outlined, size: 11, color: Colors.white24),
        const SizedBox(width: 3),
        const Text('点开就看 · 长按整理',
            style: TextStyle(fontSize: 9.5, color: Colors.white24)),
      ]),
    );
  }

  Widget _grid(List<Map<String, dynamic>> view) {
    if (_loading) {
      return const Center(
          child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (view.isEmpty) return _empty();
    final groups = _grouped(view);
    return LayoutBuilder(builder: (ctx, c) {
      const pad = 12.0;
      const gap = 10.0;
      final cols = ((c.maxWidth - pad * 2 + gap) / 118).floor().clamp(2, 6);
      final w = (c.maxWidth - pad * 2 - gap * (cols - 1)) / cols;
      // 封面按 1.6:1 定高，下面留 ~56 给两行标题 + 一行副标题。
      final h = w / 1.6 + 58;
      final delegate = SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        crossAxisSpacing: gap,
        mainAxisSpacing: 16,
        mainAxisExtent: h,
      );
      return CustomScrollView(
        slivers: [
          for (var gi = 0; gi < groups.length; gi++) ...[
            SliverToBoxAdapter(
                child: _groupHeader(groups[gi], first: gi == 0)),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: pad),
              sliver: SliverGrid(
                gridDelegate: delegate,
                delegate: SliverChildBuilderDelegate(
                  (_, i) => _card(groups[gi].items[i]),
                  childCount: groups[gi].items.length,
                ),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 26)),
        ],
      );
    });
  }

  /// 分组头就是那条「分隔线」：左边是这一档的名字，中间一条细线延伸到右边条数。
  /// 时间档还带具体日期和星期，避免「今天」这种相对写法过两天就看不懂。
  Widget _groupHeader(_Group g, {required bool first}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12, first ? 2 : 16, 12, 8),
      child: Row(children: [
        Text(g.title,
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: Colors.white70)),
        if (g.sub.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(g.sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9.5, color: Colors.white30)),
          ),
        ],
        const SizedBox(width: 8),
        Expanded(
          child: Container(height: 0.5, color: Colors.white.withOpacity(0.10)),
        ),
        const SizedBox(width: 8),
        Text('${g.items.length}',
            style: const TextStyle(fontSize: 9.5, color: Colors.white30)),
      ]),
    );
  }

  Widget _empty() {
    final filtered = _items.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(filtered ? Icons.filter_alt_off : Icons.inbox_outlined,
                size: 30, color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              filtered ? '这个筛选下没有内容' : '这个库还是空的',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.white54),
            ),
            const SizedBox(height: 6),
            Text(
              filtered
                  ? '把上面的筛选放宽一点，或者点「全部」。'
                  : '复制一条 B站/抖音分享链接，回到 App 会自动问你\n要不要整理进来；也可以回侧栏手动填一条。',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 10.5, height: 1.7, color: Colors.white24),
            ),
            if (filtered) ...[
              const SizedBox(height: 14),
              TextButton(
                onPressed: () => setState(() {
                  _plat = null;
                  _tier = null;
                  _kind = null;
                  _tag = null;
                  _state = 'all';
                  _q = '';
                  _qCtrl.clear();
                }),
                child: const Text('清空筛选',
                    style: TextStyle(fontSize: 12, color: _accent)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _card(Map<String, dynamic> it) {
    final platform = '${it['platform'] ?? ''}'.trim();
    final pColor = culturePlatformColor(platform);
    final title = '${it['title'] ?? ''}'.trim();
    final author = '${it['author'] ?? ''}'.trim();
    final note = '${it['note'] ?? ''}'.trim();
    final dur = '${it['duration'] ?? ''}'.trim();
    final done = _n(it['state']) == 2;
    final opened = _n(it['open_count']);
    final fav = _n(it['fav']) == 1;
    final sub = note.isNotEmpty ? note : author;

    return GestureDetector(
      onTap: () => _open(it),
      onLongPress: () => _menu(it),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1.6,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(fit: StackFit.expand, children: [
                _cover(it, pColor),
                // 看完的压暗，第一眼就能和没看的分开。
                if (done) const ColoredBox(color: Color(0xAA000000)),
                // 左上：平台（取平台主色，B站粉、抖音黑）
                if (platform.isNotEmpty)
                  Positioned(
                    left: 5,
                    top: 5,
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: pColor.withOpacity(0.92),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(platform,
                          style: const TextStyle(
                              fontSize: 8.5,
                              fontWeight: FontWeight.w800,
                              color: Colors.white)),
                    ),
                  ),
                // 右上：看完 / 收藏
                Positioned(
                  right: 5,
                  top: 5,
                  child: Row(children: [
                    if (fav)
                      const Padding(
                        padding: EdgeInsets.only(right: 3),
                        child: Icon(Icons.star,
                            size: 11, color: Color(0xFFFBBF24)),
                      ),
                    if (done)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.62),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: const Row(children: [
                          Icon(Icons.check, size: 8.5, color: Colors.white70),
                          SizedBox(width: 1),
                          Text('看完',
                              style: TextStyle(
                                  fontSize: 8, color: Colors.white70)),
                        ]),
                      ),
                  ]),
                ),
                // 右下：时长；没有时长就显示打开次数
                if (dur.isNotEmpty || opened > 0)
                  Positioned(
                    right: 5,
                    bottom: 5,
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.66),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        dur.isNotEmpty ? dur : '$opened 次',
                        style: const TextStyle(
                            fontSize: 8.5, color: Colors.white70),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 6),
          // 标题和副标题一起放进剩余空间，字体被系统放大时只压缩标题，
          // 不会撑破网格（撑破在真机上是一条黄黑警示条）。
          Expanded(
            child: ClipRect(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text(
                      title.isEmpty ? '（无标题）' : title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: done ? Colors.white38 : kFeedInk,
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    sub.isEmpty ? (done ? '已看完' : '未看') : sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 9.5, color: Colors.white30),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cover(Map<String, dynamic> it, Color pColor) {
    final cover = '${it['cover'] ?? ''}'.trim();
    if (cover.isEmpty) return _fallbackCover(it, pColor);
    final u = cover.startsWith('http://') ? 'https://${cover.substring(7)}' : cover;
    return Image.network(
      u,
      fit: BoxFit.cover,
      cacheWidth: 360,
      errorBuilder: (_, __, ___) => _fallbackCover(it, pColor),
      loadingBuilder: (c, child, p) =>
          p == null ? child : _fallbackCover(it, pColor),
    );
  }

  /// 没封面时不留白块：平台渐变 + 标题首字，至少能认出是哪条。
  Widget _fallbackCover(Map<String, dynamic> it, Color pColor) {
    final title = '${it['title'] ?? ''}'.trim();
    final ch = title.isEmpty ? '·' : title.characters.first;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(pColor, Colors.black, 0.35)!,
            Color.lerp(pColor, Colors.black, 0.75)!,
          ],
        ),
      ),
      child: Center(
        child: Text(ch,
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Colors.white.withOpacity(0.5))),
      ),
    );
  }
}

/// 一个分组：分隔线上的一档 + 这一档里的条目（已经排好序）。
class _Group {
  final String title;
  final String sub;
  final List<Map<String, dynamic>> items;

  const _Group(this.title, this.sub, this.items);
}
