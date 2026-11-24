// 文化模块的唯一入口：全屏推荐流。
//
// 设计原则（对应这一版的需求）：
//   1. 一进来就是内容，不是菜单。竖向 PageView 一屏一条，像短视频一样往下刷。
//   2. 内容引进 / 分级 / 库 / 再创作全部收进右侧可隐藏的侧边栏，首页不再有 tab。
//   3. 点开就在 App 内看完：内置 WebView 播放器，带登录入口，不跳去别的 App。
//   4. 看完可以就地让 DeepSeek 结合「这条内容 + 我自己写的笔记」生成工具包。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'app_update.dart';
import 'content_feed.dart';
import 'content_fetch.dart';
import 'content_intake.dart';
import 'culture_page.dart';
import 'deepseek_service.dart';
import 'native_clip.dart';
import 'player_target.dart';

const Color kFeedBg = Color(0xFF0B0F17);
const Color kFeedInk = Color(0xFFF8FAFC);

class CultureFeedPage extends StatefulWidget {
  final Database db;

  /// 主壳引进内容后 +1，页面收到新 token 就重载。
  final int reloadToken;
  const CultureFeedPage({super.key, required this.db, this.reloadToken = 0});

  @override
  State<CultureFeedPage> createState() => _CultureFeedPageState();
}

class _CultureFeedPageState extends State<CultureFeedPage> {
  final PageController _pc = PageController();
  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();

  List _libs = [];
  List _items = [];
  List _grades = [];
  List _kits = [];
  int? _battery;
  bool _onlyCurrentTier = true;
  ClipStatus _clipStatus = const ClipStatus(); // 「复制即弹」的真实状态
  bool _loading = true;
  int _page = 0;
  // 全屏：只留视频，横屏 + 沉浸，其他 UI 全收起来
  bool _full = false;

  CultureFeedResult _feed = const CultureFeedResult();

  @override
  void initState() {
    super.initState();
    _restoreUi();
    _load(syncLibs: true);
  }

