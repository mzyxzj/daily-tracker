import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

// ==================== 1. 查找与备份页面 (支持标题组上下拖拽排序 & 树形勾选) ====================
class SearchPage extends StatefulWidget {
  final Database db;
  const SearchPage({super.key, required this.db});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String _kw = '';
  bool _busy = false;

  Future<Map<String, dynamic>> _load() async {
    List<Map<String, dynamic>> groups;
    try {
      groups = List<Map<String, dynamic>>.from(
        await widget.db.query('module_groups', orderBy: 'sort_order ASC, id DESC'),
      );
    } catch (_) {
      groups = List<Map<String, dynamic>>.from(
        await widget.db.query('module_groups', orderBy: 'id DESC'),
      );
    }
    final hits = <Map<String, dynamic>>[];
    if (_kw.isNotEmpty) {
      final like = '%$_kw%';
      for (final r in await widget.db.rawQuery(
        'SELECT r.date, r.value, i.name FROM status_records r JOIN status_items i ON r.item_id = i.id WHERE r.value LIKE ? OR i.name LIKE ? ORDER BY r.date DESC LIMIT 30',
        [like, like],
      )) {
        hits.add({'tag': '状态 · ${r['date']}', 'title': '${r['name']}', 'sub': '${r['value']}'});
      }
      for (final m in await widget.db.query('modules', where: 'title LIKE ?', whereArgs: [like])) {
        hits.add({'tag': '家庭标题', 'title': '${m['title']}', 'sub': '点击家庭页查看'});
      }
      for (final e in await widget.db.rawQuery(
        'SELECT e.seq, e.content, m.title FROM module_entries e JOIN modules m ON e.module_id = m.id WHERE e.content LIKE ? LIMIT 30',
        [like],
      )) {
        hits.add({'tag': '家庭 · ${e['title']}', 'title': '${e['seq']}. ${e['content']}', 'sub': ''});
      }
    }
    return {'groups': groups, 'hits': hits};
  }

  Future<void> _exportBackup() async {
    setState(() => _busy = true);
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(appDir.path, 'daily_tracker.db');
      final tmpDir = await getTemporaryDirectory();
      final zipPath = p.join(tmpDir.path, 'daily_tracker_backup.zip');
      if (await File(zipPath).exists()) await File(zipPath).delete();

      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      if (await File(dbPath).exists()) encoder.addFile(File(dbPath), 'daily_tracker.db');
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

  Future<void> _importBackup() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.any);
    if (res == null || res.files.single.path == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await File(res.files.single.path!).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final appDir = await getApplicationDocumentsDirectory();
      for (final file in archive) {
        final outPath = p.join(appDir.path, file.name);
        if (file.isFile) {
          final outFile = File(outPath);
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('🎉 导入成功！请彻底关闭并重启 App 以加载恢复的数据')),
        );
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
    final mods = await widget.db.query('modules', orderBy: 'sort_order ASC, id ASC');
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
                  if (saveMode) {
                    if (nameCtrl.text.trim().isEmpty) return;
                    if (isEdit) {
                      await widget.db.update(
                        'module_groups',
                        {
                          'name': nameCtrl.text.trim(),
                          'module_ids': jsonEncode(sel.toList()),
                        },
                        where: 'id = ?',
                        whereArgs: [existingGroup['id']],
                      );
                    } else {
                      final allG = await widget.db.query('module_groups');
                      await widget.db.insert('module_groups', {
                        'name': nameCtrl.text.trim(),
                        'module_ids': jsonEncode(sel.toList()),
                        'sort_order': allG.length,
                        'created_at': DateTime.now().toIso8601String(),
                      });
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
    final allMods = await widget.db.query('modules', orderBy: 'sort_order ASC, id ASC');
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
      final es = await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [id], orderBy: 'seq ASC');
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
                  child: Text('💡 长按标题组右侧 ☰ 可上下拖动调整排列顺序', style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                ),
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: groups.length,
                  onReorder: (oldIdx, newIdx) async {
                    if (newIdx > oldIdx) newIdx -= 1;
                    final moved = groups.removeAt(oldIdx);
                    groups.insert(newIdx, moved);
                    for (int i = 0; i < groups.length; i++) {
                      await widget.db.update(
                        'module_groups',
                        {'sort_order': i},
                        where: 'id = ?',
                        whereArgs: [groups[i]['id']],
                      );
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
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: const BorderSide(color: Color(0xFFE2E8F0)),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.only(left: 14, right: 8),
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
                                await widget.db.delete('module_groups', where: 'id = ?', whereArgs: [g['id']]);
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
              if (hits.isNotEmpty) ...[
                const SizedBox(height: 12),
                ...hits.map((h) => Card(
                      child: ListTile(
                        dense: true,
                        title: Text('[${h['tag']}] ${h['title']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: (h['sub'] as String).isEmpty ? null : Text('${h['sub']}'),
                      ),
                    )),
              ],
            ],
          );
        },
      ),
    );
  }
}

