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
                 