  @override
  void didUpdateWidget(covariant CultureFeedPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) {
      _load(syncLibs: true);
    }
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  Future<void> _restoreUi() async {
    try {
      final raw = await CultureDb.getState(widget.db, 'culture_feed_ui');
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw) as Map;
      if (mounted) {
        setState(() => _onlyCurrentTier = m['onlyTier'] != false);
      }
    } catch (_) {}
  }

  Future<void> _saveUi() async {
    try {
      await CultureDb.setState(widget.db, 'culture_feed_ui',
          jsonEncode({'onlyTier': _onlyCurrentTier}));
    } catch (_) {}
  }

  Future<void> _load({bool syncLibs = false}) async {
    try {
      final db = widget.db;
      if (syncLibs) {
        try {
          await CultureDb.syncLibrariesFromFocus(db);
        } catch (_) {}
      }
      final libs =
          await db.query('culture_libraries', orderBy: 'sort_order ASC, id ASC');
      final items = await db.query('culture_items', orderBy: 'id DESC');
      final grades = await db
          .query('culture_grades', orderBy: 'sort_order ASC, tier ASC, id ASC');
      final kits = await db.query('culture_kits', orderBy: 'updated_at DESC');
      final batteryRaw = await CultureDb.getState(db, 'medical_battery_now');
      var dims = <String>[];
      try {
        final rows = await db.rawQuery(
            "SELECT DISTINCT title FROM focus_items WHERE TRIM(title) <> '' "
            'ORDER BY date DESC LIMIT 40');
        dims = rows
            .map((e) => '${e['title']}'.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      } catch (_) {}
      try {
        await CultureDb.refreshSignals(db);
      } catch (_) {}

      var clip = const ClipStatus();
      try {
        clip = await NativeClip.status();
      } catch (_) {}
      final battery = int.tryParse('${batteryRaw ?? ''}'.trim());
      final feed = buildCultureFeed(
        items: items,
        libs: libs,
        grades: grades,
        focusDims: dims,
        battery: battery,
        onlyCurrentTier: _onlyCurrentTier,
      );
      if (!mounted) return;
      setState(() {
        _libs = libs;
        _items = items;
        _grades = grades;
        _kits = kits;
        _battery = battery;
        _clipStatus = clip;
        _feed = feed;
        _loading = false;
        if (_page >= feed.entries.length) {
          _page = feed.entries.isEmpty ? 0 : feed.entries.length - 1;
        }
      });
      // 条目变少时把 PageView 拉回有效位置。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_pc.hasClients) return;
        final max = _feed.entries.isEmpty ? 0 : _feed.entries.length - 1;
        final target = _page.clamp(0, max);
        if ((_pc.page?.round() ?? 0) != target) _pc.jumpToPage(target);
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------------- 动作 ----------------

  Future<void> _toggleTierFilter() async {
    setState(() => _onlyCurrentTier = !_onlyCurrentTier);
    _saveUi();
    await _load();
  }

  Future<void> _toggleFav(FeedEntry e) async {
    final cur = (e.item['fav'] as num?)?.toInt() ?? 0;
    await widget.db.update('culture_items', {'fav': cur == 1 ? 0 : 1},
        where: 'id = ?', whereArgs: [e.item['id']]);
    // 收藏只改这一页的标记，不重排整条流——否则点一下星星就跳到别的视频了。
    if (mounted) setState(() => e.item['fav'] = cur == 1 ? 0 : 1);
    _toast(cur == 1 ? '已取消收藏' : '已收藏');
  }

  Future<void> _markDone(FeedEntry e) async {
    await widget.db.update(
        'culture_items',
        {'state': 2, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [e.item['id']]);
    _toast('标记看完，这条不再推');
    await _load();
  }

  Future<void> _openPlayer(FeedEntry e) async {
    await CultureDb.touchItem(widget.db, e.item['id'] as int);
    _load();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CulturePlayerPage(
        db: widget.db,
        item: e.item,
        onChanged: _load,
      ),
    ));
    _load();
  }

  Future<void> _openKitStudio(FeedEntry e) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => KitStudioPage(db: widget.db, item: e.item),
    ));
    _load();
  }

  Future<void> _itemMenu(FeedEntry e) async {
    final act = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kFeedBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
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
          _darkTile(Icons.signal_cellular_alt, '设置分级', 'grade'),
          _darkTile(Icons.edit_outlined, '编辑标题/链接', 'edit'),
          _darkTile(Icons.swap_horiz, '换个库', 'lib'),
          _darkTile(Icons.delete_outline, '删掉这条', 'delete', danger: true),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (act == null) return;
    if (act == 'grade') await _pickGrade(e.item);
    if (act == 'edit') await _editItem(e.item);
    if (act == 'lib') await _moveLib(e.item);
    if (act == 'delete') await _deleteItem(e.item);
  }

  Widget _darkTile(IconData icon, String label, String value,
      {bool danger = false}) {
    final color = danger ? const Color(0xFFF87171) : Colors.white;
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 19, color: color),
      title: Text(label, style: TextStyle(fontSize: 13.5, color: color)),
      onTap: () => Navigator.pop(context, value),
    );
  }

  Future<void> _pickGrade(Map item) async {
    final cur = (item['grade_tier'] as num?)?.toInt() ?? 0;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: kFeedBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 14),
          const Text('这条属于哪一档？',
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: kFeedInk)),
          const SizedBox(height: 6),
          for (final g in _grades)
            ListTile(
              dense: true,
              leading: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    color: cultureGradeColor((g['max_b'] as num?)?.toInt() ?? 100),
                    shape: BoxShape.circle),
              ),
              title: Text('${g['name'] ?? ''}',
                  style: const TextStyle(fontSize: 13, color: kFeedInk)),
              subtitle: '${g['allow'] ?? ''}'.trim().isEmpty
                  ? null
                  : Text('${g['allow']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
              trailing: cur == (g['tier'] as num?)?.toInt()
                  ? const Icon(Icons.check_circle, size: 18, color: Colors.white)
                  : const Icon(Icons.circle_outlined,
                      size: 18, color: Colors.white24),
              onTap: () => Navigator.pop(context, (g['tier'] as num?)?.toInt()),
            ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.remove_circle_outline,
                size: 16, color: Colors.white38),
            title: const Text('先不标',
                style: TextStyle(fontSize: 13, color: Colors.white70)),
            trailing: cur == 0
                ? const Icon(Icons.check_circle, size: 18, color: Colors.white)
                : null,
            onTap: () => Navigator.pop(context, 0),
          ),
          const SizedBox(height: 10),
        ]),
      ),
    );
    if (picked == null) return;
    await CultureDb.updateItemGrade(widget.db, item['id'] as int, picked);
    _toast('分级已更新');
    await _load();
  }

  Future<void> _moveLib(Map item) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: kFeedBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          children: [
            const SizedBox(height: 14),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('放到哪个库？',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700, color: kFeedInk)),
            ),
            const SizedBox(height: 6),
            for (final l in _libs)
              ListTile(
                dense: true,
                leading: Text('${l['icon'] ?? '📚'}',
                    style: const TextStyle(fontSize: 16)),
                title: Text('${l['name'] ?? ''}',
                    style: const TextStyle(fontSize: 13, color: kFeedInk)),
                trailing: item['lib_id'] == l['id']
                    ? const Icon(Icons.check_circle, size: 18, color: Colors.white)
                    : null,
                onTap: () => Navigator.pop(context, l['id'] as int),
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await widget.db.update('culture_items', {'lib_id': picked},
        where: 'id = ?', whereArgs: [item['id']]);
    _toast('已换库');
    await _load();
  }

  Future<void> _deleteItem(Map item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('删掉这条？', style: TextStyle(fontSize: 15)),
        content: Text('「${item['title'] ?? ''}」会从库里移除。',
            style: const TextStyle(fontSize: 12.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('算了')),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFDC2626))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.db
        .delete('culture_items', where: 'id = ?', whereArgs: [item['id']]);
    _toast('已删除');
    await _load();
  }

  Future<void> _editItem(Map item) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CultureItemSheet(
        db: widget.db,
        libs: _libs,
        grades: _grades,
        libId: item['lib_id'] as int? ?? 0,
        item: item,
        onSaved: _load,
      ),
    );
    await _load();
  }

  Future<void> _addItem({int? libId}) async {
    if (_libs.isEmpty) {
      await _newLib();
      if (!mounted) return;
    }
    if (_libs.isEmpty) return;
    final id = libId ??
        (_libs.first['id'] as int?) ??
        0;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CultureItemSheet(
        db: widget.db,
        libs: _libs,
        grades: _grades,
        libId: id,
        onSaved: _load,
      ),
    );
    await _load();
  }

  Future<void> _intakeFromClipboard() async {
    String text = '';
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text ?? '';
    } catch (_) {}
    final parsed = parseShareText(text);
    if (parsed.isEmpty) {
      _toast('剪贴板里没有链接，先复制一条分享文案');
      return;
    }
    await _openIntake(parsed);
  }

  Future<void> _openIntake(ParsedShare share) async {
    if (_libs.isEmpty) {
      await _newLib();
      if (!mounted) return;
    }
    if (!mounted) return;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ContentIntakeSheet(
        db: widget.db,
        share: share,
        libs: _libs,
        grades: _grades,
        battery: _battery,
      ),
    );
    if (ok == true) {
      await _load();
      if (mounted) {
        setState(() => _page = 0);
        if (_pc.hasClients) _pc.jumpToPage(0);
      }
    }
  }

  Future<void> _newLib() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('新建库', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '库名（建议就是你的聚焦维度）',
            hintText: '例：AI / 健身 / 摄影',
            isDense: true,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('建'),
          ),
        ],
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || name.isEmpty) return;
    await widget.db.insert('culture_libraries', {
      'name': name,
      'icon': '📚',
      'note': '',
      'source': 'manual',
      'sort_order': _libs.length,
      'created_at': DateTime.now().toIso8601String(),
    });
    await _load();
    _toast('已建「$name」');
  }

  Future<void> _newGrade() async {
    final name = TextEditingController();
    final minB = TextEditingController();
    final allow = TextEditingController();
    final forbid = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('新增一档', style: TextStyle(fontSize: 15)),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '档名', isDense: true),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: minB,
              keyboardType: TextInputType.number,
              decoration:
                  const InputDecoration(labelText: '电量下限 %', isDense: true),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: allow,
              decoration: const InputDecoration(labelText: '这一档能做', isDense: true),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: forbid,
              decoration: const InputDecoration(labelText: '这一档别碰', isDense: true),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final n = name.text.trim();
    if (n.isEmpty) return;
    final min = int.tryParse(minB.text.trim()) ?? 0;
    final tierNo = _grades.length + 1;
    await CultureDb.saveGrade(widget.db, {
      'tier': tierNo,
      'name': n,
      'min_b': min,
      'max_b': min == 0 ? 100 : min + 20,
      'allow': allow.text.trim(),
      'forbid': forbid.text.trim(),
      'note': '',
      'sort_order': tierNo,
    });
    name.dispose();
    minB.dispose();
    allow.dispose();
    forbid.dispose();
    await _load();
  }

  Future<void> _editGrade(Map g) async {
    final name = TextEditingController(text: '${g['name'] ?? ''}');
    final allow = TextEditingController(text: '${g['allow'] ?? ''}');
    final forbid = TextEditingController(text: '${g['forbid'] ?? ''}');
    final minB = TextEditingController(text: '${g['min_b'] ?? 0}');
    final maxB = TextEditingController(text: '${g['max_b'] ?? 100}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('编辑分级', style: TextStyle(fontSize: 15)),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '档名', isDense: true),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: minB,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '下限 %', isDense: true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: maxB,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '上限 %', isDense: true),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: allow,
              decoration: const InputDecoration(labelText: '能做', isDense: true),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: forbid,
              decoration: const InputDecoration(labelText: '别碰', isDense: true),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    await CultureDb.saveGrade(widget.db, {
      'tier': g['tier'],
      'name': name.text.trim().isEmpty ? '${g['name']}' : name.text.trim(),
      'min_b': int.tryParse(minB.text.trim()) ?? 0,
      'max_b': int.tryParse(maxB.text.trim()) ?? 100,
      'allow': allow.text.trim(),
      'forbid': forbid.text.trim(),
      'note': '${g['note'] ?? ''}',
      'sort_order': (g['sort_order'] as num?)?.toInt() ?? 0,
    }, id: (g['id'] as num?)?.toInt());
    name.dispose();
    allow.dispose();
    forbid.dispose();
    minB.dispose();
    maxB.dispose();
    await _load();
  }

  /// 「复制就弹」自检面板。
  ///
  /// 用户报「复制了没弹」时，光看一个「已开启」的勾是没用的——真正要确认的是
  /// 服务进程还活着、能不能读剪贴板、浮层权限给没给。这三件事分开显示。
  Future<void> _showClipDiag() async {
    var st = _clipStatus;
    await showDialog<void>(
      context: context,
      builder: (dctx) => StatefulBuilder(builder: (dctx, setSt) {
        Future<void> refresh() async {
          final s = await NativeClip.status();
          if (!dctx.mounted) return;
          setSt(() => st = s);
        }

        String ago(int v) {
          if (v < 0) return '还没有过';
          if (v < 60) return '$v 秒前';
          if (v < 3600) return '${v ~/ 60} 分钟前';
          return '${v ~/ 3600} 小时前';
        }

        Widget row(String label, String value, {bool good = false, bool bad = false}) {
          final color = good
              ? const Color(0xFF4ADE80)
              : (bad ? const Color(0xFFF87171) : Colors.white70);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              Expanded(
                  child: Text(label,
                      style: const TextStyle(fontSize: 11.5, color: Colors.white54))),
              Text(value,
                  style: TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
            ]),
          );
        }

        final noOverlay = !st.overlayPermission;
        return AlertDialog(
          backgroundColor: const Color(0xFF141A26),
          title: const Text('复制即弹 · 自检',
              style: TextStyle(fontSize: 15.5, color: kFeedInk)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row('无障碍开关', st.enabled ? '已开启' : '未开启',
                    good: st.enabled, bad: !st.enabled),
                row('服务是否在跑', st.connected ? '在跑' : '没连上',
                    good: st.connected, bad: !st.connected),
                row('浮层权限', st.overlayPermission ? '已授权' : '未授权',
                    good: st.overlayPermission, bad: false),
                const Divider(color: Colors.white10, height: 16),
                row('最近一次系统事件', ago(st.lastEventAgo)),
                row('最近读到剪贴板', ago(st.lastClipAgo),
                    bad: st.lastClipAgo < 0 && st.enabled),
                row('最近弹过提示卡', ago(st.lastOverlayAgo)),
                if (st.lastPkg.isNotEmpty) row('最近前台 App', st.lastPkg),
                if (st.error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('底层报错：${st.error}',
                        style: const TextStyle(
                            fontSize: 10, height: 1.5, color: Color(0xFFFCA5A5))),
                  ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    st.enabled && !st.connected
                        ? '系统把它停了（小米/OPPO 常见）：去设置里关掉再打开一次，然后回来点「刷新」。'
                        : (!st.enabled
                            ? '还没开启。点下面「去开启」，在系统列表里找到「文化 · 复制即整理」打开。'
                            : (noOverlay
                                ? '已经能用。再给一个「显示在其他应用上层」权限，提示卡能从后台弹出来（安卓 10 起后台起界面的前提）。'
                                : '一切正常。复制一条抖音/B站分享链接试试，屏幕上方会立刻出现「整理 / 略过」。')),
                    style: const TextStyle(
                        fontSize: 10.5, height: 1.65, color: Colors.white60),
                  ),
                ),
              ],
            ),
          ),
          actionsOverflowDirection: VerticalDirection.down,
          actions: [
            TextButton(onPressed: refresh, child: const Text('刷新')),
            if (noOverlay)
              TextButton(
                onPressed: () async {
                  await NativeClip.openOverlaySettings();
                },
                child: const Text('浮层权限'),
              ),
            if (st.connected)
              TextButton(
                onPressed: () async {
                  final ok = await NativeClip.test();
                  if (!dctx.mounted) return;
                  ScaffoldMessenger.of(dctx).showSnackBar(SnackBar(
                    content: Text(ok ? '已弹一条到屏幕上方，看到了吗' : '服务没响应，去重开一次无障碍',
                        style: const TextStyle(fontSize: 12)),
                    behavior: SnackBarBehavior.floating,
                  ));
                },
                child: const Text('试一下'),
              ),
            FilledButton(
              onPressed: () async {
                await NativeClip.openSettings();
              },
              child: Text(st.enabled ? '重开权限' : '去开启'),
            ),
          ],
        );
      }),
    );
    await _load();
  }

  Future<void> _openKits() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CultureKitsPage(db: widget.db),
    ));
    await _load();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 12.5)),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  // ---------------- build ----------------

  @override
  Widget build(BuildContext context) {
    final feed = _feed;
    return PopScope(
      canPop: !_full,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _full) _setFull(false);
      },
      child: Scaffold(
      key: _scaffold,
      backgroundColor: kFeedBg,
      endDrawer: _SidePanel(
        libs: _libs,
        grades: _grades,
        items: _items,
        kits: _kits,
        battery: _battery,
        tier: feed.tier,
        onlyCurrentTier: _onlyCurrentTier,
        onToggleTier: _toggleTierFilter,
        onIntakeClip: () {
          Navigator.pop(context);
          _intakeFromClipboard();
        },
        onManualAdd: () {
          Navigator.pop(context);
          _addItem();
        },
        clipStatus: _clipStatus,
        onOpenClipDiag: () {
          Navigator.pop(context);
          _showClipDiag();
        },
        onNewLib: () {
          Navigator.pop(context);
          _newLib();
        },
        onNewGrade: () {
          Navigator.pop(context);
          _newGrade();
        },
        onEditGrade: (g) {
          Navigator.pop(context);
          _editGrade(g);
        },
        onOpenKits: () {
          Navigator.pop(context);
          _openKits();
        },
        onEditItem: (item) {
          Navigator.pop(context);
          _editItem(item);
        },
        onCheckUpdate: () {
          Navigator.pop(context);
          showUpdateDialog(context);
        },
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white54))
          : Stack(children: [
              if (feed.isEmpty)
                _emptyState()
              else
                PageView.builder(
                  controller: _pc,
                  scrollDirection: Axis.vertical,
                  itemCount: feed.entries.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (ctx, i) => _feedCard(feed.entries[i], i),
                ),
              if (!_full) _topBar(),
              if (_full) _exitFullButton(),
            ]),
      ),
    );
  }

  /// 全屏：横屏 + 沉浸，只留画面；返回键/右上角都能退出。
  Future<void> _setFull(bool on) async {
    if (!mounted) return;
    setState(() => _full = on);
    try {
      if (on) {
        await SystemChrome.setPreferredOrientations(
            [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        await SystemChrome.setPreferredOrientations(
            [DeviceOrientation.portraitUp]);
      }
    } catch (_) {}
  }

  Widget _exitFullButton() {
    return Positioned(
      right: 10,
      top: 10,
      child: SafeArea(
        child: IconButton(
          tooltip: '退出全屏',
          onPressed: () => _setFull(false),
          icon: const Icon(Icons.fullscreen_exit, size: 22, color: Colors.white70),
        ),
      ),
    );
  }

  Widget _topBar() {
    final tier = _feed.tier;
    final color = tier == null
        ? Colors.white70
        : cultureGradeColor((tier['max_b'] as num?)?.toInt() ?? 100);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 0),
          child: Row(children: [
            const Text('📚 文化',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: kFeedInk,
                    letterSpacing: 0.3)),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _toggleTierFilter,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.42),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: color.withOpacity(0.55)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 5),
                  Text(_feed.headline,
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: color)),
                  const SizedBox(width: 3),
                  Icon(_onlyCurrentTier ? Icons.filter_alt : Icons.filter_alt_off,
                      size: 11, color: color.withOpacity(0.9)),
                ]),
              ),
            ),
            const Spacer(),
            if (_feed.entries.length > 1)
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Text('${_page + 1}/${_feed.entries.length}',
                    style: const TextStyle(fontSize: 10, color: Colors.white38)),
              ),
            IconButton(
              tooltip: '侧边栏',
              onPressed: () => _scaffold.currentState?.openEndDrawer(),
              icon: const Icon(Icons.tune, size: 22, color: kFeedInk),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _feedCard(FeedEntry e, int index) {
    final item = e.item;
    final platform = '${item['platform'] ?? ''}';
    final pColor = culturePlatformColor(platform);
    final cover = '${item['cover'] ?? ''}'.trim();
    final title = '${item['title'] ?? ''}'.trim();
    final author = '${item['author'] ?? ''}'.trim();
    final lib = _libName((item['lib_id'] as num?)?.toInt());
    final isVideo = looksLikeVideo(item);
    final dur = '${item['duration'] ?? ''}'.trim();
    final size = MediaQuery.of(context).size;
    // 只有当前这一页才真的挂 WebView：滑走就销毁，10 条也不会同时播 10 个。
    final inline = isVideo && index == _page;

    return Stack(fit: StackFit.expand, children: [
      if (inline)
        _InlineVideo(
          key: ValueKey('pv-${item['id']}-$index'),
          item: Map<String, dynamic>.from(item as Map),
          active: true,
          full: _full,
          onFull: () => _setFull(!_full),
          onFallback: () => _openPlayer(e),
        )
      // 背景：有封面就铺满并压暗；没封面用平台渐变。
      else if (cover.isNotEmpty)
        Image.network(
          cover,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _gradientBg(pColor),
          loadingBuilder: (c, child, p) =>
              p == null ? child : _gradientBg(pColor),
        )
      else
        _gradientBg(pColor),
      // 上下压暗，保证白字可读；内嵌播放时只留底部一条，别糊住画面。
      if (!_full)
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: inline ? const [0, 0.55, 0.75, 1] : const [0, 0.28, 0.58, 1],
              colors: inline
                  ? const [
                      Color(0x55000000),
                      Color(0x00000000),
                      Color(0x99000000),
                      Color(0xF20B0F17),
                    ]
                  : const [
                      Color(0x99000000),
                      Color(0x22000000),
                      Color(0xAA000000),
                      Color(0xF20B0F17),
                    ],
            ),
          ),
        ),
      // 中间：播放/阅读按钮（内嵌播放器在跑时不需要）
      if (!inline)
      Center(
        child: GestureDetector(
          onTap: () => _openPlayer(e),
          child: Container(
            width: 66,
            height: 66,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.42),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24),
            ),
            child: Icon(isVideo ? Icons.play_arrow_rounded : Icons.menu_book_rounded,
                size: 34, color: Colors.white),
          ),
        ),
      ),
      // 底部信息
      if (!_full)
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  if (platform.isNotEmpty) _pill(platform, pColor),
                  const SizedBox(width: 5),
                  _gradePill(item),
                  if (lib.isNotEmpty) ...[
                    const SizedBox(width: 5),
                    _pillOutlined(lib),
                  ],
                  if (dur.isNotEmpty) ...[
                    const SizedBox(width: 5),
                    _pillOutlined(dur),
                  ],
                ]),
                const SizedBox(height: 9),
                Text(title.isEmpty ? '（无标题）' : title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: size.height > 700 ? 20 : 18,
                      height: 1.28,
                      fontWeight: FontWeight.w800,
                      color: kFeedInk,
                    )),
                const SizedBox(height: 6),
                if (author.isNotEmpty)
                  Text(author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white70)),
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.auto_awesome, size: 12, color: Color(0xFF7DD3FC)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(e.reason,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF7DD3FC))),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xFF0B0F17),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => _openPlayer(e),
                      icon: Icon(
                          isVideo
                              ? Icons.play_arrow_rounded
                              : Icons.menu_book_rounded,
                          size: 19),
                      label: Text(isVideo ? '在这里看' : '在这里读',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _roundAction(
                    icon: Icons.build_circle_outlined,
                    label: '工具包',
                    onTap: () => _openKitStudio(e),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
      // 右侧竖排操作（抖音式）
      if (!_full)
      Positioned(
        right: 8,
        bottom: 196,
        child: SafeArea(
          top: false,
          child: Column(children: [
            _sideAction(
              icon: ((item['fav'] as num?)?.toInt() ?? 0) == 1
                  ? Icons.star
                  : Icons.star_border,
              label: ((item['fav'] as num?)?.toInt() ?? 0) == 1 ? '已收藏' : '收藏',
              color: ((item['fav'] as num?)?.toInt() ?? 0) == 1
                  ? const Color(0xFFFBBF24)
                  : Colors.white,
              onTap: () => _toggleFav(e),
            ),
            _sideAction(
              icon: Icons.check_circle_outline,
              label: '看完',
              onTap: () => _markDone(e),
            ),
            _sideAction(
              icon: Icons.auto_fix_high,
              label: '改写',
              onTap: () => _openKitStudio(e),
            ),
            _sideAction(
              icon: Icons.more_horiz,
              label: '更多',
              onTap: () => _itemMenu(e),
            ),
          ]),
        ),
      ),
      if (index == _feed.entries.length - 1)
        Positioned(
          bottom: 4,
          left: 0,
          right: 0,
          child: Center(
            child: Text('到底了 · 侧边栏可以整理新内容',
                style: TextStyle(fontSize: 9.5, color: Colors.white.withOpacity(0.35))),
          ),
        ),
    ]);
  }

  String _libName(int? id) {
    for (final l in _libs) {
      if (l['id'] == id) return '${l['icon'] ?? ''} ${l['name'] ?? ''}'.trim();
    }
    return '';
  }

  Widget _gradientBg(Color c) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(c, Colors.black, 0.25)!,
            Color.lerp(c, Colors.black, 0.7)!,
            kFeedBg,
          ],
        ),
      ),
    );
  }

  Widget _pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.9),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(text,
          style: const TextStyle(
              fontSize: 9.5, fontWeight: FontWeight.w800, color: Colors.white)),
    );
  }

  Widget _pillOutlined(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 9.5, color: Colors.white70)),
    );
  }

  Widget _gradePill(Map item) {
    final t = (item['grade_tier'] as num?)?.toInt() ?? 0;
    Map? g;
    for (final e in _grades) {
      if ((e['tier'] as num?)?.toInt() == t) g = e as Map;
    }
    if (t == 0 || g == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.12),
          borderRadius: BorderRadius.circular(5),
        ),
        child: const Text('未标级',
            style: TextStyle(fontSize: 9.5, color: Colors.white54)),
      );
    }
    final color = cultureGradeColor((g['max_b'] as num?)?.toInt() ?? 100);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text('${g['name'] ?? ''}',
          style: TextStyle(
              fontSize: 9.5, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _roundAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.14),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 17, color: Colors.white),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
        ]),
      ),
    );
  }

  Widget _sideAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = Colors.white,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Column(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.38),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white12),
            ),
            child: Icon(icon, size: 21, color: color),
          ),
          const SizedBox(height: 3),
          Text(label,
              style: const TextStyle(fontSize: 9.5, color: Colors.white70)),
        ]),
      ),
    );
  }

  Widget _emptyState() {
    final tier = _feed.tier;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.play_circle_outline,
              size: 54, color: Colors.white.withOpacity(0.22)),
          const SizedBox(height: 16),
          Text(_feed.headline,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w800, color: kFeedInk)),
          const SizedBox(height: 8),
          Text(
            _feed.subline.isEmpty
                ? '库里还没有能推的内容。点下面任意一个，30 秒就能存进一条。'
                : _feed.subline,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12, height: 1.7, color: Colors.white.withOpacity(0.55)),
          ),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: kFeedBg),
              onPressed: _intakeFromClipboard,
              icon: const Icon(Icons.content_paste_go, size: 18),
              label: const Text('从剪贴板整理', style: TextStyle(fontSize: 12.5)),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white24)),
              onPressed: () => _addItem(),
              child: const Text('手动填', style: TextStyle(fontSize: 12.5)),
            ),
          ]),
          const SizedBox(height: 18),
          if (tier == null)
            TextButton(
              onPressed: () {
                setState(() => _scaffold.currentState?.openEndDrawer());
              },
              child: const Text('先去侧边栏看看分级 / 库',
                  style: TextStyle(fontSize: 11.5, color: Colors.white38)),
            ),
        ]),
      ),
    );
  }
}

