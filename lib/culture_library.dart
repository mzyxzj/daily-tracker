// 库索引页：把「一个库」当成一本目录来翻，而不是一条一条刷。
//
// 和信息流的分工：
//   - 信息流回答「现在这一刻该看哪一条」，一次只给一条；
//   - 这个页面回答「这个方向我到底收了什么」——包括已经看完的、
//     半年没点开的，全都在这，点开就能看。
//
// 布局照 B站 索引页：顶部排序，往下几行维度筛选，最后是封面网格。
// 维度换成本地数据真有的东西：平台 / 分级 / 类型 / 状态。

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

  const CultureLibraryPage({
    super.key,
    this.db,
    required this.lib,
    this.grades = const [],
    this.items,
    this.onChanged,
  });

  @override
  State<CultureLibraryPage> createState() => _CultureLibraryPageState();
}

class _CultureLibraryPageState extends State<CultureLibraryPage> {
  static const Color _accent = Color(0xFF7DD3FC);

  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  String _sort = 'recent'; // recent / opened / hot / tier
  String? _plat;
  int? _tier;
  String? _kind;
  String _state = 'all'; // all / unread / opened / done / fav
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
      if (!mounted) return;
      setState(() {
        _items = rows
            .map((e) => Map<String, dynamic>.from(e))
            .toList(growable: false);
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
      default: // recent
        list.sort((a, b) {
          final d = _ts(b['created_at']).compareTo(_ts(a['created_at']));
          return d != 0 ? d : _n(b['id']).compareTo(_n(a['id']));
        });
    }
    return list;
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
        Row(children: [
          Expanded(
            child: _chipRow(
              label: '排序',
              opts: const {
                'recent': '最近收录',
                'opened': '最近打开',
                'hot': '打开最多',
                'tier': '按分级',
              },
              sel: _sort,
              onPick: (v) => setState(() => _sort = v),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _filtersOpen = !_filtersOpen),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 2, 8),
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
        ],
      ]),
    );
  }

  Widget _chipRow({
    required String label,
    required Map<String, String> opts,
    required String sel,
    required ValueChanged<String> onPick,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(children: [
        SizedBox(
          width: 32,
          child: Text(label,
              style: const TextStyle(fontSize: 10, color: Colors.white30)),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: opts.entries.map((o) {
                final on = o.key == sel;
                return GestureDetector(
                  onTap: () => onPick(o.key),
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
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
              }).toList(),
            ),
          ),
        ),
      ]),
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
    return LayoutBuilder(builder: (ctx, c) {
      const pad = 12.0;
      const gap = 10.0;
      final cols = ((c.maxWidth - pad * 2 + gap) / 118).floor().clamp(2, 6);
      final w = (c.maxWidth - pad * 2 - gap * (cols - 1)) / cols;
      // 封面按 1.6:1 定高，下面留 ~56 给两行标题 + 一行副标题。
      final h = w / 1.6 + 58;
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(pad, 4, pad, 26),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          crossAxisSpacing: gap,
          mainAxisSpacing: 16,
          mainAxisExtent: h,
        ),
        itemCount: view.length,
        itemBuilder: (_, i) => _card(view[i]),
      );
    });
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
