import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class SequenceParser {
  static List<({int seq, String text})> parse(String raw, int currentMaxSeq) {
    final lines = raw.split('\n');
    final results = <({int seq, String text})>[];
    final circledMap = <String, int>{};
    for (int i = 0; i < 20; i++) circledMap[String.fromCharCode(0x2460 + i)] = i + 1;
    for (int i = 0; i < 30; i++) circledMap[String.fromCharCode(0x3251 + i)] = i + 21;
    final arabic = RegExp(r'^(\d+)[\.、\)）]\s*(.*)$');
    final paren = RegExp(r'^[\(（](\d+)[\)）]\s*(.*)$');
    int autoSeq = currentMaxSeq;

    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final fc = t.characters.first;
      if (circledMap.containsKey(fc)) {
        final c = t.substring(fc.length).trim();
        if (c.isNotEmpty) results.add((seq: circledMap[fc]!, text: c));
        continue;
      }
      final m1 = arabic.firstMatch(t);
      if (m1 != null && m1.group(2)!.trim().isNotEmpty) {
        results.add((seq: int.parse(m1.group(1)!), text: m1.group(2)!.trim()));
        continue;
      }
      final m2 = paren.firstMatch(t);
      if (m2 != null && m2.group(2)!.trim().isNotEmpty) {
        results.add((seq: int.parse(m2.group(1)!), text: m2.group(2)!.trim()));
        continue;
      }
      autoSeq++;
      results.add((seq: autoSeq, text: t));
    }
    return results;
  }
}

class ModuleTreeSelector extends StatefulWidget {
  final List<Map<String, dynamic>> allMods;
  final Set<int> selectedIds;
  final VoidCallback onChanged;

  const ModuleTreeSelector({
    super.key,
    required this.allMods,
    required this.selectedIds,
    required this.onChanged,
  });

  @override
  State<ModuleTreeSelector> createState() => _ModuleTreeSelectorState();
}

class _ModuleTreeSelectorState extends State<ModuleTreeSelector> {
  final Set<int> _expandedIds = {};

  List<Map<String, dynamic>> _childrenOf(int? pid) {
    return widget.allMods.where((m) => m['parent_id'] == pid).toList();
  }

  List<int> _descendantsOf(int pid) {
    final res = <int>[];
    void walk(int cur) {
      for (final m in _childrenOf(cur)) {
        final id = m['id'] as int;
        res.add(id);
        walk(id);
      }
    }
    walk(pid);
    return res;
  }

  @override
  Widget build(BuildContext context) {
    final roots = _childrenOf(null);
    if (roots.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: Text('暂无标题', style: TextStyle(color: Colors.grey))),
      );
    }
    return ListView(
      shrinkWrap: true,
      children: roots.map((r) => _buildNode(r, 0)).toList(),
    );
  }

  Widget _buildNode(Map<String, dynamic> m, int depth) {
    final id = m['id'] as int;
    final children = _childrenOf(id);
    final hasChildren = children.isNotEmpty;
    final isExpanded = _expandedIds.contains(id);
    final isChecked = widget.selectedIds.contains(id);
    final descIds = hasChildren ? _descendantsOf(id) : <int>[];
    final selectedChildCount = descIds.where((cid) => widget.selectedIds.contains(cid)).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              if (isChecked) {
                widget.selectedIds.remove(id);
              } else {
                widget.selectedIds.add(id);
              }
            });
            widget.onChanged();
          },
          child: Padding(
            padding: EdgeInsets.only(left: depth * 16.0, top: 2, bottom: 2),
            child: SizedBox(
              height: 32,
              child: Row(
                children: [
                  if (hasChildren)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => isExpanded ? _expandedIds.remove(id) : _expandedIds.add(id)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Icon(
                          isExpanded ? Icons.arrow_drop_down : Icons.arrow_right,
                          size: 20,
                          color: const Color(0xFF4F46E5),
                        ),
                      ),
                    )
                  else
                    const SizedBox(width: 28),
                  Icon(
                    depth == 0 ? Icons.folder_outlined : Icons.subdirectory_arrow_right,
                    size: 16,
                    color: depth == 0 ? Colors.indigo : Colors.blueGrey,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${m['title']}',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: depth == 0 ? FontWeight.w600 : FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (hasChildren)
                    GestureDetector(
                      onTap: () => setState(() => isExpanded ? _expandedIds.remove(id) : _expandedIds.add(id)),
                      child: Container(
                        margin: const EdgeInsets.only(right: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: selectedChildCount > 0 ? const Color(0xFFEEF2FF) : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          selectedChildCount > 0 ? '已选$selectedChildCount/${children.length}' : '细筛(${children.length})',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: selectedChildCount > 0 ? const Color(0xFF4F46E5) : Colors.grey[600],
                          ),
                        ),
                      ),
                    ),
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: Checkbox(
                      value: isChecked,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            widget.selectedIds.add(id);
                          } else {
                            widget.selectedIds.remove(id);
                          }
                        });
                        widget.onChanged();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (hasChildren && isExpanded)
          ...children.map((c) => _buildNode(c, depth + 1)),
      ],
    );
  }
}

class FamilyPage extends StatefulWidget {
  final Database db;
  const FamilyPage({super.key, required this.db});
  @override
  State<FamilyPage> createState() => _FamilyPageState();
}

class _FamilyPageState extends State<FamilyPage> {
  final Set<int> _expandedMods = {};

  Future<List<Map<String, dynamic>>> _loadMods() async {
    return widget.db.query('modules', orderBy: 'sort_order ASC, id ASC');
  }