// ==================== 侧边栏 ====================

class _SidePanel extends StatelessWidget {
  final List libs;
  final List grades;
  final List items;
  final List kits;
  final int? battery;
  final Map<String, dynamic>? tier;
  final bool onlyCurrentTier;
  final ClipStatus clipStatus;
  final VoidCallback onOpenClipDiag;
  final VoidCallback onToggleTier;
  final VoidCallback onIntakeClip;
  final VoidCallback onManualAdd;
  final VoidCallback onNewLib;
  final VoidCallback onNewGrade;
  final void Function(Map g) onEditGrade;
  final VoidCallback onOpenKits;
  final void Function(Map item) onEditItem;
  final VoidCallback onCheckUpdate;

  const _SidePanel({
    required this.libs,
    required this.grades,
    required this.items,
    required this.kits,
    required this.battery,
    required this.tier,
    required this.onlyCurrentTier,
    required this.clipStatus,
    required this.onOpenClipDiag,
    required this.onToggleTier,
    required this.onIntakeClip,
    required this.onManualAdd,
    required this.onNewLib,
    required this.onNewGrade,
    required this.onEditGrade,
    required this.onOpenKits,
    required this.onEditItem,
    required this.onCheckUpdate,
  });

  @override
  Widget build(BuildContext context) {
    final tierColor = tier == null
        ? Colors.white38
        : cultureGradeColor((tier!['max_b'] as num?)?.toInt() ?? 100);
    final unread = items.where((e) => (e['state'] as num?)?.toInt() == 0).length;

    return Drawer(
      backgroundColor: const Color(0xFF12161F),
      width: MediaQuery.of(context).size.width * 0.84,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Row(children: [
              const Text('整理',
                  style: TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w800, color: kFeedInk)),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 20, color: Colors.white54),
              ),
            ]),
            const SizedBox(height: 4),
            // 「复制就弹」状态：三态——没开 / 开了但服务被停 / 正常。
            // 点一下进自检，能看到「服务在不在跑」「最近读到剪贴板是多久前」。
            InkWell(
              onTap: onOpenClipDiag,
              borderRadius: BorderRadius.circular(9),
              child: Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.fromLTRB(11, 9, 9, 9),
                decoration: BoxDecoration(
                  color: clipStatus.working
                      ? const Color(0xFF0F2A22)
                      : (clipStatus.enabled
                          ? const Color(0xFF2A2113)
                          : const Color(0xFF1B2333)),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                      color: clipStatus.working
                          ? const Color(0xFF22C55E).withOpacity(0.35)
                          : (clipStatus.enabled
                              ? const Color(0xFFF59E0B).withOpacity(0.35)
                              : Colors.white12)),
                ),
                child: Row(children: [
                  Icon(
                    clipStatus.working
                        ? Icons.check_circle
                        : (clipStatus.enabled
                            ? Icons.error_outline
                            : Icons.notifications_active_outlined),
                    size: 15,
                    color: clipStatus.working
                        ? const Color(0xFF4ADE80)
                        : (clipStatus.enabled
                            ? const Color(0xFFFBBF24)
                            : const Color(0xFF7DD3FC)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          clipStatus.headline,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: clipStatus.working
                                ? const Color(0xFF4ADE80)
                                : (clipStatus.enabled
                                    ? const Color(0xFFFBBF24)
                                    : Colors.white),
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          clipStatus.detail,
                          maxLines: 2,
                          style: const TextStyle(
                              fontSize: 9.5, height: 1.4, color: Colors.white38),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 16, color: Colors.white24),
                ]),
              ),
            ),
            // 电量卡
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: tierColor.withOpacity(0.10),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: tierColor.withOpacity(0.32)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.bolt, size: 15, color: tierColor),
                  const SizedBox(width: 4),
                  Text(battery == null ? '还没记电量' : '前额叶电量 $battery%',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: tierColor)),
                  const Spacer(),
                  if (tier != null)
                    Text('${tier!['name']}',
                        style: TextStyle(
                            fontSize: 10, color: tierColor.withOpacity(0.9))),
                ]),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: onToggleTier,
                  child: Row(children: [
                    Icon(onlyCurrentTier ? Icons.check_box : Icons.check_box_outline_blank,
                        size: 14, color: Colors.white54),
                    const SizedBox(width: 5),
                    const Expanded(
                      child: Text('只推这一档能承接的',
                          style: TextStyle(fontSize: 10.5, color: Colors.white54)),
                    ),
                    const Text('改电量去「医疗」',
                        style: TextStyle(fontSize: 9.5, color: Colors.white24)),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            _sectionTitle('整理进来'),
            _row(Icons.content_paste_go, '从剪贴板整理', '复制完分享文案，一键抓封面标题',
                onIntakeClip),
            _row(Icons.edit_note, '手动填一条', '抓不到时自己写标题', onManualAdd),
            const SizedBox(height: 16),
            _sectionTitle('分级 · ${grades.length} 档'),
            for (final g in grades)
              InkWell(
                onTap: () => onEditGrade(Map<String, dynamic>.from(g as Map)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: cultureGradeColor((g['max_b'] as num?)?.toInt() ?? 100),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('${g['name'] ?? ''}',
                        style: const TextStyle(fontSize: 12, color: kFeedInk)),
                    const SizedBox(width: 6),
                    Text('${g['min_b'] ?? 0}-${g['max_b'] ?? 100}%',
                        style: const TextStyle(fontSize: 9.5, color: Colors.white30)),
                    const Spacer(),
                    Text(
                      '${items.where((e) => (e['grade_tier'] as num?)?.toInt() == (g['tier'] as num?)?.toInt()).length}',
                      style: const TextStyle(fontSize: 10, color: Colors.white38),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, size: 14, color: Colors.white24),
                  ]),
                ),
              ),
            TextButton.icon(
              onPressed: onNewGrade,
              style: TextButton.styleFrom(
                  padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
              icon: const Icon(Icons.add, size: 15, color: Colors.white38),
              label: const Text('新增一档',
                  style: TextStyle(fontSize: 11, color: Colors.white38)),
            ),
            const SizedBox(height: 14),
            _sectionTitle('库 · ${libs.length} 个'),
            for (final l in libs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Text('${l['icon'] ?? '📚'}', style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text('${l['name'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: kFeedInk)),
                  ),
                  Text(
                    '${items.where((e) => e['lib_id'] == l['id']).length}',
                    style: const TextStyle(fontSize: 10, color: Colors.white38),
                  ),
                ]),
              ),
            TextButton.icon(
              onPressed: onNewLib,
              style: TextButton.styleFrom(
                  padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
              icon: const Icon(Icons.add, size: 15, color: Colors.white38),
              label: const Text('新建库',
                  style: TextStyle(fontSize: 11, color: Colors.white38)),
            ),
            const SizedBox(height: 16),
            _sectionTitle('再创作'),
            _row(Icons.build_outlined, '工具包 ${kits.length} 个',
                'DeepSeek 把内容和你的笔记变成能执行的东西', onOpenKits),
            _row(Icons.system_update_alt, '检查更新',
                '有新版就地下载覆盖安装，不用卸载重装', onCheckUpdate),
            const SizedBox(height: 16),
            _sectionTitle('最近存的'),
            for (final it in items.take(6))
              InkWell(
                onTap: () => onEditItem(Map<String, dynamic>.from(it as Map)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('· ${it['title'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: Colors.white54)),
                ),
              ),
            const SizedBox(height: 18),
            Text(
              '未看 $unread 条 · 共 ${items.length} 条\n'
              '复制链接后回到 App 会自动问你，不必先开软件。',
              style: const TextStyle(fontSize: 10, height: 1.6, color: Colors.white24),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 4),
      child: Text(t,
          style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: Colors.white38,
              letterSpacing: 0.6)),
    );
  }

  Widget _row(IconData icon, String title, String sub, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(children: [
          Icon(icon, size: 18, color: Colors.white70),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(fontSize: 12.5, color: kFeedInk)),
              const SizedBox(height: 1),
              Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9.5, color: Colors.white30)),
            ]),
          ),
          const Icon(Icons.chevron_right, size: 16, color: Colors.white24),
        ]),
      ),
    );
  }
}

