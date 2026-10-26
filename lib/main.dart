import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' hide TextDirection;
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

// ==================== 数据库层 (SQLite v2 含平滑迁移) ====================
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
      version: 2,
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
            plan_info TEXT DEFAULT '',
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
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute("ALTER TABLE schedule_items ADD COLUMN plan_info TEXT DEFAULT ''");
          } catch (_) {}
        }
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

// ==================== 折线图绘制组件 (CustomPainter) ====================
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
      child: CustomPaint(
        painter: _TrendChartPainter(points: points),
      ),
    );
  }
}

class _TrendChartPainter extends CustomPainter {
  final List<({String date, double value})> points;
  _TrendChartPainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    const leftPad = 36.0;
    const bottomPad = 26.0;
    const topPad = 16.0;
    const rightPad = 14.0;

    final chartW = size.width - leftPad - rightPad;
    final chartH = size.height - topPad - bottomPad;

    final values = points.map((e) => e.value).toList();
    double minV = values.reduce(math.min);
    double maxV = values.reduce(math.max);
    if (minV == maxV) {
      minV -= 5;
      maxV += 5;
    }
    final range = maxV - minV;

    final gridPaint = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..strokeWidth = 1;

    // 1. 绘制 3 条水平网格线与纵轴刻度
    for (int i = 0; i <= 2; i++) {
      final ratio = i / 2.0;
      final y = topPad + chartH * (1 - ratio);
      canvas.drawLine(Offset(leftPad, y), Offset(size.width - rightPad, y), gridPaint);

      final labelVal = minV + range * ratio;
      final tp = TextPainter(
        text: TextSpan(
          text: labelVal == labelVal.roundToDouble()
              ? labelVal.toInt().toString()
              : labelVal.toStringAsFixed(1),
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(math.max(0, leftPad - tp.width - 6), y - tp.height / 2));
    }

    // 2. 计算坐标点
    final coords = <Offset>[];
    for (int i = 0; i < points.length; i++) {
      final x = points.length == 1
          ? leftPad + chartW / 2
          : leftPad + (i / (points.length - 1)) * chartW;
      final y = topPad + chartH - ((points[i].value - minV) / range) * chartH;
      coords.add(Offset(x, y));
    }

    // 3. 绘制折线与底部渐变阴影
    if (coords.length > 1) {
      final fillPath = Path()..moveTo(coords.first.dx, topPad + chartH);
      for (final c in coords) {
        fillPath.lineTo(c.dx, c.dy);
      }
      fillPath.lineTo(coords.last.dx, topPad + chartH);
      fillPath.close();

      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF4F46E5).withOpacity(0.25),
            const Color(0xFF4F46E5).withOpacity(0.0),
          ],
        ).createShader(Rect.fromLTWH(leftPad, topPad, chartW, chartH));
      canvas.drawPath(fillPath, fillPaint);

      final linePath = Path()..moveTo(coords.first.dx, coords.first.dy);
      for (int i = 1; i < coords.length; i++) {
        linePath.lineTo(coords[i].dx, coords[i].dy);
      }
      final linePaint = Paint()
        ..color = const Color(0xFF4F46E5)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(linePath, linePaint);
    }

    // 4. 绘制数据点、数值标签与底部日期
    final step = math.max(1, (points.length / 6).ceil());
    for (int i = 0; i < coords.length; i++) {
      final isLast = i == coords.length - 1;
      final c = coords[i];

      canvas.drawCircle(c, isLast ? 6 : 4.5, Paint()..color = Colors.white);
      canvas.drawCircle(
        c,
        isLast ? 4.5 : 3.2,
        Paint()..color = isLast ? const Color(0xFFEF4444) : const Color(0xFF4F46E5),
      );

      if (i % step == 0 || isLast || i == 0) {
        final v = points[i].value;
        final valStr = v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
        final valTp = TextPainter(
          text: TextSpan(
            text: valStr,
            style: TextStyle(
              color: isLast ? const Color(0xFFEF4444) : const Color(0xFF1E293B),
              fontSize: 10,
              fontWeight: isLast ? FontWeight.bold : FontWeight.w500,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        valTp.paint(canvas, Offset(c.dx - valTp.width / 2, c.dy - valTp.height - 6));

        final dateShort = points[i].date.length >= 10 ? points[i].date.substring(5) : points[i].date;
        final dateTp = TextPainter(
          text: TextSpan(
            text: dateShort,
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 9.5),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        dateTp.paint(canvas, Offset(c.dx - dateTp.width / 2, topPad + chartH + 6));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TrendChartPainter oldDelegate) => true;
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
  int _tabIndex = 2; // 0:查找, 1:家庭, 2:今日, 3:规划

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

  Future<List<({String path, String nodeName})>> _loadAllPlanNodes() async {
    final mms = await widget.db.query('mindmaps', orderBy: 'id DESC');
    final result = <({String path, String nodeName})>[];

    void traverse(Map<String, dynamic> node, String prefix) {
      final text = (node['text'] as String? ?? '').trim();
      if (text.isEmpty) return;
      final currentPath = prefix.isEmpty ? text : '$prefix >$text';
      result.add((path: currentPath, nodeName: text));
      final children = (node['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final child in children) {
        traverse(child, currentPath);
      }
    }

    for (final mm in mms) {
      try {
        final root = jsonDecode(mm['root_json'] as String) as Map<String, dynamic>;
        traverse(root, '');
      } catch (_) {}
    }
    return result;
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
                final planInfo = (s['plan_info'] as String? ?? '').trim();
                return CheckboxListTile(
                  value: done,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    s['title'] as String,
                    style: TextStyle(decoration: done ? TextDecoration.lineThrough : null),
                  ),
                  subtitle: planInfo.isNotEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.account_tree_outlined, size: 13, color: Color(0xFF4F46E5)),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '规划：$planInfo',
                                  style: const TextStyle(fontSize: 12, color: Color(0xFF4F46E5)),
                                ),
                              ),
                            ],
                          ),
                        )
                      : null,
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
                    '今日完成：${schedDone.values.where((v) => v).length} /${schedules.length}',
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

  String _formatScheduleForSummary(Map<String, dynamic> s) {
    final title = s['title'] as String;
    final plan = (s['plan_info'] as String? ?? '').trim();
    return plan.isEmpty ? title : '$title（$plan）';
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
