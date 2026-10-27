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
import 'package:uuid/uuid.dart';
import 'main.dart' show AppDatabase;

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

// ==================== 家庭模块（支持添加家庭成员如“梦雨” + 多级标题与带圈序号 Word 导入） ====================
class FamilyPage extends StatefulWidget {
  final Database db;
  const FamilyPage({super.key, required this.db});
  @override
  State<FamilyPage> createState() => _FamilyPageState();
}

class _FamilyPageState extends State<FamilyPage> {
  final Set<int> _expandedMods = {};
  bool _uiLoaded = false;

  @override
  void initState() {
    super.initState();
    _restoreFamilyUiState();
  }

  Future<void> _restoreFamilyUiState() async {
    final raw = await AppDatabase.getUiState(widget.db, 'family_expanded_mods');
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List).map((e) => e as int);
        _expandedMods
          ..clear()
          ..addAll(list);
      } catch (_) {}
    }
    if (mounted) setState(() => _uiLoaded = true);
  }

  Future<void> _saveFamilyUiState() async {
    await AppDatabase.setUiState(widget.db, 'family_expanded_mods', jsonEncode(_expandedMods.toList()));
  }

  Future<List<Map<String, dynamic>>> _loadMods() async {
    if (!_uiLoaded) await _restoreFamilyUiState();
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

  String _unescapeXml(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }

  Future<int> _findOrCreateMod(String title, int? parentId) async {
    final cleanTitle = title.trim();
    final rows = await widget.db.query(
      'modules',
      where: parentId == null ? 'parent_id IS NULL AND title = ?' : 'parent_id = ? AND title = ?',
      whereArgs: parentId == null ? [cleanTitle] : [parentId, cleanTitle],
    );
    if (rows.isNotEmpty) return rows.first['id'] as int;
    final siblings = await widget.db.query(
      'modules',
      where: parentId == null ? 'parent_id IS NULL' : 'parent_id = ?',
      whereArgs: parentId == null ? null : [parentId],
    );
    return await widget.db.insert('modules', {
      'title': cleanTitle,
      'parent_id': parentId,
      'sort_order': siblings.length,
      'created_at': DateTime.now().toIso8601String(),
    });
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
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未识别到标准的 Word (.docx) 文件')));
        return;
      }

      String rawBase = p.basenameWithoutExtension(filePath).split('-').first.trim();
      if (rawBase.isEmpty || rawBase == 'document') rawBase = '梦雨';
      final nameCtrl = TextEditingController(text: rawBase);

      if (!mounted) return;
      final memberName = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入到家庭成员', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: TextField(
            controller: nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '家庭成员姓名（顶层分类）',
              hintText: '如：梦雨',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()), child: const Text('开始导入')),
          ],
        ),
      );
      if (memberName == null || memberName.isEmpty) return;

      final docXml = utf8.decode(docXmlFile.content as List<int>, allowMalformed: true);
      final pMatches = RegExp(r'<w:p\b[^>]*>([\s\S]*?)<\/w:p>').allMatches(docXml);

      final paragraphs = <({String text, int fontSize})>[];
      for (final pm in pMatches) {
        final pXml = pm.group(1)!;
        final tMatches = RegExp(r'<w:t(?:\s[^>]*)?>([\s\S]*?)<\/w:t>').allMatches(pXml);
        final text = _unescapeXml(tMatches.map((m) => m.group(1)!).join('')).trim();
        if (text.isEmpty || text == memberName || text == '每日记录') continue;

        final szM = RegExp(r'<w:sz\s+w:val="(\d+)"').firstMatch(pXml);
        final sz = szM != null ? int.parse(szM.group(1)!) : 24;
        paragraphs.add((text: text, fontSize: sz));
      }

      final circledMap = <String, int>{};
      for (int i = 0; i < 20; i++) circledMap[String.fromCharCode(0x2460 + i)] = i + 1;
      for (int i = 0; i < 30; i++) circledMap[String.fromCharCode(0x3251 + i)] = i + 21;

      final memberId = await _findOrCreateMod(memberName, null);
      _expandedMods.add(memberId);

      int? l1Id;
      int? l2Id;
      int? l3Id;
      int? lastEntryId;
      int importedTitles = 0;
      int importedEntries = 0;

      for (int i = 0; i < paragraphs.length; i++) {
        final cur = paragraphs[i];
        final txt = cur.text;

        final l1M = RegExp(r'^[一二三四五六七八九十]+[、\.\s]\s*(.+)$').firstMatch(txt);
        if (l1M != null) {
          final tName = l1M.group(1)!.replaceAll(RegExp(r'[:：]$'), '').trim();
          l1Id = await _findOrCreateMod(tName, memberId);
          l2Id = null;
          l3Id = null;
          lastEntryId = null;
          importedTitles++;
          continue;
        }

        final bulletM = RegExp(r'^[\u25CF\u2022\uF0B7\u25AA]\s*(.+)$').firstMatch(txt);
        if (bulletM != null) {
          final tName = bulletM.group(1)!.replaceAll(RegExp(r'[:：]$'), '').trim();
          l2Id = await _findOrCreateMod(tName, l1Id ?? memberId);
          l3Id = null;
          lastEntryId = null;
          importedTitles++;
          continue;
        }

        final fc = txt.characters.first;
        if (circledMap.containsKey(fc)) {
          final seqNum = circledMap[fc]!;
          final rest = txt.substring(fc.length).trim();
          final nextP = (i + 1 < paragraphs.length) ? paragraphs[i + 1] : null;
          final nextStartsWithOne = nextP != null && nextP.text.isNotEmpty && nextP.text.characters.first == '①';

          final isSubHeader = nextStartsWithOne || (cur.fontSize >= 28 && rest.length <= 15);
          if (isSubHeader) {
            final cleanHeader = rest.replaceAll(RegExp(r'[:：]$'), '').trim();
            if (cur.fontSize >= 30 || l2Id == null) {
              l2Id = await _findOrCreateMod('$fc $cleanHeader', l1Id ?? memberId);
              l3Id = null;
            } else {
              l3Id = await _findOrCreateMod('$fc $cleanHeader', l2Id);
            }
            lastEntryId = null;
            importedTitles++;
            continue;
          } else {
            final targetModId = l3Id ?? l2Id ?? l1Id ?? memberId;
            final existing = await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [targetModId]);
            lastEntryId = await widget.db.insert('module_entries', {
              'module_id': targetModId,
              'seq': seqNum,
              'content': rest,
              'sort_order': existing.length,
              'created_at': DateTime.now().toIso8601String(),
            });
            importedEntries++;
            continue;
          }
        }

        if (lastEntryId != null) {
          final rows = await widget.db.query('module_entries', where: 'id = ?', whereArgs: [lastEntryId]);
          if (rows.isNotEmpty) {
            final oldContent = '${rows.first['content']}';
            await widget.db.update(
              'module_entries',
              {'content': '$oldContent\n$txt'},
              where: 'id = ?',
              whereArgs: [lastEntryId],
            );
            continue;
          }
        }

        final targetModId = l3Id ?? l2Id ?? l1Id ?? memberId;
        final existing = await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [targetModId]);
        lastEntryId = await widget.db.insert('module_entries', {
          'module_id': targetModId,
          'seq': existing.length + 1,
          'content': txt,
          'sort_order': existing.length,
          'created_at': DateTime.now().toIso8601String(),
        });
        importedEntries++;
      }

      await _saveFamilyUiState();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('🎉 导入「$memberName」完成：共整理 $importedTitles 个分级标题、$importedEntries 条记录！')),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入 Word 失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 46,
        title: const Text('🏠 家庭', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        actions: [
          TextButton.icon(
            onPressed: _importFamilyDocx,
            icon: const Icon(Icons.description_outlined, size: 16),
            label: const Text('导入Word', style: TextStyle(fontSize: 12.5)),
          ),
          TextButton.icon(
            onPressed: () => _createOrEditMod(isMember: true),
            icon: const Icon(Icons.person_add_alt_1, size: 16),
            label: const Text('添加成员', style: TextStyle(fontSize: 12.5)),
          ),
          TextButton.icon(
            onPressed: () => _createOrEditMod(),
            icon: const Icon(Icons.add, size: 17),
            label: const Text('新标题', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _loadMods(),
        builder: (_, snap) {
          final all = snap.data ?? [];
          if (all.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('暂无家庭成员或大标题', style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(onPressed: () => _createOrEditMod(isMember: true), icon: const Icon(Icons.person_add), label: const Text('添加成员（如：梦雨）')),
                      OutlinedButton.icon(onPressed: _importFamilyDocx, icon: const Icon(Icons.description_outlined), label: const Text('导入Word文档')),
                    ],
                  ),
                ],
              ),
            );
          }
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
              margin: EdgeInsets.only(left: depth * 15.0, bottom: 6),
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
                          onTap: () {
                            setState(() => isExpanded ? _expandedMods.remove(id) : _expandedMods.add(id));
                            _saveFamilyUiState();
                          },
                          child: Padding(
                            padding: const EdgeInsets.only(right: 4, top: 2, bottom: 2),
                            child: Icon(isExpanded ? Icons.expand_more : Icons.chevron_right, size: 20, color: const Color(0xFF4F46E5)),
                          ),
                        )
                      else
                        const SizedBox(width: 4),
                      Icon(
                        depth == 0 ? Icons.folder_shared_outlined : Icons.subdirectory_arrow_right,
                        color: Colors.indigo,
                        size: 19,
                      ),
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
                                onTap: () {
                                  setState(() => isExpanded ? _expandedMods.remove(id) : _expandedMods.add(id));
                                  _saveFamilyUiState();
                                },
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
                        tooltip: '修改名称',
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
      _expandedMods.remove(did);
    }
    await _saveFamilyUiState();
    setState(() {});
  }

  void _createOrEditMod({int? parentId, String? parentTitle, Map<String, dynamic>? editMod, bool isMember = false}) {
    final isEdit = editMod != null;
    final ctrl = TextEditingController(text: isEdit ? '${editMod['title']}' : '');
    final dlgTitle = isEdit
        ? '修改名称'
        : (isMember ? '添加家庭成员' : (parentId == null ? '新建大标题' : '在「$parentTitle」下新建小标题'));

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(dlgTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: isMember ? '如：梦雨、球球' : '输入标题名称'),
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
// ==================== Tab 1: 查找页 ====================
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
      'version': '5.0.0',
      'data': {
        for (final t in ['status_items', 'status_records', 'status_images', 'schedule_items', 'schedule_records', 'modules', 'module_entries', 'module_groups', 'mindmaps', 'ui_states'])
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
        try {
          await widget.db.insert(e.key, Map<String, Object?>.from(r as Map), conflictAlgorithm: ConflictAlgorithm.replace);
        } catch (_) {}
      }
    }
    if (mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('导入恢复成功！'))); setState(() {}); }
  }
}

