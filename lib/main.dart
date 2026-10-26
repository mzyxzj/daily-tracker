import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.instance.database;
  runApp(DailyTrackerApp(db: db));
}

// ==================== 数据库层 (SQLite) ====================
class AppDatabase {
  static final AppDatabase instance = AppDatabase._();
  static Database? _db;
  AppDatabase._();

  Future<Database> get database async => _db ??= await _init();

  Future<Database> _init() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'daily_tracker.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE status_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            sort_order INTEGER DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE status_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            item_id INTEGER NOT NULL,
            date TEXT NOT NULL,
            value TEXT DEFAULT '',
            UNIQUE(item_id, date)
          )
        ''');
        await db.execute('''
          CREATE TABLE status_images (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            record_id INTEGER NOT NULL,
            file_path TEXT NOT NULL,
            sort_order INTEGER DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE schedule_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            sort_order INTEGER DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE schedule_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            item_id INTEGER NOT NULL,
            date TEXT NOT NULL,
            done INTEGER DEFAULT 0,
            UNIQUE(item_id, date)
          )
        ''');
        await db.execute('''
          CREATE TABLE modules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE module_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            module_id INTEGER NOT NULL,
            seq INTEGER NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE module_groups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            module_ids TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE mindmaps (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            root_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      },
    );
  }
}

// ==================== 序号自动识别服务 ====================
class SequenceParser {
  static List<({int seq, String text})> parse(String raw, int currentMaxSeq) {
    final lines = raw.split('\n');
    final results = <({int seq, String text})>[];
    final circledMap = <String, int>{};
    for (int i = 0; i < 20; i++) circledMap[String.fromCharCode(0x2460 + i)] = i + 1;
    for (int i = 0; i < 30; i++) circledMap[String.fromCharCode(0x3251 + i)] = i + 21;

    final arabicPattern = RegExp(r'^(\d+)[\.、\)）]\s*(.*)$');
    final parenPattern = RegExp(r'^[\(（](\d+)[\)）]\s*(.*)$');
    int autoSeq = currentMaxSeq;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final firstChar = trimmed.characters.first;
      if (circledMap.containsKey(firstChar)) {
        final content = trimmed.substring(firstChar.length).trim();
        if (content.isNotEmpty) results.add((seq: circledMap[firstChar]!, text: content));
        continue;
      }
      final m1 = arabicPattern.firstMatch(trimmed);
      if (m1 != null && m1.group(2)!.trim().isNotEmpty) {
        results.add((seq: int.parse(m1.group(1)!), text: m1.group(2)!.trim()));
        continue;
      }
      final m2 = parenPattern.firstMatch(trimmed);
      if (m2 != null && m2.group(2)!.trim().isNotEmpty) {
        results.add((seq: int.parse(m2.group(1)!), text: m2.group(2)!.trim()));
        continue;
      }
      autoSeq++;
      results.add((seq: autoSeq, text: trimmed));
    }
    return results;
  }
}

// ==================== 主应用入口 ====================
class DailyTrackerApp extends StatelessWidget {
  final Database db;
  const DailyTrackerApp({super.key, required this.db});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '每日记录',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4F46E5)),
        useMaterial3: true,
      ),
      home: MainShell(db: db),
    );
  }
}

class MainShell extends StatefulWidget {
  final Database db;
  const MainShell({super.key, required this.db});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tabIndex = 0; // 0:查找, 1:家庭, 2:今日, 3:规划

  @override
  Widget build(BuildContext context) {
    final pages = [
      SearchPage(db: widget.db),
      FamilyPage(db: widget.db),
      TodayPage(db: widget.db),
      PlanPage(db: widget.db),
    ];
    return Scaffold(
      body: pages[_tabIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (idx) => setState(() => _tabIndex = idx),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.search), label: '查找'),
          NavigationDestination(icon: Icon(Icons.home_outlined), label: '家庭'),
          NavigationDestination(icon: Icon(Icons.calendar_today), label: '今日'),
          NavigationDestination(icon: Icon(Icons.account_tree_outlined), label: '规划'),
        ],
      ),
    );
  }
}

// ==================== Tab 3: 今日页 ====================
class TodayPage extends StatefulWidget {
  final Database db;
  const TodayPage({super.key, required this.db});

  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  String _selectedDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
  final Map<int, bool> _expandedRecords = {};