// ==================== 内嵌自动播放 ====================

/// 流里就地播放：滑到这一页就自动播，滑走就暂停，页面销毁时一起回收。
///
/// 和「点开播放器页」的区别：不再需要点两下。抖音的做法是滑到即播，
/// 这里用同一套 WebView 播放器页 + 关闭手势限制实现真实自动播放。
class _InlineVideo extends StatefulWidget {
  final Map<String, dynamic> item;
  final bool active;
  final bool full;
  final VoidCallback onFull;
  final VoidCallback onFallback;

  const _InlineVideo({
    super.key,
    required this.item,
    required this.active,
    required this.full,
    required this.onFull,
    required this.onFallback,
  });

  @override
  State<_InlineVideo> createState() => _InlineVideoState();
}

class _InlineVideoState extends State<_InlineVideo> {
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';
  static const String _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  WebViewController? _ctrl;
  PlayTarget? _target;
  int _tryIdx = 0;
  bool _failed = false;
  bool _ready = false;
  bool _started = false;

  String get _url => cultureNormalizeUrl('${widget.item['url'] ?? ''}');

  List<String> get _sources {
    final t = _target;
    if (t == null) return [_url];
    return [t.primary, t.fallback, t.desktop].where((e) => e.isNotEmpty).toList();
  }