// ==================== XMind 风格树状连接线与节点渲染组件 ====================
class XMindBranchNodeWidget extends StatelessWidget {
  final Map<String, dynamic> node;
  final int depth;
  final int branchIdx;
  final Set<String> collapsedIds;
  final bool interactive;
  final void Function(String nodeId)? onToggleCollapse;
  final void Function(Map<String, dynamic> node, int depth)? onTapNode;

  const XMindBranchNodeWidget({
    super.key,
    required this.node,
    required this.depth,
    required this.branchIdx,
    required this.collapsedIds,
    required this.interactive,
    this.onToggleCollapse,
    this.onTapNode,
  });

  static const List<Color> _branchColors = [
    Color(0xFFF0564A),
    Color(0xFFED8936),
    Color(0xFFDF5A49),
    Color(0xFF3B82F6),
    Color(0xFF10B981),
    Color(0xFF8B5CF6),
  ];

  @override
  Widget build(BuildContext context) {
    final id = '${node['id']}';
    final children = (node['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final isCollapsed = collapsedIds.contains(id);
    final hasChildren = children.isNotEmpty;
    final color = _branchColors[branchIdx % _branchColors.length];

    final card = _buildXMindCard(node, depth, color, hasChildren, isCollapsed, children.length);

    if (!hasChildren || isCollapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3.5),
        child: card,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: _XMindTreeRow(
        parent: card,
        lineColor: color,
        children: List.generate(children.length, (i) {
          final nextBranchIdx = depth == 0 ? i : branchIdx;
          return XMindBranchNodeWidget(
            node: children[i],
            depth: depth + 1,
            branchIdx: nextBranchIdx,
            collapsedIds: collapsedIds,
            interactive: interactive,
            onToggleCollapse: onToggleCollapse,
            onTapNode: onTapNode,
          );
        }),
      ),
    );
  }

  Widget _buildXMindCard(
    Map<String, dynamic> n,
    int d,
    Color branchColor,
    bool hasChildren,
    bool isCollapsed,
    int childCount,
  ) {
    final id = '${n['id']}';
    Color bg;
    Color fg;
    Color borderCol;

    if (d == 0) {
      bg = const Color(0xFF111827);
      fg = Colors.white;
      borderCol = const Color(0xFF111827);
    } else if (d == 1) {
      bg = branchColor;
      fg = Colors.white;
      borderCol = branchColor;
    } else {
      bg = branchColor.withOpacity(0.11);
      fg = const Color(0xFF1F2937);
      borderCol = branchColor.withOpacity(0.45);
    }

    final pill = Container(
      constraints: BoxConstraints(minWidth: 44, maxWidth: d == 0 ? 160 : (d == 1 ? 180 : 240)),
      padding: EdgeInsets.symmetric(
        horizontal: d == 0 ? 14 : (d == 1 ? 11 : 9),
        vertical: d == 0 ? 8 : (d == 1 ? 6 : 4.5),
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(d <= 1 ? 7 : 5),
        border: Border.all(color: borderCol, width: 1.1),
      ),
      child: Text(
        '${n['text']}',
        style: TextStyle(
          fontSize: d == 0 ? 14 : (d == 1 ? 12.5 : 11.5),
          fontWeight: d <= 1 ? FontWeight.bold : FontWeight.w500,
          color: fg,
          height: 1.25,
        ),
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        interactive && onTapNode != null
            ? GestureDetector(onTap: () => onTapNode!(n, d), child: pill)
            : pill,
        if (hasChildren && (isCollapsed || interactive))
          GestureDetector(
            onTap: interactive && onToggleCollapse != null ? () => onToggleCollapse!(id) : null,
            child: Container(
              margin: const EdgeInsets.only(left: 3),
              width: isCollapsed ? null : 16,
              height: 16,
              padding: EdgeInsets.symmetric(horizontal: isCollapsed ? 4.5 : 0),
              decoration: BoxDecoration(
                color: isCollapsed ? branchColor : Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: branchColor, width: 1.1),
              ),
              alignment: Alignment.center,
              child: Text(
                isCollapsed ? '$childCount' : '−',
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                  color: isCollapsed ? Colors.white : branchColor,
                  height: 1.0,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _XMindTreeRow extends StatefulWidget {
  final Widget parent;
  final List<Widget> children;
  final Color lineColor;

  const _XMindTreeRow({
    required this.parent,
    required this.children,
    required this.lineColor,
  });

  @override
  State<_XMindTreeRow> createState() => _XMindTreeRowState();
}

class _XMindTreeRowState extends State<_XMindTreeRow> {
  final GlobalKey _rowKey = GlobalKey();
  final GlobalKey _parentKey = GlobalKey();
  late List<GlobalKey> _childKeys;
  Offset? _parentAnchor;
  List<Offset> _childAnchors = [];

  @override
  void initState() {
    super.initState();
    _initKeys();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(covariant _XMindTreeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _initKeys();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _initKeys() {
    _childKeys = List.generate(widget.children.length, (_) => GlobalKey());
  }

  void _measure() {
    if (!mounted) return;
    final rowBox = _rowKey.currentContext?.findRenderObject() as RenderBox?;
    final pBox = _parentKey.currentContext?.findRenderObject() as RenderBox?;
    if (rowBox == null || pBox == null || !rowBox.hasSize || !pBox.hasSize) return;

    final pPos = pBox.localToGlobal(Offset(pBox.size.width, pBox.size.height / 2), ancestor: rowBox);
    final cAnchors = <Offset>[];
    for (final k in _childKeys) {
      final cBox = k.currentContext?.findRenderObject() as RenderBox?;
      if (cBox != null && cBox.hasSize) {
        cAnchors.add(cBox.localToGlobal(Offset(0, cBox.size.height / 2), ancestor: rowBox));
      }
    }
    if (cAnchors.isNotEmpty) {
      setState(() {
        _parentAnchor = pPos;
        _childAnchors = cAnchors;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      key: _rowKey,
      painter: _XMindBracketPainter(
        parentRight: _parentAnchor,
        childLefts: _childAnchors,
        color: widget.lineColor,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(key: _parentKey, child: widget.parent),
          const SizedBox(width: 24),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: List.generate(widget.children.length, (i) {
              return Container(
                key: _childKeys[i],
                child: widget.children[i],
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _XMindBracketPainter extends CustomPainter {
  final Offset? parentRight;
  final List<Offset> childLefts;
  final Color color;

  _XMindBracketPainter({
    required this.parentRight,
    required this.childLefts,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (parentRight == null || childLefts.isEmpty) return;
    final paint = Paint()
      ..color = color.withOpacity(0.75)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final pr = parentRight!;
    final midX = pr.dx + (childLefts.first.dx - pr.dx) * 0.45;

    canvas.drawLine(pr, Offset(midX, pr.dy), paint);

    final minY = math.min(pr.dy, childLefts.first.dy);
    final maxY = math.max(pr.dy, childLefts.last.dy);
    if ((maxY - minY).abs() > 0.5) {
      canvas.drawLine(Offset(midX, minY), Offset(midX, maxY), paint);
    }

    for (final cl in childLefts) {
      canvas.drawLine(Offset(midX, cl.dy), cl, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _XMindBracketPainter oldDelegate) {
    return oldDelegate.parentRight != parentRight ||
        oldDelegate.childLefts.length != childLefts.length ||
        oldDelegate.color != color;
  }
}

// ==================== 全屏思维导图画布页 ====================
class FullscreenMindmapPage extends StatefulWidget {
  final int mmId;
  final Map<String, dynamic> root;
  final Set<String> collapsedIds;
  final Future<void> Function(Map<String, dynamic> updatedRoot) onSave;
  final Future<void> Function() onSaveCollapseState;

  const FullscreenMindmapPage({
    super.key,
    required this.mmId,
    required this.root,
    required this.collapsedIds,
    required this.onSave,
    required this.onSaveCollapseState,
  });

  @override
  State<FullscreenMindmapPage> createState() => _FullscreenMindmapPageState();
}

class _FullscreenMindmapPageState extends State<FullscreenMindmapPage> {
  final _uuid = const Uuid();
  bool _isLandscape = false;

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
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
    if (idx != -1) {
      ch.removeAt(idx);
      return true;
    }
    return ch.any((c) => _rm(c, tid));
  }

  void _onNodeAction(Map<String, dynamic> node, int depth) {
    final id = '${node['id']}';
    final hasChildren = ((node['children'] as List?) ?? []).isNotEmpty;
    final isCol = widget.collapsedIds.contains(id);

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.account_tree, color: Color(0xFFF0564A)),
              title: Text('${node['text']}', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('选择对该节点的操作'),
            ),
            const Divider(height: 1),
            if (hasChildren)
              ListTile(
                leading: Icon(isCol ? Icons.unfold_more : Icons.unfold_less, color: const Color(0xFF4F46E5)),
                title: Text(isCol ? '展开该节点分支' : '折叠收起该节点分支'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    if (isCol) {
                      widget.collapsedIds.remove(id);
                    } else {
                      widget.collapsedIds.add(id);
                    }
                  });
                  widget.onSaveCollapseState();
                },
              ),
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
                          widget.collapsedIds.remove(id);
                          await widget.onSaveCollapseState();
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
                  _rm(widget.root, id);
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
      backgroundColor: Colors.white,
      appBar: AppBar(
        toolbarHeight: 44,
        title: Text('${widget.root['text']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        actions: [
          TextButton.icon(
            onPressed: () {
              setState(() {
                if (widget.collapsedIds.isNotEmpty) {
                  widget.collapsedIds.clear();
                } else {
                  void foldDeep(Map<String, dynamic> n, int d) {
                    if (d >= 1 && ((n['children'] as List?) ?? []).isNotEmpty) {
                      widget.collapsedIds.add('${n['id']}');
                    }
                    for (final c in ((n['children'] as List?)?.cast<Map<String, dynamic>>() ?? [])) {
                      foldDeep(c, d + 1);
                    }
                  }
                  foldDeep(widget.root, 0);
                }
              });
              widget.onSaveCollapseState();
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
        boundaryMargin: const EdgeInsets.all(800),
        minScale: 0.1,
        maxScale: 3.0,
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: XMindBranchNodeWidget(
            node: widget.root,
            depth: 0,
            branchIdx: 0,
            collapsedIds: widget.collapsedIds,
            interactive: true,
            onToggleCollapse: (id) {
              setState(() {
                if (widget.collapsedIds.contains(id)) {
                  widget.collapsedIds.remove(id);
                } else {
                  widget.collapsedIds.add(id);
                }
              });
              widget.onSaveCollapseState();
            },
            onTapNode: _onNodeAction,
          ),
        ),
      ),
    );
  }
}

// ==================== Tab 4: 规划页 ====================
class PlanPage extends StatefulWidget {
  final Database db;
  const PlanPage({super.key, required this.db});
  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  final _uuid = const Uuid();
  final Set<String> _col = {};
  bool _uiLoaded = false;

  @override
  void initState() {
    super.initState();
    _restorePlanUiState();
  }

  Future<void> _restorePlanUiState() async {
    final raw = await AppDatabase.getUiState(widget.db, 'plan_collapsed_nodes');
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List).map((e) => '$e');
        _col
          ..clear()
          ..addAll(list);
      } catch (_) {}
    }
    if (mounted) setState(() => _uiLoaded = true);
  }

  Future<void> _savePlanUiState() async {
    await AppDatabase.setUiState(widget.db, 'plan_collapsed_nodes', jsonEncode(_col.toList()));
  }

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

  void _openFullscreen(int mmId, Map<String, dynamic> root) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullscreenMindmapPage(
          mmId: mmId,
          root: root,
          collapsedIds: _col,
          onSave: (updated) => _save(mmId, updated),
          onSaveCollapseState: _savePlanUiState,
        ),
      ),
    ).then((_) => setState(() {}));
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
        future: () async {
          if (!_uiLoaded) await _restorePlanUiState();
          return widget.db.query('mindmaps', orderBy: 'id DESC');
        }(),
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
                color: Colors.white,
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
                      Row(
                        children: [
                          const Icon(Icons.account_tree, size: 16, color: Color(0xFFF0564A)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${root['text']}',
                              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
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
                                  if (d >= 1 && ((n['children'] as List?) ?? []).isNotEmpty) {
                                    subIds.add('${n['id']}');
                                  }
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
                              _savePlanUiState();
                            },
                            child: const Text('收起/展开', style: TextStyle(fontSize: 11.5)),
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
                        padding: EdgeInsets.only(top: 2, bottom: 6),
                        child: Text(
                          '💡 全景微缩预览 · 轻点下方导图任意位置即可进入全屏查看与编辑',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ),
                      const Divider(height: 1),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _openFullscreen(mmId, root),
                        child: Container(
                          width: double.infinity,
                          height: 360,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFAFAFA),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: IgnorePointer(
                            child: FittedBox(
                              fit: BoxFit.contain,
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: XMindBranchNodeWidget(
                                  node: root,
                                  depth: 0,
                                  branchIdx: 0,
                                  collapsedIds: _col,
                                  interactive: false,
                                ),
                              ),
                            ),
                          ),
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
}
