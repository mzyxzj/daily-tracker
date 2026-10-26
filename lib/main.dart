import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'pages_extra.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.instance.database;
  runApp(DailyTrackerApp(db: db));
}

class AppDatabase {
  static final AppDatabase instance = AppDatabase._();
  static Database? _db;
  AppDatabase._();
  Future<Database> get database async => _db ??= await _init();

  Future<Database> _init() async {
    final dir = await getApplicationDocumentsDirectory();
    return openDatabase(
      p.join(dir.path, 'daily_tracker.db'),
      version: 3,
      onCreate: (db, v) async {
        await db.execute('CREATE TABLE status_items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, type TEXT NOT NULL, sort_order INTEGER DEFAULT 0)');
        await db.execute('CREATE TABLE status_records (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, date TEXT NOT NULL, value TEXT DEFAULT "", UNIQUE(item_id, date))');
        await db.execute('CREATE TABLE status_images (id INTEGER PRIMARY KEY AUTOINCREMENT, record_id INTEGER NOT NULL, file_path TEXT NOT NULL, sort_order INTEGER DEFAULT 0)');
        await db.execute('CREATE TABLE schedule_items (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, plan_info TEXT DEFAULT "", sort_order INTEGER DEFAULT 0)');
        await db.execute('CREATE TABLE schedule_records (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, date TEXT NOT NULL, done INTEGER DEFAULT 0, UNIQUE(item_id, date))');
        await db.execute('CREATE TABLE modules (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, parent_id INTEGER, sort_order INTEGER DEFAULT 0, created_at TEXT NOT NULL)');
        await db.execute('CREATE TABLE module_entries (id INTEGER PRIMARY KEY AUTOINCREMENT, module_id INTEGER NOT NULL, seq INTEGER NOT NULL, content TEXT NOT NULL, sort_order INTEGER DEFAULT 0, created_at TEXT NOT NULL)');
        await db.execute('CREATE TABLE module_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, module_ids TEXT NOT NULL, created_at TEXT NOT NULL)');
        await db.execute('CREATE TABLE mindmaps (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, root_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)');
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          try { await db.execute("ALTER TABLE schedule_items ADD COLUMN plan_info TEXT DEFAULT ''"); } catch (_) {}
        }
        if (oldV < 3) {
          try { await db.execute("ALTER TABLE modules ADD COLUMN parent_id INTEGER"); } catch (_) {}
          try { await db.execute("ALTER TABLE modules ADD COLUMN sort_order INTEGER DEFAULT 0"); } catch (_) {}
          try { await db.execute("ALTER TABLE module_entries ADD COLUMN sort_order INTEGER DEFAULT 0"); } catch (_) {}
        }
      },
    );
  }
}

class TrendLineChart extends StatelessWidget {
  final List<({String date, double value})> points;
  const TrendLineChart({super.key, required this.points});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 220,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 24, 20, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: CustomPaint(painter: _TrendChartPainter(points)),
    );
  }
}

class _TrendChartPainter extends CustomPainter {
  final List<({String date, double value})> points;
  _TrendChartPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    const lPad = 36.0, bPad = 26.0, tPad = 16.0, rPad = 14.0;
    final cw = size.width - lPad - rPad, ch = size.height - tPad - bPad;
    final vals = points.map((e) => e.value).toList();
    double minV = vals.reduce(math.min), maxV = vals.reduce(math.max);
    if (minV == maxV) { minV -= 5; maxV += 5; }
    final range = maxV - minV;
    final gridPaint = Paint()..color = const Color(0xFFE2E8F0)..strokeWidth = 1;

