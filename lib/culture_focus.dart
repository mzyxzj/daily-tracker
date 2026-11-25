// 「不在科技树里的库」的收容页。
//
// 为什么要单独一页：V4.6 起库只跟「规划 → 科技树」走。以前建的库（其他/复盘/…）
// 如果还有内容，直接删会丢东西，留着又会污染信息流。折中是——
// 它们不出现在侧栏、不进信息流，但内容还在，等你决定：
//   · 归到某个科技树节点（逐条改 / 整库并过去）；
//   · 或者连内容一起删掉。
// 一旦导图里长出同名节点，下次同步会自动把它放回侧栏。

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'culture_feed.dart';
import 'culture_library.dart';
import 'culture_techtree.dart';

class CultureHiddenLibsPage extends StatefulWidget {
  final Database db;
  final Future Function()? onChanged;

  const CultureHiddenLibsPage({super.key, required this.db, this.onChanged});

  @override
  State<CultureHiddenLibsPage> createState() => _CultureHiddenLibsPageState();
}

class _CultureHiddenLibsPageState extends State<CultureHiddenLibsPage> {
  List<Map<String, dynamic>> _libs = [];
  Map<int, int> _counts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // 先把空库清掉：内容归位/删完之后，这个库就不该再占一行。
      try {
        await syncLibrariesToTechTree(widget.db);
      } catch (_) {}
      final libs = await hiddenLibs(widget.db);
      final rows = await widget.db.rawQuery(
          'SELECT lib_id, COUNT(*) c FROM culture_items GROUP BY lib_id');
      final counts = <int, int>{};
      for (final r in rows) {
        counts[(r['lib_id'] as num?)?.toInt() ?? 0] =
            (r['c'] as num?)?.toInt() ?? 0;
      }
      if (!mounted) return;
      setState(() {
        _libs = libs.where((l) => (counts[(l['id'] as num).toInt()] ?? 0) > 0).toList();
        _counts = counts;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 12)),
        backgroundColor: const Color(0xFF1B2230),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 18),
        duration: const Duration(milliseconds: 1800),
      ));
  }

  Future<void> _open(Map<String, dynamic> lib) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CultureLibraryPage(
        db: widget.db,
        lib: lib,
        onChanged: () async {
          await _load();
          await widget.onChanged?.call();
        },
      ),
    ));
    await _load();
    await widget.onChanged?.call();
  }

  /// 整库并到某个科技树节点上：条目改 lib_id，旧库随之清空删除。
  Future<void> _mergeAll(Map<String, dynamic> lib) async {
    final libs = await visibleLibs(widget.db);
    if (!mounted) return;
    if (libs.isEmpty) {
      _snack('科技树里还没有节点，先去「规划」加一节');
      return;
    }
    final target = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: kFeedBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (bctx) => SafeArea(
        top: false,
        child: ListView(shrinkWrap: true, children: [
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('「${lib['name']}」整库并到哪一节？',
                style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: kFeedInk)),
          ),
          const SizedBox(height: 6),
          for (final l in libs)
            ListTile(
              dense: true,
              leading: Text('${l['icon'] ?? '📦'}',
                  style: const TextStyle(fontSize: 16)),
              title: Text('${l['name'] ?? ''}',
                  style: const TextStyle(fontSize: 13, color: kFeedInk)),
              onTap: () => Navigator.pop(bctx, (l['id'] as num).toInt()),
            ),
          const SizedBox(height: 10),
        ]),
      ),
    );
    if (target == null) return;
    await widget.db.update(
      'culture_items',
      {'lib_id': target, 'updated_at': DateTime.now().toIso8601String()},
      where: 'lib_id = ?',
      whereArgs: [lib['id']],
    );
    await widget.db.delete('culture_libraries',
        where: 'id = ?', whereArgs: [lib['id']]);
    _snack('已并过去');
    await _load();
    await widget.onChanged?.call();
  }

  Future<void> _purge(Map<String, dynamic> lib) async {
    final n = _counts[(lib['id'] as num).toInt()] ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('连内容一起删？', style: TextStyle(fontSize: 15)),
        content: Text(
          '「${lib['name']}」里的 $n 条会一起删掉，删了找不回。\n'
          '只想清理库、保住内容，就用「并到科技树」。',
          style: const TextStyle(fontSize: 12.5, height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('算了')),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('全删', style: TextStyle(color: Color(0xFFDC2626))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await purgeLibrary(widget.db, (lib['id'] as num).toInt());
    _snack('已删除「${lib['name']}」');
    await _load();
    await widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kFeedBg,
      appBar: AppBar(
        backgroundColor: kFeedBg,
        elevation: 0,
        title: const Text('不在科技树里的库',
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
        iconTheme: const IconThemeData(color: kFeedInk),
      ),
      body: _loading
          ? const Center(
              child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A160C),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(
                        color: const Color(0xFFFBBF24).withOpacity(0.28)),
                  ),
                  child: const Text(
                    '这些库不在「科技树」分支下，已经不进信息流、也不在侧栏里。\n'
                    '两条路：把内容并到某个科技树节点，或者连内容一起删。\n'
                    '导图里以后长出同名节点，它会自动回来。',
                    style: TextStyle(
                        fontSize: 11, height: 1.65, color: Colors.white54),
                  ),
                ),
                const SizedBox(height: 12),
                if (_libs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 40),
                    child: Center(
                      child: Text('干净了：所有库都在科技树上',
                          style: TextStyle(
                              fontSize: 12.5, color: Colors.white38)),
                    ),
                  ),
                for (final l in _libs) _row(l),
              ],
            ),
    );
  }

  Widget _row(Map<String, dynamic> l) {
    final n = _counts[(l['id'] as num).toInt()] ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      decoration: BoxDecoration(
        color: const Color(0xFF141A26),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _open(l),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text('${l['icon'] ?? '📦'}',
                    style: const TextStyle(fontSize: 15)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${l['name'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, color: kFeedInk)),
                ),
                Text('$n 条',
                    style: const TextStyle(
                        fontSize: 10.5, color: Colors.white38)),
                const SizedBox(width: 2),
                const Icon(Icons.chevron_right,
                    size: 15, color: Colors.white24),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                _act('逐条归位', () => _open(l)),
                const SizedBox(width: 6),
                _act('整库并走', () => _mergeAll(l)),
                const Spacer(),
                _act('连内容删', () => _purge(l), danger: true),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _act(String label, VoidCallback onTap, {bool danger = false}) {
    final c = danger ? const Color(0xFFF87171) : Colors.white54;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.withOpacity(0.28)),
        ),
        child: Text(label, style: TextStyle(fontSize: 10, color: c)),
      ),
    );
  }
}
