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
      version: 4,
      onCreate: (db, v) async {
        await db.execute('CREATE TABLE status_items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, type TEXT NOT NULL, sort_order INTEGER DEFAULT 0)');
        await db.execute('CREATE TABLE status_records (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, date TEXT NOT NULL, value TEXT DEFAULT "", UNIQUE(item_id, date))');
        await db.execute('CREATE TABLE status_images (id INTEGER PRIMARY KEY AUTOINCREMENT, record_id INTEGER NOT NULL, file_path TEXT NOT NULL, sort_order INTEGER DEFAULT 0)');
        await db.execute('CREATE TABLE schedule_items (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, plan_info TEXT DEFAULT "", parent_id INTEGER, sort_order INTEGER DEFAULT 0)');
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
        if (oldV < 4) {
          try { await db.execute("ALTER TABLE schedule_items ADD COLUMN parent_id INTEGER"); } catch (_) {}
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
        height: 62,
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
  final Map<int, bool> _expandedPhoto = {};
  final Set<int> _collapsedStatusIds = {};
  final Set<int> _collapsedSchedParents = {};
  bool _foldSummary = false; // 默认展开分列摘要
  bool _foldStatusSection = false;
  bool _foldSchedSection = false;

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

  /// 智能识别换行、|、◦、•、；、; 或多段句号，拆分为分列数组
  List<String> _splitColumns(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return [];
    if (trimmed.contains('\n')) {
      return trimmed.split('\n').map((s) => s.replaceFirst(RegExp(r'^[◦•\-\*]\s*'), '').trim()).where((s) => s.isNotEmpty).toList();
    }
    if (trimmed.contains('|')) {
      return trimmed.split('|').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }
    if (trimmed.contains('◦') || trimmed.contains('•')) {
      return trimmed.split(RegExp(r'[◦•]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }
    if (trimmed.contains('；') || trimmed.contains(';')) {
      return trimmed.split(RegExp(r'[；;]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }
    if (trimmed.contains('。')) {
      final parts = trimmed.split('。').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      if (parts.length > 1) return parts;
    }
    return [trimmed];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 46,
        title: Text(_date == _today ? '今天 · $_date' : _date, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.date_range, size: 20),
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

          final doneCount = doneMap.values.where((v) => v).length;

          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              _buildSummary(items, disp, scheds, doneMap),

              _buildSectionHeader(
                icon: '📊',
                title: '每日状态 (${items.length})',
                isFolded: _foldStatusSection,
                onToggleFold: () => setState(() => _foldStatusSection = !_foldStatusSection),
                actionLabel: '新条目',
                onAction: () => _addOrEditStatusItemDialog(),
              ),
              if (!_foldStatusSection)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                  child: items.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: Text('暂无状态条目，点击右上角「+ 新条目」添加', style: TextStyle(color: Colors.grey, fontSize: 13))),
                        )
                      : Column(
                          children: [
                            for (int i = 0; i < items.length; i++) ...[
                              if (i > 0) const Divider(height: 1, color: Color(0xFFF1F5F9)),
                              _buildCompactStatusRow(items[i], disp[items[i]['id'] as int]),
                            ],
                          ],
                        ),
                ),

              _buildSectionHeader(
                icon: '📅',
                title: '日程打卡 ($doneCount/${scheds.length})',
                isFolded: _foldSchedSection,
                onToggleFold: () => setState(() => _foldSchedSection = !_foldSchedSection),
                actionLabel: '新日程',
                onAction: () => _addOrEditSchedDialog(),
              ),
              if (!_foldSchedSection)
                Card(
                  margin: const EdgeInsets.only(bottom: 16),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                  child: scheds.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: Text('暂无日程，点击右上角「+ 新日程」添加', style: TextStyle(color: Colors.grey, fontSize: 13))),
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: _buildScheduleTree(scheds, doneMap),
                        ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSectionHeader({
    required String icon,
    required String title,
    required bool isFolded,
    required VoidCallback onToggleFold,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onToggleFold,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Row(
                children: [
                  Icon(isFolded ? Icons.chevron_right : Icons.expand_more, size: 20, color: const Color(0xFF475569)),
                  const SizedBox(width: 2),
                  Text('$icon $title', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          const Spacer(),
          TextButton.icon(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: onAction,
            icon: const Icon(Icons.add, size: 16),
            label: Text(actionLabel, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  /// 结构化分列展示的「今日状态摘要」卡片 + 结构化分列复制文本
  Widget _buildSummary(List<Map<String, dynamic>> items, Map<int, Map<String, dynamic>> disp, List<Map<String, dynamic>> scheds, Map<int, bool> doneMap) {
    final copyLines = <String>[];
    final summaryRows = <Widget>[];

    for (final it in items) {
      final d = disp[it['id'] as int];
      if (d == null) continue;
      final name = '${it['name']}';
      if (it['type'] == 'image') {
        final imgs = d['images'] as List<String>;
        if (imgs.isNotEmpty) {
          copyLines.add('$name：[${imgs.length}张图片]');
          summaryRows.add(_buildSummarySingleLine(name, '[${imgs.length}张图片]'));
        }
      } else {
        final rawVal = (d['value'] as String).trim();
        if (rawVal.isEmpty) continue;
        final cols = _splitColumns(rawVal);
        if (cols.length <= 1) {
          copyLines.add('$name：${cols.first}');
          summaryRows.add(_buildSummarySingleLine(name, cols.first));
        } else {
          // 多列内容：复制时自动换行缩进分列，界面上也以分列小标签块呈现
          copyLines.add('$name：\n${cols.map((c) => '  • $c').join('\n')}');
          summaryRows.add(_buildSummaryMultiColRow(name, cols));
        }
      }
    }

    if (summaryRows.isEmpty && scheds.isEmpty) return const SizedBox.shrink();

    String fmtSched(Map<String, dynamic> s) {
      final p = (s['plan_info'] as String? ?? '').trim();
      return p.isEmpty ? '${s['title']}' : '${s['title']} ($p)';
    }

    final doneList = scheds.where((s) => doneMap[s['id']] == true).map(fmtSched).toList();
    final todoList = scheds.where((s) => doneMap[s['id']] != true).map(fmtSched).toList();

    var copyText = '📋 $_date 状态记录';
    if (copyLines.isNotEmpty) copyText += '\n${copyLines.join('\n')}';
    if (scheds.isNotEmpty) {
      copyText += '\n\n✅ 已完成日程：${doneList.isEmpty ? "无" : "\n${doneList.map((s) => "  • $s").join("\n")}"}';
      copyText += '\n⬜ 未完成日程：${todoList.isEmpty ? "无" : "\n${todoList.map((s) => "  • $s").join("\n")}"}';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _foldSummary = !_foldSummary),
                  child: Row(
                    children: [
                      Icon(_foldSummary ? Icons.chevron_right : Icons.expand_more, size: 18, color: const Color(0xFF475569)),
                      const SizedBox(width: 4),
                      Text('📋 今日状态摘要 · $_date', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                      const SizedBox(width: 6),
                      Text(_foldSummary ? '(点击展开)' : '(点击收起)', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: 26,
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: Size.zero,
                  ),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: copyText));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已按分列格式复制摘要到剪贴板')));
                  },
                  child: const Text('复制', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
          if (!_foldSummary) ...[
            const Divider(height: 12),
            ...summaryRows,
            if (scheds.isNotEmpty) ...[
              const SizedBox(height: 6),
              _buildSummaryScheduleBlock('✅ 已完成日程', doneList, const Color(0xFF10B981)),
              const SizedBox(height: 4),
              _buildSummaryScheduleBlock('⬜ 未完成日程', todoList, const Color(0xFF64748B)),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildSummarySingleLine(String name, String val) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text('$name：', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF334155))),
          ),
          Expanded(
            child: Text(val, style: const TextStyle(fontSize: 12.5, color: Color(0xFF1E293B), height: 1.35)),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryMultiColRow(String name, List<String> cols) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$name：', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF334155))),
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: cols.map((colText) {
                final colonIdx = colText.indexOf(RegExp(r'[:：]'));
                Widget content;
                if (colonIdx > 0 && colonIdx < 8) {
                  final k = colText.substring(0, colonIdx);
                  final v = colText.substring(colonIdx + 1).trim();
                  content = RichText(
                    text: TextSpan(
                      style: const TextStyle(fontSize: 12, height: 1.35, color: Color(0xFF1E293B)),
                      children: [
                        TextSpan(text: '$k：', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4F46E5))),
                        TextSpan(text: v),
                      ],
                    ),
                  );
                } else {
                  content = Text(colText, style: const TextStyle(fontSize: 12, height: 1.35, color: Color(0xFF1E293B)));
                }
                return Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 3),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: content,
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryScheduleBlock(String label, List<String> list, Color accentColor) {
    if (list.isEmpty) {
      return Row(
        children: [
          Text('$label：', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF475569))),
          const Text('无', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label (${list.length})：', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF475569))),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: list.map((item) => Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 2.5),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(5),
                border: Border(left: BorderSide(color: accentColor, width: 3)),
              ),
              child: Text(item, style: const TextStyle(fontSize: 12, color: Color(0xFF334155))),
            )).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildCompactStatusRow(Map<String, dynamic> it, Map<String, dynamic>? d) {
    final id = it['id'] as int, name = it['name'] as String, type = it['type'] as String;
    final inh = d?['isInherited'] == true, val = d?['value'] as String? ?? '';
    final imgs = (d?['images'] as List<String>?) ?? [];
    final recId = d?['recordId'] as int? ?? id;
    final cols = type == 'image' ? <String>[] : _splitColumns(val);
    final isItemFolded = _collapsedStatusIds.contains(id);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (cols.length > 1 || val.length > 22 || imgs.isNotEmpty)
                GestureDetector(
                  onTap: () => setState(() => isItemFolded ? _collapsedStatusIds.remove(id) : _collapsedStatusIds.add(id)),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(isItemFolded ? Icons.chevron_right : Icons.expand_more, size: 17, color: Colors.grey[600]),
                  ),
                ),
              GestureDetector(
                onTap: () => _addOrEditStatusItemDialog(editItem: it),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1E293B))),
                    const SizedBox(width: 3),
                    Icon(Icons.edit_note, size: 14, color: Colors.grey[400]),
                  ],
                ),
              ),
              if (inh) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(color: Colors.amber[100], borderRadius: BorderRadius.circular(4)),
                  child: Text('承自${(d!['inheritedFrom'] as String).substring(5)}', style: TextStyle(fontSize: 10, color: Colors.amber[900])),
                ),
              ],
              const SizedBox(width: 8),
              if (type != 'image' && cols.length <= 1 && val.length <= 18 && !isItemFolded)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _editValDialog(id, name, type, val),
                    child: Text(
                      val.isEmpty ? '点击填写...' : val,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontStyle: inh ? FontStyle.italic : FontStyle.normal,
                        color: val.isEmpty ? Colors.grey[400] : (inh ? Colors.grey[700] : const Color(0xFF0F172A)),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
              else
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => type == 'image' ? _pickImgs(id) : _editValDialog(id, name, type, val),
                    child: Text(
                      isItemFolded ? '已折叠 (${cols.isNotEmpty ? "${cols.length}栏" : "${imgs.length}图"})' : '',
                      style: const TextStyle(fontSize: 11.5, color: Colors.grey),
                    ),
                  ),
                ),
              if (type == 'number')
                InkWell(
                  onTap: () => _showTrend(id, name),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    child: Icon(Icons.show_chart, size: 18, color: Color(0xFF4F46E5)),
                  ),
                ),
              InkWell(
                onTap: () => type == 'image' ? _pickImgs(id) : _editValDialog(id, name, type, val),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  child: Icon(
                    type == 'image' ? Icons.add_a_photo_outlined : Icons.edit_outlined,
                    size: 17,
                    color: const Color(0xFF4F46E5),
                  ),
                ),
              ),
              InkWell(
                onTap: () => _confirmDeleteStatusItem(id, name),
                child: const Padding(
                  padding: EdgeInsets.only(left: 4, top: 2, bottom: 2),
                  child: Icon(Icons.delete_outline, size: 17, color: Colors.redAccent),
                ),
              ),
            ],
          ),

          if (!isItemFolded && type != 'image' && (cols.length > 1 || val.length > 18))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: GestureDetector(
                onTap: () => _editValDialog(id, name, type, val),
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final useTwoCols = cols.length >= 2 && cols.every((c) => c.length <= 16);
                    final itemWidth = useTwoCols ? (constraints.maxWidth - 6) / 2 : constraints.maxWidth;
                    return Wrap(
                      spacing: 6,
                      runSpacing: 5,
                      children: cols.map((colText) {
                        final colonIdx = colText.indexOf(RegExp(r'[:：]'));
                        Widget inner;
                        if (colonIdx > 0 && colonIdx < 8) {
                          final label = colText.substring(0, colonIdx);
                          final body = colText.substring(colonIdx + 1).trim();
                          inner = RichText(
                            text: TextSpan(
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.35,
                                fontStyle: inh ? FontStyle.italic : FontStyle.normal,
                                color: const Color(0xFF1E293B),
                              ),
                              children: [
                                TextSpan(text: '$label：', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4F46E5))),
                                TextSpan(text: body),
                              ],
                            ),
                          );
                        } else {
                          inner = Text(
                            colText,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.35,
                              fontStyle: inh ? FontStyle.italic : FontStyle.normal,
                              color: const Color(0xFF1E293B),
                            ),
                          );
                        }
                        return Container(
                          width: itemWidth,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: inner,
                        );
                      }).toList(),
                    );
                  },
                ),
              ),
            ),

          if (!isItemFolded && type == 'image' && imgs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _buildGrid(recId, imgs),
            ),
        ],
      ),
    );
  }

  Widget _buildScheduleTree(List<Map<String, dynamic>> allScheds, Map<int, bool> doneMap) {
    final validIds = allScheds.map((s) => s['id'] as int).toSet();
    final roots = allScheds.where((s) {
      final pid = s['parent_id'] as int?;
      return pid == null || !validIds.contains(pid);
    }).toList();

    List<Map<String, dynamic>> childrenOf(int pid) {
      return allScheds.where((s) => s['parent_id'] == pid).toList();
    }

    Widget buildNode(Map<String, dynamic> s, int depth) {
      final sid = s['id'] as int;
      final done = doneMap[sid] ?? false;
      final plan = (s['plan_info'] as String? ?? '').trim();
      final children = childrenOf(sid);
      final hasChildren = children.isNotEmpty;
      final isCollapsed = _collapsedSchedParents.contains(sid);
      final doneChildrenCount = children.where((c) => doneMap[c['id'] as int] == true).length;

      return Column(
        key: ValueKey('sched_$sid'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(left: depth * 18.0 + 6, right: 6, top: 3, bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (hasChildren)
                  GestureDetector(
                    onTap: () => setState(() => isCollapsed ? _collapsedSchedParents.remove(sid) : _collapsedSchedParents.add(sid)),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Icon(isCollapsed ? Icons.chevron_right : Icons.expand_more, size: 19, color: const Color(0xFF4F46E5)),
                    ),
                  )
                else if (depth > 0)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.subdirectory_arrow_right, size: 15, color: Colors.grey),
                  )
                else
                  const SizedBox(width: 4),
                SizedBox(
                  width: 26,
                  height: 26,
                  child: Checkbox(
                    value: done,
                    visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                    onChanged: (v) async {
                      await widget.db.insert(
                        'schedule_records',
                        {'item_id': sid, 'date': _date, 'done': (v ?? false) ? 1 : 0},
                        conflictAlgorithm: ConflictAlgorithm.replace,
                      );
                      setState(() {});
                    },
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _addOrEditSchedDialog(editSched: s),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${s['title']}',
                                style: TextStyle(
                                  fontSize: depth == 0 ? 14 : 13,
                                  fontWeight: depth == 0 ? FontWeight.w500 : FontWeight.normal,
                                  decoration: done ? TextDecoration.lineThrough : null,
                                  color: done ? Colors.grey : const Color(0xFF1E293B),
                                ),
                              ),
                            ),
                            if (hasChildren)
                              Container(
                                margin: const EdgeInsets.only(left: 4),
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEEF2FF),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '$doneChildrenCount/${children.length}',
                                  style: const TextStyle(fontSize: 10.5, color: Color(0xFF4F46E5)),
                                ),
                              ),
                          ],
                        ),
                        if (plan.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Text(
                              '🎯 $plan',
                              style: const TextStyle(fontSize: 11, color: Color(0xFF4F46E5)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => _addOrEditSchedDialog(parentId: sid, parentTitle: '${s['title']}'),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                    child: Icon(Icons.add_circle_outline, size: 17, color: Color(0xFF4F46E5)),
                  ),
                ),
                InkWell(
                  onTap: () => _addOrEditSchedDialog(editSched: s),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                    child: Icon(Icons.edit_outlined, size: 16, color: Colors.blueGrey),
                  ),
                ),
                InkWell(
                  onTap: () async {
                    final subIds = <int>[sid];
                    void collect(int p) {
                      for (final c in childrenOf(p)) {
                        final cid = c['id'] as int;
                        subIds.add(cid);
                        collect(cid);
                      }
                    }
                    collect(sid);
                    for (final did in subIds) {
                      await widget.db.delete('schedule_records', where: 'item_id = ?', whereArgs: [did]);
                      await widget.db.delete('schedule_items', where: 'id = ?', whereArgs: [did]);
                    }
                    setState(() {});
                  },
                  child: const Padding(
                    padding: EdgeInsets.only(left: 4, right: 2, top: 3, bottom: 3),
                    child: Icon(Icons.delete_outline, size: 17, color: Colors.redAccent),
                  ),
                ),
              ],
            ),
          ),
          if (hasChildren && !isCollapsed)
            ...children.map((c) => buildNode(c, depth + 1)),
        ],
      );
    }

    return Column(
      children: [
        for (int i = 0; i < roots.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: Color(0xFFF1F5F9)),
          buildNode(roots[i], 0),
        ],
      ],
    );
  }

  Widget _buildGrid(int recId, List<String> paths) {
    final exp = _expandedPhoto[recId] ?? false, total = paths.length;
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
        if (total > 3) TextButton(onPressed: () => setState(() => _expandedPhoto[recId] = !exp), child: Text(exp ? '收起' : '展开全部 $total 张')),
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

  void _confirmDeleteStatusItem(int id, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定删除「$name」及其所有历史记录吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              await widget.db.delete('status_records', where: 'item_id = ?', whereArgs: [id]);
              await widget.db.delete('status_items', where: 'id = ?', whereArgs: [id]);
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _addOrEditStatusItemDialog({Map<String, dynamic>? editItem}) {
    final isEdit = editItem != null;
    final ctrl = TextEditingController(text: isEdit ? '${editItem['name']}' : '');
    String type = isEdit ? '${editItem['type']}' : 'text';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(isEdit ? '编辑状态条目' : '新建状态条目', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: '条目名称（如：体重/kg、饮食记录）'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: type,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '数据类型', isDense: true),
                items: const [
                  DropdownMenuItem(value: 'text', child: Text('文本（支持多行与分列展示）')),
                  DropdownMenuItem(value: 'number', child: Text('数字（支持趋势折线图）')),
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
                if (isEdit) {
                  await widget.db.update(
                    'status_items',
                    {'name': ctrl.text.trim(), 'type': type},
                    where: 'id = ?',
                    whereArgs: [editItem['id']],
                  );
                } else {
                  await widget.db.insert('status_items', {'name': ctrl.text.trim(), 'type': type});
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

  void _editValDialog(int id, String name, String type, String init) {
    String formattedInit = init;
    if (type == 'text' && !init.contains('\n')) {
      final cols = _splitColumns(init);
      if (cols.length > 1) formattedInit = cols.join('\n');
    }
    final ctrl = TextEditingController(text: formattedInit);

    void appendTemplate(String tpl) {
      final cur = ctrl.text.trimRight();
      ctrl.text = cur.isEmpty ? tpl : '$cur\n$tpl';
      ctrl.selection = TextSelection.fromPosition(TextPosition(offset: ctrl.text.length));
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        titlePadding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        title: Text('填写：$name', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (type == 'text') ...[
                const Text('💡 每一行（或用 | 、句号分隔）会自动在卡片与摘要中独立分列展示：', style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    ActionChip(
                      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                      label: const Text('+ 新增分列行', style: TextStyle(fontSize: 11.5)),
                      onPressed: () => appendTemplate('项目：'),
                    ),
                    ActionChip(
                      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                      label: const Text('早/午/晚餐模板', style: TextStyle(fontSize: 11.5)),
                      onPressed: () => appendTemplate('早餐：\n午餐：\n晚餐：'),
                    ),
                    ActionChip(
                      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                      label: const Text('上/下/晚模板', style: TextStyle(fontSize: 11.5)),
                      onPressed: () => appendTemplate('上午：\n下午：\n晚上：'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: ctrl,
                minLines: type == 'number' ? 1 : 4,
                maxLines: type == 'number' ? 1 : 10,
                keyboardType: type == 'number' ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.multiline,
                autofocus: true,
                style: const TextStyle(fontSize: 14, height: 1.45),
                decoration: InputDecoration(
                  hintText: type == 'number' ? '输入数值...' : '输入内容（换行即可自动分列展示）...',
                  contentPadding: const EdgeInsets.all(10),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
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

  Future<void> _addOrEditSchedDialog({Map<String, dynamic>? editSched, int? parentId, String? parentTitle}) async {
    final plans = await _loadPlans();
    if (!mounted) return;

    final isEdit = editSched != null;
    final ctrl = TextEditingController(text: isEdit ? '${editSched['title']}' : '');
    String selPlan = isEdit ? ('${editSched['plan_info'] ?? ''}') : '';
    if (selPlan.isNotEmpty && !plans.any((p) => p.path == selPlan)) {
      plans.insert(0, (path: selPlan, name: selPlan.split(' > ').last));
    }

    final dlgTitle = isEdit
        ? '编辑日程'
        : (parentId != null ? '在「$parentTitle」下添加子日程' : '添加日程');

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(dlgTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '日程内容',
                    hintText: '如：晨跑30分钟',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                const Text('关联规划（确保符合规划）：', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                if (plans.isEmpty)
                  const Text('暂无规划可关联，可先在「规划」页创建或导入 XMind', style: TextStyle(fontSize: 12, color: Colors.grey))
                else
                  DropdownButtonFormField<String>(
                    value: selPlan,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('不关联规划', style: TextStyle(fontSize: 13))),
                      ...plans.map((n) => DropdownMenuItem(
                            value: n.path,
                            child: Text(n.path, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                          )),
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
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                if (ctrl.text.trim().isEmpty) return;
                if (isEdit) {
                  await widget.db.update(
                    'schedule_items',
                    {'title': ctrl.text.trim(), 'plan_info': selPlan},
                    where: 'id = ?',
                    whereArgs: [editSched['id']],
                  );
                } else {
                  await widget.db.insert('schedule_items', {
                    'title': ctrl.text.trim(),
                    'plan_info': selPlan,
                    'parent_id': parentId,
                  });
                  if (parentId != null) _collapsedSchedParents.remove(parentId);
                }
                if (mounted) Navigator.pop(ctx);
                setState(() {});
              },
              child: Text(isEdit ? '保存' : '添加'),
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