  @override
  void initState() {
    super.initState();
    if (widget.active) _boot();
  }

  @override
  void didUpdateWidget(covariant _InlineVideo old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _kickPlay();
    if (!widget.active && old.active) _pause();
  }

  @override
  void dispose() {
    _pause();
    super.dispose();
  }

  Future<void> _boot() async {
    if (_started) return;
    _started = true;
    if (_url.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    PlayTarget t;
    try {
      t = await buildPlayTarget(
        url: _url,
        platform: '${widget.item['platform'] ?? ''}',
        knownExtId: '${widget.item['ext_id'] ?? ''}',
      );
    } catch (_) {
      t = PlayTarget(primary: _url);
    }
    if (!mounted) return;
    _target = t;

    // 组件测试里没有 WebView 实现，构造会直接抛断言；当成「播不了」处理，
    // 这样 UI 还能正常渲染、测试也能跑。
    late final WebViewController c;
    try {
      c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setUserAgent(_ua)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) async {
          if (!mounted) return;
          setState(() => _ready = true);
          await _fitCss();
          await _kickPlay();
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame == true) _nextSource();
        },
        onNavigationRequest: (req) {
          // 跳 App 的 scheme 一律拦下，留在站内看。
          return req.url.startsWith('http')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
      ));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
      return;
    }

    // 关键一步：不要求用户手势。少了这句，自动播放会被 WebView 直接拦掉，
    // 表现就是「画面在、就是不动」。
    try {
      final p = c.platform;
      if (p is AndroidWebViewController) {
        await p.setMediaPlaybackRequiresUserGesture(false);
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() => _ctrl = c);
    await c.loadRequest(Uri.parse(_sources.first));
  }

  Future<void> _nextSource() async {
    if (_failed) return;
    final list = _sources;
    if (_tryIdx + 1 >= list.length) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    _tryIdx++;
    final c = _ctrl;
    if (c == null) return;
    final desktop = _target?.kind == 'bili' && _tryIdx == 2;
    try {
      await c.setUserAgent(desktop ? _desktopUa : _ua);
    } catch (_) {}
    try {
      await c.loadRequest(Uri.parse(list[_tryIdx]));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _fitCss() async {
    final c = _ctrl;
    if (c == null) return;
    try {
      await c.runJavaScript("""
(function(){
  var s=document.getElementById('dt-fit');
  if(!s){s=document.createElement('style');s.id='dt-fit';
    (document.head||document.documentElement).appendChild(s);}
  s.textContent='html,body{margin:0!important;padding:0!important;overflow:hidden!important;background:#000!important;}'
   +'video{width:100%!important;height:100%!important;object-fit:contain!important;background:#000!important;}';
})();
""");
    } catch (_) {}
  }

  Future<void> _kickPlay() async {
    final c = _ctrl;
    if (c == null) return;
    try {
      await c.runJavaScript("""
(function(){
  var v=document.querySelector('video');
  if(!v) return 'no';
  try{v.muted=false;}catch(e){}
  var p=v.play();
  if(p&&p.catch){p.catch(function(){try{v.muted=true;v.play();}catch(e){}});}
  return 'ok';
})();
""");
    } catch (_) {}
  }

  Future<void> _pause() async {
    final c = _ctrl;
    if (c == null) return;
    try {
      await c.runJavaScript(
          "document.querySelectorAll('video').forEach(function(v){try{v.pause();}catch(e){}})");
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl;
    return Stack(fit: StackFit.expand, children: [
      ColoredBox(color: Colors.black, child: c == null ? const SizedBox() : WebViewWidget(controller: c)),
      if (!_ready && !_failed)
        const Center(
          child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38)),
        ),
      if (_failed) _failedCard(),
      // 全屏：自己实现，B站播放器里的全屏按钮在 WebView 里是无效的
      Positioned(
        right: 6,
        bottom: widget.full ? 12 : 190,
        child: Material(
          color: Colors.black.withOpacity(0.42),
          shape: const CircleBorder(),
          child: IconButton(
            tooltip: widget.full ? '退出全屏' : '全屏',
            iconSize: 20,
            onPressed: widget.onFull,
            icon: Icon(
              widget.full ? Icons.fullscreen_exit : Icons.fullscreen,
              color: Colors.white,
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _failedCard() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.play_disabled, size: 34, color: Colors.white24),
          const SizedBox(height: 10),
          const Text('这条没法内嵌播放',
              style: TextStyle(fontSize: 13, color: Colors.white70)),
          const SizedBox(height: 4),
          const Text('可能是平台风控或需要登录',
              style: TextStyle(fontSize: 10.5, color: Colors.white38)),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            TextButton(
              onPressed: widget.onFallback,
              child: const Text('用播放器打开', style: TextStyle(fontSize: 12)),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _failed = false;
                  _ready = false;
                  _tryIdx = 0;
                });
                final c = _ctrl;
                if (c != null) {
                  c.loadRequest(Uri.parse(_sources.first));
                } else {
                  _started = false;
                  _boot();
                }
              },
              child: const Text('重试', style: TextStyle(fontSize: 12)),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ==================== 内置播放器 ====================

class CulturePlayerPage extends StatefulWidget {
  final Database db;
  final Map item;
  final Future Function()? onChanged;
  const CulturePlayerPage({
    super.key,
    required this.db,
    required this.item,
    this.onChanged,
  });

  @override
  State<CulturePlayerPage> createState() => _CulturePlayerPageState();
}

class _CulturePlayerPageState extends State<CulturePlayerPage> {
  static const String _kPlayerUa =
      'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';

  // 兜底源（桌面版）要用桌面 UA：用移动 UA 打开 www.bilibili.com 会被跳到 m 站。
  static const String _kDesktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  WebViewController? _ctrl;
  int _progress = 0;
  bool _failed = false;
  bool _chrome = true; // 悬浮操作条显示/隐藏
  bool _fav = false;
  bool _done = false;
  bool _grabbing = false;
  String _grabMsg = '';

  PlayTarget? _target;
  int _tryIdx = 0; // 0 主地址 / 1 备用地址 / 2 桌面版兜底
  bool _probing = false;
  bool _loginMode = false;
  String _failHint = '';

  String get _url => cultureNormalizeUrl('${widget.item['url'] ?? ''}');

  /// 依次尝试的地址：平台播放器 → 官方 iframe → 桌面版页面。
  List<String> get _sources {
    final t = _target;
    if (t == null) return [_url];
    return [t.primary, t.fallback, t.desktop]
        .where((e) => e.isNotEmpty)
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _fav = (widget.item['fav'] as num?)?.toInt() == 1;
    _done = (widget.item['state'] as num?)?.toInt() == 2;
    _init();
  }

  /// 先把链接翻译成「平台自己的播放器页」，再喂给 WebView。
  ///
  /// 关键差别：m.bilibili.com 那种落地页满屏「打开App」，点了就跳出；
  /// blackboard/html5mobileplayer 只有播放器，才叫站内播放。
  Future<void> _init() async {
    if (_url.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    PlayTarget t;
    try {
      t = await buildPlayTarget(
        url: _url,
        platform: '${widget.item['platform'] ?? ''}',
        knownExtId: '${widget.item['ext_id'] ?? ''}',
      );
    } catch (_) {
      t = PlayTarget(primary: _url);
    }
    if (!mounted) return;
    setState(() => _target = t);
    await _bindController();
  }

  Future<void> _bindController() async {
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      // 不带 "wv" 标记的移动 Chrome UA：带 wv 会被一些站点直接判为「内嵌浏览器」
      // 并强制跳 App。
      ..setUserAgent(_kPlayerUa)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        onPageFinished: _afterLoad,
        onWebResourceError: (e) {
          if (e.isForMainFrame == true && mounted) {
            setState(() {
              _failed = true;
              _failHint = '页面打不开：${e.description}';
            });
          }
        },
        onNavigationRequest: (req) {
          final u = req.url;
          // bilibili:// bytedance:// snssdk1128:// intent:// market://
          // 这类都是「把我踢到别的 App」，一律拦下，然后告诉用户已拦。
          if (!u.startsWith('http')) {
            _snack('已拦下「跳到其它 App」，这条留在这里看');
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ));
    if (!mounted) return;
    setState(() => _ctrl = c);
    await _loadSource(0);
  }

  /// 切到第 i 个源。桌面版兜底要同时把 UA 换掉。
  Future<void> _loadSource(int i) async {
    final list = _sources;
    if (list.isEmpty) return;
    final idx = i.clamp(0, list.length - 1);
    _tryIdx = idx;
    final c = _ctrl;
    if (c == null) {
      await _bindController();
      return;
    }
    final desktop = _target?.kind == 'bili' && idx == 2;
    try {
      await c.setUserAgent(desktop ? _kDesktopUa : _kPlayerUa);
    } catch (_) {}
    await _loadUrl(list[idx]);
  }

  Future<void> _loadUrl(String u) async {
    if (u.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    setState(() {
      _progress = 0;
      _failed = false;
    });
    try {
      await _ctrl?.loadRequest(Uri.parse(u));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _afterLoad(String url) {
    _applyImmersive();
    // 登录页自己跳回站内 = 登录完成，自动回到这条视频。
    if (_loginMode) {
      final lower = url.toLowerCase();
      if (!lower.contains('passport') && !lower.contains('login')) {
        _loginMode = false;
        _retryFromPrimary();
      }
      return;
    }
    final t = _target;
    if (t != null && t.isPlatformPlayer) _probeVideo();
  }

  /// 平台播放器页加载完不代表真的出画面：
  /// 页面可能只是白底 + 一句「该视频无法播放」。这里探一次 DOM，
  /// 没有 <video> 就换备用源，换完还没有才认输。
  Future<void> _probeVideo() async {
    if (_probing) return;
    _probing = true;
    try {
      for (final ms in [2200, 4200]) {
        await Future.delayed(Duration(milliseconds: ms));
        if (!mounted || _loginMode) return;
        if (await _hasPlayer()) {
          if (mounted) setState(() => _failed = false);
          return;
        }
      }
      if (!mounted) return;
      final t = _target;
      if (_tryIdx + 1 < _sources.length) {
        await _loadSource(_tryIdx + 1);
        return;
      }
      if (!mounted) return;
      setState(() {
        _failed = true;
        _failHint = t != null && t.kind == 'douyin'
            ? '抖音这个视频没开放站内播放（多数要作者授权或登录）'
            : 'B站没给画面，可能是这个视频限制了外链播放';
      });
    } finally {
      _probing = false;
    }
  }

  Future<bool> _hasPlayer() async {
    final c = _ctrl;
    if (c == null) return false;
    try {
      // B站用的是 bwp-video 自定义元素（video 在 shadow DOM 里），
      // 只查 'video' 会误判成「没画面」。
      final r = await c.runJavaScriptReturningResult(
          "(function(){var v=document.querySelector("
          "'video, bwp-video, .mplayer-video-wrap, .bpx-player-video-wrap');"
          "if(!v) return 'no';"
          "return 'yes';})()");
      final s = '$r';
      // 有 video 元素就算播起来了（src 可能还在协商）。
      return !s.contains('no');
    } catch (_) {
      return false;
    }
  }

  void _retryFromPrimary() {
    final c = _ctrl;
    if (c == null) {
      // 控制器还没建好（解析播放地址失败过），重走一遍绑定。
      _bindController();
      return;
    }
    _loadSource(0);
  }

  /// 沉浸模式：把平台自带的「推荐流 / 下一个视频 / 侧栏」藏掉。
  ///
  /// 这不是破解，只是隐藏页面元素，让这一页只剩正在看的这条内容。
  /// 站点改版后选择器可能失效，失效也只是回到原始页面，不影响播放。
  Future<void> _applyImmersive() async {
    final c = _ctrl;
    if (c == null) return;
    const js = r'''
(function(){
  if (window.__dtImmersive) return;
  window.__dtImmersive = true;
  var css = `
    /* 抖音 web：右侧推荐、底部切换、顶部导航 */
    div[class*="recommend"], div[class*="sidebar"], div[class*="Sidebar"],
    div[class*="related"], div[class*="Related"], div[class*="comment"],
    div[class*="Comment"], div[class*="feed-item"], footer,
    [data-e2e="recommend-list"], [data-e2e="comment-list"] { display:none !important; }
    /* B站：相关推荐、评论、底部栏 */
    .recommend-list, .related, .comment, #comment, .bili-header,
    .video-toolbar, .up-info-container .follow-btn { display:none !important; }
    html, body { overflow:hidden !important; }
  `;
  var s = document.createElement('style');
  s.id = '__dt_immersive';
  s.textContent = css;
  document.documentElement.appendChild(s);
  // 抖音 web 允许整页纵向滑，禁用掉，避免误触滑到下一个视频
  document.addEventListener('touchmove', function(e){
    var t = e.target;
    if (t && t.closest && t.closest('video, .xgplayer, #bilibili-player')) return;
    if (e.touches && e.touches.length > 1) return;
    // 只拦纵向单指滑动
    if (Math.abs(e.touches[0].clientX) < 1) return;
  }, {passive: true});
})();
''';
    try {
      await c.runJavaScript(js);
    } catch (_) {}
  }

  Future<void> _toggleFav() async {
    setState(() => _fav = !_fav);
    await widget.db.update('culture_items', {'fav': _fav ? 1 : 0},
        where: 'id = ?', whereArgs: [widget.item['id']]);
    if (widget.onChanged != null) await widget.onChanged!();
  }

  Future<void> _markDone() async {
    setState(() => _done = !_done);
    await widget.db.update(
        'culture_items',
        {'state': _done ? 2 : 1, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [widget.item['id']]);
    await CultureDb.refreshSignals(widget.db);
    if (widget.onChanged != null) await widget.onChanged!();
    _snack(_done ? '已标记看完' : '已标记未看');
  }

  /// 从当前页面抓正文，存进 culture_items.content_text，供 DeepSeek 用。
  Future<void> _grabText() async {
    final c = _ctrl;
    if (c == null || _grabbing) return;
    setState(() {
      _grabbing = true;
      _grabMsg = '正在取正文…';
    });
    String text = '';
    try {
      final raw = await c.runJavaScriptReturningResult(
          'document.body ? document.body.innerText : ""');
      text = '${raw}'.replaceAll('\\n', '\n').trim();
      // runJavaScriptReturningResult 在 Android 上返回的是带引号的 JSON 字符串
      if (text.startsWith('"') && text.endsWith('"')) {
        try {
          text = jsonDecode(text) as String;
        } catch (_) {}
      }
    } catch (_) {}
    if (text.length < 40) {
      // WebView 拿不到就用网络兜底（B站简介 / og 描述）。
      text = await fetchContentText(_url);
    }
    if (text.length > 8000) text = text.substring(0, 8000);
    if (text.trim().isEmpty) {
      setState(() {
        _grabbing = false;
        _grabMsg = '这页不让取正文，可以直接用标题 + 你的笔记生成';
      });
      return;
    }
    try {
      await widget.db.update('culture_items', {'content_text': text},
          where: 'id = ?', whereArgs: [widget.item['id']]);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _grabbing = false;
      _grabMsg = '已取到 ${text.length} 字，生成时会带上';
    });
  }

  Future<void> _openKitStudio() async {
    final rows = await widget.db.query('culture_items',
        where: 'id = ?', whereArgs: [widget.item['id']], limit: 1);
    final item = rows.isEmpty ? widget.item : rows.first;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => KitStudioPage(db: widget.db, item: Map<String, dynamic>.from(item)),
    ));
  }

  /// 平台登录：在同一个 WebView 里打开登录页，cookie 由系统 WebView 持久化。
  /// 登录页跳回站内后会自动回到这条视频（见 _afterLoad）。
  Future<void> _login() async {
    final p = '${widget.item['platform'] ?? ''}';
    final String url;
    if (p == 'B站') {
      url = 'https://passport.bilibili.com/login';
    } else if (p == '抖音') {
      url = 'https://www.douyin.com/';
    } else if (p == '小红书') {
      url = 'https://www.xiaohongshu.com/';
    } else if (p == '知乎') {
      url = 'https://www.zhihu.com/signin';
    } else {
      url = '${widget.item['url'] ?? ''}';
    }
    try {
      setState(() => _loginMode = true);
      await _loadUrl(url);
      _snack('登录完会自动回到这条');
    } catch (_) {
      setState(() => _loginMode = false);
      _snack('打不开登录页');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 12.5)),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final title = '${widget.item['title'] ?? ''}';
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        if (_failed)
          _fallback()
        else if (_ctrl == null)
          const Center(child: CircularProgressIndicator(color: Colors.white54))
        else
          WebViewWidget(controller: _ctrl!),
        // 顶部悬浮条
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: _chrome ? 1 : 0,
            child: IgnorePointer(
              ignoring: !_chrome,
              child: Container(
                padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top + 6,
                    left: 6,
                    right: 6,
                    bottom: 8),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xCC000000), Color(0x00000000)],
                  ),
                ),
                child: Row(children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, size: 21, color: Colors.white),
                  ),
                  Expanded(
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: Colors.white)),
                  ),
                  TextButton(
                    onPressed: _loginMode
                        ? () {
                            setState(() => _loginMode = false);
                            _retryFromPrimary();
                          }
                        : _login,
                    style: TextButton.styleFrom(
                        foregroundColor: Colors.white, minimumSize: Size.zero),
                    child: Text(_loginMode ? '回到视频' : '登录',
                        style: const TextStyle(fontSize: 11.5)),
                  ),
                  IconButton(
                    tooltip: '重播',
                    onPressed: _retryFromPrimary,
                    icon: const Icon(Icons.refresh, size: 19, color: Colors.white70),
                  ),
                ]),
              ),
            ),
          ),
        ),
        if (_progress > 0 && _progress < 100)
          Positioned(
            top: MediaQuery.of(context).padding.top + 2,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              value: _progress / 100,
              minHeight: 2,
              backgroundColor: Colors.transparent,
              valueColor: const AlwaysStoppedAnimation(Color(0xFF38BDF8)),
            ),
          ),
        // 底部操作条
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: _chrome ? 1 : 0,
            child: IgnorePointer(
              ignoring: !_chrome,
              child: Container(
                padding: EdgeInsets.fromLTRB(
                    10, 8, 10, MediaQuery.of(context).padding.bottom + 8),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xD9000000), Color(0x00000000)],
                  ),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (_grabMsg.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(_grabMsg,
                          style: const TextStyle(fontSize: 10, color: Colors.white54)),
                    ),
                  Row(children: [
                    _barBtn(
                      icon: _fav ? Icons.star : Icons.star_border,
                      label: _fav ? '已收藏' : '收藏',
                      color: _fav ? const Color(0xFFFBBF24) : Colors.white,
                      onTap: _toggleFav,
                    ),
                    _barBtn(
                      icon: _done ? Icons.check_circle : Icons.check_circle_outline,
                      label: _done ? '已看完' : '看完',
                      color: _done ? const Color(0xFF4ADE80) : Colors.white,
                      onTap: _markDone,
                    ),
                    _barBtn(
                      icon: Icons.download_for_offline_outlined,
                      label: _grabbing ? '取正文…' : '取正文',
                      onTap: _grabText,
                    ),
                    _barBtn(
                      icon: Icons.auto_fix_high,
                      label: '生成工具包',
                      color: const Color(0xFF7DD3FC),
                      onTap: _openKitStudio,
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => setState(() => _chrome = false),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                        child: Icon(Icons.visibility_off_outlined,
                            size: 17, color: Colors.white38),
                      ),
                    ),
                  ]),
                ]),
              ),
            ),
          ),
        ),
        // 点空白处把悬浮条叫回来
        if (!_chrome)
          Positioned(
            right: 10,
            bottom: MediaQuery.of(context).padding.bottom + 14,
            child: GestureDetector(
              onTap: () => setState(() => _chrome = true),
              child: Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.tune, size: 17, color: Colors.white54),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _barBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = Colors.white,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 8.5, color: color.withOpacity(0.85))),
        ]),
      ),
    );
  }

  Widget _fallback() {
    final t = _target;
    final hint = _failHint.isNotEmpty
        ? _failHint
        : '这个页面不让站内播放';
    final why = t != null && t.kind == 'bili'
        ? 'B站播放器要求登录或限制外链时会这样。登录一次就好，之后会记住。'
        : (t != null && t.kind == 'douyin'
            ? '抖音大部分视频只在自己的 App 里播，站内播放器要作者授权。\n链接不会丢，正文仍可取，工具包照样能生成。'
            : '可以登录后重试，或者先把正文取下来生成工具包。');
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(26, 90, 26, 110),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.play_disabled_rounded, size: 44, color: Colors.white24),
          const SizedBox(height: 12),
          Text(hint,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
          const SizedBox(height: 8),
          Text(why,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11.5, height: 1.7, color: Colors.white54)),
          const SizedBox(height: 18),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.white, foregroundColor: Colors.black),
              onPressed: _retryFromPrimary,
              child: const Text('换个源再试', style: TextStyle(fontSize: 12.5)),
            ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white24)),
              onPressed: _login,
              child: const Text('登录', style: TextStyle(fontSize: 12.5)),
            ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF7DD3FC),
                  side: const BorderSide(color: Color(0x557DD3FC))),
              onPressed: _openKitStudio,
              child: const Text('生成工具包', style: TextStyle(fontSize: 12.5)),
            ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Colors.white24)),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _url));
                _snack('链接已复制');
              },
              child: const Text('复制链接', style: TextStyle(fontSize: 12.5)),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ==================== 工具包工作室（DeepSeek） ====================