// ==================== 2. 家庭模块页面 (成员卡片加宽防重叠 + 树形拖拽 + Word智能拆分导入) ====================
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

  @override
  void initState() {
    super.initState();
    _restoreFamilyUiState();
  }

  Future<void> _restoreFamilyUiState() async {
    try {
      final rows = await widget.db.query('ui_states', where: 'state_key = ?', whereArgs: ['family_collapsed_ids']);
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
      await widget.db.insert(
        'ui_states',
        {'state_key': 'family_collapsed_ids', 'state_val': jsonEncode(_collapsedIds.toList())},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> _loadAllModules() async {
    if (!_uiLoaded) await _restoreFamilyUiState();
    return await widget.db.query('modules', orderBy: 'sort_order ASC, id ASC');
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
    final target = allMods.firstWhere((m) => m['id'] == targetId);

    if (zone == 'inside') {
      final siblings = allMods.where((m) => m['parent_id'] == targetId && m['id'] != dragId).toList();
      await widget.db.update(
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
        await widget.db.update(
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

        final existing = await widget.db.query(
          'modules',
          where: parentId == null ? 'title = ? AND parent_id IS NULL' : 'title = ? AND parent_id = ?',
          whereArgs: parentId == null ? [titleToSave] : [titleToSave, parentId],
        );
        if (existing.isNotEmpty) return existing.first['id'] as int;

        final siblings = await widget.db.query(
          'modules',
          where: parentId == null ? 'parent_id IS NULL' : 'parent_id = ?',
          whereArgs: parentId == null ? null : [parentId],
        );
        createdFolders++;
        return await widget.db.insert('modules', {
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
        final existing = await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [folderId]);
        createdEntries++;
        await widget.db.insert('module_entries', {
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
  Future<void> _moduleEntriesDialog(Map<String, dynamic> mod) async {
    final modId = mod['id'] as int;
    final entries = List<Map<String, dynamic>>.from(
      await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC'),
    );

    if (!mounted) return;
    final ctrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
          title: Row(
            children: [
              const Icon(Icons.folder_open, color: Color(0xFF4F46E5), size: 20),
              const SizedBox(width: 6),
              Expanded(
                child: Text('${mod['title']} · 内容详情', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ctrl,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '添加新内容（支持换行作为整体输入，仅按序号拆分）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final raw = ctrl.text.trim();
                      if (raw.isEmpty) return;

                      // 核心修复：换行不再强行拆分，仅按显式序号（如 1. / ① / 一、）拆分，整体多行作为一体
                      final lines = <String>[];
                      final seqRegex = RegExp(r'(?:^|\n)\s*(\d+[\.、]|[①②③④⑤⑥⑦⑧⑨⑩]|[一二三四五六七八九十]+[、\.])\s*');
                      if (seqRegex.hasMatch(raw)) {
                        final parts = raw.split(seqRegex);
                        for (final p in parts) {
                          final t = p.trim();
                          if (t.isNotEmpty) lines.add(t);
                        }
                      }
                      if (lines.isEmpty) {
                        lines.add(raw); // 换行内容保持一体不拆碎
                      }

                      for (final line in lines) {
                        final curAll = await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [modId]);
                        await widget.db.insert('module_entries', {
                          'module_id': modId,
                          'seq': curAll.length + 1,
                          'content': line,
                          'sort_order': curAll.length,
                          'created_at': DateTime.now().toIso8601String(),
                        });
                      }

                      ctrl.clear();
                      entries
                        ..clear()
                        ..addAll(await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC'));
                      setS(() {});
                      setState(() {});
                    },
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加'),
                  ),
                ),
                const Divider(height: 16),
                Expanded(
                  child: entries.isEmpty
                      ? const Center(child: Text('暂无详细内容条目', style: TextStyle(color: Colors.grey)))
                      : ReorderableListView.builder(
                          shrinkWrap: true,
                          buildDefaultDragHandles: false,
                          itemCount: entries.length,
                          onReorder: (oldIdx, newIdx) async {
                            if (newIdx > oldIdx) newIdx -= 1;
                            final moved = entries.removeAt(oldIdx);
                            entries.insert(newIdx, moved);
                            for (int i = 0; i < entries.length; i++) {
                              entries[i] = {...entries[i], 'seq': i + 1, 'sort_order': i};
                              await widget.db.update(
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
                            return Container(
                              key: ValueKey('entry_${e['id']}'),
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF8FAFC),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFFE2E8F0)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2, right: 6),
                                    child: Text('${i + 1}.', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4F46E5))),
                                  ),
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () => _editEntryContentDialog(e, () async {
                                        entries
                                          ..clear()
                                          ..addAll(await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC'));
                                        setS(() {});
                                        setState(() {});
                                      }),
                                      child: Text('${e['content']}', style: const TextStyle(fontSize: 13.5, height: 1.35)),
                                    ),
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(Ico  Future<void> _moduleEntriesDialog(Map<String, dynamic> mod) async {
    final modId = mod['id'] as int;
    final entries = List<Map<String, dynamic>>.from(
      await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC'),
    );

    if (!mounted) return;
    final ctrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
          title: Row(
            children: [
              const Icon(Icons.folder_open, color: Color(0xFF4F46E5), size: 20),
              const SizedBox(width: 6),
              Expanded(
                child: Text('${mod['title']} · 内容详情', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ctrl,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '添加新内容（支持换行作为整体输入，仅按序号拆分）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final raw = ctrl.text.trim();
                      if (raw.isEmpty) return;

                      // 核心修复：换行不再强行拆分，仅按显式序号（如 1. / ① / 一、）拆分，整体多行作为一体
                      final lines = <String>[];
                      final seqRegex = RegExp(r'(?:^|\n)\s*(\d+[\.、]|[①②③④⑤⑥⑦⑧⑨⑩]|[一二三四五六七八九十]+[、\.])\s*');
                      if (seqRegex.hasMatch(raw)) {
                        final parts = raw.split(seqRegex);
                        for (final p in parts) {
                          final t = p.trim();
                          if (t.isNotEmpty) lines.add(t);
                        }
                      }
                      if (lines.isEmpty) {
                        lines.add(raw); // 换行内容保持一体不拆碎
                      }

                      for (final line in lines) {
                        final curAll = await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [modId]);
                        await widget.db.insert('module_entries', {
                          'module_id': modId,
                          'seq': curAll.length + 1,
                          'content': line,
                          'sort_order': curAll.length,
                          'created_at': DateTime.now().toIso8601String(),
                        });
                      }

                      ctrl.clear();
                      entries
                        ..clear()
                        ..addAll(await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC'));
                      setS(() {});
                      setState(() {});
                    },
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加'),
                  ),
                ),
                const Divider(height: 16),
                Expanded(
                  child: entries.isEmpty
                      ? const Center(child: Text('暂无详细内容条目', style: TextStyle(color: Colors.grey)))
                      : ReorderableListView.builder(
                          shrinkWrap: true,
                          buildDefaultDragHandles: false,
                          itemCount: entries.length,
                          onReorder: (oldIdx, newIdx) async {
                            if (newIdx > oldIdx) newIdx -= 1;
                            final moved = entries.removeAt(oldIdx);
                            entries.insert(newIdx, moved);
                            for (int i = 0; i < entries.length; i++) {
                              entries[i] = {...entries[i], 'seq': i + 1, 'sort_order': i};
                              await widget.db.update(
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
                            return Container(
                              key: ValueKey('entry_${e['id']}'),
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF8FAFC),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFFE2E8F0)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2, right: 6),
                                    child: Text('${i + 1}.', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4F46E5))),
                                  ),
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () => _editEntryContentDialog(e, () async {
                                        entries
                                          ..clear()
                                          ..addAll(await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC'));
                                        setS(() {});
                                        setState(() {});
                                      }),
                                      child: Text('${e['content']}', style: const TextStyle(fontSize: 13.5, height: 1.35)),
                                    ),
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                                    onPressed: () async {
                                      await widget.db.delete('module_entries', where: 'id = ?', whereArgs: [e['id']]);
                                      entries
                                        ..clear()
                                        ..addAll(await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC'));
                                      setS(() {});
                                      setState(() {});
                                    },
                                  ),
                                  ReorderableDragStartListener(
                                    index: i,
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                                      child: Icon(Icons.drag_handle, size: 18, color: Colors.grey),
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
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      ),
    );
  }

  Future<void> _editEntryContentDialog(Map<String, dynamic> entry, VoidCallback onSaved) async {
    final ctrl = TextEditingController(text: '${entry['content']}');
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑内容'),
        content: TextField(
          controller: ctrl,
          minLines: 2,
          maxLines: 6,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (ctrl.text.trim().isEmpty) return;
              await widget.db.update(
                'module_entries',
                {'content': ctrl.text.trim()},
                where: 'id = ?',
                whereArgs: [entry['id']],
              );
              Navigator.pop(ctx);
              onSaved();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _addOrEditModuleDialog({Map<String, dynamic>? editMod, int? parentId}) async {
    final isEdit = editMod != null;
    final ctrl = TextEditingController(text: isEdit ? '${editMod['title']}' : '');
    bool isMember = isEdit ? ((editMod['is_member'] as int? ?? 0) == 1) : (parentId == null);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(isEdit ? '编辑模块标题' : (parentId != null ? '添加子模块' : '添加顶级成员/模块'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: '标题名称'),
              ),
              const SizedBox(height: 10),
              CheckboxListTile(
                value: isMember,
                contentPadding: EdgeInsets.zero,
                title: const Text('设为成员卡片（带精美头像与徽章）'),
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
                if (isEdit) {
                  await widget.db.update(
                    'modules',
                    {'title': txt, 'is_member': isMember ? 1 : 0},
                    where: 'id = ?',
                    whereArgs: [editMod['id']],
                  );
                } else {
                  final siblings = await widget.db.query(
                    'modules',
                    where: parentId == null ? 'parent_id IS NULL' : 'parent_id = ?',
                    whereArgs: parentId == null ? null : [parentId],
                  );
                  await widget.db.insert('modules', {
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
        title: const Text('🏠 家庭档案与成员管理', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          TextButton.icon(
            onPressed: _importFamilyDocx,
            icon: const Icon(Icons.description_outlined, size: 17),
            label: const Text('导入Word'),
          ),
          IconButton(
            icon: const Icon(Icons.person_add_outlined),
            tooltip: '添加成员',
            onPressed: () => _addOrEditModuleDialog(parentId: null),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建顶级模块',
            onPressed: () => _addOrEditModuleDialog(parentId: null),
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _loadAllModules(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final mods = snap.data!;
          final validIds = mods.map((m) => m['id'] as int).toSet();
          final roots = mods.where((m) {
            final pid = m['parent_id'] as int?;
            return pid == null || !validIds.contains(pid);
          }).toList();

          List<Map<String, dynamic>> childrenOf(int pid) =>
              mods.where((m) => m['parent_id'] == pid).toList();

          Widget buildNode(Map<String, dynamic> m, int depth) {
            final id = m['id'] as int;
            final isMember = (m['is_member'] as int? ?? 0) == 1;
            final children = childrenOf(id);
            final hasChildren = children.isNotEmpty;
            final isCollapsed = _collapsedIds.contains(id);

            final isHover = _hoverTargetId == id;
            final zone = isHover ? _hoverZone : null;

            return FutureBuilder<List<Map<String, dynamic>>>(
              future: widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [id]),
              builder: (ctx, eSnap) {
                final eCount = eSnap.data?.length ?? 0;

                return Column(
                  key: ValueKey('fam_node_$id'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(left: depth * 16.0, bottom: 6),
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
                            return Container(
                              decoration: BoxDecoration(
                                color: zone == 'inside'
                                    ? const Color(0xFFEEF2FF)
                                    : (isMember ? Colors.white : const Color(0xFFF8FAFC)),
                                borderRadius: BorderRadius.circular(12),
                                border: Border(
                                  top: BorderSide(
                                    color: zone == 'up' ? const Color(0xFF4F46E5) : (isMember ? const Color(0xFFE2E8F0) : const Color(0xFFCBD5E1)),
                                    width: zone == 'up' ? 3.0 : (isMember ? 1.3 : 1.0),
                                  ),
                                  bottom: BorderSide(
                                    color: zone == 'down' ? const Color(0xFF4F46E5) : (isMember ? const Color(0xFFE2E8F0) : const Color(0xFFCBD5E1)),
                                    width: zone == 'down' ? 3.0 : (isMember ? 1.3 : 1.0),
                                  ),
                                  left: BorderSide(
                                    color: zone == 'inside'
                                        ? const Color(0xFF4F46E5)
                                        : (isMember ? const Color(0xFF4F46E5) : const Color(0xFF94A3B8)),
                                    width: zone == 'inside' ? 2.5 : (isMember ? 4.0 : 2.0),
                                  ),
                                  right: BorderSide(
                                    color: zone == 'inside' ? const Color(0xFF4F46E5) : (isMember ? const Color(0xFFE2E8F0) : const Color(0xFFCBD5E1)),
                                    width: zone == 'inside' ? 2.5 : (isMember ? 1.3 : 1.0),
                                  ),
                                ),
                                boxShadow: isMember
                                    ? const [BoxShadow(color: Color(0x0A000000), blurRadius: 6, offset: Offset(0, 2))]
                                    : null,
                              ),
                              // 核心需求 ①：上下宽度适当调宽（vertical: 13.5），避免与图标重叠
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13.5),
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
                                        padding: const EdgeInsets.only(right: 2),
                                        child: Icon(
                                          isCollapsed ? Icons.chevron_right : Icons.expand_more,
                                          size: 20,
                                          color: const Color(0xFF4F46E5),
                                        ),
                                      ),
                                    )
                                  else if (depth > 0)
                                    const Padding(
                                      padding: EdgeInsets.only(right: 4),
                                      child: Icon(Icons.subdirectory_arrow_right, size: 16, color: Colors.grey),
                                    )
                                  else
                                    const SizedBox(width: 4),
                                  if (isMember) ...[
                                    CircleAvatar(
                                      radius: 14,
                                      backgroundColor: const Color(0xFFEEF2FF),
                                      child: Text('${m['title']}'.substring(0, 1), style: const TextStyle(color: Color(0xFF4F46E5), fontSize: 13, fontWeight: FontWeight.bold)),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  // 使用 Expanded + Wrap 自适应内部流式标签，彻底杜绝图标重叠
                                  Expanded(
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () => _moduleEntriesDialog(m),
                                      child: Wrap(
                                        crossAxisAlignment: WrapCrossAlignment.center,
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          Text(
                                            '${m['title']}',
                                            style: TextStyle(
                                              fontWeight: isMember || depth == 0 ? FontWeight.bold : FontWeight.normal,
                                              fontSize: isMember ? 15 : 13.5,
                                              color: const Color(0xFF1E293B),
                                            ),
                                          ),
                                          if (isMember)
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                              decoration: BoxDecoration(color: const Color(0xFFEEF2FF), borderRadius: BorderRadius.circular(4)),
                                              child: const Text('✨ MEMBER', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Color(0xFF4F46E5))),
                                            ),
                                          if (eCount > 0)
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                              decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(4)),
                                              child: Text('$eCount 项', style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B))),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  InkWell(
                                    onTap: () => _moduleEntriesDialog(m),
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                                      child: Icon(Icons.folder_open, size: 18, color: Color(0xFF4F46E5)),
                                    ),
                                  ),
                                  InkWell(
                                    onTap: () => _addOrEditModuleDialog(parentId: id),
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                                      child: Icon(Icons.add_circle_outline, size: 17, color: Color(0xFF0D9488)),
                                    ),
                                  ),
                                  InkWell(
                                    onTap: () => _addOrEditModuleDialog(editMod: m),
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                                      child: Icon(Icons.edit_outlined, size: 16, color: Colors.blueGrey),
                                    ),
                                  ),
                                  InkWell(
                                    onTap: () async {
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
                                        await widget.db.delete('module_entries', where: 'module_id = ?', whereArgs: [did]);
                                        await widget.db.delete('modules', where: 'id = ?', whereArgs: [did]);
                                      }
                                      setState(() {});
                                    },
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                                      child: Icon(Icons.delete_outline, size: 17, color: Colors.redAccent),
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
                                        child: Text('${m['title']}', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
                                      ),
                                    ),
                                    child: const Padding(
                                      padding: EdgeInsets.only(left: 4, right: 2, top: 3, bottom: 3),
                                      child: Icon(Icons.drag_handle, size: 18, color: Colors.grey),
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
              },
            );
          }

          return mods.isEmpty
              ? const Center(child: Text('暂无家庭模块，点击右上角「+」或「导入Word」添加', style: TextStyle(color: Colors.grey)))
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(left: 4, bottom: 8),
                      child: Text('💡 长按右侧 ☰ 自由拖动：拖到其他模块中央变为其子模块，拖到上下边缘调整排序', style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                    ),
                    ...roots.map((r) => buildNode(r, 0)),
                  ],
                );
        },
      ),
    );
  }
}

// ==================== 3. 规划与思维导图页面 ====================
class PlanPage extends StatefulWidget {
  final Database db;
  const PlanPage({super.key, required this.db});
  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  Future<List<Map<String, dynamic>>> _loadMindmaps() async {
    return await widget.db.query('mindmaps', orderBy: 'id DESC');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🎯 规划与目标', style: TextStyle(fontWeight: FontWeight.bold))),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _loadMindmaps(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final maps = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (maps.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('暂无规划目标，请前往查找页或导入相关规划')),
                )
              else
                ...maps.map((m) => Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        title: Text('${m['title']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('创建于: ${m['created_at'].toString().substring(0, 10)}', style: const TextStyle(fontSize: 12)),
                      ),
                    )),
            ],
          );
        },
      ),
    );
  }
}
