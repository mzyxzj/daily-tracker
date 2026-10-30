import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'main.dart';

// ==================== 1. 查找与备份页面 (零尖括号防吞版) ====================
class SearchPage extends StatefulWidget {
  final Database db;
  const SearchPage({super.key, required this.db});
  @override
  State createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String _kw = '';
  bool _busy = false;
  final TextEditingController _searchCtrl = TextEditingController();

  static const List _allTables = [
    'status_items',
    'status_records',
    'status_images',
    'schedule_items',
    'schedule_records',
    'modules',
    'module_entries',
    'module_groups',
    'mindmaps',
    'ui_states',
  ];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future _load() async {
    try {
      final activeDb = await AppDatabase.instance.database;
      List groups = [];
      try {
        groups = List.from(
          await activeDb.query('module_groups', orderBy: 'sort_order ASC, id DESC'),
        );
      } catch (_) {
        try {
          groups = List.from(
            await activeDb.query('module_groups', orderBy: 'id DESC'),
          );
        } catch (_) {}
      }

      final List hits = [];
      if (_kw.trim().isNotEmpty) {
        final like = '%${_kw.trim()}%';
        try {
          final rList = await activeDb.rawQuery(
            'SELECT r.date, r.value, i.name FROM status_records r JOIN status_items i ON r.item_id = i.id WHERE r.value LIKE ? OR i.name LIKE ? ORDER BY r.date DESC LIMIT 40',
            [like, like],
          );
          for (final r in rList) {
            hits.add({'tag': '状态 · ${r['date']}', 'title': '${r['name']}', 'sub': '${r['value']}'});
          }
        } catch (_) {}

        try {
          final mList = await activeDb.query('modules', where: 'title LIKE ?', whereArgs: [like]);
          for (final m in mList) {
            hits.add({'tag': '家庭标题', 'title': '${m['title']}', 'sub': '可在家庭页查看详情'});
          }
        } catch (_) {}

        try {
          final eList = await activeDb.rawQuery(
            'SELECT e.seq, e.content, m.title FROM module_entries e JOIN modules m ON e.module_id = m.id WHERE e.content LIKE ? LIMIT 40',
            [like],
          );
          for (final e in eList) {
            hits.add({'tag': '家庭 · ${e['title']}', 'title': '${e['seq']}. ${e['content']}', 'sub': ''});
          }
        } catch (_) {}

        try {
          final sList = await activeDb.query('schedule_items', where: 'title LIKE ? OR plan_info LIKE ?', whereArgs: [like, like]);
          for (final s in sList) {
            hits.add({'tag': '日程打卡', 'title': '${s['title']}', 'sub': '${s['plan_info'] ?? ''}'});
          }
        } catch (_) {}
      }
      return {'groups': groups, 'hits': hits};
    } catch (_) {
      return {'groups': [], 'hits': []};
    }
  }

  Future _exportZip() async {
    setState(() => _busy = true);
    try {
      final activeDb = await AppDatabase.instance.database;
      try {
        await activeDb.rawQuery('PRAGMA wal_checkpoint(FULL)');
      } catch (_) {}

      final Map dataMap = {};
      for (final table in _allTables) {
        try {
          dataMap['$table'] = await activeDb.query('$table');
        } catch (_) {}
      }

      final appDir = await getApplicationDocumentsDirectory();
      final tmpDir = await getTemporaryDirectory();
      final ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final zipPath = p.join(tmpDir.path, '每日记录_备份_$ts.zip');
      if (await File(zipPath).exists()) await File(zipPath).delete();

      final jsonTempFile = File(p.join(tmpDir.path, 'data.json'));
      await jsonTempFile.writeAsString(jsonEncode(dataMap), flush: true);

      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      encoder.addFile(jsonTempFile, 'data.json');

      final imgDir = Directory(p.join(appDir.path, 'images'));
      if (await imgDir.exists()) {
        await for (final entity in imgDir.list(recursive: true)) {
          if (entity is File) {
            final rel = p.relative(entity.path, from: appDir.path).replaceAll('\\', '/');
            encoder.addFile(entity, rel);
          }
        }
      }
      encoder.close();
      await Share.shareXFiles([XFile(zipPath)], text: '每日记录全量数据备份');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出备份失败: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future _restoreFromJsonMap(Database db, Map rootMap) async {
    Map tablesMap = rootMap;
    if (!rootMap.keys.any((k) => _allTables.contains('$k'))) {
      for (final wrapKey in ['data', 'tables', 'db', 'database']) {
        if (rootMap[wrapKey] is Map) {
          tablesMap = Map.from(rootMap[wrapKey] as Map);
          break;
        }
      }
    }

    await db.transaction((txn) async {
      for (final tName in _allTables) {
        final table = '$tName';
        final rawList = tablesMap[table];
        if (rawList is! List) continue;

        final colInfo = await txn.rawQuery('PRAGMA table_info($table)');
        final validCols = colInfo.map((c) => '${c['name']}').toSet();
        if (validCols.isEmpty) continue;

        await txn.delete(table);

        for (final item in rawList) {
          if (item is! Map) continue;
          final filteredRow = <String, Object?>{};
          for (final entry in item.entries) {
            final k = '${entry.key}';
            if (validCols.contains(k)) {
              filteredRow[k] = entry.value;
            }
          }
          if (table == 'modules' &&
              validCols.contains('is_member') &&
              !filteredRow.containsKey('is_member')) {
            final pid = filteredRow['parent_id'];
            final t = '${filteredRow['title'] ?? ''}'.trim();
            if (pid == null && t.isNotEmpty && t.length <= 4 && !t.contains('宠物')) {
              filteredRow['is_member'] = 1;
            }
          }
          if (filteredRow.isNotEmpty) {
            await txn.insert(table, filteredRow, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }
    });
  }

  Future _importZip() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.any);
    if (res == null || res.files.single.path == null) return;
    setState(() => _busy = true);
    try {
      final pickedPath = res.files.single.path!;
      final bytes = await File(pickedPath).readAsBytes();
      final appDir = await getApplicationDocumentsDirectory();

      String? jsonContent;
      List? rawDbBytes;
      int restoredImages = 0;

      final lowerName = pickedPath.toLowerCase();
      if (lowerName.endsWith('.json')) {
        jsonContent = utf8.decode(bytes, allowMalformed: true);
      } else if (lowerName.endsWith('.db')) {
        rawDbBytes = bytes;
      } else {
        final archive = ZipDecoder().decodeBytes(bytes);
        for (final file in archive) {
          if (!file.isFile) continue;
          final cleanName = file.name.replaceAll('\\', '/');
          final base = p.basename(cleanName).toLowerCase();

          if (base == 'data.json' || cleanName.toLowerCase().endsWith('.json')) {
            jsonContent = utf8.decode(file.content as List<int>, allowMalformed: true);
          } else if (base == 'daily_tracker.db' || cleanName.toLowerCase().endsWith('.db')) {
            rawDbBytes = file.content as List<int>;
          } else if (!cleanName.endsWith('-wal') &&
              !cleanName.endsWith('-shm') &&
              !cleanName.endsWith('-journal')) {
            String relPath = cleanName;
            final imgIdx = cleanName.indexOf('images/');
            if (imgIdx >= 0) {
              relPath = cleanName.substring(imgIdx);
            }
            final outFile = File(p.join(appDir.path, relPath));
            await outFile.parent.create(recursive: true);
            await outFile.writeAsBytes(file.content as List<int>, flush: true);
            restoredImages++;
          }
        }
      }

      bool restoredOk = false;
      if (jsonContent != null && jsonContent.trim().isNotEmpty) {
        final decoded = jsonDecode(jsonContent) as Map;
        final activeDb = await AppDatabase.instance.database;
        await _restoreFromJsonMap(activeDb, decoded);
        restoredOk = true;
      } else if (rawDbBytes != null) {
        await AppDatabase.closeForRestore();
        await File(p.join(appDir.path, 'daily_tracker.db')).writeAsBytes(rawDbBytes.cast(), flush: true);
        restoredOk = true;
      }

      final newDb = await AppDatabase.instance.database;
      final recCnt = Sqflite.firstIntValue(await newDb.rawQuery('SELECT COUNT(*) FROM status_records')) ?? 0;
      final modCnt = Sqflite.firstIntValue(await newDb.rawQuery('SELECT COUNT(*) FROM modules')) ?? 0;
      final schedCnt = Sqflite.firstIntValue(await newDb.rawQuery('SELECT COUNT(*) FROM schedule_items')) ?? 0;

      if (mounted) {
        if (!restoredOk) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('⚠️ 未能在所选文件中识别到 data.json 备份数据！')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('🎉 导入恢复成功！已加载 $recCnt 条状态记录、$modCnt 个标题、$schedCnt 项日程、$restoredImages 张图片！'),
              duration: const Duration(seconds: 4),
            ),
          );
          setState(() {});
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('恢复失败: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future _createOrEditGroup({Map? existingGroup}) async {
    final activeDb = await AppDatabase.instance.database;
    final mods = await activeDb.query('modules', orderBy: 'sort_order ASC, id ASC');
    if (!mounted) return;

    final isEdit = existingGroup != null;
    final nameCtrl = TextEditingController(text: isEdit ? '${existingGroup['name']}' : '');
    final Set sel = {};
    if (isEdit) {
      try {
        sel.addAll((jsonDecode('${existingGroup['module_ids']}') as List).map((e) => int.parse('$e')));
      } catch (_) {}
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Row(
            children: [
              Expanded(
                child: Text(
                  isEdit ? '编辑标题组' : '新建标题组',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
              Text('已选 ${sel.length} 项', style: const TextStyle(fontSize: 12.5, color: Color(0xFF4F46E5))),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 410,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '标题组名称',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '💡 提示：直接勾选大标题将包含其全部内容；点击左侧 ▶️ 可展开细筛内部小标题',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey),
                ),
                const Divider(height: 12),
                Expanded(
                  child: ModuleTreeSelector(
                    allMods: mods,
                    selectedIds: sel,
                    onChanged: () => setS(() {}),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                if (sel.isEmpty || nameCtrl.text.trim().isEmpty) return;
                final db = await AppDatabase.instance.database;
                if (isEdit) {
                  await db.update(
                    'module_groups',
                    {
                      'name': nameCtrl.text.trim(),
                      'module_ids': jsonEncode(sel.toList()),
                    },
                    where: 'id = ?',
                    whereArgs: [existingGroup['id']],
                  );
                } else {
                  final allG = await db.query('module_groups');
                  try {
                    await db.insert('module_groups', {
                      'name': nameCtrl.text.trim(),
                      'module_ids': jsonEncode(sel.toList()),
                      'sort_order': allG.length,
                      'created_at': DateTime.now().toIso8601String(),
                    });
                  } catch (_) {
                    await db.insert('module_groups', {
                      'name': nameCtrl.text.trim(),
                      'module_ids': jsonEncode(sel.toList()),
                      'created_at': DateTime.now().toIso8601String(),
                    });
                  }
                }
                if (mounted) Navigator.pop(ctx);
                setState(() {});
              },
              child: Text(isEdit ? '保存修改' : '创建'),
            ),
          ],
        ),
      ),
    );
  }

  Future _tempView() async {
    final activeDb = await AppDatabase.instance.database;
    final mods = await activeDb.query('modules', orderBy: 'sort_order ASC, id ASC');
    if (!mounted) return;
    final Set sel = {};

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Row(
            children: [
              const Expanded(
                child: Text('临时选择查看', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ),
              Text('已选 ${sel.length} 项', style: const TextStyle(fontSize: 12.5, color: Color(0xFF4F46E5))),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 390,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '💡 提示：直接勾选大标题将包含其全部内容；点击左侧 ▶️ 可展开细筛内部小标题',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey),
                ),
                const Divider(height: 12),
                Expanded(
                  child: ModuleTreeSelector(
                    allMods: mods,
                    selectedIds: sel,
                    onChanged: () => setS(() {}),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                if (sel.isEmpty) return;
                Navigator.pop(ctx);
                _showAgg('临时查看', sel.toList());
              },
              child: const Text('查看内容'),
            ),
          ],
        ),
      ),
    );
  }