  String get _todayStr => DateFormat('yyyy-MM-dd').format(DateTime.now());

  Future<Map<String, dynamic>> _loadData() async {
    final items = await widget.db.query('status_items', orderBy: 'sort_order ASC, id ASC');
    final displayMap = <int, Map<String, dynamic>>{};
    final appDir = await getApplicationDocumentsDirectory();

    for (final item in items) {
      final id = item['id'] as int;
      final type = item['type'] as String;
      final todayRecs = await widget.db.query(
        'status_records',
        where: 'item_id = ? AND date = ?',
        whereArgs: [id, _selectedDate],
      );
      if (todayRecs.isNotEmpty) {
        final rec = todayRecs.first;
        final imgs = await widget.db.query(
          'status_images',
          where: 'record_id = ?',
          whereArgs: [rec['id']],
          orderBy: 'sort_order ASC',
        );
        displayMap[id] = {
          'recordId': rec['id'],
          'value': rec['value'],
          'images': imgs.map((i) => p.join(appDir.path, i['file_path'] as String)).toList(),
          'isInherited': false,
        };
      } else if (type != 'image') {
        final prevRecs = await widget.db.query(
          'status_records',
          where: 'item_id = ? AND date < ? AND value != ""',
          whereArgs: [id, _selectedDate],
          orderBy: 'date DESC',
          limit: 1,
        );
        if (prevRecs.isNotEmpty) {
          displayMap[id] = {
            'recordId': null,
            'value': prevRecs.first['value'],
            'images': <String>[],
            'isInherited': true,
            'inheritedFrom': prevRecs.first['date'],
          };
        }
      }
    }

    final schedules = await widget.db.query('schedule_items', orderBy: 'sort_order ASC, id ASC');
    final schedDone = <int, bool>{};
    for (final s in schedules) {
      final sid = s['id'] as int;
      final r = await widget.db.query(
        'schedule_records',
        where: 'item_id = ? AND date = ?',
        whereArgs: [sid, _selectedDate],
      );
      schedDone[sid] = r.isNotEmpty && (r.first['done'] as int) == 1;
    }

    return {'items': items, 'display': displayMap, 'schedules': schedules, 'schedDone': schedDone};
  }