class KitStudioPage extends StatefulWidget {
  final Database db;
  final Map item;
  const KitStudioPage({super.key, required this.db, required this.item});

  @override
  State<KitStudioPage> createState() => _KitStudioPageState();
}

class _KitStudioPageState extends State<KitStudioPage> {
  final TextEditingController _note = TextEditingController();
  final TextEditingController _want = TextEditingController();
  final TextEditingController _key = TextEditingController();

  String _content = '';
  bool _fetching = true;
  bool _running = false;
  bool _saved = false;
  String _status = '';
  String _out = '';
  String _model = 'deepseek-flash';
  String _effort = 'high';
  DeepSeekCall? _call;

  @override
  void initState() {
    super.initState();
    _note.text = '${widget.item['note'] ?? ''}';
    _boot();
  }

  @override
  void dispose() {
    _call?.cancel();
    _note.dispose();
    _want.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    // 配置 & key
    try {
      final raw = await CultureDb.getState(widget.db, 'deepseek_ai_config');
      if (raw != null && raw.isNotEmpty) {
        final m = jsonDecode(raw) as Map;
        _model = '${m['model'] ?? 'deepseek-flash'}';
        _effort = '${m['effort'] ?? 'high'}';
      }
    } catch (_) {}
    try {
      final k = await DeepSeekKeyStore.read();
      if (k.isNotEmpty && mounted) _key.text = k;
    } catch (_) {}

    // 正文：先看有没有存过，再决定要不要联网抓
    final stored = '${widget.item['content_text'] ?? ''}'.trim();
    if (stored.isNotEmpty) {
      if (mounted) {
        setState(() {
          _content = stored;
          _fetching = false;
        });
      }
      return;
    }
    final text = await fetchContentText('${widget.item['url'] ?? ''}');
    if (!mounted) return;
    setState(() {
      _content = text;
      _fetching = false;
    });
  }