  String _buildFullPath(int id, Map<int, Map<String, dynamic>> map) {
    final parts = <String>[];
    int? cur = id;
    int guard = 0;
    while (cur != null && map.containsKey(cur) && guard++ < 20) {
      parts.insert(0, '${map[cur]!['title']}');
      cur = map[cur]!['parent_id'] as int?;
    }
    return parts.join(' > ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 46,
        title: const Text('🏠 家庭', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        actions: [
          TextButton.icon(
            onPressed: () => _createOrEditMod(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新建大标题'),
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _loadMods(),
        builder: (_, snap) {
          final all = snap.data ?? [];
          if (all.isEmpty) return const Center(child: Text('暂无大标题，点击右上角新建'));
          final map = {for (final m in all) m['id'] as int: m};
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: _buildModLevel(null, 0, all, map),
          );
        },
      ),
    );
  }

  Widget _buildModLevel(int? parentId, int depth, List<Map<String, dynamic>> all, Map<int, Map<String, dynamic>> map) {
    final items = all.where((m) => m['parent_id'] == parentId).toList();
    if (items.isEmpty) return const SizedBox.shrink();

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: items.length,
      onReorder: (oldIdx, newIdx) async {
        if (newIdx > oldIdx) newIdx -= 1;
        final moved = items.removeAt(oldIdx);
        items.insert(newIdx, moved);
        for (int i = 0; i < items.length; i++) {
          await widget.db.update('modules', {'sort_order': i}, where: 'id = ?', whereArgs: [items[i]['id']]);
        }
        setState(() {});
      },
      itemBuilder: (ctx, i) {
        final m = items[i];
        final id = m['id'] as int;
        final subList = all.where((x) => x['parent_id'] == id).toList();
        final hasSub = subList.isNotEmpty;
        final isExpanded = _expandedMods.contains(id);

        return Column(
          key: ValueKey('mod_$id'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              margin: EdgeInsets.only(left: depth * 16.0, bottom: 6),
              color: depth == 0 ? null : const Color(0xFFF8FAFC),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _openEntries(id, _buildFullPath(id, map)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      if (hasSub)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => isExpanded ? _expandedMods.remove(id) : _expandedMods.add(id)),
                          child: Padding(
                            padding: const EdgeInsets.only(right: 4, top: 2, bottom: 2),
                            child: Icon(isExpanded ? Icons.expand_more : Icons.chevron_right, size: 20, color: const Color(0xFF4F46E5)),
                          ),
                        )
                      else
                        const SizedBox(width: 4),
                      Icon(depth == 0 ? Icons.folder_outlined : Icons.subdirectory_arrow_right, color: Colors.indigo, size: 19),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                '${m['title']}',
                                style: TextStyle(fontWeight: depth == 0 ? FontWeight.bold : FontWeight.w600, fontSize: depth == 0 ? 15 : 14),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (hasSub) ...[
                              const SizedBox(width: 6),
                              GestureDetector(
                                onTap: () => setState(() => isExpanded ? _expandedMods.remove(id) : _expandedMods.add(id)),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFEEF2FF),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${subList.length}',
                                    style: const TextStyle(fontSize: 11, color: Color(0xFF4F46E5), fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      IconButton(
                        visualDensity: const VisualDensity(horizontal: -3, vertical: -3),
                        tooltip: '添加内部小标题',
                        icon: const Icon(Icons.create_new_folder_outlined, size: 18, color: Colors.indigo),
                        onPressed: () => _createOrEditMod(parentId: id, parentTitle: '${m['title']}'),
                      ),
                      IconButton(
                        visualDensity: const VisualDensity(horizontal: -3, vertical: -3),
                        tooltip: '修改标题名称',
                        icon: const Icon(Icons.edit_outlined, size: 18, color: Colors.blueGrey),
                        onPressed: () => _createOrEditMod(editMod: m),
                      ),
                      IconButton(
                        visualDensity: const VisualDensity(horizontal: -3, vertical: -3),
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                        onPressed: () => _deleteModCascade(id, all),
                      ),
                      ReorderableDragStartListener(
                        index: i,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(Icons.drag_handle, color: Colors.grey, size: 19),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (hasSub && isExpanded) _buildModLevel(id, depth + 1, all, map),
          ],
        );
      },
    );
  }

  Future<void> _deleteModCascade(int rootId, List<Map<String, dynamic>> all) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('删除该标题及其下属的所有子标题和内容？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;

    final toDel = <int>[];
    void collect(int pid) {
      toDel.add(pid);
      for (final m in all.where((x) => x['parent_id'] == pid)) {
        collect(m['id'] as int);
      }
    }
    collect(rootId);
    for (final did in toDel) {
      await widget.db.delete('module_entries', where: 'module_id = ?', whereArgs: [did]);
      await widget.db.delete('modules', where: 'id = ?', whereArgs: [did]);
    }
    setState(() {});
  }

  void _createOrEditMod({int? parentId, String? parentTitle, Map<String, dynamic>? editMod}) {
    final isEdit = editMod != null;
    final ctrl = TextEditingController(text: isEdit ? '${editMod['title']}' : '');
    final dlgTitle = isEdit ? '修改标题名称' : (parentId == null ? '新建大标题' : '在「$parentTitle」下新建小标题');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(dlgTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入标题名称'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final txt = ctrl.text.trim();
              if (txt.isEmpty) return;
              if (isEdit) {
                await widget.db.update('modules', {'title': txt}, where: 'id = ?', whereArgs: [editMod['id']]);
              } else {
                final siblings = await widget.db.query(
                  'modules',
                  where: parentId == null ? 'parent_id IS NULL' : 'parent_id = ?',
                  whereArgs: parentId == null ? null : [parentId],
                );
                await widget.db.insert('modules', {
                  'title': txt,
                  'parent_id': parentId,
                  'sort_order': siblings.length,
                  'created_at': DateTime.now().toIso8601String(),
                });
                if (parentId != null) _expandedMods.add(parentId);
              }
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: Text(isEdit ? '保存' : '创建'),
          ),
        ],
      ),
    );
  }

