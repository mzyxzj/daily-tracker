import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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

class FamilyPage extends StatefulWidget {
  final Database db;
  const FamilyPage({super.key, required this.db});
  @override
  State<FamilyPage> createState() => _FamilyPageState();
}

class _FamilyPageState extends State<FamilyPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🏠 家庭'),
        actions: [TextButton.icon(onPressed: _createMod, icon: const Icon(Icons.add), label: const Text('新建大标题'))],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: widget.db.query('modules', orderBy: 'id DESC'),
        builder: (_, snap) {
          final mods = snap.data ?? [];
          if (mods.isEmpty) return const Center(child: Text('暂无大标题，点击右上角新建'));
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: mods.length,
            itemBuilder: (_, i) {
              final m = mods[i];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_outlined, color: Colors.indigo),
                  title: Text('${m['title']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () async {
                      await widget.db.delete('module_entries', where: 'module_id = ?', whereArgs: [m['id']]);
                      await widget.db.delete('modules', where: 'id = ?', whereArgs: [m['id']]);
                      setState(() {});
                    },
                  ),
                  onTap: () => _openEntries(m['id'] as int, '${m['title']}'),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _createMod() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建大标题'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: '如：吃饭、近日目标')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (ctrl.text.trim().isEmpty) return;
              await widget.db.insert('modules', {'title': ctrl.text.trim(), 'created_at': DateTime.now().toIso8601String()});
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  void _openEntries(int modId, String title) {
    final ctrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          builder: (_, sc) => Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('📁 $title', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                TextField(controller: ctrl, maxLines: 3, decoration: const InputDecoration(border: OutlineInputBorder(), hintText: '支持序号自动拆分：1. / 1、 / (1) / ①')),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () async {
                      if (ctrl.text.trim().isEmpty) return;
                      final ex = await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [modId]);
                      final maxS = ex.isEmpty ? 0 : ex.map((e) => e['seq'] as int).reduce((a, b) => a > b ? a : b);
                      for (final it in SequenceParser.parse(ctrl.text, maxS)) {
                        await widget.db.insert('module_entries', {'module_id': modId, 'seq': it.seq, 'content': it.text, 'created_at': DateTime.now().toIso8601String()});
                      }
                      ctrl.clear();
                      setS(() {});
                    },
                    child: const Text('添加内容'),
                  ),
                ),
                const Divider(),
                Expanded(
                  child: FutureBuilder<List<Map<String, dynamic>>>(
                    future: widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [modId], orderBy: 'seq ASC, created_at ASC'),
                    builder: (_, snap) {
                      final list = snap.data ?? [];
                      return ListView.builder(
                        controller: sc,
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final e = list[i];
                          return ListTile(
                            leading: CircleAvatar(radius: 13, child: Text('${e['seq']}', style: const TextStyle(fontSize: 12))),
                            title: Text('${e['content']}'),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () async {
                                await widget.db.delete('module_entries', where: 'id = ?', whereArgs: [e['id']]);
                                setS(() {});
                              },
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
}

class SearchPage extends StatefulWidget {
  final Database db;
  const SearchPage({super.key, required this.db});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🔍 查找')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: widget.db.query('module_groups', orderBy: 'id DESC'),
        builder: (_, snap) {
          final groups = snap.data ?? [];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(child: FilledButton.icon(onPressed: _createGroup, icon: const Icon(Icons.add), label: const Text('新建标题组'))),
                  const SizedBox(width: 10),
                  Expanded(child: OutlinedButton.icon(onPressed: _tempView, icon: const Icon(Icons.visibility_outlined), label: const Text('临时查看'))),
                ],
              ),
              const SizedBox(height: 12),
              ...groups.map((g) {
                final ids = '${g['module_ids']}'.split(',').where((s) => s.isNotEmpty).map(int.parse).toList();
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.folder_special, color: Colors.indigo),
                    title: Text('${g['name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () async {
                        await widget.db.delete('module_groups', where: 'id = ?', whereArgs: [g['id']]);
                        setState(() {});
                      },
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

  Future<void> _createGroup() async {
    final mods = await widget.db.query('modules');
    if (!mounted || mods.isEmpty) return;
    final ctrl = TextEditingController();
    final sel = <int>{};
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('新建标题组'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: ctrl, decoration: const InputDecoration(labelText: '组名')),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: mods.map((m) {
                      final id = m['id'] as int;
                      return CheckboxListTile(value: sel.contains(id), title: Text('${m['title']}'), onChanged: (v) => setS(() => v! ? sel.add(id) : sel.remove(id)));
                    }).toList(),
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
                await widget.db.insert('module_groups', {'name': ctrl.text.trim(), 'module_ids': sel.join(','), 'created_at': DateTime.now().toIso8601String()});
                if (mounted) Navigator.pop(ctx);
                setState(() {});
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _tempView() async {
    final mods = await widget.db.query('modules');
    if (!mounted || mods.isEmpty) return;
    final sel = <int>{};
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('临时勾选查看'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: mods.map((m) {
                final id = m['id'] as int;
                return CheckboxListTile(value: sel.contains(id), title: Text('${m['title']}'), onChanged: (v) => setS(() => v! ? sel.add(id) : sel.remove(id)));
              }).toList(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(onPressed: () { Navigator.pop(ctx); if (sel.isNotEmpty) _showAgg('临时查看', sel.toList()); }, child: const Text('查看')),
          ],
        ),
      ),
    );
  }

  Future<void> _showAgg(String title, List<int> ids) async {
    final blocks = <Widget>[];
    for (final id in ids) {
      final m = await widget.db.query('modules', where: 'id = ?', whereArgs: [id]);
      if (m.isEmpty) continue;
      final es = await widget.db.query('module_entries', where: 'module_id = ?', whereArgs: [id], orderBy: 'seq ASC, created_at ASC');
      blocks.add(Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('📁 ${m.first['title']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const Divider(),
              if (es.isEmpty) const Text('（暂无内容）', style: TextStyle(color: Colors.grey)) else ...es.map((e) => Text('${e['seq']}. ${e['content']}')),
            ],
          ),
        ),
      ));
    }
    if (!mounted) return;
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => DraggableScrollableSheet(expand: false, initialChildSize: 0.75, builder: (_, sc) => ListView(controller: sc, padding: const EdgeInsets.all(16), children: [Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), const SizedBox(height: 12), ...blocks])));
  }

  Future<void> _exportZip() async {
    final appDir = await getApplicationDocumentsDirectory();
    final data = {
      'app': 'daily_tracker',
      'version': '2.0.0',
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

class PlanPage extends StatefulWidget {
  final Database db;
  const PlanPage({super.key, required this.db});
  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  final _uuid = const Uuid();
  final Set<String> _col = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🧠 规划'), actions: [TextButton.icon(onPressed: _createMm, icon: const Icon(Icons.add), label: const Text('新建规划'))]),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: widget.db.query('mindmaps', orderBy: 'id DESC'),
        builder: (_, snap) {
          final list = snap.data ?? [];
          if (list.isEmpty) return const Center(child: Text('暂无思维导图规划，点击右上角新建'));
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final mm = list[i], root = jsonDecode('${mm['root_json']}') as Map<String, dynamic>;
              return Card(
                margin: const EdgeInsets.only(bottom: 14),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                          onPressed: () async { await widget.db.delete('mindmaps', where: 'id = ?', whereArgs: [mm['id']]); setState(() {}); },
                        ),
                      ),
                      _tree(mm['id'] as int, root, root, 0),
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

  Widget _tree(int mmId, Map<String, dynamic> root, Map<String, dynamic> node, int d) {
    final id = '${node['id']}', ch = (node['children'] as List).cast<Map<String, dynamic>>(), col = _col.contains(id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (ch.isNotEmpty) IconButton(icon: Icon(col ? Icons.chevron_right : Icons.expand_more, size: 18), onPressed: () => setState(() => col ? _col.remove(id) : _col.add(id))) else const SizedBox(width: 32),
            Expanded(child: Text('${node['text']}', style: TextStyle(fontSize: d == 0 ? 16 : 14, fontWeight: d <= 1 ? FontWeight.bold : FontWeight.normal))),
            IconButton(icon: const Icon(Icons.add_circle_outline, size: 18), onPressed: () => _addNode(mmId, root, node)),
            if (d > 0) IconButton(icon: const Icon(Icons.close, size: 16, color: Colors.red), onPressed: () async { _rm(root, id); await _save(mmId, root); }),
          ],
        ),
        if (ch.isNotEmpty && !col)
          Container(
            margin: const EdgeInsets.only(left: 20),
            padding: const EdgeInsets.only(left: 12),
            decoration: const BoxDecoration(border: Border(left: BorderSide(color: Color(0xFFE5E7EB), width: 2))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: ch.map((c) => _tree(mmId, root, c, d + 1)).toList()),
          ),
      ],
    );
  }

  bool _rm(Map<String, dynamic> p, String tid) {
    final ch = (p['children'] as List).cast<Map<String, dynamic>>();
    final idx = ch.indexWhere((c) => c['id'] == tid);
    if (idx != -1) { ch.removeAt(idx); return true; }
    return ch.any((c) => _rm(c, tid));
  }

  Future<void> _save(int mmId, Map<String, dynamic> root) async {
    await widget.db.update('mindmaps', {'root_json': jsonEncode(root), 'updated_at': DateTime.now().toIso8601String()}, where: 'id = ?', whereArgs: [mmId]);
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
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (ctrl.text.trim().isEmpty) return;
              (pNode['children'] as List).add({'id': _uuid.v4(), 'text': ctrl.text.trim(), 'children': []});
              if (mounted) Navigator.pop(ctx);
              await _save(mmId, root);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }
}