  @override
  Widget build(BuildContext context) {
    final isToday = _selectedDate == _todayStr;
    return Scaffold(
      appBar: AppBar(
        title: Text(isToday ? '今天 · $_selectedDate' : _selectedDate),
        actions: [
          IconButton(
            icon: const Icon(Icons.date_range),
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: DateTime.parse(_selectedDate),
                firstDate: DateTime(2020),
                lastDate: DateTime(2035),
              );
              if (picked != null) {
                setState(() => _selectedDate = DateFormat('yyyy-MM-dd').format(picked));
              }
            },
          )
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _loadData(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!['items'] as List<Map<String, dynamic>>;
          final display = snap.data!['display'] as Map<int, Map<String, dynamic>>;
          final schedules = snap.data!['schedules'] as List<Map<String, dynamic>>;
          final schedDone = snap.data!['schedDone'] as Map<int, bool>;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildSummaryCard(items, display, schedules, schedDone),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('📊 每日状态', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  TextButton.icon(
                    onPressed: _addStatusItemDialog,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新条目'),
                  ),
                ],
              ),
              ...items.map((item) => _buildStatusItemCard(item, display[item['id'] as int])),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('📅 日程打卡', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  TextButton.icon(
                    onPressed: _addScheduleDialog,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新日程'),
                  ),
                ],
              ),
              ...schedules.map((s) {
                final sid = s['id'] as int;
                final done = schedDone[sid] ?? false;
                return CheckboxListTile(
                  value: done,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    s['title'] as String,
                    style: TextStyle(decoration: done ? TextDecoration.lineThrough : null),
                  ),
                  secondary: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () async {
                      await widget.db.delete('schedule_records', where: 'item_id = ?', whereArgs: [sid]);
                      await widget.db.delete('schedule_items', where: 'id = ?', whereArgs: [sid]);
                      setState(() {});
                    },
                  ),
                  onChanged: (val) async {
                    await widget.db.insert(
                      'schedule_records',
                      {'item_id': sid, 'date': _selectedDate, 'done': (val ?? false) ? 1 : 0},
                      conflictAlgorithm: ConflictAlgorithm.replace,
                    );
                    setState(() {});
                  },
                );
              }),
              if (schedules.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '今日完成：${schedDone.values.where((v) => v).length} / ${schedules.length}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSummaryCard(
    List<Map<String, dynamic>> items,
    Map<int, Map<String, dynamic>> display,
    List<Map<String, dynamic>> schedules,
    Map<int, bool> schedDone,
  ) {
    final lines = <String>[];
    for (final item in items) {
      final d = display[item['id'] as int];
      if (d == null) continue;
      if (item['type'] == 'image') {
        final imgs = d['images'] as List<String>;
        if (imgs.isNotEmpty) lines.add('${item['name']}：[${imgs.length}张图片]');
      } else if ((d['value'] as String).isNotEmpty) {
        lines.add('${item['name']}：${d['value']}');
      }
    }
    if (lines.isEmpty) return const SizedBox.shrink();

    final doneList = schedules.where((s) => schedDone[s['id']] == true).map((s) => s['title']).join('、');
    final todoList = schedules.where((s) => schedDone[s['id']] != true).map((s) => s['title']).join('、');
    var summary = '📋 $_selectedDate 状态记录\n${lines.join('\n')}';
    if (schedules.isNotEmpty) {
      summary += '\n\n✅ 已完成日程：${doneList.isEmpty ? "无" : doneList}';
      summary += '\n⬜ 未完成日程：${todoList.isEmpty ? "无" : todoList}';
    }

    return Card(
      color: const Color(0xFFF8FAFC),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('今日状态摘要', style: TextStyle(fontWeight: FontWeight.bold)),
                FilledButton.tonal(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: summary));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
                  },
                  child: const Text('复制'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(summary, style: const TextStyle(fontSize: 13, height: 1.5)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusItemCard(Map<String, dynamic> item, Map<String, dynamic>? disp) {
    final id = item['id'] as int;
    final name = item['name'] as String;
    final type = item['type'] as String;
    final isInherited = disp?['isInherited'] == true;
    final val = disp?['value'] as String? ?? '';
    final images = (disp?['images'] as List<String>?) ?? [];
    final recId = disp?['recordId'] as int?;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                Row(
                  children: [
                    if (type == 'number')
                      IconButton(
                        icon: const Icon(Icons.show_chart, color: Colors.indigo),
                        onPressed: () => _showTrendSheet(id, name),
                      ),
                    if (type == 'image')
                      TextButton.icon(
                        onPressed: () => _pickImages(id),
                        icon: const Icon(Icons.add_a_photo, size: 16),
                        label: const Text('添加'),
                      )
                    else
                      TextButton(
                        onPressed: () => _editValueDialog(id, name, type, val),
                        child: Text(isInherited ? '覆盖' : '修改'),
                      ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                      onPressed: () async {
                        await widget.db.delete('status_records', where: 'item_id = ?', whereArgs: [id]);
                        await widget.db.delete('status_items', where: 'id = ?', whereArgs: [id]);
                        setState(() {});
                      },
                    ),
                  ],
                ),
              ],
            ),
            if (type != 'image')
              disp == null
                  ? const Text('未填写', style: TextStyle(color: Colors.grey))
                  : Row(
                      children: [
                        Text(
                          val,
                          style: TextStyle(
                            fontStyle: isInherited ? FontStyle.italic : FontStyle.normal,
                            color: isInherited ? Colors.grey[700] : Colors.black87,
                          ),
                        ),
                        if (isInherited) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.amber[100],
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '继承自 ${disp['inheritedFrom']}',
                              style: TextStyle(fontSize: 11, color: Colors.amber[900]),
                            ),
                          ),
                        ]
                      ],
                    ),
            if (type == 'image' && images.isNotEmpty)
              _buildWeChatPhotoGrid(recId ?? id, images),
          ],
        ),
      ),
    );
  }

  Widget _buildWeChatPhotoGrid(int recId, List<String> paths) {
    final expanded = _expandedRecords[recId] ?? false;
    final total = paths.length;
    final showCount = expanded ? total : (total > 3 ? 3 : total);
    final cols = total == 1 ? 1 : (total == 2 ? 2 : 3);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: showCount,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: 6,
            mainAxisSpacing: 6,
          ),
          itemBuilder: (ctx, i) {
            final showOverlay = !expanded && total > 3 && i == 2;
            return GestureDetector(
              onTap: () => _openLightbox(paths, i),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.file(File(paths[i]), fit: BoxFit.cover),
                  ),
                  if (showOverlay)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '+${total - 3}',
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        if (total > 3)
          TextButton(
            onPressed: () => setState(() => _expandedRecords[recId] = !expanded),
            child: Text(expanded ? '收起' : '展开全部 $total 张'),
          ),
      ],
    );
  }

  void _openLightbox(List<String> paths, int initialIndex) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
          body: PageView.builder(
            controller: PageController(initialPage: initialIndex),
            itemCount: paths.length,
            itemBuilder: (_, idx) => InteractiveViewer(
              child: Center(child: Image.file(File(paths[idx]))),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickImages(int itemId) async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage(imageQuality: 100); // 100 = 原图不压缩
    if (picked.isEmpty) return;

    await widget.db.insert(
      'status_records',
      {'item_id': itemId, 'date': _selectedDate, 'value': ''},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    final recs = await widget.db.query(
      'status_records',
      where: 'item_id = ? AND date = ?',
      whereArgs: [itemId, _selectedDate],
    );
    final recId = recs.first['id'] as int;

    final appDir = await getApplicationDocumentsDirectory();
    final dateDir = _selectedDate.replaceAll('-', '');
    final targetDir = Directory(p.join(appDir.path, 'images', 'status', dateDir));
    if (!await targetDir.exists()) await targetDir.create(recursive: true);

    for (int i = 0; i < picked.length; i++) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final fileName = '${recId}_${i}_$ts.jpg';
      final relPath = p.join('images', 'status', dateDir, fileName);
      await File(picked[i].path).copy(p.join(appDir.path, relPath));
      await widget.db.insert('status_images', {'record_id': recId, 'file_path': relPath, 'sort_order': i});
    }
    setState(() {});
  }

  void _addStatusItemDialog() {
    final nameCtrl = TextEditingController();
    String type = 'text';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('新建状态条目'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '名称（如：体重）')),
              DropdownButton<String>(
                value: type,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'text', child: Text('文本')),
                  DropdownMenuItem(value: 'number', child: Text('数字（支持折线图）')),
                  DropdownMenuItem(value: 'image', child: Text('图片（九宫格原图）')),
                ],
                onChanged: (v) => setDialogState(() => type = v!),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                if (nameCtrl.text.trim().isEmpty) return;
                await widget.db.insert('status_items', {'name': nameCtrl.text.trim(), 'type': type});
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

  void _editValueDialog(int itemId, String name, String type, String initVal) {
    final ctrl = TextEditingController(text: initVal);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('填写：$name'),
        content: TextField(
          controller: ctrl,
          keyboardType: type == 'number' ? TextInputType.number : TextInputType.text,
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              await widget.db.insert(
                'status_records',
                {'item_id': itemId, 'date': _selectedDate, 'value': ctrl.text.trim()},
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _addScheduleDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加日程'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: '如：晨跑30分钟')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (ctrl.text.trim().isEmpty) return;
              await widget.db.insert('schedule_items', {'title': ctrl.text.trim()});
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  Future<void> _showTrendSheet(int itemId, String name) async {
    final recs = await widget.db.query(
      'status_records',
      where: 'item_id = ? AND value != ""',
      whereArgs: [itemId],
      orderBy: 'date ASC',
    );
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$name · 历史趋势', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            if (recs.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('暂无历史数值')))
            else
              ...recs.map((r) => ListTile(
                    dense: true,
                    title: Text(r['date'] as String),
                    trailing: Text(r['value'] as String, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  )),
          ],
        ),
      ),
    );
  }
}

