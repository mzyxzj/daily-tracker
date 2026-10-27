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
import 'pages_extra.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.instance.database;
  runApp(DailyTrackerApp(db: db));
}

// ==================== 数据库层 (SQLite v7 含成员标识与 AI 配置持久化) ====================
class AppDatabase {
  static final AppDatabase instance = AppDatabase._();
  static Database? _db;
  AppDatabase._();
  Future<Database> get database async => _db ??= await _init();

  Future<Database> _init() async {
    final dir = await getApplicationDocumentsDirectory();
    return openDatabase(
      p.join(dir.path, 'daily_tracker.db'),
      version: 7,
      onCreate: (db, v) async {
        await db.execute('CREATE TABLE status_items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, type TEXT NOT NULL, allow_inherit INTEGER DEFAULT 1, sort_order INTEGER DEFAULT 0)');
        await db.execute('CREATE TABLE status_records (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, date TEXT NOT NULL, value TEXT DEFAULT "", UNIQUE(item_id, date))');
        await db.execute('CREATE TABLE status_images (id INTEGER PRIMARY KEY AUTOINCREMENT, record_id INTEGER NOT NULL, file_path TEXT NOT NULL, sort_order INTEGER DEFAULT 0)');
        await db.execute('CREATE TABLE schedule_items (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, plan_info TEXT DEFAULT "", parent_id INTEGER, sort_order INTEGER DEFAULT 0)');
        await db.execute('CREATE TABLE schedule_records (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, date TEXT NOT NULL, done INTEGER DEFAULT 0, UNIQUE(item_id, date))');
        await db.execute('CREATE TABLE modules (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, parent_id INTEGER, is_member INTEGER DEFAULT 0, sort_order INTEGER DEFAULT 0, created_at TEXT NOT NULL)');
        await db.execute('CREATE TABLE module_entries (id INTEGER PRIMARY KEY AUTOINCREMENT, module_id INTEGER NOT NULL, seq INTEGER NOT NULL, content TEXT NOT NULL, sort_order INTEGER DEFAULT 0, created_at TEXT NOT NULL)');
        await db.execute('CREATE TABLE module_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, module_ids TEXT NOT NULL, created_at TEXT NOT NULL)');
        await db.execute('CREATE TABLE mindmaps (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, root_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)');
        await db.execute('CREATE TABLE ui_states (state_key TEXT PRIMARY KEY, state_val TEXT NOT NULL)');
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
        if (oldV < 5) {
          try { await db.execute('CREATE TABLE IF NOT EXISTS ui_states (state_key TEXT PRIMARY KEY, state_val TEXT NOT NULL)'); } catch (_) {}
        }
        if (oldV < 6) {
          try { await db.execute("ALTER TABLE status_items ADD COLUMN allow_inherit INTEGER DEFAULT 1"); } catch (_) {}
        }
        if (oldV < 7) {
          try { await db.execute("ALTER TABLE modules ADD COLUMN is_member INTEGER DEFAULT 0"); } catch (_) {}
        }
      },
    );
  }

  static Future<String?> getUiState(Database db, String key) async {
    try {
      final rows = await db.query('ui_states', where: 'state_key = ?', whereArgs: [key]);
      if (rows.isNotEmpty) return rows.first['state_val'] as String;
    } catch (_) {}
    return null;
  }