  Future _showAgg(String title, List ids) async {
    final activeDb = await AppDatabase.instance.database;
    final allMods = await activeDb.query('modules', orderBy: 'sort_order ASC, id ASC');
    final modMap = {for (final m in allMods) m['id'] as int: m};

    String fullPathOf(int id) {
      final List parts = [];
      int? cur = id;
      int guard = 0;
      while (cur != null && modMap.containsKey(cur) && guard++ < 20) {
        parts.insert(0, '${modMap[cur]!['title']}');
        cur = modMap[cur]!['parent_id'] as int?;
      }
      return parts.join(' > ');
    }

    final List data = [];
    for (final m in allMods) {
      final id = m['id'] as int;
      if (!ids.contains(id)) continue;
      final es = await activeDb.query('module_entries', where: 'module_id = ?', whereArgs: [id], orderBy: 'sort_order ASC, seq ASC');
      data.add({'title': fullPathOf(id), 'entries': es});
    }

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.78,
        builder: (_, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                FilledButton.tonalIcon(
                  onPressed: () {
                    final buf = StringBuffer();
                    for (final d in data) {
                      final es = d['entries'] as List;
                      if (es.isEmpty && data.length > 1) continue;
                      buf.writeln('【${d['title']}】');
                      for (final e in es) buf.writeln('${e['seq']}. ${e['content']}');
                      buf.writeln();
                    }
                    Clipboard.setData(ClipboardData(text: buf.toString()));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制全部内容到剪贴板')));
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('一键复制'),
                ),
              ],
            ),
            const Divider(height: 20),
            ...data.map((d) {
              final es = d['entries'] as List;
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                elevation: 0,
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('📂 ${d['title']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5, color: Color(0xFF4F46E5))),
                      const SizedBox(height: 6),
                      if (es.isEmpty)
                        const Text('（此标题下暂无直接文字条目）', style: TextStyle(color: Colors.grey, fontSize: 12)),
                      ...es.map((e) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Text('${e['seq']}. ${e['content']}', style: const TextStyle(fontSize: 13.5, height: 1.4)),
                          )),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🔍 查找', style: TextStyle(fontWeight: FontWeight.bold))),
      body: FutureBuilder(
        future: _load(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final dataMap = snap.data as Map;
          final groups = dataMap['groups'] as List;
          final hits = dataMap['hits'] as List;

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: '搜索每日状态、家庭档案、日程记录...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _kw.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _kw = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                ),
                onChanged: (v) => setState(() => _kw = v),
              ),
              const SizedBox(height: 12),
              if (_kw.trim().isNotEmpty) ...[
                Text('🔎 搜索结果 (${hits.length})：', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF475569))),
                const SizedBox(height: 6),
                if (hits.isEmpty)
                  const Card(
                    elevation: 0,
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: Text('未找到匹配内容', style: TextStyle(color: Colors.grey))),
                    ),
                  )
                else
                  ...hits.map((h) => Card(
                        elevation: 0,
                        margin: const EdgeInsets.only(bottom: 6),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: const BorderSide(color: Color(0xFFE2E8F0)),
                        ),
                        child: ListTile(
                          dense: true,
                          title: Text('[${h['tag']}] ${h['title']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                          subtitle: (h['sub'] as String).isEmpty ? null : Text('${h['sub']}', maxLines: 3, overflow: TextOverflow.ellipsis),
                        ),
                      )),
                const Divider(height: 24),
              ],
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _createOrEditGroup(),
                      icon: const Icon(Icons.add),
                      label: const Text('新建标题组'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _tempView,
                      icon: const Icon(Icons.visibility_outlined),
                      label: const Text('临时查看'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (groups.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.only(left: 4, bottom: 6),
                  child: Text('💡 长按标题组右侧 ☰ 可上下拖动调整排列位置', style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                ),
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: groups.length,
                  onReorder: (oldIdx, newIdx) async {
                    if (newIdx > oldIdx) newIdx -= 1;
                    final activeDb = await AppDatabase.instance.database;
                    final moved = groups.removeAt(oldIdx);
                    groups.insert(newIdx, moved);
                    for (int i = 0; i < groups.length; i++) {
                      try {
                        await activeDb.update(
                          'module_groups',
                          {'sort_order': i},
                          where: 'id = ?',
                          whereArgs: [groups[i]['id']],
                        );
                      } catch (_) {}
                    }
                    setState(() {});
                  },
                  itemBuilder: (ctx, idx) {
                    final g = groups[idx] as Map;
                    List ids = [];
                    try {
                      ids = (jsonDecode('${g['module_ids']}') as List).map((e) => int.parse('$e')).toList();
                    } catch (_) {}
                    return Card(
                      key: ValueKey('mgroup_${g['id']}'),
                      margin: const EdgeInsets.only(bottom: 8),
                      elevation: 0,
                      color: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: const BorderSide(color: Color(0xFFE2E8F0)),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.only(left: 14, right: 6),
                        leading: const Icon(Icons.folder_special, color: Color(0xFF4F46E5)),
                        title: Text('${g['name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('已选 ${ids.length} 项 · 点击查看', style: const TextStyle(fontSize: 12)),
                        onTap: () => _showAgg('${g['name']}', ids),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.edit_outlined, color: Colors.blueGrey, size: 20),
                              tooltip: '编辑标题组',
                              onPressed: () => _createOrEditGroup(existingGroup: g),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                              tooltip: '删除标题组',
                              onPressed: () async {
                                final activeDb = await AppDatabase.instance.database;
                                await activeDb.delete('module_groups', where: 'id = ?', whereArgs: [g['id']]);
                                setState(() {});
                              },
                            ),
                            ReorderableDragStartListener(
                              index: idx,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                                child: Icon(Icons.drag_handle, color: Colors.grey, size: 20),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
              const SizedBox(height: 12),
              const Text('💾 数据备份与恢复', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Card(
                elevation: 0,
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _busy
                      ? const Center(child: Padding(padding: EdgeInsets.all(8.0), child: CircularProgressIndicator()))
                      : Row(
                          children: [
                            Expanded(
                              child: FilledButton.tonalIcon(
                                onPressed: _exportZip,
                                icon: const Icon(Icons.upload_file),
                                label: const Text('导出备份'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _importZip,
                                icon: const Icon(Icons.download_for_offline_outlined),
                                label: const Text('导入恢复'),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class ModuleTreeSelector extends StatefulWidget {
  final List allMods;
  final Set selectedIds;
  final VoidCallback onChanged;

  const ModuleTreeSelector({
    super.key,
    required this.allMods,
    required this.selectedIds,
    required this.onChanged,
  });

  @override
  State createState() => _ModuleTreeSelectorState();
}

class _ModuleTreeSelectorState extends State<ModuleTreeSelector> {
  final Set _expanded = {};

  List _childrenOf(int? pid) =>
      widget.allMods.where((m) => m['parent_id'] == pid).toList();

  List _descendantsOf(int rootId) {
    final List res = [rootId];
    for (final c in _childrenOf(rootId)) {
      res.addAll(_descendantsOf(c['id'] as int));
    }
    return res;
  }

  Widget _buildNode(Map m, int depth) {
    final id = m['id'] as int;
    final isMember = (m['is_member'] as int? ?? 0) == 1;
    final children = _childrenOf(id);
    final hasChildren = children.isNotEmpty;
    final isExp = _expanded.contains(id);
    final subIds = _descendantsOf(id);
    final allSelected = subIds.every((sid) => widget.selectedIds.contains(sid));
    final someSelected = !allSelected && subIds.any((sid) => widget.selectedIds.contains(sid));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: depth * 18.0),
          child: Row(
            children: [
              if (hasChildren)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: Icon(
                    isExp ? Icons.arrow_drop_down : Icons.arrow_right,
                    size: 22,
                    color: const Color(0xFF4F46E5),
                  ),
                  onPressed: () => setState(() => isExp ? _expanded.remove(id) : _expanded.add(id)),
                )
              else
                const SizedBox(width: 28),
              Icon(
                isMember ? Icons.person : (depth == 0 ? Icons.folder_outlined : Icons.subdirectory_arrow_right),
                size: 16,
                color: isMember ? const Color(0xFFEC4899) : Colors.blueGrey,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    if (hasChildren) {
                      setState(() => isExp ? _expanded.remove(id) : _expanded.add(id));
                    } else {
                      setState(() {
                        widget.selectedIds.contains(id)
                            ? widget.selectedIds.remove(id)
                            : widget.selectedIds.add(id);
                      });
                      widget.onChanged();
                    }
                  },
                  child: Text(
                    '${m['title']}',
                    style: TextStyle(
                      fontWeight: depth == 0 ? FontWeight.bold : FontWeight.normal,
                      fontSize: depth == 0 ? 14.5 : 13.5,
                    ),
                  ),
                ),
              ),
              if (hasChildren)
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => setState(() => isExp ? _expanded.remove(id) : _expanded.add(id)),
                  child: Text(isExp ? '收起' : '细筛(${children.length})', style: const TextStyle(fontSize: 11.5)),
                ),
              Checkbox(
                tristate: true,
                value: allSelected ? true : (someSelected ? null : false),
                onChanged: (_) {
                  setState(() {
                    if (allSelected) {
                      widget.selectedIds.removeAll(subIds);
                    } else {
                      widget.selectedIds.addAll(subIds);
                    }
                  });
                  widget.onChanged();
                },
              ),
            ],
          ),
        ),
        if (hasChildren && isExp)
          ...children.map((c) => _buildNode(c as Map, depth + 1)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.allMods.isEmpty) {
      return const Center(child: Text('暂无家庭模块，请先在「家庭」页添加'));
    }
    final validIds = widget.allMods.map((m) => m['id'] as int).toSet();
    final roots = widget.allMods.where((m) {
      final pid = m['parent_id'] as int?;
      return pid == null || !validIds.contains(pid);
    }).toList();

    return ListView(
      children: roots.map((r) => _buildNode(r as Map, 0)).toList(),
    );
  }
}

// ==================== 2. 家庭模块页面 (零尖括号防吞版) ====================
class _MemberPalette {
  final List<Color> bgGradient;
  final List<Color> avatarGradient;
  final List<Color> badgeGradient;
  final Color borderColor;
  final Color accentColor;
  final Color titleColor;

  const _MemberPalette({
    required this.bgGradient,
    required this.avatarGradient,
    required this.badgeGradient,
    required this.borderColor,
    required this.accentColor,
    required this.titleColor,
  });
}

class FamilyPage extends StatefulWidget {
  final Database db;
  const FamilyPage({super.key, required this.db});
  @override
  State createState() => _FamilyPageState();
}

class _FamilyPageState extends State<FamilyPage> {
  final Set _expandedMods = {};
  int? _hoverTargetId;
  String? _hoverZone;
  bool _uiLoaded = false;

  static const List _memberPalettes = [
    _MemberPalette(
      bgGradient: [Color(0xFFFFF1F2), Color(0xFFF5F3FF), Color(0xFFFDF2F8)],
      avatarGradient: [Color(0xFFEC4899), Color(0xFF8B5CF6)],
      badgeGradient: [Color(0xFFF43F5E), Color(0xFFA855F7)],
      borderColor: Color(0xFFF472B6),
      accentColor: Color(0xFFDB2777),
      titleColor: Color(0xFF831843),
    ),
    _MemberPalette(
      bgGradient: [Color(0xFFEFF6FF), Color(0xFFECFEFF), Color(0xFFF0F9FF)],
      avatarGradient: [Color(0xFF2563EB), Color(0xFF06B6D4)],
      badgeGradient: [Color(0xFF3B82F6), Color(0xFF14B8A6)],
      borderColor: Color(0xFF38BDF8),
      accentColor: Color(0xFF0284C7),
      titleColor: Color(0xFF0C4A6E),
    ),
    _MemberPalette(
      bgGradient: [Color(0xFFFFFBEB), Color(0xFFFFF7ED), Color(0xFFFEF2F2)],
      avatarGradient: [Color(0xFFF59E0B), Color(0xFFEF4444)],
      badgeGradient: [Color(0xFFD97706), Color(0xFFF97316)],
      borderColor: Color(0xFFFBBF24),
      accentColor: Color(0xFFD97706),
      titleColor: Color(0xFF78350F),
    ),
    _MemberPalette(
      bgGradient: [Color(0xFFECFDF5), Color(0xFFF0FDFA), Color(0xFFF0FDF4)],
      avatarGradient: [Color(0xFF10B981), Color(0xFF0D9488)],
      badgeGradient: [Color(0xFF059669), Color(0xFF0EA5E9)],
      borderColor: Color(0xFF34D399),
      accentColor: Color(0xFF059669),
      titleColor: Color(0xFF064E3B),
    ),
    _MemberPalette(
      bgGradient: [Color(0xFFF5F3FF), Color(0xFFEEF2FF), Color(0xFFFAF5FF)],
      avatarGradient: [Color(0xFF7C3AED), Color(0xFF4F46E5)],
      badgeGradient: [Color(0xFF6D28D9), Color(0xFF2563EB)],
      borderColor: Color(0xFFA78BFA),
      accentColor: Color(0xFF6D28D9),
      titleColor: Color(0xFF311068),
    ),
    _MemberPalette(
      bgGradient: [Color(0xFFFFF1F2), Color(0xFFFFF5F5), Color(0xFFFFF7ED)],
      avatarGradient: [Color(0xFFE11D48), Color(0xFFFB7185)],
      badgeGradient: [Color(0xFFBE123C), Color(0xFFF43F5E)],
      borderColor: Color(0xFFFB7185),
      accentColor: Color(0xFFE11D48),
      titleColor: Color(0xFF881337),
    ),
  ];

  _MemberPalette _paletteForMember(String title, int memberOrderIndex, int id) {
    if (title.contains('梦')) return _memberPalettes[0] as _MemberPalette;
    if (title.contains('雁') || title.contains('冰') || title.contains('我')) return _memberPalettes[1] as _MemberPalette;
    if (title.contains('球') || title.contains('宠') || title.contains('狗')) return _memberPalettes[2] as _MemberPalette;
    if (title.contains('爸') || title.contains('父') || title.contains('妈') || title.contains('母')) return _memberPalettes[3] as _MemberPalette;
    return _memberPalettes[(memberOrderIndex + id) % _memberPalettes.length] as _MemberPalette;
  }

  @override
  void initState() {
    super.initState();
    _restoreFamilyUiState();
  }

  Future _restoreFamilyUiState() async {
    try {
      final raw = await AppDatabase.getUiState(widget.db, 'family_expanded_mods');
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List).map((e) => int.parse('$e')).toList();
        _expandedMods
          ..clear()
          ..addAll(list);
      }
    } catch (_) {}
    if (mounted) setState(() => _uiLoaded = true);
  }

  Future _saveFamilyUiState() async {
    await AppDatabase.setUiState(widget.db, 'family_expanded_mods', jsonEncode(_expandedMods.toList()));
  }

  Future _loadMods() async {
    if (!_uiLoaded) await _restoreFamilyUiState();
    final activeDb = await AppDatabase.instance.database;
    final mods = await activeDb.query('modules', orderBy: 'sort_order ASC, id ASC');
    final entries = await activeDb.query('module_entries');
    final Map entryCounts = {};
    for (final e in entries) {
      final mid = e['module_id'] as int;
      entryCounts[mid] = ((entryCounts[mid] as int?) ?? 0) + 1;
    }
    return {'mods': mods, 'counts': entryCounts};
  }

  bool _isDescendant(int dragId, int targetId, List all) {
    if (dragId == targetId) return true;
    int? cur = targetId;
    final Set visited = {};
    while (cur != null && !visited.contains(cur)) {
      visited.add(cur);
      if (cur == dragId) return true;
      final row = all.where((m) => m['id'] == cur).firstOrNull;
      cur = row?['parent_id'] as int?;
    }
    return false;
  }

  Future _moveModule({
    required int dragId,
    required int targetId,
    required String zone,
    required List allMods,
  }) async {
    if (_isDescendant(dragId, targetId, allMods)) return;
    final activeDb = await AppDatabase.instance.database;
    final target = allMods.firstWhere((m) => m['id'] == targetId);

    if (zone == 'inside') {
      final siblings = allMods.where((m) => m['parent_id'] == targetId && m['id'] != dragId).toList();
      await activeDb.update(
        'modules',
        {'parent_id': targetId, 'sort_order': siblings.length},
        where: 'id = ?',
        whereArgs: [dragId],
      );
      _expandedMods.add(targetId);
      await _saveFamilyUiState();
    } else {
      final newParentId = target['parent_id'] as int?;
      final siblings = allMods.where((m) => m['parent_id'] == newParentId && m['id'] != dragId).toList();
      final tIdx = siblings.indexWhere((m) => m['id'] == targetId);
      final insertIdx = zone == 'up' ? math.max(0, tIdx) : math.min(siblings.length, tIdx + 1);

      final dragMap = allMods.firstWhere((m) => m['id'] == dragId);
      siblings.insert(insertIdx, dragMap);

      for (int i = 0; i < siblings.length; i++) {
        await activeDb.update(
          'modules',
          {'parent_id': newParentId, 'sort_order': i},
          where: 'id = ?',
          whereArgs: [siblings[i]['id']],
        );
      }
    }
    setState(() {});
  }

  Future _deleteModCascade(int id, List allMods) async {
    final activeDb = await AppDatabase.instance.database;
    final List subIds = [id];
    void collect(int pid) {
      for (final c in allMods.where((m) => m['parent_id'] == pid)) {
        final cid = c['id'] as int;
        subIds.add(cid);
        collect(cid);
      }
    }
    collect(id);
    for (final did in subIds) {
      await activeDb.delete('module_entries', where: 'module_id = ?', whereArgs: [did]);
      await activeDb.delete('modules', where: 'id = ?', whereArgs: [did]);
    }
    setState(() {});
  }

  bool styleMatchesLevel(String text, int level) {
    if (level == 1) {
      return RegExp(r'^[一二三四五六七八九十]+[、\.]').hasMatch(text);
    }
    return false;
  }
  String _unescapeXml(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '\x3c')
        .replaceAll('&gt;', '\x3e')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }

  Future _importFamilyDocx() async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.any);
      if (res == null || res.files.single.path == null) return null;
      final activeDb = await AppDatabase.instance.database;
      final filePath = res.files.single.path!;
      final bytes = await File(filePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      ArchiveFile? docXmlFile;
      for (final f in archive) {
        if (f.isFile && f.name == 'word/document.xml') {
          docXmlFile = f;
          break;
        }
      }
      if (docXmlFile == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未识别到标准 Word 文档结构')),
          );
        }
        return null;
      }

      final List rawBytes = docXmlFile.content as List;
      final xmlStr = utf8.decode(rawBytes.cast(), allowMalformed: true);
      final pMatches = RegExp(r'\x3cw:p\b[^\x3e]*\x3e([\s\S]*?)\x3c\/w:p\x3e').allMatches(xmlStr);

      final List parsedParas = [];

      for (final pm in pMatches) {
        final pXml = pm.group(1)!;
        final tMatches = RegExp(r'\x3cw:t(?:\s[^\x3e]*)?\x3e([\s\S]*?)\x3c\/w:t\x3e').allMatches(pXml);
        final rawText = _unescapeXml(tMatches.map((m) => m.group(1)!).join('')).trim();
        if (rawText.isEmpty) continue;

        final pStyleM = RegExp(r'\x3cw:pStyle\s+w:val="([^"]+)"').firstMatch(pXml);
        final styleVal = pStyleM?.group(1) ?? '';
        final isHeadingStyle = RegExp(r'^(Heading|标题|\d+$)', caseSensitive: false).hasMatch(styleVal);

        final ilvlM = RegExp(r'\x3cw:ilvl\s+w:val="(\d+)"').firstMatch(pXml);
        final numLevel = ilvlM != null ? int.tryParse(ilvlM.group(1)!) : null;

        final indM = RegExp(r'\x3cw:ind\b[^\x3e]*w:(?:left|firstLine)="(\d+)"').firstMatch(pXml);
        final indent = indM != null ? (int.tryParse(indM.group(1)!) ?? 0) : 0;

        final isBold = pXml.contains('\x3cw:b/\x3e') || pXml.contains('\x3cw:b ') || isHeadingStyle;

        int maxSz = 24;
        for (final sm in RegExp(r'\x3cw:sz\s+w:val="(\d+)"').allMatches(pXml)) {
          final v = int.tryParse(sm.group(1)!) ?? 24;
          if (!v.isNaN && v.compareTo(maxSz) == 1) maxSz = v;
        }

        final cleanText = rawText
            .replaceFirst(RegExp(r'^[\u25CF\u2022\u25E6\u25AA\u25A1\u25B6\uF0B7\uF0A7\-\*]+\s*'), '')
            .trim();
        if (cleanText.isEmpty) continue;

        final hasExplicitSeq = RegExp(r'^(\d+[\.、]|[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳]|[一二三四五六七八九十]+[、\.])').hasMatch(cleanText);
        final endsWithColon = cleanText.endsWith('：') || cleanText.endsWith(':');

        parsedParas.add({
          'text': rawText,
          'cleanText': cleanText,
          'isBold': isBold,
          'fontSize': maxSz,
          'indent': indent,
          'numLevel': numLevel,
          'isHeadingStyle': isHeadingStyle,
          'hasExplicitSeq': hasExplicitSeq,
          'endsWithColon': endsWithColon,
        });
      }

      if (parsedParas.isEmpty) return null;

      final List folderRanks = [];
      for (int i = 0; i != parsedParas.length; i++) {
        final cur = parsedParas[i] as Map;
        final prev = i != 0 ? (parsedParas[i - 1] as Map) : null;
        final next = (i + 1) != parsedParas.length ? (parsedParas[i + 1] as Map) : null;

        final curClean = cur['cleanText'] as String;
        final curText = cur['text'] as String;
        final curNumLvl = cur['numLevel'] as int?;
        final curIndent = cur['indent'] as int;
        final curExplicitSeq = cur['hasExplicitSeq'] as bool;
        final curHeading = cur['isHeadingStyle'] as bool;
        final curFontSz = cur['fontSize'] as int;
        final curEndsColon = cur['endsWithColon'] as bool;
        final curBold = cur['isBold'] as bool;

        final txtNoColon = curClean.replaceAll(RegExp(r'[:：]$'), '').trim();
        final nextGetsDeeper = next != null &&
            ((curNumLvl != null && next['numLevel'] != null && ((next['numLevel'] as int) - curNumLvl) >= 1) ||
                (((next['indent'] as int) - curIndent) >= 101) ||
                (!curExplicitSeq && (next['hasExplicitSeq'] as bool)));

        bool isFolder = false;
        if (curHeading || curFontSz >= 28) {
          isFolder = true;
        } else if (curEndsColon && txtNoColon.length <= 18) {
          isFolder = true;
        } else if (curBold && txtNoColon.length <= 16 && !curExplicitSeq) {
          isFolder = true;
        } else if (nextGetsDeeper && txtNoColon.length <= 20 && !curExplicitSeq) {
          isFolder = true;
        } else if (curNumLvl != null && curNumLvl <= 1 && txtNoColon.length <= 12 && !curClean.contains('，') && !curClean.contains('。')) {
          final prevWasShortFolder = prev != null && folderRanks.isNotEmpty && (folderRanks.last as int) <= 90;
          if (nextGetsDeeper || prevWasShortFolder || i == 0) {
            isFolder = true;
          }
        }

        if (!isFolder) {
          folderRanks.add(99);
        } else {
          int rank = 3;
          if (curFontSz >= 32 || styleMatchesLevel(curText, 1) || (curNumLvl == 0 && curBold)) {
            rank = 1;
          } else if (curFontSz >= 28 || curNumLvl == 0) {
            rank = 2;
          } else if (curNumLvl != null) {
            rank = 2 + curNumLvl;
          } else if (curIndent >= 1) {
            rank = 3 + (curIndent ~/ 240);
          } else if (curBold && !curEndsColon) {
            rank = 2;
          } else if (curEndsColon) {
            rank = 4;
          }
          folderRanks.add(rank);
        }
      }

      int createdFolders = 0;
      int createdEntries = 0;
      final List stack = [];

      Future createOrGetFolder(String rawTitle, int? parentId, {bool isTopLevel = false}) async {
        final cleanTitle = rawTitle
            .replaceAll(RegExp(r'[:：]$'), '')
            .replaceFirst(RegExp(r'^([一二三四五六七八九十]+[、\.]|\d+[\.、])\s*'), '')
            .trim();
        final titleToSave = cleanTitle.isEmpty ? rawTitle.trim() : cleanTitle;

        final existing = await activeDb.query(
          'modules',
          where: parentId == null ? 'title = ? AND parent_id IS NULL' : 'title = ? AND parent_id = ?',
          whereArgs: parentId == null ? [titleToSave] : [titleToSave, parentId],
        );
        if (existing.isNotEmpty) return existing.first['id'] as int;

        final siblings = await activeDb.query(
          'modules',
          where: parentId == null ? 'parent_id IS NULL' : 'parent_id = ?',
          whereArgs: parentId == null ? null : [parentId],
        );
        createdFolders++;
        return await activeDb.insert('modules', {
          'title': titleToSave,
          'parent_id': parentId,
          'is_member': (parentId == null && isTopLevel && titleToSave.length <= 6) ? 1 : 0,
          'sort_order': siblings.length,
          'created_at': DateTime.now().toIso8601String(),
        });
      }

      Future insertEntryToFolder(int folderId, String rawContent) async {
        final content = rawContent
            .replaceFirst(RegExp(r'^(\d+[\.、]|[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳])\s*'), '')
            .trim();
        if (content.isEmpty) return null;
        final existing = await activeDb.query('module_entries', where: 'module_id = ?', whereArgs: [folderId]);
        createdEntries++;
        await activeDb.insert('module_entries', {
          'module_id': folderId,
          'seq': existing.length + 1,
          'content': content,
          'sort_order': existing.length,
          'created_at': DateTime.now().toIso8601String(),
        });
      }

      for (int i = 0; i != parsedParas.length; i++) {
        final pItem = parsedParas[i] as Map;
        final cleanText = pItem['cleanText'] as String;
        final hasExplicitSeq = pItem['hasExplicitSeq'] as bool;
        final rank = folderRanks[i] as int;

        if (rank <= 90) {
          final colonIdx = cleanText.indexOf(RegExp(r'[:：]'));
          final hasInlineContent = colonIdx >= 1 && (cleanText.length - colonIdx) >= 2 && colonIdx <= 12;

          while (stack.isNotEmpty && ((stack.last as Map)['rank'] as int) >= rank) {
            stack.removeLast();
          }
          final parentId = stack.isEmpty ? null : ((stack.last as Map)['id'] as int);

          if (hasInlineContent) {
            final fTitle = cleanText.substring(0, colonIdx).trim();
            final inlineBody = cleanText.substring(colonIdx + 1).trim();
            final fid = (await createOrGetFolder(fTitle, parentId, isTopLevel: parentId == null)) as int;
            stack.add({'rank': rank, 'id': fid});
            await insertEntryToFolder(fid, inlineBody);
          } else {
            final fid = (await createOrGetFolder(cleanText, parentId, isTopLevel: parentId == null)) as int;
            stack.add({'rank': rank, 'id': fid});
          }
        } else {
          final colonIdx = cleanText.indexOf(RegExp(r'[:：]'));
          if (colonIdx >= 1 && colonIdx <= 8 && !hasExplicitSeq && (cleanText.length - colonIdx) >= 2) {
            final subTitle = cleanText.substring(0, colonIdx).trim();
            final body = cleanText.substring(colonIdx + 1).trim();
            while (stack.isNotEmpty && ((stack.last as Map)['rank'] as int) >= 8) {
              stack.removeLast();
            }
            final parentId = stack.isEmpty ? null : ((stack.last as Map)['id'] as int);
            final subFid = (await createOrGetFolder(subTitle, parentId)) as int;
            stack.add({'rank': 8, 'id': subFid});
            await insertEntryToFolder(subFid, body);
          } else {
            if (stack.isEmpty) {
              final docName = p.basenameWithoutExtension(filePath);
              final rootId = (await createOrGetFolder(docName, null, isTopLevel: true)) as int;
              stack.add({'rank': 1, 'id': rootId});
            }
            await insertEntryToFolder((stack.last as Map)['id'] as int, cleanText);
          }
        }
      }

      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('🎉 导入完成：自动构建 $createdFolders 个分级标题、导入 $createdEntries 条记录！')),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入 Word 失败：$e')));
    }
  }

  Future _openEntries(Map mod, List allMods) async {
    final activeDb = await AppDatabase.instance.database;
    final modId = mod['id'] as int;
    final modMap = {for (final m in allMods) (m as Map)['id'] as int: m};
    String fullPathOf(int id) {
      final List parts = [];
      int? cur = id;
      int guard = 0;
      while (cur != null && modMap.containsKey(cur) && guard++ <= 20) {
        parts.insert(0, '${modMap[cur]!['title']}');
        cur = modMap[cur]!['parent_id'] as int?;
      }
      return parts.join(' / ');
    }

    final fullPath = fullPathOf(modId);
    final List entries = [];
    final rawEntries = await activeDb.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC, id ASC');
    for (final r in rawEntries) {
      entries.add(Map.from(r));
    }

    if (!mounted) return null;
    final ctrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.86,
          maxChildSize: 0.96,
          builder: (_, sc) => Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, MediaQuery.of(ctx).viewInsets.bottom + 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2, right: 6),
                      child: Icon(Icons.folder_open, color: Color(0xFFF59E0B), size: 22),
                    ),
                    Expanded(
                      child: Text(
                        fullPath,
                        style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold, height: 1.3),
                      ),
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _createOrEditMod(parentId: modId, forceMember: false);
                      },
                      icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                      label: const Text('加小标题', style: TextStyle(fontSize: 13)),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 22),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: ctrl,
                        minLines: 2,
                        maxLines: 5,
                        decoration: InputDecoration(
                          hintText: '输入内容(仅按 1. / ① 序号自动拆分，普通换行保持一体)，点下方文字可编辑',
                          hintStyle: const TextStyle(fontSize: 12.5, color: Colors.grey),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                      ),
                      onPressed: () async {
                        final raw = ctrl.text.trim();
                        if (raw.isEmpty) return;
                        final db = await AppDatabase.instance.database;

                        final List itemsToInsert = [];
                        final seqRegex = RegExp(
                          r'(?:^|\n)\s*(?:\d+[\.、]|[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳]|[一二三四五六七八九十]+[、\.])\s*',
                        );
                        final matches = seqRegex.allMatches(raw).toList();

                        if (matches.isEmpty) {
                          itemsToInsert.add(raw);
                        } else {
                          if (matches.first.start >= 1) {
                            final pre = raw.substring(0, matches.first.start).trim();
                            if (pre.isNotEmpty) itemsToInsert.add(pre);
                          }
                          for (int i = 0; i != matches.length; i++) {
                            final start = matches[i].end;
                            final end = ((i + 1) != matches.length) ? matches[i + 1].start : raw.length;
                            final seg = raw.substring(start, end).trim();
                            if (seg.isNotEmpty) itemsToInsert.add(seg);
                          }
                        }

                        for (final content in itemsToInsert) {
                          final curAll = await db.query('module_entries', where: 'module_id = ?', whereArgs: [modId]);
                          await db.insert('module_entries', {
                            'module_id': modId,
                            'seq': curAll.length + 1,
                            'content': '$content',
                            'sort_order': curAll.length,
                            'created_at': DateTime.now().toIso8601String(),
                          });
                        }

                        ctrl.clear();
                        final updated = await db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC, id ASC');
                        entries
                          ..clear()
                          ..addAll(updated.map((r) => Map.from(r)));
                        setS(() {});
                        setState(() {});
                      },
                      child: const Text('添加'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: entries.isEmpty
                      ? const Center(child: Text('暂无内容条目，请在上方输入框添加', style: TextStyle(color: Colors.grey)))
                      : ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          itemCount: entries.length,
                          onReorder: (oldIdx, newIdx) async {
                            if (newIdx.compareTo(oldIdx) == 1) newIdx -= 1;
                            final db = await AppDatabase.instance.database;
                            final moved = entries.removeAt(oldIdx) as Map;
                            entries.insert(newIdx, moved);
                            for (int i = 0; i != entries.length; i++) {
                              final rowMap = Map.from(entries[i] as Map);
                              rowMap['seq'] = i + 1;
                              rowMap['sort_order'] = i;
                              entries[i] = rowMap;
                              await db.update(
                                'module_entries',
                                {'seq': i + 1, 'sort_order': i},
                                where: 'id = ?',
                                whereArgs: [rowMap['id']],
                              );
                            }
                            setS(() {});
                            setState(() {});
                          },
                          itemBuilder: (ctx, i) {
                            final e = entries[i] as Map;
                            return Padding(
                              key: ValueKey('entry_${e['id']}'),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 24,
                                    height: 24,
                                    margin: const EdgeInsets.only(right: 10, top: 1),
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEEF2FF),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '${i + 1}',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: Color(0xFF4F46E5)),
                                    ),
                                  ),
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () => _editEntryContentDialog(e, () async {
                                        final db = await AppDatabase.instance.database;
                                        final updated = await db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC, id ASC');
                                        entries
                                          ..clear()
                                          ..addAll(updated.map((r) => Map.from(r)));
                                        setS(() {});
                                        setState(() {});
                                      }),
                                      child: Text('${e['content']}', style: const TextStyle(fontSize: 14.5, height: 1.45, color: Color(0xFF1E293B))),
                                    ),
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(Icons.close, size: 18, color: Colors.redAccent),
                                    onPressed: () async {
                                      final db = await AppDatabase.instance.database;
                                      await db.delete('module_entries', where: 'id = ?', whereArgs: [e['id']]);
                                      final rem = await db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC, id ASC');
                                      for (int idx = 0; idx != rem.length; idx++) {
                                        await db.update('module_entries', {'seq': idx + 1, 'sort_order': idx}, where: 'id = ?', whereArgs: [rem[idx]['id']]);
                                      }
                                      final updated = await db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC, id ASC');
                                      entries
                                        ..clear()
                                        ..addAll(updated.map((r) => Map.from(r)));
                                      setS(() {});
                                      setState(() {});
                                    },
                                  ),
                                  ReorderableDragStartListener(
                                    index: i,
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                      child: Icon(Icons.drag_handle, size: 20, color: Colors.grey),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future _editEntryContentDialog(Map entry, VoidCallback onSaved) async {
    final ctrl = TextEditingController(text: '${entry['content']}');
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑内容', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          minLines: 3,
          maxLines: 8,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (ctrl.text.trim().isEmpty) return;
              final db = await AppDatabase.instance.database;
              await db.update(
                'module_entries',
                {'content': ctrl.text.trim()},
                where: 'id = ?',
                whereArgs: [entry['id']],
              );
              if (mounted) Navigator.pop(ctx);
              onSaved();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future _createOrEditMod({Map? editMod, int? parentId, bool forceMember = false}) async {
    final isEdit = editMod != null;
    final ctrl = TextEditingController(text: isEdit ? '${editMod['title']}' : '');
    bool isMember = isEdit ? ((editMod['is_member'] as int? ?? 0) == 1) : forceMember;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(
            isEdit ? '编辑标题' : (forceMember ? '✨ 添加家庭成员' : (parentId != null ? '添加小标题' : '新建标题')),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: forceMember ? '成员姓名（如：梦钰、雁冰、球球）' : '标题名称',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              CheckboxListTile(
                value: isMember,
                contentPadding: EdgeInsets.zero,
                title: const Text('设为高定炫彩成员卡片', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
                subtitle: const Text('启用差异化流光渐变背景、专属头像与 ✨ MEMBER 徽章', style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                onChanged: (v) => setS(() => isMember = v ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                final txt = ctrl.text.trim();
                if (txt.isEmpty) return;
                final db = await AppDatabase.instance.database;
                if (isEdit) {
                  await db.update(
                    'modules',
                    {'title': txt, 'is_member': isMember ? 1 : 0},
                    where: 'id = ?',
                    whereArgs: [editMod['id']],
                  );
                } else {
                  final siblings = await db.query(
                    'modules',
                    where: parentId == null ? 'parent_id IS NULL' : 'parent_id = ?',
                    whereArgs: parentId == null ? null : [parentId],
                  );
                  await db.insert('modules', {
                    'title': txt,
                    'parent_id': parentId,
                    'is_member': isMember ? 1 : 0,
                    'sort_order': siblings.length,
                    'created_at': DateTime.now().toIso8601String(),
                  });
                  if (parentId != null) {
                    _expandedMods.add(parentId);
                    await _saveFamilyUiState();
                  }
                }
                if (mounted) Navigator.pop(ctx);
                setState(() {});
              },
              child: Text(isEdit ? '保存' : '创建'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAestheticMemberCard({
    required Map mod,
    required List allMods,
    required bool hasChildren,
    required bool isExpanded,
    required int subBadgeCount,
    required String? zone,
    required _MemberPalette palette,
  }) {
    final id = mod['id'] as int;
    final title = '${mod['title']}';

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: zone == 'inside'
              ? [const Color(0xFFEEF2FF), const Color(0xFFE0E7FF)]
              : palette.bgGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border(
          top: BorderSide(
            color: zone == 'up' ? const Color(0xFF4F46E5) : palette.borderColor.withOpacity(0.55),
            width: zone == 'up' ? 3.0 : 1.3,
          ),
          bottom: BorderSide(
            color: zone == 'down' ? const Color(0xFF4F46E5) : palette.borderColor.withOpacity(0.55),
            width: zone == 'down' ? 3.0 : 1.3,
          ),
          left: BorderSide(
            color: zone == 'inside' ? const Color(0xFF4F46E5) : palette.borderColor.withOpacity(0.85),
            width: zone == 'inside' ? 3.0 : 4.0,
          ),
          right: BorderSide(
            color: zone == 'inside' ? const Color(0xFF4F46E5) : palette.borderColor.withOpacity(0.55),
            width: zone == 'inside' ? 3.0 : 1.3,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: palette.accentColor.withOpacity(0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (hasChildren)
            GestureDetector(
              onTap: () {
                setState(() => isExpanded ? _expandedMods.remove(id) : _expandedMods.add(id));
                _saveFamilyUiState();
              },
              child: Container(
                width: 26,
                height: 26,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.85),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isExpanded ? Icons.expand_more : Icons.chevron_right,
                  size: 19,
                  color: palette.accentColor,
                ),
              ),
            )
          else
            const SizedBox(width: 6),
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: palette.avatarGradient,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: palette.accentColor.withOpacity(0.32),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              title.isNotEmpty ? title.substring(0, 1) : '★',
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openEntries(mod, allMods),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 5,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: palette.titleColor,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: palette.badgeGradient),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      '✨ MEMBER',
                      style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 0.4),
                    ),
                  ),
                  if (subBadgeCount >= 1)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: palette.borderColor.withOpacity(0.5)),
                      ),
                      child: Text(
                        '$subBadgeCount 项',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: palette.accentColor),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: () => _createOrEditMod(parentId: id, forceMember: false),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
              child: Icon(Icons.create_new_folder_outlined, size: 19, color: palette.accentColor),
            ),
          ),
          InkWell(
            onTap: () => _createOrEditMod(editMod: mod),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
              child: Icon(Icons.edit_outlined, size: 18, color: palette.accentColor.withOpacity(0.8)),
            ),
          ),
          InkWell(
            onTap: () => _deleteModCascade(id, allMods),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 5, vertical: 4),
              child: Icon(Icons.delete_outline, size: 19, color: Colors.redAccent),
            ),
          ),
          LongPressDraggable(
            data: id,
            feedback: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: 230,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: palette.bgGradient),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: palette.accentColor, width: 1.8),
                ),
                child: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: palette.titleColor)),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.only(left: 4, right: 2, top: 4, bottom: 4),
              child: Icon(Icons.drag_handle, size: 20, color: palette.accentColor.withOpacity(0.6)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStandardFolderCard({
    required Map mod,
    required List allMods,
    required int depth,
    required bool hasChildren,
    required bool isExpanded,
    required int subBadgeCount,
    required String? zone,
  }) {
    final id = mod['id'] as int;
    final title = '${mod['title']}';

    return Container(
      decoration: BoxDecoration(
        color: zone == 'inside' ? const Color(0xFFEEF2FF) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border(
          top: BorderSide(
            color: zone == 'up' ? const Color(0xFF4F46E5) : const Color(0xFFE2E8F0),
            width: zone == 'up' ? 3.0 : 1.0,
          ),
          bottom: BorderSide(
            color: zone == 'down' ? const Color(0xFF4F46E5) : const Color(0xFFE2E8F0),
            width: zone == 'down' ? 3.0 : 1.0,
          ),
          left: BorderSide(
            color: zone == 'inside' ? const Color(0xFF4F46E5) : const Color(0xFFE2E8F0),
            width: zone == 'inside' ? 2.5 : 1.0,
          ),
          right: BorderSide(
            color: zone == 'inside' ? const Color(0xFF4F46E5) : const Color(0xFFE2E8F0),
            width: zone == 'inside' ? 2.5 : 1.0,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (hasChildren)
            GestureDetector(
              onTap: () {
                setState(() => isExpanded ? _expandedMods.remove(id) : _expandedMods.add(id));
                _saveFamilyUiState();
              },
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  isExpanded ? Icons.expand_more : Icons.chevron_right,
                  size: 20,
                  color: const Color(0xFF4F46E5),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(
              depth == 0 ? Icons.folder_outlined : Icons.subdirectory_arrow_right,
              size: 18,
              color: const Color(0xFF4F46E5),
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openEntries(mod, allMods),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 4,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: depth == 0 ? FontWeight.bold : FontWeight.w600,
                      fontSize: 14.5,
                      color: const Color(0xFF1E293B),
                    ),
                  ),
                  if (subBadgeCount >= 1)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEEF2FF),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '$subBadgeCount',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF4F46E5)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () => _createOrEditMod(parentId: id, forceMember: false),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              child: Icon(Icons.create_new_folder_outlined, size: 18, color: Color(0xFF4F46E5)),
            ),
          ),
          InkWell(
            onTap: () => _createOrEditMod(editMod: mod),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              child: Icon(Icons.edit_outlined, size: 17, color: Colors.blueGrey),
            ),
          ),
          InkWell(
            onTap: () => _deleteModCascade(id, allMods),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              child: Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
            ),
          ),
          LongPressDraggable(
            data: id,
            feedback: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 220,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF2FF),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF4F46E5), width: 1.5),
                ),
                child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              ),
            ),
            child: const Padding(
              padding: EdgeInsets.only(left: 4, right: 2, top: 3, bottom: 3),
              child: Icon(Icons.drag_handle, size: 19, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('家庭', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        actions: [
          TextButton.icon(
            onPressed: _importFamilyDocx,
            icon: const Icon(Icons.description_outlined, size: 17),
            label: const Text('导入Word', style: TextStyle(fontSize: 13)),
          ),
          TextButton.icon(
            onPressed: () => _createOrEditMod(parentId: null, forceMember: true),
            icon: const Icon(Icons.person_add_alt_1, size: 17),
            label: const Text('添加成员', style: TextStyle(fontSize: 13)),
          ),
          TextButton.icon(
            onPressed: () => _createOrEditMod(parentId: null, forceMember: false),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新标题', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
      body: FutureBuilder(
        future: _loadMods(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final dataMap = snap.data as Map;
          final mods = dataMap['mods'] as List;
          final entryCounts = dataMap['counts'] as Map;

          final validIds = mods.map((m) => (m as Map)['id'] as int).toSet();
          final roots = mods.where((m) {
            final pid = (m as Map)['parent_id'] as int?;
            return pid == null || !validIds.contains(pid);
          }).toList();

          List childrenOf(int pid) =>
              mods.where((m) => (m as Map)['parent_id'] == pid).toList();

          final memberIdList = mods.where((m) => ((m as Map)['is_member'] as int? ?? 0) == 1).map((m) => (m as Map)['id'] as int).toList();

          Widget buildDraggableModLevel(Map m, int depth) {
            final id = m['id'] as int;
            final title = '${m['title']}';
            final isMember = (m['is_member'] as int? ?? 0) == 1;
            final children = childrenOf(id);
            final hasChildren = children.isNotEmpty;
            final isExpanded = _expandedMods.contains(id);

            final subBadgeCount = hasChildren ? children.length : ((entryCounts[id] as int?) ?? 0);

            final isHover = _hoverTargetId == id;
            final zone = isHover ? _hoverZone : null;

            final memberIdx = math.max(0, memberIdList.indexOf(id));
            final palette = _paletteForMember(title, memberIdx, id);

            return Column(
              key: ValueKey('tree_mod_$id'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(left: depth * 18.0, bottom: isMember ? 9 : 6),
                  child: Builder(
                    builder: (itemCtx) => DragTarget(
                      onWillAcceptWithDetails: (details) {
                        final dragId = details.data as int;
                        return !_isDescendant(dragId, id, mods);
                      },
                      onMove: (details) {
                        final box = itemCtx.findRenderObject() as RenderBox?;
                        if (box == null) return;
                        final localY = box.globalToLocal(details.offset).dy;
                        final h = box.size.height;
                        String z;
                        if (localY.compareTo(h * 0.28) <= 0) {
                          z = 'up';
                        } else if (localY.compareTo(h * 0.72) >= 0) {
                          z = 'down';
                        } else {
                          z = 'inside';
                        }
                        if (_hoverTargetId != id || _hoverZone != z) {
                          setState(() {
                            _hoverTargetId = id;
                            _hoverZone = z;
                          });
                        }
                      },
                      onLeave: (_) {
                        if (_hoverTargetId == id) {
                          setState(() {
                            _hoverTargetId = null;
                            _hoverZone = null;
                          });
                        }
                      },
                      onAcceptWithDetails: (details) async {
                        final z = _hoverZone ?? 'inside';
                        setState(() {
                          _hoverTargetId = null;
                          _hoverZone = null;
                        });
                        await _moveModule(
                          dragId: details.data as int,
                          targetId: id,
                          zone: z,
                          allMods: mods,
                        );
                      },
                      builder: (ctx, cand, rej) {
                        if (isMember) {
                          return _buildAestheticMemberCard(
                            mod: m,
                            allMods: mods,
                            hasChildren: hasChildren,
                            isExpanded: isExpanded,
                            subBadgeCount: subBadgeCount,
                            zone: zone,
                            palette: palette,
                          );
                        }
                        return _buildStandardFolderCard(
                          mod: m,
                          allMods: mods,
                          depth: depth,
                          hasChildren: hasChildren,
                          isExpanded: isExpanded,
                          subBadgeCount: subBadgeCount,
                          zone: zone,
                        );
                      },
                    ),
                  ),
                ),
                if (hasChildren && isExpanded)
                  ...children.map((c) => buildDraggableModLevel(c as Map, depth + 1)),
              ],
            );
          }

          return mods.isEmpty
              ? const Center(child: Text('暂无家庭模块，点击右上角「+ 添加成员」或「导入Word」', style: TextStyle(color: Colors.grey)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(left: 4, bottom: 8),
                      child: Text(
                        '💡 长按右侧 ☰ 可自由拖动：拖到其他标题中央变为其小标题，拖到边缘上下排序',
                        style: TextStyle(fontSize: 11.5, color: Colors.grey),
                      ),
                    ),
                    ...roots.map((r) => buildDraggableModLevel(r as Map, 0)),
                  ],
                );
        },
      ),
    );
  }
}