    for (int i = 0; i <= 2; i++) {
      final ratio = i / 2.0, y = tPad + ch * (1 - ratio);
      canvas.drawLine(Offset(lPad, y), Offset(size.width - rPad, y), gridPaint);
      final v = minV + range * ratio;
      final tp = TextPainter(
        text: TextSpan(text: v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1), style: const TextStyle(color: Color(0xFF64748B), fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(math.max(0, lPad - tp.width - 6), y - tp.height / 2));
    }

    final coords = List.generate(points.length, (i) {
      final x = points.length == 1 ? lPad + cw / 2 : lPad + (i / (points.length - 1)) * cw;
      final y = tPad + ch - ((points[i].value - minV) / range) * ch;
      return Offset(x, y);
    });

    if (coords.length > 1) {
      final fill = Path()..moveTo(coords.first.dx, tPad + ch);
      for (final c in coords) fill.lineTo(c.dx, c.dy);
      fill..lineTo(coords.last.dx, tPad + ch)..close();
      canvas.drawPath(fill, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [const Color(0xFF4F46E5).withOpacity(0.25), const Color(0xFF4F46E5).withOpacity(0.0)]).createShader(Rect.fromLTWH(lPad, tPad, cw, ch)));

      final line = Path()..moveTo(coords.first.dx, coords.first.dy);
      for (int i = 1; i < coords.length; i++) line.lineTo(coords[i].dx, coords[i].dy);
      canvas.drawPath(line, Paint()..color = const Color(0xFF4F46E5)..strokeWidth = 2.5..style = PaintingStyle.stroke);
    }