  void _openEntries(int modId, String fullPath) {
    final ctrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.92,
          maxChildSize: 0.96,
          builder: (_, sc) => Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.of(ctx).viewInsets.bottom + 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '📁 $fullPath',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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
                        _createOrEditMod(parentId: modId, parentTitle: fullPath.split(' > ').last);
                      },
                      icon: const Icon(Icons.create_new_folder_outlined, size: 15),
                      label: const Text('加小标题', style: TextStyle(fontSize: 12)),
                    ),
                    IconButton(
                      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: widget.db.query('modules', where: 'parent_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, id ASC'),
                  builder: (_, subSnap) {
                    final subs = subSnap.data ?? [];
                    if (subs.isEmpty) return const SizedBox(height: 6);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: subs.map((s) => ActionChip(
                          visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                          avatar: const Icon(Icons.folder_open, size: 14, color: Colors.indigo),
                          label: Text('${s['title']}', style: const TextStyle(fontSize: 12)),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _openEntries(s['id'] as int, '$fullPath > ${s['title']}');
                          },
                        )).toList(),
                      ),
                    );
                  },
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: ctrl,
                        minLines: 1,
                        maxLines: 3,
                        style: const TextStyle(fontSize: 13.5),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          border: OutlineInputBorder(),
                          hintText: '输入内容(支持 1. / ① 自动拆分)，点下方文字可编辑',
                          hintStyle: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        minimumSize: Size.zero,
                      ),
                      onPressed: () async {
                        if (ctrl.text.trim().isEmpty) return;
                        final ex = await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [modId]);
                        final maxS = ex.isEmpty ? 0 : ex.map((e) => e['seq'] as int).reduce((a, b) => a > b ? a : b);
                        int nextOrder = ex.length;
                        for (final it in SequenceParser.parse(ctrl.text, maxS)) {
                          await widget.db.insert('module_entries', {
                            'module_id': modId,
                            'seq': it.seq,
                            'content': it.text,
                            'sort_order': nextOrder++,
                            'created_at': DateTime.now().toIso8601String(),
                          });
                        }
                        ctrl.clear();
                        setS(() {});
                      },
                      child: const Text('添加', style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Divider(height: 1),
                Expanded(
                  child: FutureBuilder<List<Map<String, dynamic>>>(
                    future: widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'sort_order ASC, seq ASC, id ASC'),
                    builder: (_, snap) {
                      final list = List<Map<String, dynamic>>.from(snap.data ?? []);
                      if (list.isEmpty) return const Center(child: Text('暂无内容', style: TextStyle(color: Colors.grey)));
                      return ReorderableListView.builder(
                        scrollController: sc,
                        buildDefaultDragHandles: false,
                        itemCount: list.length,
                        onReorder: (oldIdx, newIdx) async {
                          if (newIdx > oldIdx) newIdx -= 1;
                          final item = list.removeAt(oldIdx);
                          list.insert(newIdx, item);
                          for (int i = 0; i < list.length; i++) {
                            await widget.db.update(
                              'module_entries',
                              {'sort_order': i, 'seq': i + 1},
                              where: 'id = ?',
                              whereArgs: [list[i]['id']],
                            );
                          }
                          setS(() {});
                        },
                        itemBuilder: (_, i) {
                          final e = list[i];
                          return Container(
                            key: ValueKey('entry_${e['id']}'),
                            decoration: const BoxDecoration(
                              border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 7),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 22,
                                  height: 22,
                                  margin: const EdgeInsets.only(top: 1, right: 8),
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFEEF2FF),
                                    shape: BoxShape.circle,
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '${e['seq']}',
                                    style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF4F46E5)),
                                  ),
                                ),
                                Expanded(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => _editEntryDialog(e, () => setS(() {})),
                                    child: Text(
                                      '${e['content']}',
                                      style: const TextStyle(fontSize: 14, height: 1.4, color: Color(0xFF1F2937)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                GestureDetector(
                                  onTap: () async {
                                    await widget.db.delete('module_entries', where: 'id = ?', whereArgs: [e['id']]);
                                    setS(() {});
                                  },
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                    child: Icon(Icons.close, size: 16, color: Colors.redAccent),
                                  ),
                                ),
                                ReorderableDragStartListener(
                                  index: i,
                                  child: const Padding(
                                    padding: EdgeInsets.only(left: 4, right: 2, top: 2),
                                    child: Icon(Icons.drag_handle, size: 18, color: Colors.grey),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
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

  void _editEntryDialog(Map<String, dynamic> entry, VoidCallback onSaved) {
    final seqCtrl = TextEditingController(text: '${entry['seq']}');
    final txtCtrl = TextEditingController(text: '${entry['content']}');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('编辑内容', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(
              width: 72,
              child: TextField(
                controller: seqCtrl,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  labelText: '序号',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: txtCtrl,
            minLines: 6,
            maxLines: 14,
            autofocus: true,
            style: const TextStyle(fontSize: 14, height: 1.45),
            decoration: const InputDecoration(
              hintText: '输入内容文本...',
              contentPadding: EdgeInsets.all(10),
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final newTxt = txtCtrl.text.trim();
              if (newTxt.isEmpty) return;
              final newSeq = int.tryParse(seqCtrl.text.trim()) ?? (entry['seq'] as int);
              await widget.db.update(
                'module_entries',
                {'seq': newSeq, 'content': newTxt},
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
}

class SearchPage extends StatefulWidget {
  final Database db;
  const SearchPage({super.key, required this.db});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String _modPath(int id, Map<int, Map<String, dynamic>> map) {
    final parts = <String>[];
    int? cur = id;
    int guard = 0;
    while (cur != null && map.containsKey(cur) && guard++ < 20) {
      parts.insert(0, '${map[cur]!['title']}');
      cur = map[cur]!['parent_id'] as int?;
    }
    return parts.join(' > ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 46,
        title: const Text('🔍 查找', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: widget.db.query('module_groups', orderBy: 'id DESC'),
        builder: (_, snap) {
          final groups = snap.data ?? [];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _createOrEditGroup(),
                      icon: const Icon(Icons.add),
                      label: const Text('新建标题组'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _tempView,
                      icon: const Icon(Icons.visibility_outlined),
                      label: const Text('临时查看'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (groups.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: Text('暂无标题组，新建后可一键聚合查阅')),
                  ),
                ),
              ...groups.map((g) {
                final ids = '${g['module_ids']}'.split(',').where((s) => s.isNotEmpty).map(int.parse).toList();
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.folder_special, color: Colors.indigo),
                    title: Text('${g['name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('已选 ${ids.length} 项 · 点击查看', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '编辑标题组（增减大标题）',
                          icon: const Icon(Icons.edit_outlined, color: Colors.blueGrey, size: 20),
                          onPressed: () => _createOrEditGroup(existingGroup: g),
                        ),
                        IconButton(
                          tooltip: '删除标题组',
                          icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                          onPressed: () async {
                            await widget.db.delete('module_groups', where: 'id = ?', whereArgs: [g['id']]);
                            setState(() {});
                          },
                        ),
                      ],
                    ),
                    onTap: () => _showAgg('${g['name']}', ids),
                  ),
                );
              }),
              const SizedBox(height: 24),
              const Text('💾 数据备份与恢复', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(child: FilledButton.tonalIcon(onPressed: _exportZip, icon: const Icon(Icons.upload_file), label: const Text('导出备份'))),
                      const SizedBox(width: 10),
                      Expanded(child: OutlinedButton.icon(onPressed: _importZip, icon: const Icon(Icons.download), label: const Text('导入恢复'))),
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

  Future<void> _createOrEditGroup({Map<String, dynamic>? existingGroup}) async {
    final mods = await widget.db.query('modules', orderBy: 'sort_order ASC, id ASC');
    if (!mounted) return;
    if (mods.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先在「家庭」页创建大标题')));
      return;
    }

    final isEdit = existingGroup != null;
    final ctrl = TextEditingController(text: isEdit ? '${existingGroup['name']}' : '');
    final sel = <int>{};
    if (isEdit) {
      final rawIds = '${existingGroup['module_ids']}'.split(',').where((s) => s.isNotEmpty).map(int.parse);
      sel.addAll(rawIds);
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          titlePadding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(isEdit ? '编辑标题组' : '新建标题组', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              Text('已选 ${sel.length} 项', style: const TextStyle(fontSize: 12, color: Color(0xFF4F46E5))),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(ctx).size.height * 0.62,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ctrl,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    labelText: '组名',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '💡 提示：直接勾选大标题将包含其全部内容；点击左侧 ▶ 可展开精细化筛选内部小标题',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const Divider(height: 10),
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
                if (ctrl.text.trim().isEmpty || sel.isEmpty) return;
                if (isEdit) {
                  await widget.db.update(
                    'module_groups',
                    {'name': ctrl.text.trim(), 'module_ids': sel.join(',')},
                    where: 'id = ?',
                    whereArgs: [existingGroup['id']],
                  );
                } else {
                  await widget.db.insert('module_groups', {
                    'name': ctrl.text.trim(),
                    'module_ids': sel.join(','),
                    'created_at': DateTime.now().toIso8601String(),
                  });
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

  Future<void> _tempView() async {
    final mods = await widget.db.query('modules', orderBy: 'sort_order ASC, id ASC');
    if (!mounted || mods.isEmpty) return;
    final sel = <int>{};
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          titlePadding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('临时勾选查看', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              Text('已选 ${sel.length} 项', style: const TextStyle(fontSize: 12, color: Color(0xFF4F46E5))),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(ctx).size.height * 0.58,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '💡 点击左侧 ▶ 可展开大标题精细化勾选小标题',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const Divider(height: 10),
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
                Navigator.pop(ctx);
                if (sel.isNotEmpty) _showAgg('临时查看', sel.toList());
              },
              child: const Text('查看'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAgg(String title, List<int> ids) async {
    final allMods = await widget.db.query('modules', orderBy: 'sort_order ASC, id ASC');
    final map = {for (final m in allMods) m['id'] as int: m};
    final selectedSet = ids.toSet();

    List<int> getDescendants(int pid) {
      final res = <int>[];
      void walk(int cur) {
        for (final m in allMods.where((x) => x['parent_id'] == cur)) {
          final cid = m['id'] as int;
          res.add(cid);
          walk(cid);
        }
      }
      walk(pid);
      return res;
    }

    final expandedIds = <int>[];
    void addSmart(int pid) {
      if (!expandedIds.contains(pid)) expandedIds.add(pid);
      final desc = getDescendants(pid);
      final hasSpecificChildSelected = desc.any((cid) => selectedSet.contains(cid));
      if (!hasSpecificChildSelected) {
        for (final cid in desc) {
          if (!expandedIds.contains(cid)) expandedIds.add(cid);
        }
      }
    }

    for (final id in ids) {
      if (map.containsKey(id)) addSmart(id);
    }

    final blocks = <Widget>[];
    for (final id in expandedIds) {
      final es = await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [id], orderBy: 'sort_order ASC, seq ASC, id ASC');
      final hasChildrenInList = allMods.any((x) => x['parent_id'] == id && expandedIds.contains(x['id'] as int));
      if (es.isEmpty && hasChildrenInList) continue;

      blocks.add(Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('📁 ${_modPath(id, map)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1E293B))),
              const Divider(height: 12),
              if (es.isEmpty)
                const Text('（暂无内容）', style: TextStyle(color: Colors.grey, fontSize: 13))
              else
                ...es.map((e) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text('${e['seq']}. ${e['content']}', style: const TextStyle(fontSize: 14, height: 1.4)),
                    )),
            ],
          ),
        ),
      ));
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.82,
        maxChildSize: 0.95,
        builder: (_, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.all(14),
          children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            ...blocks,
          ],
        ),
      ),
    );
  }

  Future<void> _exportZip() async {
    final appDir = await getApplicationDocumentsDirectory();
    final data = {
      'app': 'daily_tracker',
      'version': '4.0.0',
      'data': {
        for (final t in ['status_items', 'status_records', 'status_images', 'schedule_items', 'schedule_records', 'modules', 'module_entries', 'module_groups', 'mindmaps'])
          t: await widget.db.query(t),
      },
    };
    final zipPath = p.join(appDir.path, '每日记录_备份_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.zip');
    final enc = ZipFileEncoder()..create(zipPath);
    final jb = utf8.encode(jsonEncode(data));
    enc.addArchiveFile(ArchiveFile('data.json', jb.length, jb));
    final imgDir = Directory(p.join(appDir.path, 'images'));
    if (await imgDir.exists()) {
      await for (final f in imgDir.list(recursive: true)) {
        if (f is File) {
          final b = await f.readAsBytes();
          enc.addArchiveFile(ArchiveFile(p.relative(f.path, from: appDir.path), b.length, b));
        }
      }
    }
    enc.close();
    await Share.shareXFiles([XFile(zipPath)]);
  }

  Future<void> _importZip() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.any);
    if (res == null || res.files.single.path == null) return;
    final arch = ZipDecoder().decodeBytes(await File(res.files.single.path!).readAsBytes());
    final appDir = await getApplicationDocumentsDirectory();
    Map<String, dynamic>? bj;
    for (final f in arch) {
      if (!f.isFile) continue;
      if (f.name == 'data.json') bj = jsonDecode(utf8.decode(f.content as List<int>)) as Map<String, dynamic>;
      else if (f.name.startsWith('images/')) {
        final out = File(p.join(appDir.path, f.name));
        await out.parent.create(recursive: true);
        await out.writeAsBytes(f.content as List<int>);
      }
    }
    if (bj == null || bj['app'] != 'daily_tracker') return;
    final tables = bj['data'] as Map<String, dynamic>;
    for (final e in tables.entries) {
      for (final r in (e.value as List)) {
        await widget.db.insert(e.key, Map<String, Object?>.from(r as Map), conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    if (mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('导入恢复成功！'))); setState(() {}); }
  }
}

// ==================== 二维连接线思维导图绘制器（支持从左向右树形连接线 + 折叠） ====================
class _BranchLinePainter extends CustomPainter {
  final int childCount;
  final Color color;
  _BranchLinePainter({required this.childCount, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;
    final midY = size.height / 2;
    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), p);
  }

  @override
  bool shouldRepaint(covariant _BranchLinePainter oldDelegate) => false;
}

class MindmapGraphView extends StatelessWidget {
  final Map<String, dynamic> root;
  final Set<String> collapsedIds;
  final void Function(String nodeId) onToggleCollapse;
  final void Function(Map<String, dynamic> node, int depth) onTapNode;

  const MindmapGraphView({
    super.key,
    required this.root,
    required this.collapsedIds,
    required this.onToggleCollapse,
    required this.onTapNode,
  });

  static const List<Color> _palette = [
    Color(0xFF4F46E5),
    Color(0xFF0EA5E9),
    Color(0xFF10B981),
    Color(0xFFF59E0B),
    Color(0xFFEC4899),
    Color(0xFF8B5CF6),
  ];

  @override
  Widget build(BuildContext context) {
    return _buildSubtree(root, 0, 0);
  }

  Widget _buildSubtree(Map<String, dynamic> node, int depth, int branchIndex) {
    final id = '${node['id']}';
    final children = (node['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final isCollapsed = collapsedIds.contains(id);
    final hasChildren = children.isNotEmpty;
    final accent = _palette[branchIndex % _palette.length];

    final nodeCard = _buildNodeCard(node, depth, accent, hasChildren, isCollapsed, children.length);

    if (!hasChildren || isCollapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: nodeCard,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            nodeCard,
            // 父节点右侧引出水平连接线
            SizedBox(
              width: 18,
              height: 20,
              child: CustomPaint(painter: _BranchLinePainter(childCount: children.length, color: accent.withOpacity(0.55))),
            ),
            // 子节点列（左侧带垂直汇流树枝线）
            Container(
              decoration: children.length > 1
                  ? BoxDecoration(
                      border: Border(left: BorderSide(color: accent.withOpacity(0.45), width: 2)),
                    )
                  : null,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(children.length, (idx) {
                  final subBranchIdx = depth == 0 ? idx : branchIndex;
                  final subColor = _palette[subBranchIdx % _palette.length];
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(width: 14, height: 1.8, color: subColor.withOpacity(0.55)),
                      _buildSubtree(children[idx], depth + 1, subBranchIdx),
                    ],
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNodeCard(
    Map<String, dynamic> node,
    int depth,
    Color accent,
    bool hasChildren,
    bool isCollapsed,
    int childCount,
  ) {
    final id = '${node['id']}';
    Color bg;
    Color fg;
    Color borderCol;
    if (depth == 0) {
      bg = const Color(0xFF4F46E5);
      fg = Colors.white;
      borderCol = const Color(0xFF4F46E5);
    } else if (depth == 1) {
      bg = accent.withOpacity(0.12);
      fg = const Color(0xFF0F172A);
      borderCol = accent.withOpacity(0.6);
    } else {
      bg = Colors.white;
      fg = const Color(0xFF1E293B);
      borderCol = accent.withOpacity(0.35);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => onTapNode(node, depth),
          child: Container(
            constraints: BoxConstraints(minWidth: 56, maxWidth: depth == 0 ? 180 : 210),
            padding: EdgeInsets.symmetric(horizontal: depth == 0 ? 12 : 10, vertical: depth == 0 ? 8 : 6),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderCol, width: depth <= 1 ? 1.5 : 1.0),
              boxShadow: const [BoxShadow(color: Color(0x0A000000), blurRadius: 3, offset: Offset(0, 1))],
            ),
            child: Text(
              '${node['text']}',
              style: TextStyle(
                fontSize: depth == 0 ? 14 : (depth == 1 ? 13 : 12.5),
                fontWeight: depth <= 1 ? FontWeight.bold : FontWeight.w500,
                color: fg,
                height: 1.3,
              ),
            ),
          ),
        ),
        if (hasChildren)
          GestureDetector(
            onTap: () => onToggleCollapse(id),
            child: Container(
              margin: const EdgeInsets.only(left: 3),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: isCollapsed ? accent : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: accent, width: 1.2),
              ),
              child: Text(
                isCollapsed ? '+$childCount' : '−',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                  color: isCollapsed ? Colors.white : accent,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ==================== 全屏横屏思维导图画布页 ====================
class FullscreenMindmapPage extends StatefulWidget {
  final int mmId;
  final Map<String, dynamic> root;
  final Set<String> collapsedIds;
  final Future<void> Function(Map<String, dynamic> updatedRoot) onSave;

  const FullscreenMindmapPage({
    super.key,
    required this.mmId,
    required this.root,
    required this.collapsedIds,
    required this.onSave,
  });

  @override
  State<FullscreenMindmapPage> createState() => _FullscreenMindmapPageState();
}

class _FullscreenMindmapPageState extends State<FullscreenMindmapPage> {
  final _uuid = const Uuid();
  bool _isLandscape = true;

  @override
  void initState() {
    super.initState();
    // 进入全屏画布默认切换为横屏，视野更开阔
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    // 退出时自动恢复竖屏
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    super.dispose();
  }

  void _toggleOrientation() {
    setState(() {
      _isLandscape = !_isLandscape;
      if (_isLandscape) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
      }
    });
  }

  bool _rm(Map<String, dynamic> p, String tid) {
    final ch = (p['children'] as List).cast<Map<String, dynamic>>();
    final idx = ch.indexWhere((c) => c['id'] == tid);
    if (idx != -1) { ch.removeAt(idx); return true; }
    return ch.any((c) => _rm(c, tid));
  }

  void _onNodeAction(Map<String, dynamic> node, int depth) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.account_tree, color: Color(0xFF4F46E5)),
              title: Text('${node['text']}', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('选择对该节点的操作'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add_circle_outline, color: Colors.indigo),
              title: const Text('添加子节点'),
              onTap: () {
                Navigator.pop(ctx);
                final ctrl = TextEditingController();
                showDialog(
                  context: context,
                  builder: (dCtx) => AlertDialog(
                    title: const Text('添加子节点'),
                    content: TextField(controller: ctrl, autofocus: true, minLines: 1, maxLines: 3),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('取消')),
                      FilledButton(
                        onPressed: () async {
                          if (ctrl.text.trim().isEmpty) return;
                          (node['children'] as List).add({'id': _uuid.v4(), 'text': ctrl.text.trim(), 'children': []});
                          widget.collapsedIds.remove('${node['id']}');
                          if (mounted) Navigator.pop(dCtx);
                          await widget.onSave(widget.root);
                          setState(() {});
                        },
                        child: const Text('添加'),
                      ),
                    ],
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: Colors.blueGrey),
              title: const Text('修改节点文字'),
              onTap: () {
                Navigator.pop(ctx);
                final ctrl = TextEditingController(text: '${node['text']}');
                showDialog(
                  context: context,
                  builder: (dCtx) => AlertDialog(
                    title: const Text('修改节点文字'),
                    content: TextField(controller: ctrl, autofocus: true, minLines: 1, maxLines: 4),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('取消')),
                      FilledButton(
                        onPressed: () async {
                          if (ctrl.text.trim().isEmpty) return;
                          node['text'] = ctrl.text.trim();
                          if (mounted) Navigator.pop(dCtx);
                          await widget.onSave(widget.root);
                          setState(() {});
                        },
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                );
              },
            ),
            if (depth > 0)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('删除该节点及下属分支', style: TextStyle(color: Colors.redAccent)),
                onTap: () async {
                  Navigator.pop(ctx);
                  _rm(widget.root, '${node['id']}');
                  await widget.onSave(widget.root);
                  setState(() {});
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        toolbarHeight: 44,
        title: Text('🧠 ${widget.root['text']}（双指缩放 / 轻点节点编辑）', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold)),
        actions: [
          TextButton.icon(
            onPressed: () {
              setState(() {
                if (widget.collapsedIds.isNotEmpty) {
                  widget.collapsedIds.clear();
                } else {
                  // 一键收起到只显示前 2 层，理清主干
                  void foldDeep(Map<String, dynamic> n, int d) {
                    if (d >= 1) widget.collapsedIds.add('${n['id']}');
                    for (final c in ((n['children'] as List?)?.cast<Map<String, dynamic>>() ?? [])) {
                      foldDeep(c, d + 1);
                    }
                  }
                  foldDeep(widget.root, 0);
                }
              });
            },
            icon: const Icon(Icons.unfold_less, size: 17),
            label: Text(widget.collapsedIds.isNotEmpty ? '全部展开' : '只看主干', style: const TextStyle(fontSize: 12.5)),
          ),
          TextButton.icon(
            onPressed: _toggleOrientation,
            icon: const Icon(Icons.screen_rotation, size: 16),
            label: Text(_isLandscape ? '切回竖屏' : '切换横屏', style: const TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
      body: InteractiveViewer(
        constrained: false,
        boundaryMargin: const EdgeInsets.all(400),
        minScale: 0.25,
        maxScale: 2.5,
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: MindmapGraphView(
            root: widget.root,
            collapsedIds: widget.collapsedIds,
            onToggleCollapse: (id) => setState(() {
              if (widget.collapsedIds.contains(id)) {
                widget.collapsedIds.remove(id);
              } else {
                widget.collapsedIds.add(id);
              }
            }),
            onTapNode: _onNodeAction,
          ),
        ),
      ),
    );
  }
}

// ==================== Tab 4: 规划页（支持二维连接线导图 + 一键全屏横屏 + 导入 XMind） ====================
class PlanPage extends StatefulWidget {
  final Database db;
  const PlanPage({super.key, required this.db});
  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  final _uuid = const Uuid();
  final Set<String> _col = {};

  Map<String, dynamic> _convertXMindJsonTopic(Map<String, dynamic> topic) {
    final title = (topic['title'] ?? '未命名节点').toString().trim();
    final childrenList = <Map<String, dynamic>>[];
    final childrenObj = topic['children'];
    if (childrenObj is Map) {
      for (final key in ['attached', 'detached', 'summary']) {
        if (childrenObj[key] is List) {
          for (final sub in (childrenObj[key] as List)) {
            if (sub is Map<String, dynamic>) {
              childrenList.add(_convertXMindJsonTopic(sub));
            }
          }
        }
      }
    } else if (childrenObj is List) {
      for (final sub in childrenObj) {
        if (sub is Map<String, dynamic>) {
          childrenList.add(_convertXMindJsonTopic(sub));
        }
      }
    }
    return {
      'id': _uuid.v4(),
      'text': title.isEmpty ? '节点' : title,
      'children': childrenList,
    };
  }

  Map<String, dynamic>? _parseLegacyXMindXml(String xmlStr) {
    final matches = RegExp(r'<title[^>]*>([\s\S]*?)</title>').allMatches(xmlStr).map((m) => m.group(1)!.trim()).where((s) => s.isNotEmpty).toList();
    if (matches.isEmpty) return null;
    final rootTitle = matches.first;
    final children = matches.skip(1).map((t) => {'id': _uuid.v4(), 'text': t, 'children': <Map<String, dynamic>>[]}).toList();
    return {'id': _uuid.v4(), 'text': rootTitle, 'children': children};
  }

  Future<void> _importXMindFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.any);
      if (res == null || res.files.single.path == null) return;
      final filePath = res.files.single.path!;
      final bytes = await File(filePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      int importedCount = 0;
      final now = DateTime.now().toIso8601String();

      ArchiveFile? jsonFile;
      ArchiveFile? xmlFile;
      for (final f in archive) {
        if (f.isFile && (f.name == 'content.json' || f.name.endsWith('/content.json'))) {
          jsonFile = f;
          break;
        }
        if (f.isFile && (f.name == 'content.xml' || f.name.endsWith('/content.xml'))) {
          xmlFile = f;
        }
      }

      if (jsonFile != null) {
        final jsonStr = utf8.decode(jsonFile.content as List<int>);
        final decoded = jsonDecode(jsonStr);
        if (decoded is List) {
          for (final sheet in decoded) {
            if (sheet is Map<String, dynamic> && sheet['rootTopic'] is Map<String, dynamic>) {
              final rootNode = _convertXMindJsonTopic(sheet['rootTopic'] as Map<String, dynamic>);
              await widget.db.insert('mindmaps', {
                'title': '${rootNode['text']}',
                'root_json': jsonEncode(rootNode),
                'created_at': now,
                'updated_at': now,
              });
              importedCount++;
            }
          }
        } else if (decoded is Map<String, dynamic> && decoded['rootTopic'] is Map<String, dynamic>) {
          final rootNode = _convertXMindJsonTopic(decoded['rootTopic'] as Map<String, dynamic>);
          await widget.db.insert('mindmaps', {
            'title': '${rootNode['text']}',
            'root_json': jsonEncode(rootNode),
            'created_at': now,
            'updated_at': now,
          });
          importedCount++;
        }
      } else if (xmlFile != null) {
        final xmlStr = utf8.decode(xmlFile.content as List<int>);
        final rootNode = _parseLegacyXMindXml(xmlStr);
        if (rootNode != null) {
          await widget.db.insert('mindmaps', {
            'title': '${rootNode['text']}',
            'root_json': jsonEncode(rootNode),
            'created_at': now,
            'updated_at': now,
          });
          importedCount++;
        }
      }

      if (!mounted) return;
      if (importedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('🎉 成功从 XMind 导入 $importedCount 张思维导图！')));
        setState(() {});
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未在该文件中识别到有效的 XMind 导图结构')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('读取 XMind 文件失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 46,
        title: const Text('🧠 规划', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        actions: [
          TextButton.icon(
            onPressed: _importXMindFile,
            icon: const Icon(Icons.file_open_outlined, size: 17),
            label: const Text('导入XMind', style: TextStyle(fontSize: 13)),
          ),
          TextButton.icon(
            onPressed: _createMm,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新建规划', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: widget.db.query('mindmaps', orderBy: 'id DESC'),
        builder: (_, snap) {
          final list = snap.data ?? [];
          if (list.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('暂无思维导图规划', style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton.icon(onPressed: _createMm, icon: const Icon(Icons.add), label: const Text('新建规划')),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(onPressed: _importXMindFile, icon: const Icon(Icons.file_open_outlined), label: const Text('导入 .xmind 文件')),
                    ],
                  ),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final mm = list[i];
              final mmId = mm['id'] as int;
              final root = jsonDecode('${mm['root_json']}') as Map<String, dynamic>;

              return Card(
                margin: const EdgeInsets.only(bottom: 14),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 顶部栏：标题 + 只看主干/展开 + 全屏横屏按钮 + 删除
                      Row(
                        children: [
                          const Icon(Icons.account_tree, size: 16, color: Color(0xFF4F46E5)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${root['text']}',
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () {
                              setState(() {
                                final subIds = <String>[];
                                void collectDeep(Map<String, dynamic> n, int d) {
                                  if (d >= 1) subIds.add('${n['id']}');
                                  for (final c in ((n['children'] as List?)?.cast<Map<String, dynamic>>() ?? [])) {
                                    collectDeep(c, d + 1);
                                  }
                                }
                                collectDeep(root, 0);
                                final anyCol = subIds.any((id) => _col.contains(id));
                                if (anyCol) {
                                  _col.removeAll(subIds);
                                } else {
                                  _col.addAll(subIds);
                                }
                              });
                            },
                            child: const Text('收起/展开', style: TextStyle(fontSize: 11.5)),
                          ),
                          const SizedBox(width: 4),
                          FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => FullscreenMindmapPage(
                                    mmId: mmId,
                                    root: root,
                                    collapsedIds: _col,
                                    onSave: (updated) => _save(mmId, updated),
                                  ),
                                ),
                              ).then((_) => setState(() {}));
                            },
                            icon: const Icon(Icons.screen_rotation, size: 13),
                            label: const Text('全屏横屏', style: TextStyle(fontSize: 11.5)),
                          ),
                          InkWell(
                            onTap: () => _confirmDeleteMindmap(mmId, '${root['text']}'),
                            child: const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                            ),
                          ),
                        ],
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 2, bottom: 4),
                        child: Text(
                          '💡 左右滑动查看树状连接脉络 · 轻点任意节点可增删编辑 · 点击右上「全屏横屏」可双指自由缩放',
                          style: TextStyle(fontSize: 10.5, color: Colors.grey),
                        ),
                      ),
                      const Divider(height: 8),
                      // 二维树状连接线导图视图（支持横向滚动）
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                        child: MindmapGraphView(
                          root: root,
                          collapsedIds: _col,
                          onToggleCollapse: (id) => setState(() {
                            if (_col.contains(id)) {
                              _col.remove(id);
                            } else {
                              _col.add(id);
                            }
                          }),
                          onTapNode: (node, depth) => _showNodeActionSheet(mmId, root, node, depth),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showNodeActionSheet(int mmId, Map<String, dynamic> root, Map<String, dynamic> node, int depth) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.account_tree, color: Color(0xFF4F46E5)),
              title: Text('${node['text']}', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('选择对该节点的操作'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add_circle_outline, color: Colors.indigo),
              title: const Text('添加子节点'),
              onTap: () {
                Navigator.pop(ctx);
                _addNode(mmId, root, node);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: Colors.blueGrey),
              title: const Text('修改节点文字'),
              onTap: () {
                Navigator.pop(ctx);
                _editNode(mmId, root, node);
              },
            ),
            if (depth > 0)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('删除该节点及下属分支', style: TextStyle(color: Colors.redAccent)),
                onTap: () async {
                  Navigator.pop(ctx);
                  _rm(root, '${node['id']}');
                  await _save(mmId, root);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteMindmap(int mmId, String title) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除规划'),
        content: Text('确定删除整张规划「$title」吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              await widget.db.delete('mindmaps', where: 'id = ?', whereArgs: [mmId]);
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  bool _rm(Map<String, dynamic> p, String tid) {
    final ch = (p['children'] as List).cast<Map<String, dynamic>>();
    final idx = ch.indexWhere((c) => c['id'] == tid);
    if (idx != -1) { ch.removeAt(idx); return true; }
    return ch.any((c) => _rm(c, tid));
  }

  Future<void> _save(int mmId, Map<String, dynamic> root) async {
    await widget.db.update('mindmaps', {'title': root['text'], 'root_json': jsonEncode(root), 'updated_at': DateTime.now().toIso8601String()}, where: 'id = ?', whereArgs: [mmId]);
    setState(() {});
  }

  void _createMm() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建规划'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: '如：年度目标')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (ctrl.text.trim().isEmpty) return;
              final now = DateTime.now().toIso8601String();
              await widget.db.insert('mindmaps', {'title': ctrl.text.trim(), 'root_json': jsonEncode({'id': _uuid.v4(), 'text': ctrl.text.trim(), 'children': []}), 'created_at': now, 'updated_at': now});
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  void _addNode(int mmId, Map<String, dynamic> root, Map<String, dynamic> pNode) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加子节点'),
        content: TextField(controller: ctrl, autofocus: true, minLines: 1, maxLines: 3),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (ctrl.text.trim().isEmpty) return;
              (pNode['children'] as List).add({'id': _uuid.v4(), 'text': ctrl.text.trim(), 'children': []});
              _col.remove('${pNode['id']}');
              if (mounted) Navigator.pop(ctx);
              await _save(mmId, root);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _editNode(int mmId, Map<String, dynamic> root, Map<String, dynamic> node) {
    final ctrl = TextEditingController(text: '${node['text']}');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改节点内容'),
        content: TextField(controller: ctrl, autofocus: true, minLines: 1, maxLines: 4),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (ctrl.text.trim().isEmpty) return;
              node['text'] = ctrl.text.trim();
              if (mounted) Navigator.pop(ctx);
              await _save(mmId, root);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