  static Future<void> setUiState(Database db, String key, String val) async {
    try {
      await db.insert(
        'ui_states',
        {'state_key': key, 'state_val': val},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
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
  bool _foldSummary = false;
  bool _foldStatusSection = false;
  bool _foldSchedSection = false;
  bool _uiLoaded = false;

  String get _today => DateFormat('yyyy-MM-dd').format(DateTime.now());

  @override
  void initState() {
    super.initState();
    _restoreTodayUiState();
  }

  Future<void> _restoreTodayUiState() async {
    final raw = await AppDatabase.getUiState(widget.db, 'today_ui_state');
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _foldSummary = map['foldSummary'] == true;
        _foldStatusSection = map['foldStatusSection'] == true;
        _foldSchedSection = map['foldSchedSection'] == true;
        _collapsedStatusIds
          ..clear()
          ..addAll(((map['collapsedStatusIds'] as List?) ?? []).map((e) => e as int));
        _collapsedSchedParents
          ..clear()
          ..addAll(((map['collapsedSchedParents'] as List?) ?? []).map((e) => e as int));
      } catch (_) {}
    }
    if (mounted) setState(() => _uiLoaded = true);
  }

  Future<void> _saveTodayUiState() async {
    final data = jsonEncode({
      'foldSummary': _foldSummary,
      'foldStatusSection': _foldStatusSection,
      'foldSchedSection': _foldSchedSection,
      'collapsedStatusIds': _collapsedStatusIds.toList(),
      'collapsedSchedParents': _collapsedSchedParents.toList(),
    });
    await AppDatabase.setUiState(widget.db, 'today_ui_state', data);
  }

  Future<Map<String, dynamic>> _load() async {
    if (!_uiLoaded) await _restoreTodayUiState();
    final items = await widget.db.query('status_items', orderBy: 'sort_order ASC, id ASC');
    final disp = <int, Map<String, dynamic>>{};
    final appDir = await getApplicationDocumentsDirectory();

    for (final it in items) {
      final id = it['id'] as int, type = it['type'] as String;
      final allowInherit = (it['allow_inherit'] as int? ?? 1) == 1;

      final todayRecs = await widget.db.query('status_records', where: 'item_id = ? AND date = ?', whereArgs: [id, _date]);
      if (todayRecs.isNotEmpty) {
        final r = todayRecs.first;
        final imgs = await widget.db.query('status_images', where: 'record_id = ?', whereArgs: [r['id']], orderBy: 'sort_order ASC');
        disp[id] = {'recordId': r['id'], 'value': r['value'], 'images': imgs.map((i) => p.join(appDir.path, i['file_path'] as String)).toList(), 'isInherited': false};
      } else if (type != 'image' && allowInherit) {
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

  String _unescapeXml(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }

  Future<int> _ensureStatusItem(String name, String type) async {
    final existing = await widget.db.query('status_items', where: 'name = ?', whereArgs: [name]);
    if (existing.isNotEmpty) return existing.first['id'] as int;
    if (name == '状态与异状' || name == '状态和异状') {
      final alt = await widget.db.query('status_items', where: 'name IN (?, ?)', whereArgs: ['状态与异状', '状态和异状']);
      if (alt.isNotEmpty) return alt.first['id'] as int;
    }
    final all = await widget.db.query('status_items');
    return await widget.db.insert('status_items', {
      'name': name,
      'type': type,
      'allow_inherit': 1,
      'sort_order': all.length,
    });
  }

  // ==================== 新增：Gemini AI 状态总结分析与一键导入每日状态 ====================
  Future<void> _openGeminiAnalyzerSheet(String summaryText) async {
    final rawCfg = await AppDatabase.getUiState(widget.db, 'gemini_ai_config');
    Map<String, dynamic> cfg = {
      'model': 'gemini-3.1-pro',
      'mode': 'gem', // 'chat' (普通对话) 或 'gem' (专属Gem)
      'gemName': '每日状态系统分析师',
      'gemPrompt': '请从最客观、最理性的第一性原理角度分析我今日的状态记录（饮食、体重波动、运动与情绪精力关联），无需单纯情感安慰，请分条给出：1. 生理与能量机制复盘；2. 系统秩序与潜在风险预警；3. 明日具体可执行改进建议。每条控制在一段话内，格式如“标题：具体分析”。',
      'targetField': 'AI 深度异状分析',
      'apiKey': '',
    };
    if (rawCfg != null && rawCfg.isNotEmpty) {
      try {
        cfg.addAll(jsonDecode(rawCfg) as Map<String, dynamic>);
      } catch (_) {}
    }

    if (!mounted) return;
    final gemNameCtrl = TextEditingController(text: '${cfg['gemName']}');
    final gemPromptCtrl = TextEditingController(text: '${cfg['gemPrompt']}');
    final targetFieldCtrl = TextEditingController(text: '${cfg['targetField']}');
    final apiKeyCtrl = TextEditingController(text: '${cfg['apiKey']}');
    final resultCtrl = TextEditingController();
    String selectedModel = '${cfg['model']}';
    String selectedMode = '${cfg['mode']}';
    bool isLoading = false;
    bool showAdvancedKey = false;

    Future<void> saveCurrentConfig() async {
      final newCfg = {
        'model': selectedModel,
        'mode': selectedMode,
        'gemName': gemNameCtrl.text.trim(),
        'gemPrompt': gemPromptCtrl.text.trim(),
        'targetField': targetFieldCtrl.text.trim().isEmpty ? 'AI 深度异状分析' : targetFieldCtrl.text.trim(),
        'apiKey': apiKeyCtrl.text.trim(),
      };
      await AppDatabase.setUiState(widget.db, 'gemini_ai_config', jsonEncode(newCfg));
    }

    String buildFullPrompt() {
      final header = selectedMode == 'gem'
          ? '【当前启用 Gem：${gemNameCtrl.text.trim()} | 模型：$selectedModel】\n${gemPromptCtrl.text.trim()}\n\n'
          : '【模型：$selectedModel】\n请客观分析以下今日状态并给出分条建议：\n\n';
      return '$header$summaryText';
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.88,
          maxChildSize: 0.96,
          builder: (_, sc) => Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, MediaQuery.of(ctx).viewInsets.bottom + 14),
            child: ListView(
              controller: sc,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(colors: [Color(0xFF4F46E5), Color(0xFF9333EA)]),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.auto_awesome, color: Colors.white, size: 18),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('Gemini 今日状态智能分析', style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text('💡 自动记忆上次选用的模型、对话模式与 Gem 设定，支持直接生成或拉起外部 Gemini', style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                const Divider(height: 16),

                // 1. 模型选择 & 对话/Gem 模式切换
                Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: DropdownButtonFormField<String>(
                        value: ['gemini-3.1-pro', 'gemini-2.5-pro', 'gemini-2.5-flash'].contains(selectedModel)
                            ? selectedModel
                            : 'gemini-3.1-pro',
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '选择模型 (Model)',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'gemini-3.1-pro', child: Text('Gemini 3.1 Pro', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
                          DropdownMenuItem(value: 'gemini-2.5-pro', child: Text('Gemini 2.5 Pro', style: TextStyle(fontSize: 13))),
                          DropdownMenuItem(value: 'gemini-2.5-flash', child: Text('Gemini 2.5 Flash', style: TextStyle(fontSize: 13))),
                        ],
                        onChanged: (v) {
                          setS(() => selectedModel = v!);
                          saveCurrentConfig();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 4,
                      child: DropdownButtonFormField<String>(
                        value: selectedMode == 'chat' ? 'chat' : 'gem',
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '会话类型',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'gem', child: Text('💎 专属 Gem', style: TextStyle(fontSize: 13))),
                          DropdownMenuItem(value: 'chat', child: Text('💬 普通对话', style: TextStyle(fontSize: 13))),
                        ],
                        onChanged: (v) {
                          setS(() => selectedMode = v!);
                          saveCurrentConfig();
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // 2. Gem 设定（当选择专属 Gem 时展示）
                if (selectedMode == 'gem') ...[
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: gemNameCtrl,
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                            labelText: 'Gem 名称 / 预设角色',
                            border: OutlineInputBorder(),
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                          onChanged: (_) => saveCurrentConfig(),
                        ),
                      ),
                      const SizedBox(width: 6),
                      PopupMenuButton<({String name, String prompt})>(
                        tooltip: '快速切换常用 Gem 预设',
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEEF2FF),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFC7D2FE)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.bookmarks_outlined, size: 15, color: Color(0xFF4F46E5)),
                              SizedBox(width: 4),
                              Text('预设Gem', style: TextStyle(fontSize: 12, color: Color(0xFF4F46E5), fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                        onSelected: (preset) {
                          setS(() {
                            gemNameCtrl.text = preset.name;
                            gemPromptCtrl.text = preset.prompt;
                          });
                          saveCurrentConfig();
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: (
                              name: '客观理性系统分析师',
                              prompt: '请从最客观、最理性的第一性原理角度分析我今日的状态记录（饮食、体重波动、运动与情绪精力关联），无需单纯情感安慰，请分条给出：1. 生理与能量机制复盘；2. 系统秩序与潜在风险预警；3. 明日具体可执行改进建议。每条格式如“标题：具体分析”。',
                            ),
                            child: Text('💎 客观理性系统分析师'),
                          ),
                          const PopupMenuItem(
                            value: (
                              name: '代谢与营养精算师',
                              prompt: '请聚焦我今日的饮食结构（碳水/蛋白质/钠摄入）与体重变化、体能训练表现，分析水肿或热量缺口情况，并给出明日三餐调整方案。每条格式如“标题：具体分析”。',
                            ),
                            child: Text('🥗 代谢与营养精算师'),
                          ),
                          const PopupMenuItem(
                            value: (
                              name: '精力与日程效能教练',
                              prompt: '请结合我今日的已完成/未完成日程与核心目标，分析精力分配与决策疲劳点，给出明日单线程减法行动建议。每条格式如“标题：具体分析”。',
                            ),
                            child: Text('⚡ 精力与日程效能教练'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: gemPromptCtrl,
                    minLines: 2,
                    maxLines: 4,
                    style: const TextStyle(fontSize: 12.5, height: 1.35),
                    decoration: const InputDecoration(
                      labelText: 'Gem 专属分析指令（自动保存）',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(8),
                    ),
                    onChanged: (_) => saveCurrentConfig(),
                  ),
                  const SizedBox(height: 10),
                ],

                // 3. 导出目标条目设置 & API Key 折叠配置
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: targetFieldCtrl,
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                          labelText: '导出到每日状态的条目名称',
                          hintText: '如：AI 深度异状分析',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        ),
                        onChanged: (_) => saveCurrentConfig(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: () => setS(() => showAdvancedKey = !showAdvancedKey),
                      icon: Icon(showAdvancedKey ? Icons.key_off : Icons.key, size: 16),
                      label: Text(apiKeyCtrl.text.trim().isEmpty ? '配置API直连' : '已配API', style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                if (showAdvancedKey) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: apiKeyCtrl,
                    obscureText: true,
                    style: const TextStyle(fontSize: 12.5),
                    decoration: const InputDecoration(
                      labelText: 'Gemini API Key（选填，配置后可直接在App内一键生成）',
                      hintText: 'AIzaSy...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => saveCurrentConfig(),
                  ),
                ],
                const SizedBox(height: 12),

                // 4. 操作按钮栏：方式A（复制并跳转 Gemini App/对话） & 方式B（API 内置一键生成）
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10)),
                        onPressed: () async {
                          await saveCurrentConfig();
                          final fullPrompt = buildFullPrompt();
                          await Clipboard.setData(ClipboardData(text: fullPrompt));
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('✅ 已复制含「${selectedMode == 'gem' ? gemNameCtrl.text : '对话'}」指令的今日摘要，正在拉起 Gemini...')),
                            );
                          }
                          await Share.share(fullPrompt, subject: '今日状态 Gemini 分析');
                        },
                        icon: const Icon(Icons.open_in_new, size: 17),
                        label: const Text('复制并拉起 Gemini App', style: TextStyle(fontSize: 12.5)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF4F46E5),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        onPressed: isLoading
                            ? null
                            : () async {
                                await saveCurrentConfig();
                                final key = apiKeyCtrl.text.trim();
                                if (key.isEmpty) {
                                  // 若未配置 API Key，自动复制完整提示词并提示粘贴回下方框
                                  final fullPrompt = buildFullPrompt();
                                  await Clipboard.setData(ClipboardData(text: fullPrompt));
                                  setS(() => showAdvancedKey = true);
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('📋 已复制完整分析指令！可点左侧拉起 Gemini 对话，或填入 API Key 实现应用内直连生成')),
                                    );
                                  }
                                  return;
                                }
                                setS(() => isLoading = true);
                                try {
                                  // 映射实际 API 模型端点（兼容 3.1-pro 与 2.5-pro）
                                  final apiModel = selectedModel.contains('flash') ? 'gemini-2.5-flash' : 'gemini-2.5-pro';
                                  final uri = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$apiModel:generateContent?key=$key');
                                  final client = HttpClient();
                                  final req = await client.postUrl(uri);
                                  req.headers.set('Content-Type', 'application/json; charset=utf-8');
                                  final body = jsonEncode({
                                    'contents': [
                                      {
                                        'parts': [
                                          {'text': buildFullPrompt()}
                                        ]
                                      }
                                    ]
                                  });
                                  req.add(utf8.encode(body));
                                  final resp = await req.close();
                                  final respStr = await resp.transform(utf8.decoder).join();
                                  final json = jsonDecode(respStr) as Map<String, dynamic>;
                                  final candidates = json['candidates'] as List?;
                                  if (candidates != null && candidates.isNotEmpty) {
                                    final parts = candidates.first['content']['parts'] as List;
                                    final aiText = parts.map((p) => p['text']).join('\n').trim();
                                    setS(() => resultCtrl.text = aiText);
                                  } else {
                                    throw Exception(json['error']?['message'] ?? '返回结果为空');
                                  }
                                } catch (e) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('API 调用提示：$e')));
                                  }
                                } finally {
                                  setS(() => isLoading = false);
                                }
                              },
                        icon: isLoading
                            ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.bolt, size: 17),
                        label: Text(isLoading ? '正在分析...' : 'AI 直接生成分析', style: const TextStyle(fontSize: 12.5)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // 5. AI 分析结果预览 / 粘贴框 + 一键导出至每日状态
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('📥 AI 分析建议（可自由编辑或从 Gemini 粘贴）：', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () async {
                        final clip = await Clipboard.getData(Clipboard.kTextPlain);
                        if (clip?.text != null && clip!.text!.trim().isNotEmpty) {
                          setS(() => resultCtrl.text = clip.text!.trim());
                        }
                      },
                      icon: const Icon(Icons.content_paste, size: 14),
                      label: const Text('一键粘贴剪贴板', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: resultCtrl,
                  minLines: 5,
                  maxLines: 11,
                  style: const TextStyle(fontSize: 13.5, height: 1.45),
                  decoration: const InputDecoration(
                    hintText: '在此查看 AI 生成的分析建议，或将你在 Gemini App / Gem 中得到的回复粘贴到这里，点击下方按钮即可自动分列导入到今日状态中...',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(10),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () async {
                      final rawAi = resultCtrl.text.trim();
                      if (rawAi.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先生成或粘贴 AI 分析内容')));
                        return;
                      }
                      await saveCurrentConfig();
                      final targetName = targetFieldCtrl.text.trim().isEmpty ? 'AI 深度异状分析' : targetFieldCtrl.text.trim();
                      // 清理 Markdown 星号符号并将空行规整为标准分列换行
                      final cleanedLines = rawAi
                          .split('\n')
                          .map((line) => line.replaceAll('**', '').replaceFirst(RegExp(r'^[\-\*\•\d]+[\.、\s]\s*'), '').trim())
                          .where((line) => line.isNotEmpty)
                          .toList();

                      final itemId = await _ensureStatusItem(targetName, 'text');
                      // AI 分析默认设为不跨天继承，确保每天都是针对当日的独立评估
                      await widget.db.update('status_items', {'allow_inherit': 0}, where: 'id = ?', whereArgs: [itemId]);
                      await widget.db.insert(
                        'status_records',
                        {'item_id': itemId, 'date': _date, 'value': cleanedLines.join('\n')},
                        conflictAlgorithm: ConflictAlgorithm.replace,
                      );
                      if (mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('🎉 已将 AI 分析建议导入至今日「$targetName」（共 ${cleanedLines.length} 栏）！')),
                        );
                        setState(() {});
                      }
                    },
                    icon: const Icon(Icons.download_done, size: 18),
                    label: const Text('导出 AI 分析建议至「每日状态」', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _importDailyDocx() async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.any);
      if (res == null || res.files.single.path == null) return;
      final filePath = res.files.single.path!;
      final bytes = await File(filePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      ArchiveFile? docXmlFile;
      ArchiveFile? relsXmlFile;
      final mediaFiles = <String, ArchiveFile>{};

      for (final f in archive) {
        if (!f.isFile) continue;
        if (f.name == 'word/document.xml') {
          docXmlFile = f;
        } else if (f.name == 'word/_rels/document.xml.rels') {
          relsXmlFile = f;
        } else if (f.name.startsWith('word/media/')) {
          mediaFiles[f.name] = f;
        }
      }

      if (docXmlFile == null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未识别到标准 Word 结构')));
        return;
      }

      final relMap = <String, String>{};
      if (relsXmlFile != null) {
        final relsXml = utf8.decode(relsXmlFile.content as List<int>, allowMalformed: true);
        final relMatches = RegExp(r'<Relationship\b[^>]*>').allMatches(relsXml);
        for (final m in relMatches) {
          final tag = m.group(0)!;
          final idM = RegExp(r'Id="([^"]+)"').firstMatch(tag);
          final targetM = RegExp(r'Target="([^"]+)"').firstMatch(tag);
          if (idM != null && targetM != null) {
            var target = targetM.group(1)!;
            if (target.startsWith('/')) {
              target = target.substring(1);
            } else if (!target.startsWith('word/')) {
              target = 'word/$target';
            }
            relMap[idM.group(1)!] = target;
          }
        }
      }

      final docXml = utf8.decode(docXmlFile.content as List<int>, allowMalformed: true);
      final pMatches = RegExp(r'<w:p\b[^>]*>([\s\S]*?)<\/w:p>').allMatches(docXml);

      String currentDate = _date;
      String? lastimportedDate;
      String? currentField;
      final dateTextData = <String, Map<String, List<String>>>{};
      final dateImages = <String, List<String>>{};

      void addTextLine(String dateKey, String fieldName, String val) {
        final v = val.trim();
        if (v.isEmpty) return;
        dateTextData.putIfAbsent(dateKey, () => {});
        dateTextData[dateKey]!.putIfAbsent(fieldName, () => []);
        dateTextData[dateKey]![fieldName]!.add(v);
      }

      final dateHeaderRegex = RegExp(r'^【\s*(?:(\d{4})\s*年\s*)?(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]\s*】');
      final topFields = [
        '基础数据',
        '核心目标',
        '饮食记录',
        '打卡进度',
        '状态与异状',
        '状态和异状',
        'AI 深度异状分析',
        'AI深度异状分析',
        '复盘与分析',
        '今日总结',
      ];

      for (final pm in pMatches) {
        final pXml = pm.group(1)!;
        final tMatches = RegExp(r'<w:t(?:\s[^>]*)?>([\s\S]*?)<\/w:t>').allMatches(pXml);
        final rawText = _unescapeXml(tMatches.map((m) => m.group(1)!).join('')).trim();

        final blipMatches = RegExp(r'r:(?:embed|id)="([^"]+)"').allMatches(pXml);
        for (final bm in blipMatches) {
          final rId = bm.group(1)!;
          final mediaPath = relMap[rId];
          if (mediaPath != null && mediaFiles.containsKey(mediaPath)) {
            dateImages.putIfAbsent(currentDate, () => []);
            if (!dateImages[currentDate]!.contains(mediaPath)) {
              dateImages[currentDate]!.add(mediaPath);
            }
          }
        }

        if (rawText.isEmpty || rawText == '每日记录') continue;

        final dm = dateHeaderRegex.firstMatch(rawText);
        if (dm != null) {
          final year = dm.group(1) != null ? int.parse(dm.group(1)!) : DateTime.parse(_date).year;
          final month = int.parse(dm.group(2)!);
          final day = int.parse(dm.group(3)!);
          currentDate = '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
          lastimportedDate = currentDate;
          currentField = null;
          continue;
        }

        final cleanLine = rawText.replaceFirst(RegExp(r'^[\u25CF\u2022\u25E6\u25AA\u25A1\u25B6\uF0B7\uF0A7\-\*]+\s*'), '').trim();
        if (cleanLine.isEmpty) continue;

        String? matchedField;
        String remainder = '';
        final colonIdx = cleanLine.indexOf(RegExp(r'[:：]'));
        if (colonIdx > 0 && colonIdx <= 14) {
          final prefix = cleanLine.substring(0, colonIdx).trim();
          final after = cleanLine.substring(colonIdx + 1).trim();
          final isSubItemPrefix = RegExp(r'^([a-zA-Z]{1,4}[\.、]|早餐|午餐|下午茶|晚餐|夜宵|加餐|上午|下午|晚上|\d+[\.、])').hasMatch(cleanLine);
          if (topFields.contains(prefix) || (!isSubItemPrefix && currentField == null)) {
            matchedField = prefix;
            remainder = after;
          }
        }

        if (matchedField != null) {
          if (matchedField == '基础数据') {
            currentField = null;
            final parts = remainder.split(RegExp(r'[|｜；;]'));
            for (final part in parts) {
              final pTrim = part.trim();
              if (pTrim.isEmpty) continue;
              if (pTrim.contains('体重')) {
                final numM = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(pTrim);
                if (numM != null) addTextLine(currentDate, '体重/kg', numM.group(1)!);
              } else if (pTrim.contains('运动')) {
                final subColon = pTrim.indexOf(RegExp(r'[:：]'));
                final sportVal = subColon >= 0 ? pTrim.substring(subColon + 1).trim() : pTrim.replaceFirst('运动', '').trim();
                addTextLine(currentDate, '运动量', sportVal);
              } else {
                final subColon = pTrim.indexOf(RegExp(r'[:：]'));
                if (subColon > 0) addTextLine(currentDate, pTrim.substring(0, subColon).trim(), pTrim.substring(subColon + 1).trim());
              }
            }
          } else {
            currentField = matchedField;
            if (remainder.isNotEmpty) addTextLine(currentDate, currentField!, remainder);
          }
        } else {
          final targetField = currentField ?? '状态与异状';
          addTextLine(currentDate, targetField, cleanLine);
        }
      }

      int importedDays = 0;
      int importedImgs = 0;
      final allDates = <String>{...dateTextData.keys, ...dateImages.keys};
      final appDir = await getApplicationDocumentsDirectory();

      for (final dKey in allDates) {
        importedDays++;
        final fieldsMap = dateTextData[dKey] ?? {};
        for (final entry in fieldsMap.entries) {
          final fName = entry.key;
          final fLines = entry.value;
          if (fLines.isEmpty) continue;

          final isNumber = fName.contains('体重') && fLines.length == 1 && double.tryParse(fLines.first) != null;
          final itemId = await _ensureStatusItem(fName, isNumber ? 'number' : 'text');
          final joinedVal = fLines.join('\n');

          await widget.db.insert(
            'status_records',
            {'item_id': itemId, 'date': dKey, 'value': joinedVal},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        final imgList = dateImages[dKey] ?? [];
        if (imgList.isNotEmpty) {
          final imgItemId = await _ensureStatusItem('今日图片', 'image');
          await widget.db.insert(
            'status_records',
            {'item_id': imgItemId, 'date': dKey, 'value': ''},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          final recs = await widget.db.query('status_records', where: 'item_id = ? AND date = ?', whereArgs: [imgItemId, dKey]);
          final recId = recs.first['id'] as int;

          final dFolder = dKey.replaceAll('-', '');
          final targetDir = Directory(p.join(appDir.path, 'images', 'status', dFolder));
          if (!await targetDir.exists()) await targetDir.create(recursive: true);

          final existingImgs = await widget.db.query('status_images', where: 'record_id = ?', whereArgs: [recId]);
          int nextSort = existingImgs.length;

          for (final mediaKey in imgList) {
            final archFile = mediaFiles[mediaKey]!;
            final ext = p.extension(mediaKey).isNotEmpty ? p.extension(mediaKey) : '.jpg';
            final fileName = '${recId}_${nextSort}_${DateTime.now().millisecondsSinceEpoch}$ext';
            final relPath = p.join('images', 'status', dFolder, fileName);
            await File(p.join(appDir.path, relPath)).writeAsBytes(archFile.content as List<int>);
            await widget.db.insert('status_images', {
              'record_id': recId,
              'file_path': relPath,
              'sort_order': nextSort++,
            });
            importedImgs++;
          }
        }
      }

      if (lastimportedDate != null) _date = lastimportedDate;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('🎉 成功导入 $importedDays 天记录、$importedImgs 张图片！')));
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
        title: Text(_date == _today ? '今天 · $_date' : _date, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold)),
        actions: [
          TextButton.icon(
            onPressed: _importDailyDocx,
            icon: const Icon(Icons.description_outlined, size: 17),
            label: const Text('导入Word', style: TextStyle(fontSize: 13)),
          ),
          IconButton(
            icon: const Icon(Icons.date_range, size: 20),
            tooltip: '切换日期',
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
                onToggleFold: () {
                  setState(() => _foldStatusSection = !_foldStatusSection);
                  _saveTodayUiState();
                },
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
                          child: Center(child: Text('暂无状态条目，可点击右上角「导入Word」或「+ 新条目」', style: TextStyle(color: Colors.grey, fontSize: 13))),
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
                onToggleFold: () {
                  setState(() => _foldSchedSection = !_foldSchedSection);
                  _saveTodayUiState();
                },
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
                  onTap: () {
                    setState(() => _foldSummary = !_foldSummary);
                    _saveTodayUiState();
                  },
                  child: Row(
                    children: [
                      Icon(_foldSummary ? Icons.chevron_right : Icons.expand_more, size: 18, color: const Color(0xFF475569)),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          '📋 今日状态摘要 · $_date',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // 一键导入 Gemini 分析按钮
              SizedBox(
                height: 26,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF4F46E5),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                  ),
                  onPressed: () => _openGeminiAnalyzerSheet(copyText),
                  icon: const Icon(Icons.auto_awesome, size: 13),
                  label: const Text('Gemini分析', style: TextStyle(fontSize: 11.5)),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                height: 26,
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                    minimumSize: Size.zero,
                  ),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: copyText));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已按分列格式复制摘要到剪贴板')));
                  },
                  child: const Text('复制', style: TextStyle(fontSize: 11.5)),
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
            width: 82,
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
                if (colonIdx > 0 && colonIdx < 14) {
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
                  onTap: () {
                    setState(() => isItemFolded ? _collapsedStatusIds.remove(id) : _collapsedStatusIds.add(id));
                    _saveTodayUiState();
                  },
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
                        if (colonIdx > 0 && colonIdx < 14) {
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
                    onTap: () {
                      setState(() => isCollapsed ? _collapsedSchedParents.remove(sid) : _collapsedSchedParents.add(sid));
                      _saveTodayUiState();
                    },
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
    bool allowInherit = isEdit ? ((editItem['allow_inherit'] as int? ?? 1) == 1) : true;

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
              const SizedBox(height: 6),
              CheckboxListTile(
                value: allowInherit,
                contentPadding: EdgeInsets.zero,
                title: const Text('允许跨天继承历史数据', style: TextStyle(fontSize: 13.5)),
                subtitle: const Text('关闭后，若当天未填写则自动清空（不显示历史继承值）', style: TextStyle(fontSize: 11, color: Colors.grey)),
                onChanged: (v) => setS(() => allowInherit = v ?? true),
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
                    {'name': ctrl.text.trim(), 'type': type, 'allow_inherit': allowInherit ? 1 : 0},
                    where: 'id = ?',
                    whereArgs: [editItem['id']],
                  );
                } else {
                  await widget.db.insert('status_items', {
                    'name': ctrl.text.trim(),
                    'type': type,
                    'allow_inherit': allowInherit ? 1 : 0,
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
                  if (parentId != null) {
                    _collapsedSchedParents.remove(parentId);
                    _saveTodayUiState();
                  }
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
