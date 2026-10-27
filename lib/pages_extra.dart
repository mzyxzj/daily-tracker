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
    final arabic = RegExp(r'^(\d+)[\.、\)）\s]\s*(.*)$');
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

// ==================== 家庭模块（精准多级文件夹拆分 + 成员管理） ====================
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

  Future<int> _createCleanMod(String title, int? parentId) async {
    final cleanTitle = title.trim();
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

  Future<void> _clearMemberOldTree(int rootId) async {
    final all = await widget.db.query('modules');
    final toDel = <int>[];
    void collect(int pid) {
      for (final m in all.where((x) => x['parent_id'] == pid)) {
        final cid = m['id'] as int;
        toDel.add(cid);
        collect(cid);
      }
    }
    collect(rootId);
    await widget.db.delete('module_entries', where: 'module_id = ?', whereArgs: [rootId]);
    for (final did in toDel) {
      await widget.db.delete('module_entries', where: 'module_id = ?', whereArgs: [did]);
      await widget.db.delete('modules', where: 'id = ?', whereArgs: [did]);
      _expandedMods.remove(did);
    }
  }

  /// 全新多级文件夹精准解析引擎：彻底解决各级标题揉在一起的问题
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
      bool overwriteOld = true;

      if (!mounted) return;
      final confirmedName = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setS) => AlertDialog(
            title: const Text('导入家庭成员档案', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '家庭成员姓名（顶层文件夹）',
                    hintText: '如：梦雨',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: overwriteOld,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('清空该成员下旧的导入数据重新分组', style: TextStyle(fontSize: 13)),
                  subtitle: const Text('避免与上次导入揉在一起', style: TextStyle(fontSize: 11, color: Colors.grey)),
                  onChanged: (v) => setS(() => overwriteOld = v ?? true),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()), child: const Text('开始导入')),
            ],
          ),
        ),
      );
      if (confirmedName == null || confirmedName.isEmpty) return;

      final docXml = utf8.decode(docXmlFile.content as List<int>, allowMalformed: true);
      final pMatches = RegExp(r'<w:p\b[^>]*>([\s\S]*?)<\/w:p>').allMatches(docXml);

      final paragraphs = <({String text, bool isBold, int fontSize, bool hasHeadingStyle})>[];
      for (final pm in pMatches) {
        final pXml = pm.group(1)!;
        final tMatches = RegExp(r'<w:t(?:\s[^>]*)?>([\s\S]*?)<\/w:t>').allMatches(pXml);
        final text = _unescapeXml(tMatches.map((m) => m.group(1)!).join('')).trim();
        if (text.isEmpty || text == confirmedName || text == '每日记录') continue;

        final isBold = pXml.contains('<w:b/>') || pXml.contains('<w:b ') || pXml.contains('w:val="bold"');
        final styleM = RegExp(r'<w:pStyle\s+w:val="([^"]+)"').firstMatch(pXml);
        final styleVal = styleM?.group(1) ?? '';
        final hasHeadingStyle = styleVal.toLowerCase().contains('heading') || RegExp(r'^[1-9]$').hasMatch(styleVal);

        int maxSz = 24;
        for (final sm in RegExp(r'<w:sz\s+w:val="(\d+)"').allMatches(pXml)) {
          final v = int.tryParse(sm.group(1)!) ?? 24;
          if (v > maxSz) maxSz = v;
        }
        paragraphs.add((text: text, isBold: isBold, fontSize: maxSz, hasHeadingStyle: hasHeadingStyle));
      }

      final circledMap = <String, int>{};
      for (int i = 0; i < 20; i++) circledMap[String.fromCharCode(0x2460 + i)] = i + 1;
      for (int i = 0; i < 30; i++) circledMap[String.fromCharCode(0x3251 + i)] = i + 21;

      int? extractSeq(String s) {
        final t = s.trim();
        if (t.isEmpty) return null;
        final fc = t.characters.first;
        if (circledMap.containsKey(fc)) return circledMap[fc];
        final m = RegExp(r'^(\d{1,2})[\.、\s]\s*(.+)$').firstMatch(t);
        if (m != null) return int.tryParse(m.group(1)!);
        return null;
      }

      String stripSeqPrefix(String s) {
        final t = s.trim();
        final fc = t.characters.first;
        if (circledMap.containsKey(fc)) return t.substring(fc.length).trim();
        final m = RegExp(r'^(\d{1,2})[\.、\s]\s*(.+)$').firstMatch(t);
        if (m != null) return m.group(2)!.trim();
        return t;
      }

      // 查找或创建顶层成员文件夹（如：梦雨）
      final existingRoots = await widget.db.query('modules', where: 'parent_id IS NULL AND title = ?', whereArgs: [confirmedName]);
      int memberId;
      if (existingRoots.isNotEmpty) {
        memberId = existingRoots.first['id'] as int;
        if (overwriteOld) await _clearMemberOldTree(memberId);
      } else {
        memberId = await _createCleanMod(confirmedName, null);
      }
      _expandedMods.add(memberId);

      int? l1Id;     // 一、安排 / 二、首要信息
      int? l2Id;     // ● 身体情况 / ① 短期安排 / ② 长期规划 / ④ 喜欢的主食
      int? l3Id;     // ① 喜欢吃辣 / ① 过敏 / ② 胃炎 / ③ 晕车 ...
      int? lastListEntryId; // 用于把“店铺：...”、“菜品：...”合并到上一条探店记录
      int importedFolders = 0;
      int importedEntries = 0;

      for (int i = 0; i < paragraphs.length; i++) {
        final cur = paragraphs[i];
        final txt = cur.text;

        // 1. 一级大标题文件夹（如：“一、安排：”、“二、首要信息：”）
        final l1M = RegExp(r'^[一二三四五六七八九十]+[、\.\s]\s*(.+)$').firstMatch(txt);
        if (l1M != null) {
          final folderName = txt.replaceAll(RegExp(r'[:：]$'), '').trim();
          l1Id = await _createCleanMod(folderName, memberId);
          l2Id = null;
          l3Id = null;
          lastListEntryId = null;
          importedFolders++;
          continue;
        }

        // 2. 实心圆点分类文件夹（如：“● 身体情况：”、“● 住址：”）
        final bulletM = RegExp(r'^[\u25CF\u2022\uF0B7\u25AA]\s*(.+)$').firstMatch(txt);
        if (bulletM != null) {
          final folderName = bulletM.group(1)!.replaceAll(RegExp(r'[:：]$'), '').trim();
          l2Id = await _createCleanMod(folderName, l1Id ?? memberId);
          l3Id = null;
          lastListEntryId = null;
          importedFolders++;
          continue;
        }

        // 3. 识别带圈数字或阿拉伯数字序号开头的段落
        final seqNum = extractSeq(txt);
        if (seqNum != null) {
          final rest = stripSeqPrefix(txt);
          final cleanTitle = rest.replaceAll(RegExp(r'[:：]$'), '').trim();
          final hasTrailingColon = rest.endsWith(':') || rest.endsWith('：');

          final nextP = (i + 1 < paragraphs.length) ? paragraphs[i + 1] : null;
          final nextSeq = nextP != null ? extractSeq(nextP.text) : null;
          final nextIsPlainText = nextP != null &&
              nextSeq == null &&
              !RegExp(r'^[一二三四五六七八九十]+[、\.\s]').hasMatch(nextP.text) &&
              !RegExp(r'^[\u25CF\u2022\uF0B7\u25AA]').hasMatch(nextP.text);
          final nextIsShopOrDish = nextP != null && RegExp(r'^(店铺|菜品|地址|推荐|备注)[:：]').hasMatch(nextP.text);

          // 情况 A：下一段立刻又是 ①（如“① 短期安排”后跟“① 想要去玩水”，“④ 喜欢的主食”后跟“① 喜欢吃辣”），或字号很大（>=28）
          if (nextSeq == 1 || cur.fontSize >= 28 || cur.hasHeadingStyle) {
            if (cur.fontSize >= 30 || l2Id == null || nextSeq == 1 && l3Id == null && (l2Id != null && seqNum > 1)) {
              // 若是 ② 长期规划（紧跟在 ① 短期安排的第24条后面，它的下一段又是 ① 我需要多分享自己的生活），与 ① 短期安排并列作为二级文件夹！
              if (nextSeq == 1 && rest.contains('喜欢吃')) {
                // 如 ④ 喜欢的主食 下面的 ① 喜欢吃辣（下一段是 ① 喜欢吃火锅）
                l3Id = await _createCleanMod('$seqNum. $cleanTitle', l2Id ?? l1Id ?? memberId);
              } else {
                l2Id = await _createCleanMod('$seqNum. $cleanTitle', l1Id ?? memberId);
                l3Id = null;
              }
            } else {
              l3Id = await _createCleanMod('$seqNum. $cleanTitle', l2Id);
            }
            lastListEntryId = null;
            importedFolders++;
            continue;
          }

          // 情况 B：像“身体情况”下的 ① 过敏：、② 胃炎：、③ 晕车：、④ 例假：、⑤ 睡眠：、⑥ 外貌：、⑦ 敏感处、⑧ 化妆品、⑨ 肺结核
          // 特征：本身很短（<=18字），且（带冒号 或 加粗 或 下一段是普通多行描述文本且不是店铺/菜品）
          if (cleanTitle.length <= 18 && (hasTrailingColon || cur.isBold || (nextIsPlainText && !nextIsShopOrDish))) {
            final parentFolder = l2Id ?? l1Id ?? memberId;
            l3Id = await _createCleanMod('$seqNum. $cleanTitle', parentFolder);
            lastListEntryId = null;
            importedFolders++;
            continue;
          }

          // 情况 C：普通列表条目（如短期安排下的 ①~24，长期规划下的 ①~⑧，喜欢吃辣下的 ① 喜欢吃火锅）
          final targetModId = l3Id ?? l2Id ?? l1Id ?? memberId;
          final existing = await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [targetModId]);
          lastListEntryId = await widget.db.insert('module_entries', {
            'module_id': targetModId,
            'seq': seqNum,
            'content': rest,
            'sort_order': existing.length,
            'created_at': DateTime.now().toIso8601String(),
          });
          importedEntries++;
          continue;
        }

        // 4. 普通无序号段落：
        // 如果是以“店铺：”、“菜品：”开头且紧跟在某个带圈条目后（如“① 喜欢吃火锅”），合并到该条目内方便一起看
        if (lastListEntryId != null && RegExp(r'^(店铺|菜品|地址|推荐)[:：]').hasMatch(txt)) {
          final rows = await widget.db.query('module_entries', where: 'id = ?', whereArgs: [lastListEntryId]);
          if (rows.isNotEmpty) {
            final oldContent = '${rows.first['content']}';
            if (txt != '菜品：' && txt != '菜品:') {
              await widget.db.update(
                'module_entries',
                {'content': '$oldContent\n$txt'},
                where: 'id = ?',
                whereArgs: [lastListEntryId],
              );
            }
            continue;
          }
        }

        // 否则（如“二、首要信息”下的生日/小名，或“② 胃炎”、“⑥ 外貌”子文件夹下的每一段详细描述），作为独立编号条目存入当前子文件夹！
        final targetModId = l3Id ?? l2Id ?? l1Id ?? memberId;
        final existing = await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [targetModId]);
        await widget.db.insert('module_entries', {
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
        SnackBar(content: Text('🎉 导入「$confirmedName」成功：已拆分为 $importedFolders 个独立文件夹、$importedEntries 条内容！')),
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
                await _createCleanMod(txt, parentId);
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
                      if (list.isEmpty) return const Center(child: Text('暂无直接内容（可点击上方小标题查看子分类）', style: TextStyle(color: Colors.grey, fontSize: 13)));
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