  Future<void> _generate() async {
    if (_running) return;
    if (_key.text.trim().isEmpty) {
      _snack('先填 DeepSeek API Key');
      return;
    }
    await DeepSeekKeyStore.write(_key.text.trim());
    final call = DeepSeekCall();
    _call = call;
    setState(() {
      _running = true;
      _saved = false;
      _out = '';
      _status = '正在把这条内容拆成能执行的东西…';
    });
    try {
      final res = await call.run(
        config: DeepSeekConfig(
          apiKey: _key.text.trim(),
          model: _model,
          effort: _effort,
        ),
        systemPrompt: kKitSystemPrompt,
        userPrompt: buildKitPrompt(
          item: widget.item,
          contentText: _content,
          myNote: _note.text,
          want: _want.text,
        ),
        stream: true,
        onDelta: (c, r) {
          if (!mounted || call.cancelled) return;
          setState(() => _out = c);
        },
      );
      if (!mounted) return;
      setState(() {
        _out = res.content.isEmpty ? _out : res.content;
        _running = false;
        _status = '生成完了，可以存成工具包';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _status = '$e';
      });
    }
  }

  Future<void> _saveKit() async {
    if (_out.trim().isEmpty) return;
    final now = DateTime.now().toIso8601String();
    final steps = _parseSteps(_out);
    final id = await widget.db.insert('culture_kits', {
      'title': '${widget.item['title'] ?? '内容'} · 工具包',
      'lib_id': widget.item['lib_id'] ?? 0,
      'item_id': widget.item['id'] ?? 0,
      'goal': _firstLine(_out),
      'steps': jsonEncode(steps),
      'body': _out,
      'tags': widget.item['tags'] ?? '',
      'created_at': now,
      'updated_at': now,
    });
    // 笔记回写到内容条目，下次不用重打。
    try {
      await widget.db.update('culture_items', {'note': _note.text.trim()},
          where: 'id = ?', whereArgs: [widget.item['id']]);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _saved = true);
    _snack('已保存为工具包 #$id');
  }