// ==================== Tab 2: 家庭页 ====================
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
        actions: [
          TextButton.icon(
            onPressed: _createModuleDialog,
            icon: const Icon(Icons.add),
            label: const Text('新建大标题'),
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: widget.db.query('modules', orderBy: 'id DESC'),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final mods = snap.data!;
          if (mods.isEmpty) return const Center(child: Text('暂无大标题，点击右上角新建'));
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: mods.length,
            itemBuilder: (_, idx) {
              final m = mods[idx];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_outlined, color: Colors.indigo),
                  title: Text(m['title'] as String, style: const TextStyle(fontWeight: FontWeight.bold)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () async {
                      await widget.db.delete('module_entries', where: 'module_id = ?', whereArgs: [m['id']]);
                      await widget.db.delete('modules', where: 'id = ?', whereArgs: [m['id']]);
                      setState(() {});
                    },
                  ),
                  onTap: () => _openEntriesSheet(m['id'] as int, m['title'] as String),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _createModuleDialog() {
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
              await widget.db.insert('modules', {
                'title': ctrl.text.trim(),
                'created_at': DateTime.now().toIso8601String(),
              });
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  void _openEntriesSheet(int moduleId, String title) {
    final inputCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          builder: (_, scrollCtrl) => Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('📁 $title', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                TextField(
                  controller: inputCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '支持序号自动拆分：1. / 1、 / (1) / ①',
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () async {
                      if (inputCtrl.text.trim().isEmpty) return;
                      final existing = await widget.db.query(
                        'module_entries',
                        where: 'module_id = ?',
                        whereArgs: [moduleId],
                      );
                      final maxSeq = existing.isEmpty
                          ? 0
                          : existing.map((e) => e['seq'] as int).reduce((a, b) => a > b ? a : b);
                      final parsed = SequenceParser.parse(inputCtrl.text, maxSeq);
                      for (final item in parsed) {
                        await widget.db.insert('module_entries', {
                          'module_id': moduleId,
                          'seq': item.seq,
                          'content': item.text,
                          'created_at': DateTime.now().toIso8601String(),
                        });
                      }
                      inputCtrl.clear();
                      setSheetState(() {});
                    },
                    child: const Text('添加内容'),
                  ),
                ),
                const Divider(),
                Expanded(
                  child: FutureBuilder<List<Map<String, dynamic>>>(
                    future: widget.db.query(
                      'module_entries',
                      where: 'module_id = ?',
                      whereArgs: [moduleId],
                      orderBy: 'seq ASC, created_at ASC',
                    ),
                    builder: (_, snap) {
                      if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                      final list = snap.data!;
                      return ListView.builder(
                        controller: scrollCtrl,
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final e = list[i];
                          return ListTile(
                            leading: CircleAvatar(radius: 13, child: Text('${e['seq']}', style: const TextStyle(fontSize: 12))),
                            title: Text(e['content'] as String),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () async {
                                await widget.db.delete('module_entries', where: 'id = ?', whereArgs: [e['id']]);
                                setSheetState(() {});
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

// ==================== Tab 1: 查找页（含 ZIP 备份与恢复） ====================
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
        builder: (ctx, snap) {
          final groups = snap.data ?? [];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _createGroupDialog,
                      icon: const Icon(Icons.add),
                      label: const Text('新建标题组'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _tempViewDialog,
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
                    child: Center(child: Text('暂无标题组，新建后可一键聚合查阅多个大标题')),
                  ),
                ),
              ...groups.map((g) {
                final ids = (g['module_ids'] as String)
                    .split(',')
                    .where((s) => s.isNotEmpty)
                    .map(int.parse)
                    .toList();
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.folder_special, color: Colors.indigo),
                    title: Text(g['name'] as String, style: const TextStyle(fontWeight: FontWeight.bold)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () async {
                        await widget.db.delete('module_groups', where: 'id = ?', whereArgs: [g['id']]);
                        setState(() {});
                      },
                    ),
                    onTap: () => _showAggregatedSheet(g['name'] as String, ids),
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
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: _exportZipBackup,
                          icon: const Icon(Icons.upload_file),
                          label: const Text('导出 ZIP 备份'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _importZipBackup,
                          icon: const Icon(Icons.download),
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

  Future<void> _createGroupDialog() async {
    final mods = await widget.db.query('modules');
    if (!mounted) return;
    if (mods.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先在家庭页创建大标题')));
      return;
    }
    final nameCtrl = TextEditingController();
    final selected = <int>{};
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('新建标题组'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '标题组名称')),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: mods.map((m) {
                      final id = m['id'] as int;
                      return CheckboxListTile(
                        value: selected.contains(id),
                        title: Text(m['title'] as String),
                        onChanged: (v) => setDialogState(() => v! ? selected.add(id) : selected.remove(id)),
                      );
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
                if (nameCtrl.text.trim().isEmpty || selected.isEmpty) return;
                await widget.db.insert('module_groups', {
                  'name': nameCtrl.text.trim(),
                  'module_ids': selected.join(','),
                  'created_at': DateTime.now().toIso8601String(),
                });
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

  Future<void> _tempViewDialog() async {
    final mods = await widget.db.query('modules');
    if (!mounted || mods.isEmpty) return;
    final selected = <int>{};
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('临时勾选查看'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: mods.map((m) {
                final id = m['id'] as int;
                return CheckboxListTile(
                  value: selected.contains(id),
                  title: Text(m['title'] as String),
                  onChanged: (v) => setDialogState(() => v! ? selected.add(id) : selected.remove(id)),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                if (selected.isNotEmpty) _showAggregatedSheet('临时查看', selected.toList());
              },
              child: const Text('查看'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAggregatedSheet(String groupTitle, List<int> modIds) async {
    final blocks = <Widget>[];
    for (final id in modIds) {
      final m = await widget.db.query('modules', where: 'id = ?', whereArgs: [id]);
      if (m.isEmpty) continue;
      final entries = await widget.db.query(
        'module_entries',
        where: 'module_id = ?',
        whereArgs: [id],
        orderBy: 'seq ASC, created_at ASC',
      );
      blocks.add(
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('📁 ${m.first['title']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const Divider(),
                if (entries.isEmpty)
                  const Text('（暂无内容）', style: TextStyle(color: Colors.grey))
                else
                  ...entries.map((e) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text('${e['seq']}. ${e['content']}'),
                      )),
              ],
            ),
          ),
        ),
      );
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        builder: (_, ctrl) => ListView(
          controller: ctrl,
          padding: const EdgeInsets.all(16),
          children: [
            Text(groupTitle, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ...blocks,
          ],
        ),
      ),
    );
  }

  Future<void> _exportZipBackup() async {
    final appDir = await getApplicationDocumentsDirectory();
    final data = {
      'app': 'daily_tracker',
      'version': '1.0.0',
      'exportTime': DateTime.now().toIso8601String(),
      'data': {
        'status_items': await widget.db.query('status_items'),
        'status_records': await widget.db.query('status_records'),
        'status_images': await widget.db.query('status_images'),
        'schedule_items': await widget.db.query('schedule_items'),
        'schedule_records': await widget.db.query('schedule_records'),
        'modules': await widget.db.query('modules'),
        'module_entries': await widget.db.query('module_entries'),
        'module_groups': await widget.db.query('module_groups'),
        'mindmaps': await widget.db.query('mindmaps'),
      },
    };

    final ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final zipPath = p.join(appDir.path, '每日记录_备份_$ts.zip');
    final encoder = ZipFileEncoder();
    encoder.create(zipPath);

    final jsonBytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(data));
    encoder.addArchiveFile(ArchiveFile('data.json', jsonBytes.length, jsonBytes));

    final imgDir = Directory(p.join(appDir.path, 'images'));
    if (await imgDir.exists()) {
      await for (final entity in imgDir.list(recursive: true)) {
        if (entity is File) {
          final rel = p.relative(entity.path, from: appDir.path);
          final bytes = await entity.readAsBytes();
          encoder.addArchiveFile(ArchiveFile(rel, bytes.length, bytes));
        }
      }
    }
    encoder.close();
    await Share.shareXFiles([XFile(zipPath)], text: '每日记录备份');
  }

  Future<void> _importZipBackup() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.any);
    if (res == null || res.files.single.path == null) return;
    final bytes = await File(res.files.single.path!).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final appDir = await getApplicationDocumentsDirectory();

    Map<String, dynamic>? backupJson;
    for (final file in archive) {
      if (!file.isFile) continue;
      if (file.name == 'data.json') {
        backupJson = jsonDecode(utf8.decode(file.content as List<int>)) as Map<String, dynamic>;
      } else if (file.name.startsWith('images/')) {
        final outFile = File(p.join(appDir.path, file.name));
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      }
    }
    if (backupJson == null || backupJson['app'] != 'daily_tracker') return;
    final tables = backupJson['data'] as Map<String, dynamic>;
    for (final entry in tables.entries) {
      for (final row in (entry.value as List)) {
        await widget.db.insert(
          entry.key,
          Map<String, Object?>.from(row as Map),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('备份导入恢复成功！')));
      setState(() {});
    }
  }
}

// ==================== Tab 4: 规划页（思维导图） ====================
class PlanPage extends StatefulWidget {
  final Database db;
  const PlanPage({super.key, required this.db});

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  final _uuid = const Uuid();
  final Set<String> _collapsed = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🧠 规划'),
        actions: [
          TextButton.icon(
            onPressed: _createMindmapDialog,
            icon: const Icon(Icons.add),
            label: const Text('新建规划'),
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: widget.db.query('mindmaps', orderBy: 'id DESC'),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = snap.data!;
          if (list.isEmpty) return const Center(child: Text('暂无思维导图规划，点击右上角新建'));
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            itemBuilder: (_, idx) {
              final mm = list[idx];
              final root = jsonDecode(mm['root_json'] as String) as Map<String, dynamic>;
              return Card(
                margin: const EdgeInsets.only(bottom: 14),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('规划 #${mm['id']}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                            onPressed: () async {
                              await widget.db.delete('mindmaps', where: 'id = ?', whereArgs: [mm['id']]);
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                      _buildTree(mm['id'] as int, root, root, 0),
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

  Widget _buildTree(int mmId, Map<String, dynamic> root, Map<String, dynamic> node, int depth) {
    final id = node['id'] as String;
    final text = node['text'] as String;
    final children = (node['children'] as List).cast<Map<String, dynamic>>();
    final isCollapsed = _collapsed.contains(id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (children.isNotEmpty)
              IconButton(
                icon: Icon(isCollapsed ? Icons.chevron_right : Icons.expand_more, size: 18),
                onPressed: () => setState(() => isCollapsed ? _collapsed.remove(id) : _collapsed.add(id)),
              )
            else
              const SizedBox(width: 32),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: depth == 0 ? 16 : (depth == 1 ? 15 : 14),
                  fontWeight: depth <= 1 ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline, size: 18),
              onPressed: () => _addChildNodeDialog(mmId, root, node),
            ),
            if (depth > 0)
              IconButton(
                icon: const Icon(Icons.close, size: 16, color: Colors.red),
                onPressed: () async {
                  _removeNode(root, id);
                  await _saveRoot(mmId, root);
                },
              ),
          ],
        ),
        if (children.isNotEmpty && !isCollapsed)
          Container(
            margin: const EdgeInsets.only(left: 20),
            padding: const EdgeInsets.only(left: 12),
            decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: Color(0xFFE5E7EB), width: 2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children.map((c) => _buildTree(mmId, root, c, depth + 1)).toList(),
            ),
          ),
      ],
    );
  }

  bool _removeNode(Map<String, dynamic> parent, String targetId) {
    final children = (parent['children'] as List).cast<Map<String, dynamic>>();
    final idx = children.indexWhere((c) => c['id'] == targetId);
    if (idx != -1) {
      children.removeAt(idx);
      return true;
    }
    return children.any((c) => _removeNode(c, targetId));
  }

  Future<void> _saveRoot(int mmId, Map<String, dynamic> root) async {
    await widget.db.update(
      'mindmaps',
      {'root_json': jsonEncode(root), 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [mmId],
    );
    setState(() {});
  }

  void _createMindmapDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建规划'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: '根节点名称（如：年度目标）')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (ctrl.text.trim().isEmpty) return;
              final now = DateTime.now().toIso8601String();
              final root = {'id': _uuid.v4(), 'text': ctrl.text.trim(), 'children': []};
              await widget.db.insert('mindmaps', {
                'title': ctrl.text.trim(),
                'root_json': jsonEncode(root),
                'created_at': now,
                'updated_at': now,
              });
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  void _addChildNodeDialog(int mmId, Map<String, dynamic> root, Map<String, dynamic> parentNode) {
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
              (parentNode['children'] as List).add({'id': _uuid.v4(), 'text': ctrl.text.trim(), 'children': []});
              if (mounted) Navigator.pop(ctx);
              await _saveRoot(mmId, root);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }
}