// ==================== 3. 规划与思维导图模块 (零尖括号防吞版) ====================
class PlanPage extends StatefulWidget {
  final Database db;
  const PlanPage({super.key, required this.db});
  @override
  State createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  final Set _collapsedNodes = {};
  bool _uiLoaded = false;
  bool _busy = false;
  String? _hoverNodeId;
  String? _hoverZone;

  @override
  void initState() {
    super.initState();
    _restorePlanUiState();
  }

  Future _restorePlanUiState() async {
    try {
      final raw = await AppDatabase.getUiState(widget.db, 'plan_collapsed_nodes');
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List).map((e) => '$e').toList();
        _collapsedNodes
          ..clear()
          ..addAll(list);
      }
    } catch (_) {}
    if (mounted) setState(() => _uiLoaded = true);
  }

  Future _savePlanUiState() async {
    await AppDatabase.setUiState(
      widget.db,
      'plan_collapsed_nodes',
      jsonEncode(_collapsedNodes.toList()),
    );
  }

  String _genId() => '${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(99999)}';

  Map _normalizeNode(Map raw) {
    final map = Map.from(raw);
    if (map['id'] == null || '${map['id']}'.isEmpty) {
      map['id'] = _genId();
    } else {
      map['id'] = '${map['id']}';
    }
    map['text'] = '${map['text'] ?? map['title'] ?? '节点'}';
    final rawCh = map['children'];
    final List chList = [];
    if (rawCh is List) {
      for (final c in rawCh) {
        if (c is Map) chList.add(_normalizeNode(c));
      }
    }
    map['children'] = chList;
    return map;
  }

  Future _loadPlans() async {
    if (!_uiLoaded) await _restorePlanUiState();
    try {
      final activeDb = await AppDatabase.instance.database;
      return await activeDb.query('mindmaps', orderBy: 'id DESC');
    } catch (_) {
      return [];
    }
  }

  Future _save(int id, Map root) async {
    final activeDb = await AppDatabase.instance.database;
    final title = '${root['text'] ?? '规划'}'.trim();
    await activeDb.update(
      'mindmaps',
      {
        'title': title.isEmpty ? '规划' : title,
        'root_json': jsonEncode(root),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    if (mounted) setState(() {});
  }

  String _unescapeXml(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '\x3c')
        .replaceAll('&gt;', '\x3e')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }

  Map _convertXMindJsonTopic(Map topic) {
    final title = (topic['title'] ?? topic['text'] ?? '未命名节点').toString().trim();
    final List childrenList = [];
    final childrenObj = topic['children'];
    if (childrenObj is Map) {
      final attached = childrenObj['attached'];
      if (attached is List) {
        for (final c in attached) {
          if (c is Map) {
            childrenList.add(_convertXMindJsonTopic(c));
          }
        }
      }
    } else if (childrenObj is List) {
      for (final c in childrenObj) {
        if (c is Map) {
          childrenList.add(_convertXMindJsonTopic(c));
        }
      }
    }
    return {
      'id': _genId(),
      'text': title.isEmpty ? '节点' : title,
      'children': childrenList,
    };
  }

  Map? _parseLegacyXMindXml(String xmlStr) {
    final rootMatch = RegExp(r'\x3ctopic\b[^\x3e]*\x3e([\s\S]*)\x3c\/topic\x3e').firstMatch(xmlStr);
    if (rootMatch == null) return null;

    Map walkTopic(String content) {
      String title = '节点';
      final tMatch = RegExp(r'\x3ctitle[^\x3e]*\x3e([\s\S]*?)\x3c\/title\x3e').firstMatch(content);
      if (tMatch != null) {
        title = _unescapeXml(tMatch.group(1)!.replaceAll(RegExp(r'\x3c[^\x3e]+\x3e'), '').trim());
      }
      final List children = [];
      final tPos = tMatch?.end ?? 0;
      final subContent = content.substring(tPos);

      int idx = 0;
      while (idx.compareTo(subContent.length) == -1) {
        final openMatch = RegExp(r'\x3ctopic\b[^\x3e]*\x3e').firstMatch(subContent.substring(idx));
        if (openMatch == null) break;
        final startTagPos = idx + openMatch.start;
        final afterOpenPos = idx + openMatch.end;

        if (subContent.substring(startTagPos, afterOpenPos).endsWith('/\x3e')) {
          idx = afterOpenPos;
          continue;
        }

        int depth = 1;
        int scan = afterOpenPos;
        while (depth >= 1 && scan.compareTo(subContent.length) == -1) {
          final nextOpen = subContent.indexOf('\x3ctopic', scan);
          final nextClose = subContent.indexOf('\x3c/topic\x3e', scan);
          if (nextClose == -1) break;
          if (nextOpen != -1 && nextOpen.compareTo(nextClose) == -1) {
            final closeBracket = subContent.indexOf('\x3e', nextOpen);
            if (closeBracket != -1 && !subContent.substring(nextOpen, closeBracket + 1).endsWith('/\x3e')) {
              depth++;
            }
            scan = closeBracket != -1 ? closeBracket + 1 : nextOpen + 6;
          } else {
            depth--;
            if (depth == 0) {
              final childInner = subContent.substring(afterOpenPos, nextClose);
              children.add(walkTopic(childInner));
            }
            scan = nextClose + 8;
          }
        }
        idx = scan;
      }

      return {
        'id': _genId(),
        'text': title.isEmpty ? '节点' : title,
        'children': children,
      };
    }

    return walkTopic(rootMatch.group(1)!);
  }

  Future _importXMindFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.any);
      if (res == null || res.files.single.path == null) return null;
      setState(() => _busy = true);

      final filePath = res.files.single.path!;
      final bytes = await File(filePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      ArchiveFile? jsonFile;
      ArchiveFile? xmlFile;
      for (final f in archive) {
        if (!f.isFile) continue;
        if (f.name.endsWith('content.json')) jsonFile = f;
        if (f.name.endsWith('content.xml')) xmlFile = f;
      }

      Map? rootNode;
      if (jsonFile != null) {
        final List rawContent = jsonFile.content as List;
        final jsonStr = utf8.decode(rawContent.cast(), allowMalformed: true);
        final decoded = jsonDecode(jsonStr);
        if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
          final firstMap = decoded.first as Map;
          if (firstMap['rootTopic'] is Map) {
            rootNode = _convertXMindJsonTopic(firstMap['rootTopic'] as Map);
          }
        } else if (decoded is Map && decoded['rootTopic'] is Map) {
          rootNode = _convertXMindJsonTopic(decoded['rootTopic'] as Map);
        }
      } else if (xmlFile != null) {
        final List rawContent = xmlFile.content as List;
        final xmlStr = utf8.decode(rawContent.cast(), allowMalformed: true);
        rootNode = _parseLegacyXMindXml(xmlStr);
      }

      if (rootNode == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未能识别该 XMind 思维导图文件格式')),
          );
        }
        return null;
      }

      final activeDb = await AppDatabase.instance.database;
      final title = (rootNode['text'] as String? ?? p.basenameWithoutExtension(filePath)).trim();
      final now = DateTime.now().toIso8601String();
      final id = await activeDb.insert('mindmaps', {
        'title': title.isEmpty ? '导入的规划' : title,
        'root_json': jsonEncode(rootNode),
        'created_at': now,
        'updated_at': now,
      });

      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('🎉 成功导入思维导图「$title」')),
      );
      setState(() {});
      _openFullscreen(id, rootNode);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future _createMm() async {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建规划导图', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '规划主题名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final t = ctrl.text.trim();
              if (t.isEmpty) return;
              final activeDb = await AppDatabase.instance.database;
              final Map root = {
                'id': _genId(),
                'text': t,
                'children': [],
              };
              final now = DateTime.now().toIso8601String();
              final id = await activeDb.insert('mindmaps', {
                'title': t,
                'root_json': jsonEncode(root),
                'created_at': now,
                'updated_at': now,
              });
              if (mounted) {
                Navigator.pop(ctx);
                setState(() {});
                _openFullscreen(id, root);
              }
            },
            child: const Text('创建并进入'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteMindmap(int id, String title) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除规划'),
        content: Text('确定删除规划导图「$title」吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              final activeDb = await AppDatabase.instance.database;
              await activeDb.delete('mindmaps', where: 'id = ?', whereArgs: [id]);
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  bool _rm(Map parent, String targetId) {
    final ch = List.from(parent['children'] as List? ?? []);
    final idx = ch.indexWhere((c) => '${(c as Map)['id']}' == targetId);
    if (idx != -1) {
      ch.removeAt(idx);
      parent['children'] = ch;
      return true;
    }
    for (final c in ch) {
      if (c is Map && _rm(c, targetId)) return true;
    }
    return false;
  }

  bool _isDescendantNode(Map root, String dragId, String targetId) {
    if (dragId == targetId) return true;
    Map? findNode(Map cur, String id) {
      if ('${cur['id']}' == id) return cur;
      final ch = cur['children'] as List? ?? [];
      for (final c in ch) {
        if (c is Map) {
          final f = findNode(c, id);
          if (f != null) return f;
        }
      }
      return null;
    }

    final dragNode = findNode(root, dragId);
    if (dragNode == null) return false;
    return findNode(dragNode, targetId) != null;
  }

  Future _moveTreeNode({
    required int mapId,
    required Map root,
    required String dragId,
    required String targetId,
    required String zone,
    required VoidCallback onRefresh,
  }) async {
    if ('${root['id']}' == dragId || _isDescendantNode(root, dragId, targetId)) return null;

    Map? removed;
    bool extractNode(Map cur) {
      final ch = List.from(cur['children'] as List? ?? []);
      final idx = ch.indexWhere((c) => '${(c as Map)['id']}' == dragId);
      if (idx != -1) {
        removed = Map.from(ch.removeAt(idx) as Map);
        cur['children'] = ch;
        return true;
      }
      for (final c in ch) {
        if (c is Map && extractNode(c)) return true;
      }
      return false;
    }

    if (!extractNode(root) || removed == null) return null;

    if (zone == 'inside' || '${root['id']}' == targetId) {
      bool insertInside(Map cur) {
        if ('${cur['id']}' == targetId) {
          final ch = List.from(cur['children'] as List? ?? []);
          ch.add(removed!);
          cur['children'] = ch;
          _collapsedNodes.remove(targetId);
          return true;
        }
        final ch = cur['children'] as List? ?? [];
        for (final c in ch) {
          if (c is Map && insertInside(c)) return true;
        }
        return false;
      }

      insertInside(root);
      await _savePlanUiState();
    } else {
      bool insertSibling(Map cur) {
        final ch = List.from(cur['children'] as List? ?? []);
        final tIdx = ch.indexWhere((c) => '${(c as Map)['id']}' == targetId);
        if (tIdx != -1) {
          final insIdx = zone == 'up' ? tIdx : tIdx + 1;
          ch.insert(insIdx.clamp(0, ch.length), removed!);
          cur['children'] = ch;
          return true;
        }
        for (final c in ch) {
          if (c is Map && insertSibling(c)) return true;
        }
        return false;
      }

      insertSibling(root);
    }

    await _save(mapId, root);
    onRefresh();
  }

  void _onNodeAction(
    int mapId,
    Map root,
    Map node,
    bool isRoot,
    VoidCallback onRefresh,
  ) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: Color(0xFFE11D48)),
              title: const Text('编辑节点文字'),
              onTap: () {
                Navigator.pop(ctx);
                final ctrl = TextEditingController(text: '${node['text']}');
                showDialog(
                  context: context,
                  builder: (dCtx) => AlertDialog(
                    title: const Text('编辑节点', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    content: TextField(
                      controller: ctrl,
                      autofocus: true,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(border: OutlineInputBorder()),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('取消')),
                      FilledButton(
                        onPressed: () async {
                          if (ctrl.text.trim().isEmpty) return;
                          node['text'] = ctrl.text.trim();
                          await _save(mapId, root);
                          if (mounted) Navigator.pop(dCtx);
                          onRefresh();
                        },
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.subdirectory_arrow_right, color: Color(0xFF4F46E5)),
              title: const Text('添加子节点'),
              onTap: () {
                Navigator.pop(ctx);
                final ctrl = TextEditingController();
                showDialog(
                  context: context,
                  builder: (dCtx) => AlertDialog(
                    title: Text('在「${node['text']}」下添加子节点', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    content: TextField(
                      controller: ctrl,
                      autofocus: true,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(hintText: '输入子节点内容...', border: OutlineInputBorder()),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('取消')),
                      FilledButton(
                        onPressed: () async {
                          if (ctrl.text.trim().isEmpty) return;
                          final ch = List.from(node['children'] as List? ?? []);
                          ch.add({
                            'id': _genId(),
                            'text': ctrl.text.trim(),
                            'children': [],
                          });
                          node['children'] = ch;
                          _collapsedNodes.remove('${node['id']}');
                          await _savePlanUiState();
                          await _save(mapId, root);
                          if (mounted) Navigator.pop(dCtx);
                          onRefresh();
                        },
                        child: const Text('添加'),
                      ),
                    ],
                  ),
                );
              },
            ),
            if (!isRoot)
              ListTile(
                leading: const Icon(Icons.add_circle_outline, color: Color(0xFF0D9488)),
                title: const Text('添加同级节点'),
                onTap: () {
                  Navigator.pop(ctx);
                  final ctrl = TextEditingController();
                  showDialog(
                    context: context,
                    builder: (dCtx) => AlertDialog(
                      title: const Text('添加同级节点', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      content: TextField(
                        controller: ctrl,
                        autofocus: true,
                        minLines: 1,
                        maxLines: 4,
                        decoration: const InputDecoration(hintText: '输入同级节点内容...', border: OutlineInputBorder()),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('取消')),
                        FilledButton(
                          onPressed: () async {
                            if (ctrl.text.trim().isEmpty) return;
                            final targetId = '${node['id']}';
                            bool insertAfter(Map cur) {
                              final ch = List.from(cur['children'] as List? ?? []);
                              final idx = ch.indexWhere((c) => '${(c as Map)['id']}' == targetId);
                              if (idx != -1) {
                                ch.insert(idx + 1, {
                                  'id': _genId(),
                                  'text': ctrl.text.trim(),
                                  'children': [],
                                });
                                cur['children'] = ch;
                                return true;
                              }
                              for (final c in ch) {
                                if (c is Map && insertAfter(c)) return true;
                              }
                              return false;
                            }

                            insertAfter(root);
                            await _save(mapId, root);
                            if (mounted) Navigator.pop(dCtx);
                            onRefresh();
                          },
                          child: const Text('添加'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            if (!isRoot)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('删除此节点及其子节点', style: TextStyle(color: Colors.redAccent)),
                onTap: () async {
                  Navigator.pop(ctx);
                  _rm(root, '${node['id']}');
                  await _save(mapId, root);
                  onRefresh();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _openFullscreen(int mapId, Map root) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullscreenMindmapPage(
          title: '${root['text'] ?? '规划'}',
          root: root,
          collapsedNodes: _collapsedNodes,
          onToggleCollapse: (nid) {
            setState(() {
              _collapsedNodes.contains(nid)
                  ? _collapsedNodes.remove(nid)
                  : _collapsedNodes.add(nid);
            });
            _savePlanUiState();
          },
          onSaveState: _savePlanUiState,
          onNodeTap: (n, isR, refresh) => _onNodeAction(mapId, root, n, isR, refresh),
          onNodeMove: (dragId, targetId, zone, refresh) => _moveTreeNode(
            mapId: mapId,
            root: root,
            dragId: dragId,
            targetId: targetId,
            zone: zone,
            onRefresh: refresh,
          ),
          canAcceptDrop: (dragId, targetId) => !_isDescendantNode(root, dragId, targetId),
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  void _collectNonRootIds(Map node, Set out, {bool isRoot = true}) {
    final ch = node['children'] as List? ?? [];
    if (!isRoot && ch.isNotEmpty) {
      out.add('${node['id']}');
    }
    for (final c in ch) {
      if (c is Map) {
        _collectNonRootIds(c, out, isRoot: false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('🎯 规划', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        actions: [
          TextButton.icon(
            onPressed: _busy ? null : _importXMindFile,
            icon: const Icon(Icons.upload_file_outlined, size: 18),
            label: const Text('导入XMind', style: TextStyle(fontSize: 13)),
          ),
          TextButton.icon(
            onPressed: _createMm,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新规划', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
      body: FutureBuilder(
        future: _loadPlans(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final maps = snap.data as List;
          if (maps.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.account_tree_outlined, size: 54, color: Colors.grey),
                  const SizedBox(height: 10),
                  const Text('暂无规划导图，可点击右上角「导入XMind」或「+ 新规划」', style: TextStyle(color: Colors.grey, fontSize: 13)),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _importXMindFile,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('导入 XMind 思维导图'),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: maps.length,
            itemBuilder: (ctx, i) {
              final m = maps[i] as Map;
              final mapId = m['id'] as int;
              Map root;
              try {
                root = _normalizeNode(jsonDecode('${m['root_json']}') as Map);
              } catch (_) {
                root = {'id': 'root_$mapId', 'text': '${m['title']}', 'children': []};
              }

              final Set collapsibleIds = {};
              _collectNonRootIds(root, collapsibleIds);
              final anyCollapsed = collapsibleIds.any((id) => _collapsedNodes.contains(id));

              return Card(
                margin: const EdgeInsets.only(bottom: 14),
                elevation: 0,
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
                      child: Row(
                        children: [
                          const Icon(Icons.account_tree, color: Color(0xFFE11D48), size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => _openFullscreen(mapId, root),
                              child: Text(
                                '${root['text']}',
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () {
                              setState(() {
                                if (anyCollapsed) {
                                  _collapsedNodes.removeAll(collapsibleIds);
                                } else {
                                  _collapsedNodes.addAll(collapsibleIds);
                                }
                              });
                              _savePlanUiState();
                            },
                            icon: Icon(anyCollapsed ? Icons.unfold_more : Icons.unfold_less, size: 16),
                            label: Text(anyCollapsed ? '全部展开' : '全部收起', style: const TextStyle(fontSize: 12)),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '全屏查看/编辑导图',
                            icon: const Icon(Icons.fullscreen, color: Color(0xFF4F46E5)),
                            onPressed: () => _openFullscreen(mapId, root),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '删除导图',
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                            onPressed: () => _confirmDeleteMindmap(mapId, '${root['text']}'),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    SizedBox(
                      height: 340,
                      width: double.infinity,
                      child: InteractiveViewer(
                        constrained: false,
                        boundaryMargin: const EdgeInsets.all(300),
                        minScale: 0.2,
                        maxScale: 2.5,
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: XMindBranchNodeWidget(
                            node: root,
                            isRoot: true,
                            collapsedNodes: _collapsedNodes,
                            hoverNodeId: _hoverNodeId,
                            hoverZone: _hoverZone,
                            onHoverChanged: (nid, z) {
                              if (_hoverNodeId != nid || _hoverZone != z) {
                                setState(() {
                                  _hoverNodeId = nid;
                                  _hoverZone = z;
                                });
                              }
                            },
                            onToggleCollapse: (nid) {
                              setState(() {
                                _collapsedNodes.contains(nid)
                                    ? _collapsedNodes.remove(nid)
                                    : _collapsedNodes.add(nid);
                              });
                              _savePlanUiState();
                            },
                            onNodeTap: (n, isR) => _onNodeAction(mapId, root, n, isR, () {
                              if (mounted) setState(() {});
                            }),
                            canAcceptDrop: (dragId, targetId) => !_isDescendantNode(root, dragId, targetId),
                            onNodeDrop: (dragId, targetId, zone) => _moveTreeNode(
                              mapId: mapId,
                              root: root,
                              dragId: dragId,
                              targetId: targetId,
                              zone: zone,
                              onRefresh: () {
                                if (mounted) setState(() {});
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class FullscreenMindmapPage extends StatefulWidget {
  final String title;
  final Map root;
  final Set collapsedNodes;
  final void Function(String nodeId) onToggleCollapse;
  final Future Function() onSaveState;
  final void Function(Map node, bool isRoot, VoidCallback refresh) onNodeTap;
  final void Function(String dragId, String targetId, String zone, VoidCallback refresh) onNodeMove;
  final bool Function(String dragId, String targetId) canAcceptDrop;

  const FullscreenMindmapPage({
    super.key,
    required this.title,
    required this.root,
    required this.collapsedNodes,
    required this.onToggleCollapse,
    required this.onSaveState,
    required this.onNodeTap,
    required this.onNodeMove,
    required this.canAcceptDrop,
  });

  @override
  State createState() => _FullscreenMindmapPageState();
}

class _FullscreenMindmapPageState extends State<FullscreenMindmapPage> {
  bool _landscape = false;
  String? _hoverNodeId;
  String? _hoverZone;

  @override
  void dispose() {
    if (_landscape) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
    super.dispose();
  }

  void _toggleOrientation() {
    setState(() => _landscape = !_landscape);
    SystemChrome.setPreferredOrientations(
      _landscape
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp],
    );
  }

  void _collectAllCollapsibleIds(Map node, Set out, {bool isRoot = true}) {
    final ch = node['children'] as List? ?? [];
    if (!isRoot && ch.isNotEmpty) {
      out.add('${node['id']}');
    }
    for (final c in ch) {
      if (c is Map) {
        _collectAllCollapsibleIds(c, out, isRoot: false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final Set allCollapsible = {};
    _collectAllCollapsibleIds(widget.root, allCollapsible);
    final anyCollapsed = allCollapsible.any((id) => widget.collapsedNodes.contains(id));

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Text('${widget.root['text'] ?? widget.title}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        actions: [
          TextButton.icon(
            onPressed: () {
              setState(() {
                if (anyCollapsed) {
                  widget.collapsedNodes.removeAll(allCollapsible);
                } else {
                  widget.collapsedNodes.addAll(allCollapsible);
                }
              });
              widget.onSaveState();
            },
            icon: Icon(anyCollapsed ? Icons.unfold_more : Icons.unfold_less, size: 18),
            label: Text(anyCollapsed ? '全部展开' : '全部收起', style: const TextStyle(fontSize: 13)),
          ),
          TextButton.icon(
            onPressed: _toggleOrientation,
            icon: const Icon(Icons.screen_rotation_outlined, size: 17),
            label: Text(_landscape ? '切换竖屏' : '切换横屏', style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
      body: InteractiveViewer(
        constrained: false,
        boundaryMargin: const EdgeInsets.all(800),
        minScale: 0.15,
        maxScale: 3.0,
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: XMindBranchNodeWidget(
            node: widget.root,
            isRoot: true,
            collapsedNodes: widget.collapsedNodes,
            hoverNodeId: _hoverNodeId,
            hoverZone: _hoverZone,
            onHoverChanged: (nid, z) {
              if (_hoverNodeId != nid || _hoverZone != z) {
                setState(() {
                  _hoverNodeId = nid;
                  _hoverZone = z;
                });
              }
            },
            onToggleCollapse: (nid) {
              setState(() => widget.onToggleCollapse(nid));
            },
            onNodeTap: (n, isR) => widget.onNodeTap(n, isR, () {
              if (mounted) setState(() {});
            }),
            canAcceptDrop: widget.canAcceptDrop,
            onNodeDrop: (dragId, targetId, zone) => widget.onNodeMove(
              dragId,
              targetId,
              zone,
              () {
                if (mounted) setState(() {});
              },
            ),
          ),
        ),
      ),
    );
  }
}

class XMindBranchNodeWidget extends StatelessWidget {
  final Map node;
  final bool isRoot;
  final Set collapsedNodes;
  final String? hoverNodeId;
  final String? hoverZone;
  final void Function(String? nodeId, String? zone) onHoverChanged;
  final void Function(String nodeId) onToggleCollapse;
  final void Function(Map node, bool isRoot) onNodeTap;
  final bool Function(String dragId, String targetId) canAcceptDrop;
  final void Function(String dragId, String targetId, String zone) onNodeDrop;

  const XMindBranchNodeWidget({
    super.key,
    required this.node,
    required this.isRoot,
    required this.collapsedNodes,
    required this.hoverNodeId,
    required this.hoverZone,
    required this.onHoverChanged,
    required this.onToggleCollapse,
    required this.onNodeTap,
    required this.canAcceptDrop,
    required this.onNodeDrop,
  });

  Widget _buildPillCard(String text, {required String? zone, bool isFeedback = false}) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 245, minWidth: 54),
      padding: EdgeInsets.symmetric(
        horizontal: isRoot ? 16 : 12,
        vertical: isRoot ? 10 : 8,
      ),
      decoration: BoxDecoration(
        color: zone == 'inside'
            ? const Color(0xFFFFE4E6)
            : (isRoot ? const Color(0xFFEF5350) : const Color(0xFFFFF5F5)),
        borderRadius: BorderRadius.circular(isRoot ? 10 : 7),
        border: Border(
          top: BorderSide(
            color: zone == 'up'
                ? const Color(0xFFD32F2F)
                : (isRoot ? const Color(0xFFEF5350) : const Color(0xFFE5A3A3)),
            width: zone == 'up' ? 3.5 : 1.2,
          ),
          bottom: BorderSide(
            color: zone == 'down'
                ? const Color(0xFFD32F2F)
                : (isRoot ? const Color(0xFFEF5350) : const Color(0xFFE5A3A3)),
            width: zone == 'down' ? 3.5 : 1.2,
          ),
          left: BorderSide(
            color: zone == 'inside'
                ? const Color(0xFFD32F2F)
                : (isRoot ? const Color(0xFFEF5350) : const Color(0xFFE5A3A3)),
            width: zone == 'inside' ? 2.5 : 1.2,
          ),
          right: BorderSide(
            color: zone == 'inside'
                ? const Color(0xFFD32F2F)
                : (isRoot ? const Color(0xFFEF5350) : const Color(0xFFE5A3A3)),
            width: zone == 'inside' ? 2.5 : 1.2,
          ),
        ),
        boxShadow: isFeedback
            ? const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 3))]
            : null,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: isRoot ? 15.5 : 13.8,
          fontWeight: isRoot ? FontWeight.bold : FontWeight.w500,
          color: isRoot && zone != 'inside' ? Colors.white : const Color(0xFF1E293B),
          height: 1.35,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final id = '${node['id']}';
    final text = '${node['text'] ?? ''}';
    final children = node['children'] as List? ?? [];
    final isCollapsed = !isRoot && collapsedNodes.contains(id);

    final isHovered = hoverNodeId == id;
    final zone = isHovered ? hoverZone : null;

    final pillWithDrag = Builder(
      builder: (itemCtx) => DragTarget(
        onWillAcceptWithDetails: (details) => canAcceptDrop('${details.data}', id),
        onMove: (details) {
          final box = itemCtx.findRenderObject() as RenderBox?;
          if (box == null) return;
          final localY = box.globalToLocal(details.offset).dy;
          final h = box.size.height;
          String z;
          if (isRoot) {
            z = 'inside';
          } else if (localY.compareTo(h * 0.28) <= 0) {
            z = 'up';
          } else if (localY.compareTo(h * 0.72) >= 0) {
            z = 'down';
          } else {
            z = 'inside';
          }
          onHoverChanged(id, z);
        },
        onLeave: (_) {
          if (hoverNodeId == id) onHoverChanged(null, null);
        },
        onAcceptWithDetails: (details) {
          final z = hoverZone ?? 'inside';
          onHoverChanged(null, null);
          onNodeDrop('${details.data}', id, z);
        },
        builder: (ctx, cand, rej) {
          final pill = GestureDetector(
            onTap: () => onNodeTap(node, isRoot),
            child: _buildPillCard(text, zone: zone),
          );
          if (isRoot) return pill;
          return LongPressDraggable(
            data: id,
            feedback: Material(
              color: Colors.transparent,
              child: _buildPillCard(text, zone: null, isFeedback: true),
            ),
            childWhenDragging: Opacity(opacity: 0.35, child: pill),
            child: pill,
          );
        },
      ),
    );

    if (children.isEmpty) {
      return pillWithDrag;
    }

    if (isCollapsed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          pillWithDrag,
          Container(width: 10, height: 1.5, color: const Color(0xFFEF5350)),
          GestureDetector(
            onTap: () => onToggleCollapse(id),
            child: Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: Color(0xFFEF5350),
                shape: BoxShape.circle,
              ),
              child: Text(
                '${children.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      );
    }

    final parentWithToggle = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        pillWithDrag,
        if (!isRoot) ...[
          Container(width: 10, height: 1.5, color: const Color(0xFFEF5350)),
          GestureDetector(
            onTap: () => onToggleCollapse(id),
            child: Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFEF5350), width: 1.3),
              ),
              child: const Text(
                '-',
                style: TextStyle(
                  color: Color(0xFFEF5350),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  height: 1.0,
                ),
              ),
            ),
          ),
        ],
      ],
    );

    return _XMindTreeRow(
      parentWidget: parentWithToggle,
      childWidgets: children
          .map(
            (c) => XMindBranchNodeWidget(
              key: ValueKey('xm_node_${(c as Map)['id']}'),
              node: c,
              isRoot: false,
              collapsedNodes: collapsedNodes,
              hoverNodeId: hoverNodeId,
              hoverZone: hoverZone,
              onHoverChanged: onHoverChanged,
              onToggleCollapse: onToggleCollapse,
              onNodeTap: onNodeTap,
              canAcceptDrop: canAcceptDrop,
              onNodeDrop: onNodeDrop,
            ),
          )
          .toList(),
    );
  }
}

class _XMindTreeRow extends StatefulWidget {
  final Widget parentWidget;
  final List childWidgets;

  const _XMindTreeRow({
    required this.parentWidget,
    required this.childWidgets,
  });

  @override
  State createState() => _XMindTreeRowState();
}

class _XMindTreeRowState extends State<_XMindTreeRow> {
  final GlobalKey _rowKey = GlobalKey();
  final GlobalKey _parentKey = GlobalKey();
  late List _childKeys;
  double? _parentY;
  List _childYs = [];

  @override
  void initState() {
    super.initState();
    _initKeys();
  }

  @override
  void didUpdateWidget(covariant _XMindTreeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _initKeys();
  }

  void _initKeys() {
    _childKeys = List.generate(widget.childWidgets.length, (_) => GlobalKey());
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    if (!mounted) return;
    final rowBox = _rowKey.currentContext?.findRenderObject() as RenderBox?;
    final pBox = _parentKey.currentContext?.findRenderObject() as RenderBox?;
    if (rowBox == null || pBox == null || !rowBox.hasSize || !pBox.hasSize) return;

    final pCenter = pBox.localToGlobal(Offset(0, pBox.size.height / 2), ancestor: rowBox).dy;
    final List cYs = [];
    for (final k in _childKeys) {
      final cBox = (k as GlobalKey).currentContext?.findRenderObject() as RenderBox?;
      if (cBox != null && cBox.hasSize) {
        cYs.add(cBox.localToGlobal(Offset(0, cBox.size.height / 2), ancestor: rowBox).dy);
      }
    }

    if (_parentY != pCenter || _childYs.length != cYs.length) {
      setState(() {
        _parentY = pCenter;
        _childYs = cYs;
      });
    } else {
      bool changed = false;
      for (int i = 0; i != cYs.length; i++) {
        if (((_childYs[i] as double) - (cYs[i] as double)).abs().compareTo(0.5) == 1) {
          changed = true;
          break;
        }
      }
      if (changed) {
        setState(() {
          _parentY = pCenter;
          _childYs = cYs;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    return IntrinsicHeight(
      key: _rowKey,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(key: _parentKey, child: widget.parentWidget),
          SizedBox(
            width: 32,
            height: double.infinity,
            child: CustomPaint(
              painter: _XMindBracketPainter(
                parentY: _parentY,
                childYs: _childYs,
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: List.generate(widget.childWidgets.length, (i) {
              return Padding(
                key: _childKeys[i] as GlobalKey,
                padding: EdgeInsets.only(
                  top: i == 0 ? 0 : 7,
                  bottom: i == widget.childWidgets.length - 1 ? 0 : 7,
                ),
                child: widget.childWidgets[i] as Widget,
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _XMindBracketPainter extends CustomPainter {
  final double? parentY;
  final List childYs;

  _XMindBracketPainter({required this.parentY, required this.childYs});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFEF5350)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final pY = parentY ?? (size.height / 2);
    if (childYs.isEmpty) {
      canvas.drawLine(Offset(0, pY), Offset(size.width, pY), paint);
      return;
    }

    final midX = size.width * 0.45;
    canvas.drawLine(Offset(0, pY), Offset(midX, pY), paint);

    double minY = pY;
    double maxY = pY;
    for (final rawCy in childYs) {
      final cy = rawCy as double;
      if (cy.compareTo(minY) == -1) minY = cy;
      if (cy.compareTo(maxY) == 1) maxY = cy;
    }
    if ((maxY - minY).abs().compareTo(0.5) == 1) {
      canvas.drawLine(Offset(midX, minY), Offset(midX, maxY), paint);
    }

    for (final rawCy in childYs) {
      final cy = rawCy as double;
      canvas.drawLine(Offset(midX, cy), Offset(size.width, cy), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _XMindBracketPainter oldDelegate) {
    if (oldDelegate.parentY != parentY || oldDelegate.childYs.length != childYs.length) {
      return true;
    }
    for (int i = 0; i != childYs.length; i++) {
      if (((oldDelegate.childYs[i] as double) - (childYs[i] as double)).abs().compareTo(0.5) == 1) {
        return true;
      }
    }
    return false;
  }
}