  String _firstLine(String md) {
    for (final line in md.split('\n')) {
      final t = line.replaceAll(RegExp(r'^[#>\-\*\s]+'), '').trim();
      if (t.isNotEmpty) return t.length > 80 ? t.substring(0, 80) : t;
    }
    return '';
  }

  List<Map<String, dynamic>> _parseSteps(String md) {
    final out = <Map<String, dynamic>>[];
    for (final line in md.split('\n')) {
      final m = RegExp(r'^\s*(?:\d+[\.\)、]|[-*])\s+(.{4,})$').firstMatch(line);
      if (m == null) continue;
      final t = m.group(1)!.replaceAll(RegExp(r'[*`_]'), '').trim();
      if (t.isEmpty) continue;
      out.add({'text': t.length > 90 ? t.substring(0, 90) : t, 'done': false});
      if (out.length >= 6) break;
    }
    return out;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 12.5)),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final title = '${widget.item['title'] ?? ''}';
    return Scaffold(
      backgroundColor: kFeedBg,
      appBar: AppBar(
        backgroundColor: kFeedBg,
        surfaceTintColor: kFeedBg,
        foregroundColor: kFeedInk,
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('生成工具包',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.white38)),
        ]),
        actions: [
          if (_out.trim().isNotEmpty)
            TextButton(
              onPressed: _saved ? null : _saveKit,
              child: Text(_saved ? '已保存' : '保存',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: _saved ? Colors.white24 : const Color(0xFF7DD3FC))),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          // 材料
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF12161F),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.article_outlined, size: 14, color: Colors.white54),
                const SizedBox(width: 5),
                const Text('这条内容的正文',
                    style: TextStyle(fontSize: 11.5, color: Colors.white70)),
                const Spacer(),
                if (_fetching)
                  const SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.6, color: Colors.white38),
                  )
                else
                  Text('${_content.length} 字',
                      style: const TextStyle(fontSize: 9.5, color: Colors.white24)),
              ]),
              const SizedBox(height: 8),
              Text(
                _fetching
                    ? '正在取…'
                    : (_content.trim().isEmpty
                        ? '没取到正文（多是平台要登录）。不影响生成：我会用标题 + 你的笔记。'
                        : _content),
                maxLines: _fetching ? 2 : 6,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.65,
                  color: _content.trim().isEmpty
                      ? Colors.white30
                      : Colors.white54,
                ),
              ),
            ]),
          ),
          const SizedBox(height: 14),
          _label('我自己的笔记（可以不填）'),
          TextField(
            controller: _note,
            maxLines: 4,
            style: const TextStyle(fontSize: 12.5, color: kFeedInk),
            decoration: _inputDeco('看完想到的、和我有关的例子、不同意的点…'),
          ),
          const SizedBox(height: 12),
          _label('我想要什么（不填就按默认：今天能照着做的步骤 + 模板 + 清单）'),
          TextField(
            controller: _want,
            maxLines: 2,
            style: const TextStyle(fontSize: 12.5, color: kFeedInk),
            decoration: _inputDeco('例：给我一套下周就能跑的短视频脚本模板'),
          ),
          const SizedBox(height: 12),
          if (_key.text.trim().isEmpty) ...[
            _label('DeepSeek API Key'),
            TextField(
              controller: _key,
              obscureText: true,
              style: const TextStyle(fontSize: 12.5, color: kFeedInk),
              decoration: _inputDeco('sk-…'),
            ),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF38BDF8),
                foregroundColor: const Color(0xFF04121C),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              onPressed: _running ? null : _generate,
              icon: _running
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white70))
                  : const Icon(Icons.auto_fix_high, size: 18),
              label: Text(_running ? '生成中…' : '让 DeepSeek 生成',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          ),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_status,
                  style: const TextStyle(fontSize: 10.5, color: Colors.white38)),
            ),
          if (_out.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white10),
              ),
              child: SelectableText(
                _out,
                style: const TextStyle(
                    fontSize: 12, height: 1.75, color: Color(0xFFE2E8F0)),
              ),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24)),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _out));
                    _snack('已复制');
                  },
                  icon: const Icon(Icons.copy, size: 15),
                  label: const Text('复制', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.white, foregroundColor: kFeedBg),
                  onPressed: _saved ? null : _saveKit,
                  child: Text(_saved ? '已保存' : '存成工具包',
                      style: const TextStyle(fontSize: 12)),
                ),
              ),
            ]),
            if (_saved)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TextButton(
                  onPressed: () async {
                    final rows = await widget.db.query('culture_kits',
                        orderBy: 'id DESC', limit: 1);
                    if (rows.isEmpty || !mounted) return;
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => CultureKitPage(
                          db: widget.db, kitId: rows.first['id'] as int),
                    ));
                  },
                  child: const Text('打开工具包看步骤',
                      style: TextStyle(fontSize: 12, color: Color(0xFF7DD3FC))),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t,
            style: const TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w700, color: Colors.white38)),
      );

  InputDecoration _inputDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 11, color: Colors.white24),
        filled: true,
        fillColor: const Color(0xFF12161F),
        isDense: true,
        contentPadding: const EdgeInsets.all(11),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: Colors.white10),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: Colors.white10),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: Color(0xFF38BDF8)),
        ),
      );
}

// ==================== 工具包列表 ====================

class CultureKitsPage extends StatefulWidget {
  final Database db;
  const CultureKitsPage({super.key, required this.db});

  @override
  State<CultureKitsPage> createState() => _CultureKitsPageState();
}

class _CultureKitsPageState extends State<CultureKitsPage> {
  List _kits = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows =
        await widget.db.query('culture_kits', orderBy: 'updated_at DESC');
    if (!mounted) return;
    setState(() {
      _kits = rows;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kFeedBg,
      appBar: AppBar(
        backgroundColor: kFeedBg,
        surfaceTintColor: kFeedBg,
        foregroundColor: kFeedInk,
        title: const Text('工具包', style: TextStyle(fontSize: 15)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.white38))
          : _kits.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      '还没有工具包。\n在推荐流里点「工具包」，让 DeepSeek 把这条内容和你的笔记拆成能执行的步骤。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, height: 1.7, color: Colors.white38),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
                  itemCount: _kits.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 9),
                  itemBuilder: (ctx, i) {
                    final k = _kits[i] as Map;
                    final steps = cultureParseSteps(k['steps'] as String?);
                    final done = steps.where((e) => e['done'] == true).length;
                    return InkWell(
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => CultureKitPage(
                              db: widget.db, kitId: k['id'] as int),
                        ));
                        _load();
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.04),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${k['title'] ?? ''}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: kFeedInk)),
                            const SizedBox(height: 5),
                            Text(
                              steps.isEmpty
                                  ? '还没有步骤，点开补'
                                  : '$done/${steps.length} 步完成',
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.white38),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