    final step = math.max(1, (points.length / 6).ceil());
    for (int i = 0; i < coords.length; i++) {
      final isLast = i == coords.length - 1, c = coords[i];
      canvas.drawCircle(c, isLast ? 6 : 4.5, Paint()..color = Colors.white);
      canvas.drawCircle(c, isLast ? 4.5 : 3.2, Paint()..color = isLast ? const Color(0xFFEF4444) : const Color(0xFF4F46E5));
      if (i % step == 0 || isLast || i == 0) {
        final v = points[i].value;
        final vStr = v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1);
        final vTp = TextPainter(text: TextSpan(text: vStr, style: TextStyle(color: isLast ? const Color(0xFFEF4444) : const Color(0xFF1E293B), fontSize: 10, fontWeight: isLast ? FontWeight.bold : FontWeight.w500)), textDirection: TextDirection.ltr)..layout();
        vTp.paint(canvas, Offset(c.dx - vTp.width / 2, c.dy - vTp.height - 6));

        final dShort = points[i].date.length >= 10 ? points[i].date.substring(5) : points[i].date;
        final dTp = TextPainter(text: TextSpan(text: dShort, style: const TextStyle(color: Color(0xFF64748B), fontSize: 9.5)), textDirection: TextDirection.ltr)..layout();
        dTp.paint(canvas, Offset(c.dx - dTp.width / 2, tPad + ch + 6));
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class DailyTrackerApp extends StatelessWidget {
  final Database db;
  const DailyTrackerApp({super.key, required this.db});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '每日记录',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4F46E5)), useMaterial3: true),
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
  int _idx = 2;
  @override
  Widget build(BuildContext context) {
    final pages = [SearchPage(db: widget.db), FamilyPage(db: widget.db), TodayPage(db: widget.db), PlanPage(db: widget.db)];
    return Scaffold(
      body: pages[_idx],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _idx,
        onDestinationSelected: (i) => setState(() => _idx = i),
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

class TodayPage extends StatefulWidget {
  final Database db;
  const TodayPage({super.key, required this.db});
  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  String _date = DateFormat('yyyy-MM-dd').format(DateTime.now());
  final Map<int, bool> _expanded = {};
  String get _today => DateFormat('yyyy-MM-dd').format(DateTime.now());

  Future<Map<String, dynamic>> _load() async {
    final items = await widget.db.query('status_items', orderBy: 'sort_order ASC, id ASC');
    final disp = <int, Map<String, dynamic>>{};
    final appDir = await getApplicationDocumentsDirectory();

    for (final it in items) {
      final id = it['id'] as int, type = it['type'] as String;
      final recs = await widget.db.query('status_records', where: 'item_id = ? AND date = ?', whereArgs: [id, _date]);
      if (recs.isNotEmpty) {
        final r = recs.first;
        final imgs = await widget.db.query('status_images', where: 'record_id = ?', whereArgs: [r['id']], orderBy: 'sort_order ASC');
        disp[id] = {'recordId': r['id'], 'value': r['value'], 'images': imgs.map((i) => p.join(appDir.path, i['file_path'] as String)).toList(), 'isInherited': false};
      } else if (type != 'image') {
        final prev = await widget.db.query('status_records', where: 'item_id = ? AND date < ? AND value != ""', whereArgs: [id, _date], orderBy: 'date DESC', limit: 1);
        if (prev.isNotEmpty) disp[id] = {'recordId': null, 'value': prev.first['value'], 'images': <String>[], 'isInherited': true, 'inheritedFrom': prev.first['date']};
      }
    }
    final scheds = await widget.db.query('schedule_items', orderBy: 'sort_order ASC, id ASC');
    final doneMap = <int, bool>{};
    for (final s in scheds) {
      final sid = s['id'] as int;
      final r = await widget.db.query('schedule_records', where: 'item_id = ? AND date = ?', whereArgs: [sid, _date]);
      doneMap[sid] = r.isNotEmpty && (r.first['done'] as int) == 1;
    }
    return {'items': items, 'disp': disp, 'scheds': scheds, 'done': doneMap};
  }

  Future<List<({String path, String name})>> _loadPlans() async {
    final mms = await widget.db.query('mindmaps', orderBy: 'id DESC');
    final res = <({String path, String name})>[];
    void walk(Map<String, dynamic> n, String pre) {
      final t = (n['text'] as String? ?? '').trim();
      if (t.isEmpty) return;
      final cur = pre.isEmpty ? t : '$pre > $t';
      res.add((path: cur, name: t));
      for (final c in ((n['children'] as List?)?.cast<Map<String, dynamic>>() ?? [])) walk(c, cur);
    }
    for (final m in mms) {
      try { walk(jsonDecode(m['root_json'] as String) as Map<String, dynamic>, ''); } catch (_) {}
    }
    return res;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_date == _today ? '今天 · $_date' : _date),
        actions: [
          IconButton(
            icon: const Icon(Icons.date_range),
            onPressed: () async {
              final d = await showDatePicker(context: context, initialDate: DateTime.parse(_date), firstDate: DateTime(2020), lastDate: DateTime(2035));
              if (d != null) setState(() => _date = DateFormat('yyyy-MM-dd').format(d));
            },
          )
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _load(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!['items'] as List<Map<String, dynamic>>;
          final disp = snap.data!['disp'] as Map<int, Map<String, dynamic>>;
          final scheds = snap.data!['scheds'] as List<Map<String, dynamic>>;
          final doneMap = snap.data!['done'] as Map<int, bool>;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildSummary(items, disp, scheds, doneMap),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('📊 每日状态', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  TextButton.icon(onPressed: _addStatusDialog, icon: const Icon(Icons.add, size: 18), label: const Text('新条目')),
                ],
              ),
              ...items.map((it) => _buildStatusCard(it, disp[it['id'] as int])),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('📅 日程打卡', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  TextButton.icon(onPressed: _addSchedDialog, icon: const Icon(Icons.add, size: 18), label: const Text('新日程')),
                ],
              ),
              ...scheds.map((s) {
                final sid = s['id'] as int, done = doneMap[sid] ?? false;
                final plan = (s['plan_info'] as String? ?? '').trim();
                return CheckboxListTile(
                  value: done,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(s['title'] as String, style: TextStyle(decoration: done ? TextDecoration.lineThrough : null)),
                  subtitle: plan.isNotEmpty ? Text('🎯 关联规划：$plan', style: const TextStyle(fontSize: 12, color: Color(0xFF4F46E5))) : null,
                  secondary: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () async {
                      await widget.db.delete('schedule_records', where: 'item_id = ?', whereArgs: [sid]);
                      await widget.db.delete('schedule_items', where: 'id = ?', whereArgs: [sid]);
                      setState(() {});
                    },
                  ),
                  onChanged: (v) async {
                    await widget.db.insert('schedule_records', {'item_id': sid, 'date': _date, 'done': (v ?? false) ? 1 : 0}, conflictAlgorithm: ConflictAlgorithm.replace);
                    setState(() {});
                  },
                );
              }),
              if (scheds.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('今日完成：${doneMap.values.where((v) => v).length} / ${scheds.length}', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSummary(List<Map<String, dynamic>> items, Map<int, Map<String, dynamic>> disp, List<Map<String, dynamic>> scheds, Map<int, bool> doneMap) {
    final lines = <String>[];
    for (final it in items) {
      final d = disp[it['id'] as int];
      if (d == null) continue;
      if (it['type'] == 'image') {
        final imgs = d['images'] as List<String>;
        if (imgs.isNotEmpty) lines.add('${it['name']}：[${imgs.length}张图片]');
      } else if ((d['value'] as String).isNotEmpty) {
        lines.add('${it['name']}：${d['value']}');
      }
    }
    if (lines.isEmpty && scheds.isEmpty) return const SizedBox.shrink();
    String fmt(Map<String, dynamic> s) {
      final p = (s['plan_info'] as String? ?? '').trim();
      return p.isEmpty ? '${s['title']}' : '${s['title']}($p)';
    }
    final doneStr = scheds.where((s) => doneMap[s['id']] == true).map(fmt).join('、');
    final todoStr = scheds.where((s) => doneMap[s['id']] != true).map(fmt).join('、');
    var text = '📋 $_date 状态记录${lines.isNotEmpty ? '\n${lines.join('\n')}' : ''}';
    if (scheds.isNotEmpty) text += '\n\n✅ 已完成日程：${doneStr.isEmpty ? "无" : doneStr}\n⬜ 未完成日程：${todoStr.isEmpty ? "无" : todoStr}';

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
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
                  },
                  child: const Text('复制'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(text, style: const TextStyle(fontSize: 13, height: 1.5)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard(Map<String, dynamic> it, Map<String, dynamic>? d) {
    final id = it['id'] as int, name = it['name'] as String, type = it['type'] as String;
    final inh = d?['isInherited'] == true, val = d?['value'] as String? ?? '';
    final imgs = (d?['images'] as List<String>?) ?? [];
    final recId = d?['recordId'] as int? ?? id;

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
                    if (type == 'number') IconButton(icon: const Icon(Icons.show_chart, color: Colors.indigo), onPressed: () => _showTrend(id, name)),
                    if (type == 'image')
                      TextButton.icon(onPressed: () => _pickImgs(id), icon: const Icon(Icons.add_a_photo, size: 16), label: const Text('添加'))
                    else
                      TextButton(onPressed: () => _editValDialog(id, name, type, val), child: Text(inh ? '覆盖' : '修改')),
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
              d == null
                  ? const Text('未填写', style: TextStyle(color: Colors.grey))
                  : Row(
                      children: [
                        Text(val, style: TextStyle(fontStyle: inh ? FontStyle.italic : FontStyle.normal)),
                        if (inh) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: Colors.amber[100], borderRadius: BorderRadius.circular(4)),
                            child: Text('继承自 ${d['inheritedFrom']}', style: TextStyle(fontSize: 11, color: Colors.amber[900])),
                          ),
                        ]
                      ],
                    ),
            if (type == 'image' && imgs.isNotEmpty) _buildGrid(recId, imgs),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(int recId, List<String> paths) {
    final exp = _expanded[recId] ?? false, total = paths.length;
    final show = exp ? total : math.min(3, total);
    final cols = total == 1 ? 1 : (total == 2 ? 2 : 3);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: show,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, crossAxisSpacing: 6, mainAxisSpacing: 6),
          itemBuilder: (_, i) => GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(backgroundColor: Colors.black, appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white), body: PageView.builder(controller: PageController(initialPage: i), itemCount: total, itemBuilder: (_, idx) => InteractiveViewer(child: Center(child: Image.file(File(paths[idx])))))))),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.file(File(paths[i]), fit: BoxFit.cover)),
                if (!exp && total > 3 && i == 2)
                  Container(decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)), alignment: Alignment.center, child: Text('+${total - 3}', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
              ],
            ),
          ),
        ),
        if (total > 3) TextButton(onPressed: () => setState(() => _expanded[recId] = !exp), child: Text(exp ? '收起' : '展开全部 $total 张')),
      ],
    );
  }

  Future<void> _pickImgs(int itemId) async {
    final picked = await ImagePicker().pickMultiImage(imageQuality: 100);
    if (picked.isEmpty) return;
    await widget.db.insert('status_records', {'item_id': itemId, 'date': _date, 'value': ''}, conflictAlgorithm: ConflictAlgorithm.ignore);
    final recs = await widget.db.query('status_records', where: 'item_id = ? AND date = ?', whereArgs: [itemId, _date]);
    final recId = recs.first['id'] as int;
    final appDir = await getApplicationDocumentsDirectory();
    final dStr = _date.replaceAll('-', '');
    final dir = Directory(p.join(appDir.path, 'images', 'status', dStr));
    if (!await dir.exists()) await dir.create(recursive: true);
    for (int i = 0; i < picked.length; i++) {
      final rel = p.join('images', 'status', dStr, '${recId}_${i}_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(picked[i].path).copy(p.join(appDir.path, rel));
      await widget.db.insert('status_images', {'record_id': recId, 'file_path': rel, 'sort_order': i});
    }
    setState(() {});
  }

  void _addStatusDialog() {
    final ctrl = TextEditingController();
    String type = 'text';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('新建状态条目'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: ctrl, decoration: const InputDecoration(labelText: '名称（如：体重）')),
              DropdownButton<String>(
                value: type,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'text', child: Text('文本')),
                  DropdownMenuItem(value: 'number', child: Text('数字（支持折线图）')),
                  DropdownMenuItem(value: 'image', child: Text('图片（九宫格原图）')),
                ],
                onChanged: (v) => setS(() => type = v!),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                if (ctrl.text.trim().isEmpty) return;
                await widget.db.insert('status_items', {'name': ctrl.text.trim(), 'type': type});
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

  void _editValDialog(int id, String name, String type, String init) {
    final ctrl = TextEditingController(text: init);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('填写：$name'),
        content: TextField(controller: ctrl, keyboardType: type == 'number' ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              await widget.db.insert('status_records', {'item_id': id, 'date': _date, 'value': ctrl.text.trim()}, conflictAlgorithm: ConflictAlgorithm.replace);
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _addSchedDialog() async {
    final plans = await _loadPlans();
    if (!mounted) return;
    final ctrl = TextEditingController();
    String selPlan = '';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('添加日程'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: '日程内容', hintText: '如：晨跑30分钟')),
              const SizedBox(height: 14),
              const Text('关联规划（确保符合规划）：', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              if (plans.isEmpty)
                const Text('暂无规划可关联，可先在「规划」页创建', style: TextStyle(fontSize: 12, color: Colors.grey))
              else
                DropdownButtonFormField<String>(
                  value: selPlan,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: '', child: Text('不关联规划')),
                    ...plans.map((n) => DropdownMenuItem(value: n.path, child: Text(n.path, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))),
                  ],
                  onChanged: (v) => setS(() {
                    selPlan = v ?? '';
                    if (selPlan.isNotEmpty && ctrl.text.trim().isEmpty) {
                      ctrl.text = plans.firstWhere((e) => e.path == selPlan).name;
                    }
                  }),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                if (ctrl.text.trim().isEmpty) return;
                await widget.db.insert('schedule_items', {'title': ctrl.text.trim(), 'plan_info': selPlan});
                if (mounted) Navigator.pop(ctx);
                setState(() {});
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTrend(int itemId, String name) async {
    final recs = await widget.db.query('status_records', where: 'item_id = ? AND value != ""', whereArgs: [itemId], orderBy: 'date ASC');
    final pts = <({String date, double value})>[];
    for (final r in recs) {
      final v = double.tryParse('${r['value']}');
      if (v != null) pts.add((date: '${r['date']}', value: v));
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        builder: (_, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.all(16),
          children: [
            Text('$name · 历史趋势折线图', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 14),
            if (pts.isEmpty)
              const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('暂无有效数值记录')))
            else ...[
              TrendLineChart(points: pts),
              const SizedBox(height: 14),
              ...pts.reversed.map((p) => ListTile(dense: true, title: Text(p.date), trailing: Text('${p.value}', style: const TextStyle(fontWeight: FontWeight.bold)))),
            ],
          ],
        ),
      ),
    );
  }
}
