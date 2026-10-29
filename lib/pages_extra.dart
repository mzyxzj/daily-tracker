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

// ==================== 1. 查找与备份页面 (原生支持 data.json + images 备份恢复 + 标题组上下拖拽) ====================
class SearchPage extends StatefulWidget {
  final Database db;
  const SearchPage({super.key, required this.db});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String _kw = '';
  bool _busy = false;
  final TextEditingController _searchCtrl = TextEditingController();

  static const List<String> _allTables = [
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

  Future<Map<String, dynamic>> _load() async {
    final activeDb = await AppDatabase.instance.database;
    List<Map<String, dynamic>> groups;
    try {
      groups = List<Map<String, dynamic>>.from(
        await activeDb.query('module_groups', orderBy: 'sort_order ASC, id DESC'),
      );
    } catch (_) {
      groups = List<Map<String, dynamic>>.from(
        await activeDb.query('module_groups', orderBy: 'id DESC'),
      );
    }
    final hits = <Map<String, dynamic>>[];
    if (_kw.trim().isNotEmpty) {
      final like = '%${_kw.trim()}%';
      for (final r in await activeDb.rawQuery(
        'SELECT r.date, r.value, i.name FROM status_records r JOIN status_items i ON r.item_id = i.id WHERE r.value LIKE ? OR i.name LIKE ? ORDER BY r.date DESC LIMIT 40',
        [like, like],
      )) {
        hits.add({'tag': '状态 · ${r['date']}', 'title': '${r['name']}', 'sub': '${r['value']}'});
      }
      for (final m in await activeDb.query('modules', where: 'title LIKE ?', whereArgs: [like])) {
        hits.add({'tag': '家庭标题', 'title': '${m['title']}', 'sub': '可在家庭页查看详情'});
      }
      for (final e in await activeDb.rawQuery(
        'SELECT e.seq, e.content, m.title FROM module_entries e JOIN modules m ON e.module_id = m.id WHERE e.content LIKE ? LIMIT 40',
        [like],
      )) {
        hits.add({'tag': '家庭 · ${e['title']}', 'title': '${e['seq']}. ${e['content']}', 'sub': ''});
      }
      for (final s in await activeDb.query('schedule_items', where: 'title LIKE ? OR plan_info LIKE ?', whereArgs: [like, like])) {
        hits.add({'tag': '日程打卡', 'title': '${s['title']}', 'sub': '${s['plan_info'] ?? ''}'});
      }
    }
    return {'groups': groups, 'hits': hits};
  }

  /// 导出备份：统一采用 data.json + images/ 结构（同时附带 daily_tracker.db 双保险）
  Future<void> _exportBackup() async {
    setState(() => _busy = true);
    try {
      final activeDb = await AppDatabase.instance.database;
      final dataMap = <String, dynamic>{};
      for (final table in _allTables) {
        try {
          dataMap[table] = await activeDb.query(table);
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('备份失败: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 将解析出的 data.json 映射安全写入当前 SQLite 数据库（自动校验列名兼容跨版本结构）
  Future<void> _restoreFromJsonMap(Database db, Map<String, dynamic> rootMap) async {
    // 兼容可能外层包了一层 data / tables 节点或直接以表名为顶层 Key 的结构
    Map<String, dynamic> tablesMap = rootMap;
    if (!rootMap.keys.any((k) => _allTables.contains(k))) {
      for (final wrapKey in ['data', 'tables', 'db', 'database']) {
        if (rootMap[wrapKey] is Map) {
          tablesMap = Map<String, dynamic>.from(rootMap[wrapKey] as Map);
          break;
        }
      }
    }

    await db.transaction((txn) async {
      for (final table in _allTables) {
        final rawList = tablesMap[table];
        if (rawList is! List) continue;

        final colInfo = await txn.rawQuery('PRAGMA table_info($table)');
        final validCols = colInfo.map((c) => '${c['name']}').toSet();
        if (validCols.isEmpty) continue;

        await txn.delete(table);

        for (final item in rawList) {
          if (item is! Map) continue;
          final filteredRow = <String, dynamic>{};
          for (final entry in item.entries) {
            final k = '${entry.key}';
            if (validCols.contains(k)) {
              filteredRow[k] = entry.value;
            }
          }
          // 若旧版家庭模块顶级标题未包含 is_member 字段，智能标记顶级短名为成员卡片
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

  /// 导入恢复：原生支持读取 zip 内的 data.json + images/，同时兼容单个 .json 或 .db 文件
  Future<void> _importBackup() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.any);
    if (res == null || res.files.single.path == null) return;
    setState(() => _busy = true);
    try {
      final pickedPath = res.files.single.path!;
      final bytes = await File(pickedPath).readAsBytes();
      final appDir = await getApplicationDocumentsDirectory();

      String? jsonContent;
      List<int>? rawDbBytes;
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
            // 还原图片文件到 images/...
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
        final decoded = jsonDecode(jsonContent) as Map<String, dynamic>;
        final activeDb = await AppDatabase.instance.database;
        await _restoreFromJsonMap(activeDb, decoded);
        restoredOk = true;
      } else if (rawDbBytes != null) {
        await AppDatabase.closeForRestore();
        await File(p.join(appDir.path, 'daily_tracker.db')).writeAsBytes(rawDbBytes, flush: true);
        restoredOk = true;
      }

      final newDb = await AppDatabase.instance.database;
      final recCnt = Sqflite.firstIntValue(await newDb.rawQuery('SELECT COUNT(*) FROM status_records')) ?? 0;
      final modCnt = Sqflite.firstIntValue(await newDb.rawQuery('SELECT COUNT(*) FROM modules')) ?? 0;
      final schedCnt = Sqflite.firstIntValue(await newDb.rawQuery('SELECT COUNT(*) FROM schedule_items')) ?? 0;

      if (mounted) {
        if (!restoredOk) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('⚠️ 未能在所选压缩包中识别到 data.json 备份数据！')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '🎉 恢复成功！已即时导入：$recCnt 条状态记录、$modCnt 个家庭标题、$schedCnt 项日程、$restoredImages 张图片！',
              ),
              duration: const Duration(seconds: 4),
            ),
          );
          setState(() {});
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => MainShell(db: newDb)),
          );
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('恢复失败: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _groupPickerDialog({
    required bool saveMode,
    Map<String, dynamic>? existingGroup,
  }) async {
    final activeDb = await AppDatabase.instance.database;
    final mods = await activeDb.query('modules', orderBy: 'sort_order ASC, id ASC');
    if (!mounted) return;

    final isEdit = existingGroup != null;
    final nameCtrl = TextEditingController(text: isEdit ? '${existingGroup['name']}' : '');
    final sel = <int>{};
    if (isEdit) {
      try {
        sel.addAll((jsonDecode(existingGroup['module_ids'] as String) as List).cast<int>());
      } catch (_) {}
    }
    final expanded = <int>{};

    final validIds = mods.map((m) => m['id'] as int).toSet();
    final roots = mods.where((m) {
      final pid = m['parent_id'] as int?;
      return pid == null || !validIds.contains(pid);
    }).toList();

    List<Map<String, dynamic>> childrenOf(int pid) =>
        mods.where((m) => m['parent_id'] == pid).toList();

    List<int> subtreeIdsOf(int rootId) {
      final res = <int>[rootId];
      for (final c in childrenOf(rootId)) {
        res.addAll(subtreeIdsOf(c['id'] as int));
      }
      return res;
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          Widget buildCheckNode(Map<String, dynamic> m, int depth) {
            final id = m['id'] as int;
            final isMember = (m['is_member'] as int? ?? 0) == 1;
            final children = childrenOf(id);
            final hasChildren = children.isNotEmpty;
            final isExp = expanded.contains(id);
            final subIds = subtreeIdsOf(id);
            final allSelected = subIds.every((sid) => sel.contains(sid));
            final someSelected = !allSelected && subIds.any((sid) => sel.contains(sid));

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
                          onPressed: () => setS(() => isExp ? expanded.remove(id) : expanded.add(id)),
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
                              setS(() => isExp ? expanded.remove(id) : expanded.add(id));
                            } else {
                              setS(() => sel.contains(id) ? sel.remove(id) : sel.add(id));
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
                          onPressed: () => setS(() => isExp ? expanded.remove(id) : expanded.add(id)),
                          child: Text(isExp ? '收起' : '细筛(${children.length})', style: const TextStyle(fontSize: 11.5)),
                        ),
                      Checkbox(
                        tristate: true,
                        value: allSelected ? true : (someSelected ? null : false),
                        onChanged: (v) {
                          setS(() {
                            if (allSelected) {
                              sel.removeAll(subIds);
                            } else {
                              sel.addAll(subIds);
                            }
                          });
                        },
                      ),
                    ],
                  ),
                ),
                if (hasChildren && isExp)
                  ...children.map((c) => buildCheckNode(c, depth + 1)),
              ],
            );
          }

          return AlertDialog(
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    saveMode ? (isEdit ? '编辑标题组' : '新建标题组') : '临时选择查看',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
                Text('已选 ${sel.length} 项', style: const TextStyle(fontSize: 12.5, color: Color(0xFF4F46E5))),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (saveMode) ...[
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: '组名',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  const Text(
                    '💡 提示：直接勾选大标题将包含其全部内容；点击左侧 ▶️ 可展开精细化筛选内部小标题',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey),
                  ),
                  const Divider(height: 12),
                  Expanded(
                    child: mods.isEmpty
                        ? const Center(child: Text('暂无家庭模块，请先在「家庭」页添加'))
                        : ListView(
                            children: roots.map((r) => buildCheckNode(r, 0)).toList(),
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              FilledButton(
                onPressed: () async {
                  if (sel.isEmpty) return;
                  final db = await AppDatabase.instance.database;
                  if (saveMode) {
                    if (nameCtrl.text.trim().isEmpty) return;
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
                  } else {
                    Navigator.pop(ctx);
                    _viewMods('临时查看', sel.toList());
                  }
                },
                child: Text(saveMode ? (isEdit ? '保存修改' : '创建') : '查看内容'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _viewMods(String title, List<int> ids) async {
    final activeDb = await AppDatabase.instance.database;
    final allMods = await activeDb.query('modules', orderBy: 'sort_order ASC, id ASC');
    final modMap = {for (final m in allMods) m['id'] as int: m};

    String fullPathOf(int id) {
      final parts = <String>[];
      int? cur = id;
      int guard = 0;
      while (cur != null && modMap.containsKey(cur) && guard++ < 20) {
        parts.insert(0, '${modMap[cur]!['title']}');
        cur = modMap[cur]!['parent_id'] as int?;
      }
      return parts.join(' > ');
    }

    final data = <Map<String, dynamic>>[];
    for (final m in allMods) {
      final id = m['id'] as int;
      if (!ids.contains(id)) continue;
      final es = await activeDb.query('module_entries', where: 'module_id = ?', whereArgs: [id], orderBy: 'seq ASC');
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
                      final es = d['entries'] as List<Map<String, dynamic>>;
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
              final es = d['entries'] as List<Map<String, dynamic>>;
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                elevation: 0,
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
      body: FutureBuilder<Map<String, dynamic>>(
        future: _load(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final groups = snap.data!['groups'] as List<Map<String, dynamic>>;
          final hits = snap.data!['hits'] as List<Map<String, dynamic>>;
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
                      onPressed: () => _groupPickerDialog(saveMode: true),
                      icon: const Icon(Icons.add),
                      label: const Text('新建标题组'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _groupPickerDialog(saveMode: false),
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
                  child: Text('💡 长按标题组右侧 ☰ 可上下拖动调整位置', style: TextStyle(fontSize: 11.5, color: Colors.grey)),
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
                    final g = groups[idx];
                    final ids = (jsonDecode(g['module_ids'] as String) as List).cast<int>();
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
                        onTap: () => _viewMods('${g['name']}', ids),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.edit_outlined, color: Colors.blueGrey, size: 20),
                              tooltip: '编辑标题组',
                              onPressed: () => _groupPickerDialog(saveMode: true, existingGroup: g),
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
                                onPressed: _exportBackup,
                                icon: const Icon(Icons.upload_file),
                                label: const Text('导出备份'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _importBackup,
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

// ==================== 2. 家庭模块页面 (6套差异炫彩高定成员卡片 + 加高防重叠 + 仅按序号拆分) ====================
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
  State<FamilyPage> createState() => _FamilyPageState();
}

class _FamilyPageState extends State<FamilyPage> {
  final Set<int> _collapsedIds = {};
  int? _hoverTargetId;
  String? _hoverZone;
  bool _uiLoaded = false;

  static const List<_MemberPalette> _memberPalettes = [
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
    if (title.contains('梦')) return _memberPalettes[0];
    if (title.contains('雁') || title.contains('冰') || title.contains('我')) return _memberPalettes[1];
    if (title.contains('球') || title.contains('宠') || title.contains('狗')) return _memberPalettes[2];
    if (title.contains('爸') || title.contains('父') || title.contains('妈') || title.contains('母')) return _memberPalettes[3];
    return _memberPalettes[(memberOrderIndex + id) % _memberPalettes.length];
  }

  @override
  void initState() {
    super.initState();
    _restoreFamilyUiState();
  }

  Future<void> _restoreFamilyUiState() async {
    try {
      final activeDb = await AppDatabase.instance.database;
      final rows = await activeDb.query('ui_states', where: 'state_key = ?', whereArgs: ['family_collapsed_ids']);
      if (rows.isNotEmpty) {
        final list = (jsonDecode(rows.first['state_val'] as String) as List).cast<int>();
        _collapsedIds
          ..clear()
          ..addAll(list);
      }
    } catch (_) {}
    if (mounted) setState(() => _uiLoaded = true);
  }

  Future<void> _saveFamilyUiState() async {
    try {
      final activeDb = await AppDatabase.instance.database;
      await activeDb.insert(
        'ui_states',
        {'state_key': 'family_collapsed_ids', 'state_val': jsonEncode(_collapsedIds.toList())},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _loadFamilyData() async {
    if (!_uiLoaded) await _restoreFamilyUiState();
    final activeDb = await AppDatabase.instance.database;
    final mods = await activeDb.query('modules', orderBy: 'sort_order ASC, id ASC');
    final entries = await activeDb.query('module_entries');
    final entryCounts = <int, int>{};
    for (final e in entries) {
      final mid = e['module_id'] as int;
      entryCounts[mid] = (entryCounts[mid] ?? 0) + 1;
    }
    return {'mods': mods, 'counts': entryCounts};
  }

  bool _isDescendant(int dragId, int targetId, List<Map<String, dynamic>> all) {
    if (dragId == targetId) return true;
    int? cur = targetId;
    final visited = <int>{};
    while (cur != null && !visited.contains(cur)) {
      visited.add(cur);
      if (cur == dragId) return true;
      final row = all.where((m) => m['id'] == cur).firstOrNull;
      cur = row?['parent_id'] as int?;
    }
    return false;
  }

  Future<void> _handleDrop({
    required int dragId,
    required int targetId,
    required String zone,
    required List<Map<String, dynamic>> allMods,
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
      _collapsedIds.remove(targetId);
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

  String _unescapeXml(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }

  Future<void> _importFamilyDocx() async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.any);
      if (res == null || res.files.single.path == null) return;
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
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未识别到标准 Word 文档结构')));
        return;
      }

      final xmlStr = utf8.decode(docXmlFile.content as List<int>, allowMalformed: true);
      final pMatches = RegExp(r'<w:p\b[^>]*>([\s\S]*?)<\/w:p>').allMatches(xmlStr);

      final parsedParas = <({
        String text,
        String cleanText,
        bool isBold,
        int fontSize,
        int indent,
        int? numLevel,
        bool isHeadingStyle,
        bool hasExplicitSeq,
        bool endsWithColon,
      })>[];

      for (final pm in pMatches) {
        final pXml = pm.group(1)!;
        final tMatches = RegExp(r'<w:t(?:\s[^>]*)?>([\s\S]*?)<\/w:t>').allMatches(pXml);
        final rawText = _unescapeXml(tMatches.map((m) => m.group(1)!).join('')).trim();
        if (rawText.isEmpty) continue;

        final pStyleM = RegExp(r'<w:pStyle\s+w:val="([^"]+)"').firstMatch(pXml);
        final styleVal = pStyleM?.group(1) ?? '';
        final isHeadingStyle = RegExp(r'^(Heading|标题|\d+$)', caseSensitive: false).hasMatch(styleVal);

        final ilvlM = RegExp(r'<w:ilvl\s+w:val="(\d+)"').firstMatch(pXml);
        final numLevel = ilvlM != null ? int.tryParse(ilvlM.group(1)!) : null;

        final indM = RegExp(r'<w:ind\b[^>]*w:(?:left|firstLine)="(\d+)"').firstMatch(pXml);
        final indent = indM != null ? (int.tryParse(indM.group(1)!) ?? 0) : 0;

        final isBold = pXml.contains('<w:b/>') || pXml.contains('<w:b ') || isHeadingStyle;

        int maxSz = 24;
        for (final sm in RegExp(r'<w:sz\s+w:val="(\d+)"').allMatches(pXml)) {
          final v = int.tryParse(sm.group(1)!) ?? 24;
          if (v > maxSz) maxSz = v;
        }

        final cleanText = rawText
            .replaceFirst(RegExp(r'^[\u25CF\u2022\u25E6\u25AA\u25A1\u25B6\uF0B7\uF0A7\-\*]+\s*'), '')
            .trim();
        if (cleanText.isEmpty) continue;

        final hasExplicitSeq = RegExp(r'^(\d+[\.、]|[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳]|[一二三四五六七八九十]+[、\.])').hasMatch(cleanText);
        final endsWithColon = cleanText.endsWith('：') || cleanText.endsWith(':');

        parsedParas.add((
          text: rawText,
          cleanText: cleanText,
          isBold: isBold,
          fontSize: maxSz,
          indent: indent,
          numLevel: numLevel,
          isHeadingStyle: isHeadingStyle,
          hasExplicitSeq: hasExplicitSeq,
          endsWithColon: endsWithColon,
        ));
      }

      if (parsedParas.isEmpty) return;

      final folderRanks = <int>[];
      for (int i = 0; i < parsedParas.length; i++) {
        final cur = parsedParas[i];
        final prev = i > 0 ? parsedParas[i - 1] : null;
        final next = i + 1 < parsedParas.length ? parsedParas[i + 1] : null;

        final txtNoColon = cur.cleanText.replaceAll(RegExp(r'[:：]$'), '').trim();
        final nextGetsDeeper = next != null &&
            ((cur.numLevel != null && next.numLevel != null && next.numLevel! > cur.numLevel!) ||
                (next.indent > cur.indent + 100) ||
                (!cur.hasExplicitSeq && next.hasExplicitSeq));

        bool isFolder = false;
        if (cur.isHeadingStyle || cur.fontSize >= 28) {
          isFolder = true;
        } else if (cur.endsWithColon && txtNoColon.length <= 18) {
          isFolder = true;
        } else if (cur.isBold && txtNoColon.length <= 16 && !cur.hasExplicitSeq) {
          isFolder = true;
        } else if (nextGetsDeeper && txtNoColon.length <= 20 && !cur.hasExplicitSeq) {
          isFolder = true;
        } else if (cur.numLevel != null && cur.numLevel! <= 1 && txtNoColon.length <= 12 && !cur.cleanText.contains('，') && !cur.cleanText.contains('。')) {
          final prevWasShortFolder = prev != null && folderRanks.isNotEmpty && folderRanks.last < 99;
          if (nextGetsDeeper || prevWasShortFolder || i == 0) {
            isFolder = true;
          }
        }

        if (!isFolder) {
          folderRanks.add(99);
        } else {
          int rank = 3;
          if (cur.fontSize >= 32 || styleMatchesLevel(cur.text, 1) || (cur.numLevel == 0 && cur.isBold)) {
            rank = 1;
          } else if (cur.fontSize >= 28 || cur.numLevel == 0) {
            rank = 2;
          } else if (cur.numLevel != null) {
            rank = 2 + cur.numLevel!;
          } else if (cur.indent > 0) {
            rank = 3 + (cur.indent ~/ 240);
          } else if (cur.isBold && !cur.endsWithColon) {
            rank = 2;
          } else if (cur.endsWithColon) {
            rank = 4;
          }
          folderRanks.add(rank);
        }
      }

      int createdFolders = 0;
      int createdEntries = 0;
      final stack = <({int rank, int id})>[];

      Future<int> createOrGetFolder(String rawTitle, int? parentId, {bool isTopLevel = false}) async {
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

      Future<void> insertEntryToFolder(int folderId, String rawContent) async {
        final content = rawContent
            .replaceFirst(RegExp(r'^(\d+[\.、]|[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳])\s*'), '')
            .trim();
        if (content.isEmpty) return;
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

      for (int i = 0; i < parsedParas.length; i++) {
        final pItem = parsedParas[i];
        final rank = folderRanks[i];

        if (rank < 99) {
          final colonIdx = pItem.cleanText.indexOf(RegExp(r'[:：]'));
          final hasInlineContent = colonIdx > 0 && colonIdx < pItem.cleanText.length - 1 && colonIdx <= 12;

          while (stack.isNotEmpty && stack.last.rank >= rank) {
            stack.removeLast();
          }
          final parentId = stack.isEmpty ? null : stack.last.id;

          if (hasInlineContent) {
            final fTitle = pItem.cleanText.substring(0, colonIdx).trim();
            final inlineBody = pItem.cleanText.substring(colonIdx + 1).trim();
            final fid = await createOrGetFolder(fTitle, parentId, isTopLevel: parentId == null);
            stack.add((rank: rank, id: fid));
            await insertEntryToFolder(fid, inlineBody);
          } else {
            final fid = await createOrGetFolder(pItem.cleanText, parentId, isTopLevel: parentId == null);
            stack.add((rank: rank, id: fid));
          }
        } else {
          final colonIdx = pItem.cleanText.indexOf(RegExp(r'[:：]'));
          if (colonIdx > 0 && colonIdx <= 8 && !pItem.hasExplicitSeq && pItem.cleanText.length > colonIdx + 1) {
            final subTitle = pItem.cleanText.substring(0, colonIdx).trim();
            final body = pItem.cleanText.substring(colonIdx + 1).trim();
            while (stack.isNotEmpty && stack.last.rank >= 8) {
              stack.removeLast();
            }
            final parentId = stack.isEmpty ? null : stack.last.id;
            final subFid = await createOrGetFolder(subTitle, parentId);
            stack.add((rank: 8, id: subFid));
            await insertEntryToFolder(subFid, body);
          } else {
            if (stack.isEmpty) {
              final docName = p.basenameWithoutExtension(filePath);
              final rootId = await createOrGetFolder(docName, null, isTopLevel: true);
              stack.add((rank: 1, id: rootId));
            }
            await insertEntryToFolder(stack.last.id, pItem.cleanText);
          }
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('🎉 导入完成：自动构建 $createdFolders 个分级标题、导入 $createdEntries 条记录！')),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入 Word 失败：$e')));
    }
  }

  bool styleMatchesLevel(String text, int level) {
    if (level == 1) {
      return RegExp(r'^[一二三四五六七八九十]+[、\.]').hasMatch(text);
    }
    return false;
  }

  Future<void> _moduleEntriesDialog(Map<String, dynamic> mod, List<Map<String, dynamic>> allMods) async {
    final activeDb = await AppDatabase.instance.database;
    final modId = mod['id'] as int;
    final modMap = {for (final m in allMods) m['id'] as int: m};
    String fullPathOf(int id) {
      final parts = <String>[];
      int? cur = id;
      int guard = 0;
      while (cur != null && modMap.containsKey(cur) && guard++ < 20) {
        parts.insert(0, '${modMap[cur]!['title']}');
        cur = modMap[cur]!['parent_id'] as int?;
      }
      return parts.join(' > ');
    }

    final fullPath = fullPathOf(modId);
    final entries = List<Map<String, dynamic>>.from(
      await activeDb.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC'),
    );

    if (!mounted) return;
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
                        _addOrEditModuleDialog(parentId: modId, forceMember: false);
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

                        final itemsToInsert = <String>[];
                        final seqRegex = RegExp(
                          r'(?:^|\n)\s*(?:\d+[\.、]|[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳]|[一二三四五六七八九十]+[、\.])\s*',
                        );
                        final matches = seqRegex.allMatches(raw).toList();

                        if (matches.isEmpty) {
                          itemsToInsert.add(raw);
                        } else {
                          if (matches.first.start > 0) {
                            final pre = raw.substring(0, matches.first.start).trim();
                            if (pre.isNotEmpty) itemsToInsert.add(pre);
                          }
                          for (int i = 0; i < matches.length; i++) {
                            final start = matches[i].end;
                            final end = (i + 1 < matches.length) ? matches[i + 1].start : raw.length;
                            final seg = raw.substring(start, end).trim();
                            if (seg.isNotEmpty) itemsToInsert.add(seg);
                          }
                        }

                        for (final content in itemsToInsert) {
                          final curAll = await db.query('module_entries', where: 'module_id = ?', whereArgs: [modId]);
                          await db.insert('module_entries', {
                            'module_id': modId,
                            'seq': curAll.length + 1,
                            'content': content,
                            'sort_order': curAll.length,
                            'created_at': DateTime.now().toIso8601String(),
                          });
                        }

                        ctrl.clear();
                        entries
                          ..clear()
                          ..addAll(await db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC'));
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
                            if (newIdx > oldIdx) newIdx -= 1;
                            final db = await AppDatabase.instance.database;
                            final moved = entries.removeAt(oldIdx);
                            entries.insert(newIdx, moved);
                            for (int i = 0; i < entries.length; i++) {
                              entries[i] = {...entries[i], 'seq': i + 1, 'sort_order': i};
                              await db.update(
                                'module_entries',
                                {'seq': i + 1, 'sort_order': i},
                                where: 'id = ?',
                                whereArgs: [entries[i]['id']],
                              );
                            }
                            setS(() {});
                            setState(() {});
                          },
                          itemBuilder: (ctx, i) {
                            final e = entries[i];
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
                                        entries
                                          ..clear()
                                          ..addAll(await db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC'));
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
                                      final rem = await db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC');
                                      for (int idx = 0; idx < rem.length; idx++) {
                                        await db.update('module_entries', {'seq': idx + 1, 'sort_order': idx}, where: 'id = ?', whereArgs: [rem[idx]['id']]);
                                      }
                                      entries
                                        ..clear()
                                        ..addAll(await db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC'));
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

  Future<void> _editEntryContentDialog(Map<String, dynamic> entry, VoidCallback onSaved) async {
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

  Future<void> _addOrEditModuleDialog({Map<String, dynamic>? editMod, int? parentId, bool forceMember = false}) async {
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
                  labelText: forceMember ? '成员姓名（如：梦雨、雁冰、球球）' : '标题名称',
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
            onPressed: () => _addOrEditModuleDialog(parentId: null, forceMember: true),
            icon: const Icon(Icons.person_add_alt_1, size: 17),
            label: const Text('添加成员', style: TextStyle(fontSize: 13)),
          ),
          TextButton.icon(
            onPressed: () => _addOrEditModuleDialog(parentId: null, forceMember: false),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新标题', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _loadFamilyData(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final mods = snap.data!['mods'] as List<Map<String, dynamic>>;
          final entryCounts = snap.data!['counts'] as Map<int, int>;

          final validIds = mods.map((m) => m['id'] as int).toSet();
          final roots = mods.where((m) {
            final pid = m['parent_id'] as int?;
            return pid == null || !validIds.contains(pid);
          }).toList();

          List<Map<String, dynamic>> childrenOf(int pid) =>
              mods.where((m) => m['parent_id'] == pid).toList();

          final memberIdList = mods.where((m) => (m['is_member'] as int? ?? 0) == 1).map((m) => m['id'] as int).toList();

          Widget buildNode(Map<String, dynamic> m, int depth) {
            final id = m['id'] as int;
            final title = '${m['title']}';
            final isMember = (m['is_member'] as int? ?? 0) == 1;
            final children = childrenOf(id);
            final hasChildren = children.isNotEmpty;
            final isCollapsed = _collapsedIds.contains(id);

            final subBadgeCount = hasChildren ? children.length : (entryCounts[id] ?? 0);

            final isHover = _hoverTargetId == id;
            final zone = isHover ? _hoverZone : null;

            final memberIdx = math.max(0, memberIdList.indexOf(id));
            final palette = _paletteForMember(title, memberIdx, id);

            return Column(
              key: ValueKey('fam_node_$id'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(left: depth * 18.0, bottom: isMember ? 9 : 6),
                  child: Builder(
                    builder: (itemCtx) => DragTarget<int>(
                      onWillAcceptWithDetails: (details) {
                        final dragId = details.data;
                        return !_isDescendant(dragId, id, mods);
                      },
                      onMove: (details) {
                        final box = itemCtx.findRenderObject() as RenderBox?;
                        if (box == null) return;
                        final localY = box.globalToLocal(details.offset).dy;
                        final h = box.size.height;
                        String z;
                        if (localY < h * 0.28) {
                          z = 'up';
                        } else if (localY > h * 0.72) {
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
                        await _handleDrop(
                          dragId: details.data,
                          targetId: id,
                          zone: z,
                          allMods: mods,
                        );
                      },
                      builder: (ctx, cand, rej) {
                        if (isMember) {
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
                                      setState(() => isCollapsed ? _collapsedIds.remove(id) : _collapsedIds.add(id));
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
                                        isCollapsed ? Icons.chevron_right : Icons.expand_more,
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
                                    onTap: () => _moduleEntriesDialog(m, mods),
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
                                        if (subBadgeCount > 0)
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
                                  onTap: () => _addOrEditModuleDialog(parentId: id, forceMember: false),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
                                    child: Icon(Icons.create_new_folder_outlined, size: 19, color: palette.accentColor),
                                  ),
                                ),
                                InkWell(
                                  onTap: () => _addOrEditModuleDialog(editMod: m),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
                                    child: Icon(Icons.edit_outlined, size: 18, color: palette.accentColor.withOpacity(0.8)),
                                  ),
                                ),
                                InkWell(
                                  onTap: () async {
                                    final db = await AppDatabase.instance.database;
                                    final subIds = <int>[id];
                                    void collect(int p) {
                                      for (final c in childrenOf(p)) {
                                        final cid = c['id'] as int;
                                        subIds.add(cid);
                                        collect(cid);
                                      }
                                    }
                                    collect(id);
                                    for (final did in subIds) {
                                      await db.delete('module_entries', where: 'module_id = ?', whereArgs: [did]);
                                      await db.delete('modules', where: 'id = ?', whereArgs: [did]);
                                    }
                                    setState(() {});
                                  },
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 5, vertical: 4),
                                    child: Icon(Icons.delete_outline, size: 19, color: Colors.redAccent),
                                  ),
                                ),
                                LongPressDraggable<int>(
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
                                    setState(() => isCollapsed ? _collapsedIds.remove(id) : _collapsedIds.add(id));
                                    _saveFamilyUiState();
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Icon(
                                      isCollapsed ? Icons.chevron_right : Icons.expand_more,
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
                                  onTap: () => _moduleEntriesDialog(m, mods),
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
                                      if (subBadgeCount > 0)
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
                                onTap: () => _addOrEditModuleDialog(parentId: id, forceMember: false),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                                  child: Icon(Icons.create_new_folder_outlined, size: 18, color: Color(0xFF4F46E5)),
                                ),
                              ),
                              InkWell(
                                onTap: () => _addOrEditModuleDialog(editMod: m),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                                  child: Icon(Icons.edit_outlined, size: 17, color: Colors.blueGrey),
                                ),
                              ),
                              InkWell(
                                onTap: () async {
                                  final db = await AppDatabase.instance.database;
                                  final subIds = <int>[id];
                                  void collect(int p) {
                                    for (final c in childrenOf(p)) {
                                      final cid = c['id'] as int;
                                      subIds.add(cid);
                                      collect(cid);
                                    }
                                  }
                                  collect(id);
                                  for (final did in subIds) {
                                    await db.delete('module_entries', where: 'module_id = ?', whereArgs: [did]);
                                    await db.delete('modules', where: 'id = ?', whereArgs: [did]);
                                  }
                                  setState(() {});
                                },
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                                  child: Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                                ),
                              ),
                              LongPressDraggable<int>(
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
                      },
                    ),
                  ),
                ),
                if (hasChildren && !isCollapsed)
                  ...children.map((c) => buildNode(c, depth + 1)),
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
                    ...roots.map((r) => buildNode(r, 0)),
                  ],
                );
        },
      ),
    );
  }
}
// ==================== 3. 规划与思维导图页面 (支持 XMind 导入 + 节点长按拖拽移动) ====================
class PlanPage extends StatefulWidget {
  final Database db;
  const PlanPage({super.key, required this.db});
  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  bool _busy = false;

  Future<List<Map<String, dynamic>>> _loadMindmaps() async {
    final activeDb = await AppDatabase.instance.database;
    return await activeDb.query('mindmaps', orderBy: 'updated_at DESC, id DESC');
  }

  String _genId() => '${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(99999)}';

  String _unescapeXml(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }

  Map<String, dynamic> _convertXmindJsonTopic(Map<String, dynamic> topic) {
    final title = (topic['title'] ?? '未命名节点').toString().trim();
    final childrenList = <Map<String, dynamic>>[];
    final childrenObj = topic['children'];
    if (childrenObj is Map) {
      final attached = childrenObj['attached'];
      if (attached is List) {
        for (final c in attached) {
          if (c is Map<String, dynamic>) {
            childrenList.add(_convertXmindJsonTopic(c));
          } else if (c is Map) {
            childrenList.add(_convertXmindJsonTopic(Map<String, dynamic>.from(c)));
          }
        }
      }
    } else if (childrenObj is List) {
      for (final c in childrenObj) {
        if (c is Map) childrenList.add(_convertXmindJsonTopic(Map<String, dynamic>.from(c)));
      }
    }
    return {
      'id': _genId(),
      'text': title.isEmpty ? '节点' : title,
      'collapsed': false,
      'children': childrenList,
    };
  }

  Map<String, dynamic>? _parseXmindXml(String xmlStr) {
    final rootMatch = RegExp(r'<topic\b[^>]*>([\s\S]*)</topic>').firstMatch(xmlStr);
    if (rootMatch == null) return null;

    Map<String, dynamic> walkTopic(String content) {
      String title = '节点';
      final tMatch = RegExp(r'<title[^>]*>([\s\S]*?)</title>').firstMatch(content);
      if (tMatch != null) {
        title = _unescapeXml(tMatch.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim());
      }
      final children = <Map<String, dynamic>>[];
      final tPos = tMatch?.end ?? 0;
      final subContent = content.substring(tPos);

      int idx = 0;
      while (idx < subContent.length) {
        final openMatch = RegExp(r'<topic\b[^>]*>').firstMatch(subContent.substring(idx));
        if (openMatch == null) break;
        final startTagPos = idx + openMatch.start;
        final afterOpenPos = idx + openMatch.end;

        if (subContent.substring(startTagPos, afterOpenPos).endsWith('/>')) {
          idx = afterOpenPos;
          continue;
        }

        int depth = 1;
        int scan = afterOpenPos;
        while (depth > 0 && scan < subContent.length) {
          final nextOpen = subContent.indexOf('<topic', scan);
          final nextClose = subContent.indexOf('</topic>', scan);
          if (nextClose == -1) break;
          if (nextOpen != -1 && nextOpen < nextClose) {
            final closeBracket = subContent.indexOf('>', nextOpen);
            if (closeBracket != -1 && !subContent.substring(nextOpen, closeBracket + 1).endsWith('/>')) {
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
        'collapsed': false,
        'children': children,
      };
    }

    return walkTopic(rootMatch.group(1)!);
  }

  Future<void> _importXmind() async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.any);
      if (res == null || res.files.single.path == null) return;
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

      Map<String, dynamic>? rootNode;
      if (jsonFile != null) {
        final jsonStr = utf8.decode(jsonFile.content as List<int>, allowMalformed: true);
        final decoded = jsonDecode(jsonStr);
        if (decoded is List && decoded.isNotEmpty) {
          final rootTopic = decoded.first['rootTopic'] as Map<String, dynamic>?;
          if (rootTopic != null) rootNode = _convertXmindJsonTopic(rootTopic);
        } else if (decoded is Map && decoded['rootTopic'] != null) {
          rootNode = _convertXmindJsonTopic(Map<String, dynamic>.from(decoded['rootTopic']));
        }
      } else if (xmlFile != null) {
        final xmlStr = utf8.decode(xmlFile.content as List<int>, allowMalformed: true);
        rootNode = _parseXmindXml(xmlStr);
      }

      if (rootNode == null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未能识别该思维导图文件格式')));
        return;
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

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('🎉 成功导入思维导图「$title」')));
      setState(() {});
      _openEditor(id, title, rootNode);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入失败: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createNewMindmapDialog() async {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建规划导图', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '规划主题名称（如：2026人生模拟器规划）',
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
              final root = {
                'id': _genId(),
                'text': t,
                'collapsed': false,
                'children': <Map<String, dynamic>>[],
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
                _openEditor(id, t, root);
              }
            },
            child: const Text('创建并进入'),
          ),
        ],
      ),
    );
  }

  void _openEditor(int id, String title, Map<String, dynamic> root) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MindmapEditorPage(db: widget.db, mapId: id, initialTitle: title, initialRoot: root),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
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
            onPressed: _busy ? null : _importXmind,
            icon: const Icon(Icons.upload_file_outlined, size: 18),
            label: const Text('导入XMind', style: TextStyle(fontSize: 13)),
          ),
          TextButton.icon(
            onPressed: _createNewMindmapDialog,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新规划', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _loadMindmaps(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final maps = snap.data!;
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
                    onPressed: _importXmind,
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
              final m = maps[i];
              final id = m['id'] as int;
              final title = '${m['title']}';
              Map<String, dynamic> root = {};
              int totalNodes = 1;
              try {
                root = jsonDecode(m['root_json'] as String) as Map<String, dynamic>;
                void countNodes(Map<String, dynamic> n) {
                  for (final c in ((n['children'] as List?)?.cast<Map<String, dynamic>>() ?? [])) {
                    totalNodes++;
                    countNodes(c);
                  }
                }
                countNodes(root);
              } catch (_) {}

              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                elevation: 0,
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF1F2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.account_tree, color: Color(0xFFE11D48)),
                  ),
                  title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15.5)),
                  subtitle: Text(
                    '共 $totalNodes 个规划节点 · 点击进入思维导图画布',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  onTap: () => _openEditor(id, title, root),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    onPressed: () async {
                      final activeDb = await AppDatabase.instance.database;
                      await activeDb.delete('mindmaps', where: 'id = ?', whereArgs: [id]);
                      setState(() {});
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _NodeLayoutInfo {
  final String id;
  final Map<String, dynamic> node;
  final String? parentId;
  final int depth;
  final Rect rect;
  double subtreeHeight;

  _NodeLayoutInfo({
    required this.id,
    required this.node,
    required this.parentId,
    required this.depth,
    required this.rect,
    this.subtreeHeight = 0,
  });
}

class MindmapEditorPage extends StatefulWidget {
  final Database db;
  final int mapId;
  final String initialTitle;
  final Map<String, dynamic> initialRoot;

  const MindmapEditorPage({
    super.key,
    required this.db,
    required this.mapId,
    required this.initialTitle,
    required this.initialRoot,
  });

  @override
  State<MindmapEditorPage> createState() => _MindmapEditorPageState();
}

class _MindmapEditorPageState extends State<MindmapEditorPage> {
  late Map<String, dynamic> _root;
  late String _title;
  bool _isLandscape = false;
  bool _allExpanded = true;

  String? _hoverTargetId;
  String? _hoverZone;

  final TransformationController _transCtrl = TransformationController();

  @override
  void initState() {
    super.initState();
    _title = widget.initialTitle;
    _root = jsonDecode(jsonEncode(widget.initialRoot)) as Map<String, dynamic>;
    _ensureNodeIds(_root);
  }

  @override
  void dispose() {
    if (_isLandscape) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
    _transCtrl.dispose();
    super.dispose();
  }

  void _ensureNodeIds(Map<String, dynamic> node) {
    if (node['id'] == null || node['id'].toString().isEmpty) {
      node['id'] = '${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(999999)}';
    }
    node['collapsed'] = node['collapsed'] == true;
    final children = (node['children'] as List?)?.cast<Map<String, dynamic>>() ?? <Map<String, dynamic>>[];
    node['children'] = children;
    for (final c in children) {
      _ensureNodeIds(c);
    }
  }

  Future<void> _saveToDb() async {
    _title = (_root['text'] as String? ?? _title).trim();
    final activeDb = await AppDatabase.instance.database;
    await activeDb.update(
      'mindmaps',
      {
        'title': _title,
        'root_json': jsonEncode(_root),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [widget.mapId],
    );
  }

  int _countDescendants(Map<String, dynamic> node) {
    final children = (node['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    int count = children.length;
    for (final c in children) {
      count += _countDescendants(c);
    }
    return count;
  }

  void _setAllCollapsed(Map<String, dynamic> node, bool collapsed, {bool isRoot = true}) {
    if (!isRoot) node['collapsed'] = collapsed;
    for (final c in ((node['children'] as List?)?.cast<Map<String, dynamic>>() ?? [])) {
      _setAllCollapsed(c, collapsed, isRoot: false);
    }
  }

  bool _isDescendantInTree(String dragId, String targetId) {
    if (dragId == targetId) return true;
    Map<String, dynamic>? findNode(Map<String, dynamic> cur, String id) {
      if (cur['id'] == id) return cur;
      for (final c in ((cur['children'] as List?)?.cast<Map<String, dynamic>>() ?? [])) {
        final found = findNode(c, id);
        if (found != null) return found;
      }
      return null;
    }

    final dragNode = findNode(_root, dragId);
    if (dragNode == null) return false;
    return findNode(dragNode, targetId) != null;
  }

  Future<void> _moveMindmapNode({
    required String dragId,
    required String targetId,
    required String zone,
  }) async {
    if (dragId == _root['id'] || _isDescendantInTree(dragId, targetId)) return;

    Map<String, dynamic>? removedNode;

    bool removeFromParent(Map<String, dynamic> cur) {
      final children = (cur['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final idx = children.indexWhere((c) => c['id'] == dragId);
      if (idx != -1) {
        removedNode = children.removeAt(idx);
        cur['children'] = children;
        return true;
      }
      for (final c in children) {
        if (removeFromParent(c)) return true;
      }
      return false;
    }

    if (!removeFromParent(_root) || removedNode == null) return;

    if (zone == 'inside' || targetId == _root['id']) {
      bool insertInside(Map<String, dynamic> cur) {
        if (cur['id'] == targetId) {
          final children = (cur['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          children.add(removedNode!);
          cur['children'] = children;
          cur['collapsed'] = false;
          return true;
        }
        for (final c in ((cur['children'] as List?)?.cast<Map<String, dynamic>>() ?? [])) {
          if (insertInside(c)) return true;
        }
        return false;
      }

      insertInside(_root);
    } else {
      bool insertSibling(Map<String, dynamic> cur) {
        final children = (cur['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        final tIdx = children.indexWhere((c) => c['id'] == targetId);
        if (tIdx != -1) {
          final insIdx = zone == 'up' ? tIdx : tIdx + 1;
          children.insert(insIdx.clamp(0, children.length), removedNode!);
          cur['children'] = children;
          return true;
        }
        for (final c in children) {
          if (insertSibling(c)) return true;
        }
        return false;
      }

      insertSibling(_root);
    }

    await _saveToDb();
    if (mounted) setState(() {});
  }

  void _onNodeActionSheet(Map<String, dynamic> node, {required bool isRoot}) {
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
                _editNodeTextDialog(node);
              },
            ),
            ListTile(
              leading: const Icon(Icons.subdirectory_arrow_right, color: Color(0xFF4F46E5)),
              title: const Text('添加子节点'),
              onTap: () {
                Navigator.pop(ctx);
                _addChildNodeDialog(node);
              },
            ),
            if (!isRoot)
              ListTile(
                leading: const Icon(Icons.add_circle_outline, color: Color(0xFF0D9488)),
                title: const Text('添加同级节点'),
                onTap: () {
                  Navigator.pop(ctx);
                  _addSiblingNodeDialog(node['id'] as String);
                },
              ),
            if (!isRoot)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('删除此节点及其子节点', style: TextStyle(color: Colors.redAccent)),
                onTap: () async {
                  Navigator.pop(ctx);
                  _deleteNodeById(_root, node['id'] as String);
                  await _saveToDb();
                  setState(() {});
                },
              ),
          ],
        ),
      ),
    );
  }

  void _editNodeTextDialog(Map<String, dynamic> node) {
    final ctrl = TextEditingController(text: '${node['text']}');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑节点', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (ctrl.text.trim().isEmpty) return;
              node['text'] = ctrl.text.trim();
              await _saveToDb();
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _addChildNodeDialog(Map<String, dynamic> parentNode) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('在「${parentNode['text']}」下添加子节点', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(hintText: '输入子节点内容...', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (ctrl.text.trim().isEmpty) return;
              final children = (parentNode['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
              children.add({
                'id': '${DateTime.now().microsecondsSinceEpoch}',
                'text': ctrl.text.trim(),
                'collapsed': false,
                'children': <Map<String, dynamic>>[],
              });
              parentNode['children'] = children;
              parentNode['collapsed'] = false;
              await _saveToDb();
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _addSiblingNodeDialog(String targetId) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加同级节点', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(hintText: '输入同级节点内容...', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (ctrl.text.trim().isEmpty) return;
              bool insertAfter(Map<String, dynamic> cur) {
                final children = (cur['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
                final idx = children.indexWhere((c) => c['id'] == targetId);
                if (idx != -1) {
                  children.insert(idx + 1, {
                    'id': '${DateTime.now().microsecondsSinceEpoch}',
                    'text': ctrl.text.trim(),
                    'collapsed': false,
                    'children': <Map<String, dynamic>>[],
                  });
                  cur['children'] = children;
                  return true;
                }
                for (final c in children) {
                  if (insertAfter(c)) return true;
                }
                return false;
              }

              insertAfter(_root);
              await _saveToDb();
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  bool _deleteNodeById(Map<String, dynamic> cur, String targetId) {
    final children = (cur['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final idx = children.indexWhere((c) => c['id'] == targetId);
    if (idx != -1) {
      children.removeAt(idx);
      cur['children'] = children;
      return true;
    }
    for (final c in children) {
      if (_deleteNodeById(c, targetId)) return true;
    }
    return false;
  }

  Size _measureNodeSize(String text, int depth) {
    final tp = TextPainter(
      text: TextSpan(
        text: text.isEmpty ? '节点' : text,
        style: TextStyle(
          fontSize: depth == 0 ? 15.5 : 14.0,
          fontWeight: depth <= 1 ? FontWeight.w600 : FontWeight.normal,
          height: 1.35,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 240);
    return Size(math.max(58, tp.width + 26), math.max(38, tp.height + 20));
  }

  ({List<_NodeLayoutInfo> nodes, Size canvasSize}) _computeTreeLayout() {
    final nodes = <_NodeLayoutInfo>[];
    final sizeCache = <String, Size>{};
    final subHeightCache = <String, double>{};
    const double vGap = 18.0;
    const double hGap = 68.0;

    double measureSubtree(Map<String, dynamic> n, int depth) {
      final id = n['id'] as String;
      final sz = _measureNodeSize('${n['text'] ?? ''}', depth);
      sizeCache[id] = sz;
      final children = (n['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final isCollapsed = n['collapsed'] == true;
      if (children.isEmpty || isCollapsed) {
        subHeightCache[id] = sz.height;
        return sz.height;
      }
      double sum = 0;
      for (int i = 0; i < children.length; i++) {
        if (i > 0) sum += vGap;
        sum += measureSubtree(children[i], depth + 1);
      }
      final h = math.max(sz.height, sum);
      subHeightCache[id] = h;
      return h;
    }

    final totalTreeH = measureSubtree(_root, 0);
    double maxRight = 800;
    double maxBottom = math.max(600, totalTreeH + 160);

    void assignCoords(Map<String, dynamic> n, String? parentId, int depth, double leftX, double topY) {
      final id = n['id'] as String;
      final sz = sizeCache[id]!;
      final subH = subHeightCache[id]!;
      final nodeTop = topY + (subH - sz.height) / 2;
      final rect = Rect.fromLTWH(leftX, nodeTop, sz.width, sz.height);

      maxRight = math.max(maxRight, rect.right + 180);
      maxBottom = math.max(maxBottom, topY + subH + 120);

      nodes.add(_NodeLayoutInfo(
        id: id,
        node: n,
        parentId: parentId,
        depth: depth,
        rect: rect,
        subtreeHeight: subH,
      ));

      final children = (n['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final isCollapsed = n['collapsed'] == true;
      if (children.isEmpty || isCollapsed) return;

      double childrenTotalH = 0;
      for (int i = 0; i < children.length; i++) {
        if (i > 0) childrenTotalH += vGap;
        childrenTotalH += subHeightCache[children[i]['id'] as String]!;
      }

      double curY = topY + (subH - childrenTotalH) / 2;
      final childLeftX = rect.right + hGap;
      for (final c in children) {
        final cid = c['id'] as String;
        final cSubH = subHeightCache[cid]!;
        assignCoords(c, id, depth + 1, childLeftX, curY);
        curY += cSubH + vGap;
      }
    }

    assignCoords(_root, null, 0, 60, 80);
    return (nodes: nodes, canvasSize: Size(maxRight, maxBottom));
  }

  Widget _buildNodeCardWidget(_NodeLayoutInfo info, {bool isDraggingFeedback = false}) {
    final id = info.id;
    final text = '${info.node['text'] ?? ''}';
    final isHover = _hoverTargetId == id && !isDraggingFeedback;
    final zone = isHover ? _hoverZone : null;

    return Container(
      width: info.rect.width,
      height: info.rect.height,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: zone == 'inside'
            ? const Color(0xFFFFE4E6)
            : (info.depth == 0 ? const Color(0xFFFEF2F2) : const Color(0xFFFFF5F5)),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          top: BorderSide(
            color: zone == 'up' ? const Color(0xFFE11D48) : const Color(0xFFE5A3A3),
            width: zone == 'up' ? 3.5 : 1.2,
          ),
          bottom: BorderSide(
            color: zone == 'down' ? const Color(0xFFE11D48) : const Color(0xFFE5A3A3),
            width: zone == 'down' ? 3.5 : 1.2,
          ),
          left: BorderSide(
            color: zone == 'inside' ? const Color(0xFFE11D48) : const Color(0xFFE5A3A3),
            width: zone == 'inside' ? 2.5 : 1.2,
          ),
          right: BorderSide(
            color: zone == 'inside' ? const Color(0xFFE11D48) : const Color(0xFFE5A3A3),
            width: zone == 'inside' ? 2.5 : 1.2,
          ),
        ),
        boxShadow: isDraggingFeedback
            ? const [BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4))]
            : null,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: info.depth == 0 ? 15.5 : 14.0,
          fontWeight: info.depth <= 1 ? FontWeight.w600 : FontWeight.normal,
          color: const Color(0xFF1E293B),
          height: 1.35,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final layout = _computeTreeLayout();
    final nodeMap = {for (final n in layout.nodes) n.id: n};

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Text(_title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        actions: [
          TextButton.icon(
            onPressed: () {
              setState(() {
                _allExpanded = !_allExpanded;
                _setAllCollapsed(_root, !_allExpanded);
              });
              _saveToDb();
            },
            icon: Icon(_allExpanded ? Icons.unfold_less : Icons.unfold_more, size: 18),
            label: Text(_allExpanded ? '全部收起' : '全部展开', style: const TextStyle(fontSize: 13)),
          ),
          TextButton.icon(
            onPressed: () {
              setState(() => _isLandscape = !_isLandscape);
              SystemChrome.setPreferredOrientations(
                _isLandscape
                    ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
                    : [DeviceOrientation.portraitUp],
              );
            },
            icon: const Icon(Icons.screen_rotation_outlined, size: 17),
            label: Text(_isLandscape ? '切换竖屏' : '切换横屏', style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            color: const Color(0xFFFFF1F2),
            child: const Text(
              '💡 点击节点编辑/加子项；长按节点可自由拖拽：拖到其他节点中央变为其子项，拖到上下边缘调序',
              style: TextStyle(fontSize: 11.5, color: Color(0xFFBE123C)),
            ),
          ),
          Expanded(
            child: InteractiveViewer(
              transformationController: _transCtrl,
              constrained: false,
              boundaryMargin: const EdgeInsets.all(600),
              minScale: 0.25,
              maxScale: 2.8,
              child: SizedBox(
                width: layout.canvasSize.width,
                height: layout.canvasSize.height,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _MindmapLinePainter(nodes: layout.nodes, nodeMap: nodeMap),
                      ),
                    ),
                    ...layout.nodes.map((info) {
                      final isRoot = info.depth == 0;
                      final children = (info.node['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
                      final hasChildren = children.isNotEmpty;
                      final isCollapsed = info.node['collapsed'] == true;
                      final hiddenCount = isCollapsed ? _countDescendants(info.node) : 0;

                      return Positioned(
                        left: info.rect.left,
                        top: info.rect.top,
                        width: info.rect.width + (hasChildren ? 38 : 0),
                        height: info.rect.height,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Builder(
                              builder: (nodeCtx) => DragTarget<String>(
                                onWillAcceptWithDetails: (details) {
                                  final dragId = details.data;
                                  return !_isDescendantInTree(dragId, info.id);
                                },
                                onMove: (details) {
                                  final box = nodeCtx.findRenderObject() as RenderBox?;
                                  if (box == null) return;
                                  final localY = box.globalToLocal(details.offset).dy;
                                  final h = box.size.height;
                                  String z;
                                  if (isRoot) {
                                    z = 'inside';
                                  } else if (localY < h * 0.28) {
                                    z = 'up';
                                  } else if (localY > h * 0.72) {
                                    z = 'down';
                                  } else {
                                    z = 'inside';
                                  }
                                  if (_hoverTargetId != info.id || _hoverZone != z) {
                                    setState(() {
                                      _hoverTargetId = info.id;
                                      _hoverZone = z;
                                    });
                                  }
                                },
                                onLeave: (_) {
                                  if (_hoverTargetId == info.id) {
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
                                  await _moveMindmapNode(
                                    dragId: details.data,
                                    targetId: info.id,
                                    zone: z,
                                  );
                                },
                                builder: (ctx, cand, rej) {
                                  final card = GestureDetector(
                                    onTap: () => _onNodeActionSheet(info.node, isRoot: isRoot),
                                    child: _buildNodeCardWidget(info),
                                  );
                                  if (isRoot) return card;
                                  return LongPressDraggable<String>(
                                    data: info.id,
                                    feedback: Material(
                                      color: Colors.transparent,
                                      child: _buildNodeCardWidget(info, isDraggingFeedback: true),
                                    ),
                                    childWhenDragging: Opacity(opacity: 0.35, child: card),
                                    child: card,
                                  );
                                },
                              ),
                            ),
                            if (hasChildren)
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () async {
                                  setState(() {
                                    info.node['collapsed'] = !isCollapsed;
                                  });
                                  await _saveToDb();
                                },
                                child: Container(
                                  width: 24,
                                  height: 24,
                                  margin: const EdgeInsets.only(left: 10),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: isCollapsed ? const Color(0xFFEF5350) : Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: const Color(0xFFEF5350),
                                      width: 1.4,
                                    ),
                                  ),
                                  child: isCollapsed
                                      ? Text(
                                          '$hiddenCount',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        )
                                      : const Text(
                                          '-',
                                          style: TextStyle(
                                            color: Color(0xFFEF5350),
                                            fontSize: 15,
                                            fontWeight: FontWeight.bold,
                                            height: 1.0,
                                          ),
                                        ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MindmapLinePainter extends CustomPainter {
  final List<_NodeLayoutInfo> nodes;
  final Map<String, _NodeLayoutInfo> nodeMap;

  _MindmapLinePainter({required this.nodes, required this.nodeMap});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFEF5350)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;

    for (final info in nodes) {
      if (info.parentId == null) continue;
      final parent = nodeMap[info.parentId!];
      if (parent == null) continue;

      final startX = parent.rect.right + 34.0;
      final startY = parent.rect.center.dy;
      final endX = info.rect.left;
      final endY = info.rect.center.dy;
      final midX = startX + (endX - startX) * 0.45;

      canvas.drawLine(
        Offset(parent.rect.right, startY),
        Offset(parent.rect.right + 10.0, startY),
        paint,
      );

      final path = Path()
        ..moveTo(startX, startY)
        ..lineTo(midX, startY)
        ..lineTo(midX, endY)
        ..lineTo(endX, endY);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MindmapLinePainter oldDelegate) => true;
}
