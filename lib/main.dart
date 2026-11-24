import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'pages_extra.dart';
import 'deepseek_sheet.dart';
import 'empire_page.dart';
import 'culture_page.dart';
import 'medical_page.dart';
import 'content_fetch.dart';
import 'content_intake.dart';
import 'native_clip.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.instance.database;
  runApp(DailyTrackerApp(db: db));
}

// ==================== 数据库层 (零尖括号防吞版) ====================
class AppDatabase {
  static final AppDatabase instance = AppDatabase._();
  static Database? _db;
  AppDatabase._();

  Future get database async {
    if (_db != null && _db!.isOpen) return _db!;
    _db = await _init();
    return _db!;
  }

  static Future closeForRestore() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'daily_tracker.db');
    if (_db != null) {
      try {
        if (_db!.isOpen) await _db!.close();
      } catch (_) {}
      _db = null;
    }
    try {
      await deleteDatabase(dbPath);
    } catch (_) {}
    for (final ext in ['', '-wal', '-shm', '-journal']) {
      final f = File('$dbPath$ext');
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    return null;
  }

  Future _init() async {
    final dir = await getApplicationDocumentsDirectory();
    return openDatabase(
      p.join(dir.path, 'daily_tracker.db'),
      version: 15,
      onCreate: (db, v) async {
        await db.execute('CREATE TABLE status_items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, type TEXT NOT NULL, allow_inherit INTEGER DEFAULT 1, sort_order INTEGER DEFAULT 0)');
        await db.execute('CREATE TABLE status_records (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, date TEXT NOT NULL, value TEXT DEFAULT "", UNIQUE(item_id, date))');
        await db.execute('CREATE TABLE status_images (id INTEGER PRIMARY KEY AUTOINCREMENT, record_id INTEGER NOT NULL, file_path TEXT NOT NULL, sort_order INTEGER DEFAULT 0)');
        await db.execute('CREATE TABLE schedule_items (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, plan_info TEXT DEFAULT "", parent_id INTEGER, sort_order INTEGER DEFAULT 0)');
        await db.execute('CREATE TABLE schedule_records (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, date TEXT NOT NULL, done INTEGER DEFAULT 0, UNIQUE(item_id, date))');
        await db.execute('CREATE TABLE modules (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, parent_id INTEGER, is_member INTEGER DEFAULT 0, sort_order INTEGER DEFAULT 0, created_at TEXT NOT NULL)');
        await db.execute('CREATE TABLE module_entries (id INTEGER PRIMARY KEY AUTOINCREMENT, module_id INTEGER NOT NULL, seq INTEGER NOT NULL, content TEXT NOT NULL, sort_order INTEGER DEFAULT 0, created_at TEXT NOT NULL)');
        await db.execute('CREATE TABLE module_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, module_ids TEXT NOT NULL, sort_order INTEGER DEFAULT 0, created_at TEXT NOT NULL)');
        await db.execute('CREATE TABLE mindmaps (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, root_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)');
        await db.execute('CREATE TABLE ui_states (state_key TEXT PRIMARY KEY, state_val TEXT NOT NULL)');
        await db.execute("CREATE TABLE focus_items (id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL, title TEXT NOT NULL, next_step TEXT DEFAULT '', done_criteria TEXT DEFAULT '', multiplier REAL DEFAULT 1.0, done INTEGER DEFAULT 0, note TEXT DEFAULT '', rolled INTEGER DEFAULT 0, sort_order INTEGER DEFAULT 0, created_at TEXT NOT NULL)");
        await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_focus_unique ON focus_items(date, title, next_step)');
        await CultureDb.ensureTables(db);
        await MedicalDb.ensureTables(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV.compareTo(15) == -1) {
          // v15：内置播放器「取正文」要落一列 content_text。
          try { await CultureDb.ensureTables(db); } catch (_) {}
        }
        if (oldV.compareTo(14) == -1) {
          // v14：内容引进要存封面/作者/分级标签，老库补 4 列。
          try { await CultureDb.ensureTables(db); } catch (_) {}
        }
        if (oldV.compareTo(13) == -1) {
          // 分级从医疗搬到文化：ensureTables 会把旧 medical_grades 原样迁到 culture_grades，
          // 用户之前改过的档位文案不会丢。
          try { await CultureDb.ensureTables(db); } catch (_) {}
        }
        if (oldV.compareTo(2) == -1) {
          try { await db.execute("ALTER TABLE schedule_items ADD COLUMN plan_info TEXT DEFAULT ''"); } catch (_) {}
        }
        if (oldV.compareTo(3) == -1) {
          try { await db.execute("ALTER TABLE modules ADD COLUMN parent_id INTEGER"); } catch (_) {}
          try { await db.execute("ALTER TABLE modules ADD COLUMN sort_order INTEGER DEFAULT 0"); } catch (_) {}
          try { await db.execute("ALTER TABLE module_entries ADD COLUMN sort_order INTEGER DEFAULT 0"); } catch (_) {}
        }
        if (oldV.compareTo(4) == -1) {
          try { await db.execute("ALTER TABLE schedule_items ADD COLUMN parent_id INTEGER"); } catch (_) {}
        }
        if (oldV.compareTo(5) == -1) {
          try { await db.execute('CREATE TABLE IF NOT EXISTS ui_states (state_key TEXT PRIMARY KEY, state_val TEXT NOT NULL)'); } catch (_) {}
        }
        if (oldV.compareTo(6) == -1) {
          try { await db.execute("ALTER TABLE status_items ADD COLUMN allow_inherit INTEGER DEFAULT 1"); } catch (_) {}
        }
        if (oldV.compareTo(7) == -1) {
          try { await db.execute("ALTER TABLE modules ADD COLUMN is_member INTEGER DEFAULT 0"); } catch (_) {}
        }
        if (oldV.compareTo(8) == -1) {
          try { await db.execute("ALTER TABLE module_groups ADD COLUMN sort_order INTEGER DEFAULT 0"); } catch (_) {}
        }
        if (oldV.compareTo(9) == -1) {
          try { await db.execute("CREATE TABLE IF NOT EXISTS focus_items (id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL, title TEXT NOT NULL, next_step TEXT DEFAULT '', done_criteria TEXT DEFAULT '', multiplier REAL DEFAULT 1.0, done INTEGER DEFAULT 0, note TEXT DEFAULT '', rolled INTEGER DEFAULT 0, sort_order INTEGER DEFAULT 0, created_at TEXT NOT NULL)"); } catch (_) {}
        }
        if (oldV.compareTo(12) == -1) {
          try { await MedicalDb.ensureTables(db); } catch (_) {}
        }
        if (oldV.compareTo(11) == -1) {
          try { await CultureDb.ensureTables(db); } catch (_) {}
        }
        if (oldV.compareTo(10) == -1) {
          // 老库里可能已经有重复的聚焦条目（旧版每次重建 FutureBuilder 都会并发跑一次
          // 「顺延」，几条并发同时判断「不存在」就各插一条）。这里先按
          // (日期, 维度, 下一步) 去重，再加唯一索引，从库层面堵死重复。
          try { await dedupeFocusItems(db); } catch (_) {}
        }
      },
    );
  }

  static Future getUiState(Database db, String key) async {
    try {
      final Database activeDb = await instance.database;
      final rows = await activeDb.query('ui_states', where: 'state_key = ?', whereArgs: [key]);
      if (rows.isNotEmpty) return rows.first['state_val'] as String;
    } catch (_) {}
    return null;
  }

  static Future setUiState(Database db, String key, String val) async {
    try {
      final Database activeDb = await instance.database;
      await activeDb.insert('ui_states', {'state_key': key, 'state_val': val}, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {}
    return null;
  }

  /// 合并同一天里「维度 + 下一步」完全相同的聚焦条目，并给表加唯一索引。
  /// 旧版并发顺延会插出多条一样的；升级时跑一次，也供以后手动清理用。
  /// 返回被删掉的重复条数。
  static Future<int> dedupeFocusItems(Database db) async {
    await db.execute("UPDATE focus_items SET next_step = '' WHERE next_step IS NULL");
    final rows = await db.query('focus_items',
        orderBy: 'date ASC, title ASC, next_step ASC, done DESC, id ASC');
    final Map<String, int> kept = <String, int>{};
    int removed = 0;
    for (final r in rows) {
      final key = '${r['date']}\u0001${r['title']}\u0001${r['next_step'] ?? ''}';
      final int id = r['id'] as int;
      final int? keptId = kept[key];
      if (keptId == null) {
        kept[key] = id;
        continue;
      }
      // 合并：重复行里更长的备注、已勾选状态，带到保留行上
      final String dupNote = (r['note'] ?? '').toString().trim();
      if (dupNote.isNotEmpty) {
        final cur =
            await db.query('focus_items', where: 'id = ?', whereArgs: [keptId]);
        final String curNote =
            cur.isEmpty ? '' : (cur.first['note'] ?? '').toString().trim();
        if (dupNote.length > curNote.length) {
          await db.update('focus_items', {'note': dupNote, 'done': r['done'] ?? 0},
              where: 'id = ?', whereArgs: [keptId]);
        }
      }
      await db.delete('focus_items', where: 'id = ?', whereArgs: [id]);
      removed++;
    }
    try {
      await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_focus_unique '
          'ON focus_items(date, title, next_step)');
    } catch (_) {}
    return removed;
  }

  /// 战略聚焦：把勾选完成信号聚合成帝国模块可直接读取的键，写入 ui_states。
  /// 取消勾选会重算，因此乘数效应会自动退回。
  static Future<Map> refreshFocusSignals(Database db, String date) async {
    try {
      final Database activeDb = await instance.database;
      final dayRows = await activeDb.query(
        'focus_items', where: 'date = ? AND done = 1', whereArgs: [date]);
      final allRows = await activeDb.query('focus_items', where: 'done = 1');
      double dayMul = 1.0;
      for (final r in dayRows) {
        final v = (r['multiplier'] as num?)?.toDouble() ?? 1.0;
        dayMul *= v > 0 ? v : 1.0;
      }
      double totalMul = 1.0;
      for (final r in allRows) {
        final v = (r['multiplier'] as num?)?.toDouble() ?? 1.0;
        totalMul *= v > 0 ? v : 1.0;
      }
      final ids = dayRows.map((r) => r['id']).toList();
      await setUiState(db, 'focus_multiplier_$date', dayMul.toStringAsFixed(6));
      await setUiState(db, 'focus_multiplier_total', totalMul.toStringAsFixed(6));
      await setUiState(db, 'focus_done_ids_$date', jsonEncode(ids));
      return {'day': dayMul, 'total': totalMul, 'count': dayRows.length};
    } catch (_) {
      return {'day': 1.0, 'total': 1.0, 'count': 0};
    }
  }
}

class TrendLineChart extends StatelessWidget {
  final List points;
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
  final List points;
  _TrendChartPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    const lPad = 36.0, bPad = 26.0, tPad = 16.0, rPad = 14.0;
    final cw = size.width - lPad - rPad, ch = size.height - tPad - bPad;
    final List vals = points.map((e) => (e as Map)['value'] as double).toList();
    double minV = vals.first as double;
    double maxV = vals.first as double;
    for (final rawV in vals) {
      final v = rawV as double;
      if (v.compareTo(minV) == -1) minV = v;
      if (v.compareTo(maxV) == 1) maxV = v;
    }
    if (minV == maxV) {
      minV -= 5;
      maxV += 5;
    }
    final range = maxV - minV;
    final gridPaint = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..strokeWidth = 1;

    for (int i = 0; i <= 2; i++) {
      final ratio = i / 2.0, y = tPad + ch * (1 - ratio);
      canvas.drawLine(Offset(lPad, y), Offset(size.width - rPad, y), gridPaint);
      final v = minV + range * ratio;
      final tp = TextPainter(
        text: TextSpan(
          text: v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1),
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(math.max(0, lPad - tp.width - 6), y - tp.height / 2));
    }

    final coords = List.generate(points.length, (i) {
      final pt = points[i] as Map;
      final ptVal = pt['value'] as double;
      final x = points.length == 1 ? lPad + cw / 2 : lPad + (i / (points.length - 1)) * cw;
      final y = tPad + ch - ((ptVal - minV) / range) * ch;
      return Offset(x, y);
    });

    if (coords.length >= 2) {
      final fill = Path()..moveTo(coords.first.dx, tPad + ch);
      for (final c in coords) {
        fill.lineTo(c.dx, c.dy);
      }
      fill
        ..lineTo(coords.last.dx, tPad + ch)
        ..close();
      canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF4F46E5).withOpacity(0.25),
              const Color(0xFF4F46E5).withOpacity(0.0),
            ],
          ).createShader(Rect.fromLTWH(lPad, tPad, cw, ch)),
      );

      final line = Path()..moveTo(coords.first.dx, coords.first.dy);
      for (int i = 1; i != coords.length; i++) {
        line.lineTo(coords[i].dx, coords[i].dy);
      }
      canvas.drawPath(
        line,
        Paint()
          ..color = const Color(0xFF4F46E5)
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke,
      );
    }

    final step = math.max(1, (points.length / 6).ceil());
    for (int i = 0; i != coords.length; i++) {
      final isLast = i == coords.length - 1, c = coords[i];
      final pt = points[i] as Map;
      final v = pt['value'] as double;
      final dStr = '${pt['date']}';
      canvas.drawCircle(c, isLast ? 6 : 4.5, Paint()..color = Colors.white);
      canvas.drawCircle(
        c,
        isLast ? 4.5 : 3.2,
        Paint()..color = isLast ? const Color(0xFFEF4444) : const Color(0xFF4F46E5),
      );
      if (i % step == 0 || isLast || i == 0) {
        final vStr = v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1);
        final vTp = TextPainter(
          text: TextSpan(
            text: vStr,
            style: TextStyle(
              color: isLast ? const Color(0xFFEF4444) : const Color(0xFF1E293B),
              fontSize: 10,
              fontWeight: isLast ? FontWeight.bold : FontWeight.w500,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        vTp.paint(canvas, Offset(c.dx - vTp.width / 2, c.dy - vTp.height - 6));

        final dShort = dStr.length >= 10 ? dStr.substring(5) : dStr;
        final dTp = TextPainter(
          text: TextSpan(text: dShort, style: const TextStyle(color: Color(0xFF64748B), fontSize: 9.5)),
          textDirection: TextDirection.ltr,
        )..layout();
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4F46E5)),
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
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
  State createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _idx = 2;
  int _empireTick = 0;
  int _cultureTick = 0;

  ClipboardIntakeWatcher? _clip;
  ParsedShare? _pending;
  bool _intakeOpen = false;
  Timer? _pendingTimer;

  StreamSubscription<String>? _nativeSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clip = ClipboardIntakeWatcher(db: widget.db, onFound: _onShareFound);
    _clip!.start();
    _wireNative();
  }

  /// 两条路一起用：
  ///   - 原生无障碍服务：复制那一刻就弹悬浮窗，点「整理」把链接带进 App；
  ///   - Flutter 侧前台读取：没开无障碍权限时的兜底（切回 App 时读一次）。
  Future<void> _wireNative() async {
    // 冷启动：悬浮窗点「整理」带进来的链接。
    try {
      final initial = await NativeClip.getInitial();
      if (initial.isNotEmpty) {
        final share = parseShareText(initial);
        if (!share.isEmpty) _onShareFound(share);
      }
    } catch (_) {}
    // 运行中：服务读到新链接时推过来。
    try {
      _nativeSub = NativeClip.events.listen((text) {
        if (text.isEmpty) return;
        final share = parseShareText(text);
        if (!share.isEmpty) _onShareFound(share);
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pendingTimer?.cancel();
    _nativeSub?.cancel();
    _clip?.stop();
    super.dispose();
  }

  /// 只在前台轮询：后台读剪贴板既没意义，也会被系统拦。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _clip?.start();
      _clip?.checkNow();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _clip?.stop();
    }
  }

  void _onShareFound(ParsedShare share) {
    if (!mounted || _intakeOpen) return;
    _pendingTimer?.cancel();
    setState(() => _pending = share);
    _pendingTimer = Timer(const Duration(seconds: 18), () {
      if (mounted && _pending?.url == share.url) setState(() => _pending = null);
    });
  }

  Future<void> _dismissPending() async {
    final share = _pending;
    _pendingTimer?.cancel();
    setState(() => _pending = null);
    if (share != null) await CultureDb.addSeenUrl(widget.db, share.url);
  }

  Future<void> _muteClip() async {
    await CultureDb.setClipEnabled(widget.db, false);
    _pendingTimer?.cancel();
    if (!mounted) return;
    setState(() => _pending = null);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('已关闭剪贴板自动识别，可在「文化」右上角菜单重新打开',
          style: TextStyle(fontSize: 12.5)),
      duration: Duration(seconds: 3),
    ));
  }

  Future<void> _importPending() async {
    final share = _pending;
    if (share == null || _intakeOpen) return;
    _intakeOpen = true;
    _pendingTimer?.cancel();
    setState(() => _pending = null);
    try {
      final db = await AppDatabase.instance.database;
      final libs = await db.query('culture_libraries',
          orderBy: 'sort_order ASC, id ASC');
      final grades = await db.query('culture_grades',
          orderBy: 'sort_order ASC, tier ASC, id ASC');
      final batteryRaw =
          await AppDatabase.getUiState(db, 'medical_battery_now');
      if (!mounted) return;
      final ok = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => ContentIntakeSheet(
          db: db,
          share: share,
          libs: libs,
          grades: grades,
          battery: int.tryParse('${batteryRaw ?? ''}'.trim()),
        ),
      );
      _clip?.remember(share.url);
      if (ok == true && mounted) {
        setState(() {
          _idx = 5;
          _cultureTick++;
        });
      }
    } finally {
      _intakeOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: AppDatabase.instance.database,
      builder: (ctx, snap) {
        final activeDb = (snap.data as Database?) ?? widget.db;
        final pages = [
          SearchPage(db: activeDb),
          FamilyPage(db: activeDb),
          TodayPage(db: activeDb),
          EmpirePage(db: activeDb, reloadToken: _empireTick),
          PlanPage(db: activeDb),
          CulturePage(db: activeDb, reloadToken: _cultureTick),
          MedicalPage(db: activeDb),
        ];
        return Scaffold(
          body: Stack(children: [
            pages[_idx],
            if (_pending != null)
              Positioned(
                left: 10,
                right: 10,
                top: MediaQuery.of(context).padding.top + 56,
                child: IntakeBanner(
                  share: _pending!,
                  onImport: _importPending,
                  onDismiss: _dismissPending,
                  onMute: _muteClip,
                ),
              ),
          ]),
          bottomNavigationBar: NavigationBar(
            height: 62,
            selectedIndex: _idx,
            onDestinationSelected: (i) {
              setState(() {
                _idx = i;
                if (i == 3) _empireTick++;
              });
              // 点开文化时顺手查一次剪贴板：用户可能刚在别的 App 复制完就切过来。
              if (i == 5) _clip?.checkNow();
            },
            destinations: const [
              NavigationDestination(icon: Icon(Icons.search), label: '查找'),
              NavigationDestination(icon: Icon(Icons.home_outlined), label: '家庭'),
              NavigationDestination(icon: Icon(Icons.calendar_today), label: '今日'),
              NavigationDestination(
                  icon: Icon(Icons.account_balance_outlined),
                  selectedIcon: Icon(Icons.account_balance),
                  label: '帝国'),
              NavigationDestination(icon: Icon(Icons.account_tree_outlined), label: '规划'),
              NavigationDestination(
                  icon: Icon(Icons.video_library_outlined),
                  selectedIcon: Icon(Icons.video_library),
                  label: '文化'),
              NavigationDestination(
                  icon: Icon(Icons.medical_services_outlined),
                  selectedIcon: Icon(Icons.medical_services),
                  label: '医疗'),
            ],
          ),
        );
      },
    );
  }
}

class TodayPage extends StatefulWidget {
  final Database db;
  const TodayPage({super.key, required this.db});
  @override
  State createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  String _date = DateFormat('yyyy-MM-dd').format(DateTime.now());
  final Map _expandedPhoto = {};
  final Set _collapsedStatusIds = {};
  final Set _collapsedSchedParents = {};
  bool _foldSummary = false;
  bool _foldStatusSection = false;
  bool _foldSchedSection = false;
  bool _foldFocusSection = false;
  bool _uiLoaded = false;
  Future? _loadingFuture;
  String? _loadingDate;
  List _sectionOrder = ['summary', 'status', 'focus', 'schedule'];

  int? _hoverSchedTargetId;
  String? _hoverSchedZone;

  String get _today => DateFormat('yyyy-MM-dd').format(DateTime.now());

  @override
  void initState() {
    super.initState();
    _restoreTodayUiState();
  }

  Future _restoreTodayUiState() async {
    final raw = await AppDatabase.getUiState(widget.db, 'today_ui_state');
    if (raw != null && (raw as String).isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map;
        _foldSummary = map['foldSummary'] == true;
        _foldStatusSection = map['foldStatusSection'] == true;
        _foldSchedSection = map['foldSchedSection'] == true;
        _foldFocusSection = map['foldFocusSection'] == true;
        if (map['sectionOrder'] is List) {
          final loadedOrder = (map['sectionOrder'] as List).map((e) => '$e').toList();
          for (final k in ['summary', 'status', 'focus', 'schedule']) {
            if (!loadedOrder.contains(k)) loadedOrder.add(k);
          }
          _sectionOrder = loadedOrder;
        }
        _collapsedStatusIds
          ..clear()
          ..addAll(((map['collapsedStatusIds'] as List?) ?? []).map((e) => int.parse('$e')));
        _collapsedSchedParents
          ..clear()
          ..addAll(((map['collapsedSchedParents'] as List?) ?? []).map((e) => int.parse('$e')));
      } catch (_) {}
    }
    if (mounted) setState(() => _uiLoaded = true);
    return null;
  }

  Future _saveTodayUiState() async {
    final data = jsonEncode({
      'foldSummary': _foldSummary,
      'foldStatusSection': _foldStatusSection,
      'foldSchedSection': _foldSchedSection,
      'foldFocusSection': _foldFocusSection,
      'sectionOrder': _sectionOrder,
      'collapsedStatusIds': _collapsedStatusIds.toList(),
      'collapsedSchedParents': _collapsedSchedParents.toList(),
    });
    await AppDatabase.setUiState(widget.db, 'today_ui_state', data);
    return null;
  }

  /// FutureBuilder 每次 build 都会调一次 _load；以前是各跑各的，几条并发同时
  /// 判断「昨天这条还没顺延」就各插一条，于是同一条聚焦会重复出现。
  /// 同一日期的加载在飞时复用同一个 Future，顺延逻辑再也不会并发执行。
  Future _load() {
    final cached = _loadingFuture;
    if (cached != null && _loadingDate == _date) return cached;
    late Future f;
    void clear() {
      if (identical(_loadingFuture, f)) {
        _loadingFuture = null;
        _loadingDate = null;
      }
    }

    f = _loadInner();
    _loadingFuture = f;
    _loadingDate = _date;
    f.then((_) => clear(), onError: (Object e, StackTrace s) => clear());
    return f;
  }

  Future _loadInner() async {
    if (!_uiLoaded) await _restoreTodayUiState();
    final Database db = await AppDatabase.instance.database;
    final items = List.from(
      await db.query('status_items', orderBy: 'sort_order ASC, id ASC'),
    );
    final Map disp = {};
    final appDir = await getApplicationDocumentsDirectory();

    for (final rawIt in items) {
      final it = rawIt as Map;
      final id = it['id'] as int, type = it['type'] as String;
      final allowInherit = (it['allow_inherit'] as int? ?? 1) == 1;

      final todayRecs = await db.query('status_records', where: 'item_id = ? AND date = ?', whereArgs: [id, _date]);
      if (todayRecs.isNotEmpty) {
        final r = todayRecs.first;
        final imgs = await db.query('status_images', where: 'record_id = ?', whereArgs: [r['id']], orderBy: 'sort_order ASC');
        disp[id] = {
          'recordId': r['id'],
          'value': r['value'],
          'images': imgs.map((i) => p.join(appDir.path, i['file_path'] as String)).toList(),
          'isInherited': false,
        };
      } else if (type != 'image' && allowInherit) {
        final prev = await db.query(
          'status_records',
          where: 'item_id = ? AND date \x3c ? AND value != ""',
          whereArgs: [id, _date],
          orderBy: 'date DESC',
          limit: 1,
        );
        if (prev.isNotEmpty) {
          disp[id] = {
            'recordId': null,
            'value': prev.first['value'],
            'images': [],
            'isInherited': true,
            'inheritedFrom': prev.first['date'],
          };
        }
      }
    }
    final scheds = List.from(
      await db.query('schedule_items', orderBy: 'sort_order ASC, id ASC'),
    );
    final Map doneMap = {};
    for (final rawS in scheds) {
      final s = rawS as Map;
      final sid = s['id'] as int;
      final r = await db.query('schedule_records', where: 'item_id = ? AND date = ?', whereArgs: [sid, _date]);
      doneMap[sid] = r.isNotEmpty && (r.first['done'] as int) == 1;
    }
    // 未完成的战略聚焦顺延到今天：复制今日副本，历史原记录保留并标记已顺延，
    // 这样查看前一天仍能看到并修改，且不会每天重复复制。
    if (_date == _today) {
      final pending = await db.query('focus_items',
          where: 'date < ? AND done = 0 AND rolled = 0', whereArgs: [_date],
          orderBy: 'date ASC, sort_order ASC, id ASC');
      for (final r in pending) {
        final int id = r['id'] as int;
        final String title = '${r['title'] ?? ''}';
        final String step = '${r['next_step'] ?? ''}';
        // 去重键改成「维度 + 下一步」：同一维度下可能有多个不同下一步，旧逻辑只看
        // 标题会把它们误判成同一条而丢掉。同时插入用 ignore，配合唯一索引，
        // 多路 _load 并发时最多只会落一条。
        final same = await db.query('focus_items',
            where: 'date = ? AND title = ? AND next_step = ?',
            whereArgs: [_date, title, step]);
        if (same.isEmpty) {
          final cnt = await db.query('focus_items', where: 'date = ?', whereArgs: [_date]);
          await db.insert(
            'focus_items',
            {
              'date': _date,
              'title': title,
              'next_step': step,
              'done_criteria': r['done_criteria'],
              'multiplier': r['multiplier'],
              'done': 0,
              'note': '',
              'rolled': 0,
              'sort_order': cnt.length,
              'created_at': DateTime.now().toIso8601String(),
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        // 处理完一条立刻标记，缩小并发窗口
        await db.update('focus_items', {'rolled': 1},
            where: 'id = ?', whereArgs: [id]);
      }
    }
    final focusRows = List.from(await db.query('focus_items',
        where: 'date = ?', whereArgs: [_date], orderBy: 'sort_order ASC, id ASC'));
    final focusSignal = await AppDatabase.refreshFocusSignals(db, _date);
    return {'items': items, 'disp': disp, 'scheds': scheds, 'done': doneMap,
            'focus': focusRows, 'signal': focusSignal};
  }

  List _splitColumns(String raw) {
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
      if (parts.length >= 2) return parts;
    }
    return [trimmed];
  }

  String _unescapeXml(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '\x3c')
        .replaceAll('&gt;', '\x3e')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }

  Future _ensureStatusItem(String name, String type) async {
    final Database db = await AppDatabase.instance.database;
    final existing = await db.query('status_items', where: 'name = ?', whereArgs: [name]);
    if (existing.isNotEmpty) return existing.first['id'] as int;
    // 旧的「AI 深度异状分析」条目直接改名沿用，避免每日状态里留两条重复
    if (name == '反思') {
      final oldAi = await db.query('status_items',
          where: 'name IN (?, ?)', whereArgs: ['AI 深度异状分析', 'AI深度异状分析']);
      if (oldAi.isNotEmpty) {
        await db.update('status_items', {'name': '反思'},
            where: 'id = ?', whereArgs: [oldAi.first['id'] as int]);
        return oldAi.first['id'] as int;
      }
    }
    if (name == '状态与异状' || name == '状态和异状') {
      final alt = await db.query('status_items', where: 'name IN (?, ?)', whereArgs: ['状态与异状', '状态和异状']);
      if (alt.isNotEmpty) return alt.first['id'] as int;
    }
    final all = await db.query('status_items');
    return await db.insert('status_items', {
      'name': name,
      'type': type,
      'allow_inherit': 1,
      'sort_order': all.length,
    });
  }

  bool _isSchedDescendant(int dragId, int targetId, List all) {
    if (dragId == targetId) return true;
    int? cur = targetId;
    final Set visited = {};
    while (cur != null && !visited.contains(cur)) {
      visited.add(cur);
      if (cur == dragId) return true;
      final row = all.where((m) => (m as Map)['id'] == cur).firstOrNull as Map?;
      cur = row?['parent_id'] as int?;
    }
    return false;
  }

  Future _handleScheduleDrop({
    required int dragId,
    required int targetId,
    required String zone,
    required List allScheds,
  }) async {
    if (_isSchedDescendant(dragId, targetId, allScheds)) return null;
    final Database db = await AppDatabase.instance.database;
    final target = allScheds.firstWhere((m) => (m as Map)['id'] == targetId) as Map;

    if (zone == 'inside') {
      final siblings = allScheds.where((m) => (m as Map)['parent_id'] == targetId && m['id'] != dragId).toList();
      await db.update(
        'schedule_items',
        {'parent_id': targetId, 'sort_order': siblings.length},
        where: 'id = ?',
        whereArgs: [dragId],
      );
      _collapsedSchedParents.remove(targetId);
      await _saveTodayUiState();
    } else {
      final newParentId = target['parent_id'] as int?;
      final siblings = allScheds.where((m) => (m as Map)['parent_id'] == newParentId && m['id'] != dragId).toList();
      final tIdx = siblings.indexWhere((m) => (m as Map)['id'] == targetId);
      final insertIdx = zone == 'up' ? math.max(0, tIdx) : math.min(siblings.length, tIdx + 1);

      final dragMap = allScheds.firstWhere((m) => (m as Map)['id'] == dragId);
      siblings.insert(insertIdx, dragMap);

      for (int i = 0; i != siblings.length; i++) {
        await db.update(
          'schedule_items',
          {'parent_id': newParentId, 'sort_order': i},
          where: 'id = ?',
          whereArgs: [(siblings[i] as Map)['id']],
        );
      }
    }
    if (mounted) setState(() {});
    return null;
  }

  Future _toggleScheduleCheckbox(
    int sid,
    bool targetDone,
    List allScheds,
    Map doneMap,
  ) async {
    final Database db = await AppDatabase.instance.database;
    List childrenOf(int pid) =>
        allScheds.where((s) => (s as Map)['parent_id'] == pid).toList();

    doneMap[sid] = targetDone;
    await db.insert(
      'schedule_records',
      {'item_id': sid, 'date': _date, 'done': targetDone ? 1 : 0},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    Future cascadeDown(int pId, bool d) async {
      for (final rawSub in childrenOf(pId)) {
        final sub = rawSub as Map;
        final subId = sub['id'] as int;
        doneMap[subId] = d;
        await db.insert(
          'schedule_records',
          {'item_id': subId, 'date': _date, 'done': d ? 1 : 0},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await cascadeDown(subId, d);
      }
      return null;
    }

    await cascadeDown(sid, targetDone);

    final currentItem = allScheds.where((s) => (s as Map)['id'] == sid).firstOrNull as Map?;
    int? pId = currentItem?['parent_id'] as int?;
    final Set visited = {};
    while (pId != null && !visited.contains(pId)) {
      visited.add(pId);
      final siblings = childrenOf(pId);
      if (siblings.isNotEmpty) {
        final allSiblingsDone = siblings.every((c) => doneMap[(c as Map)['id'] as int] == true);
        doneMap[pId] = allSiblingsDone;
        await db.insert(
          'schedule_records',
          {'item_id': pId, 'date': _date, 'done': allSiblingsDone ? 1 : 0},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      final parentItem = allScheds.where((s) => (s as Map)['id'] == pId).firstOrNull as Map?;
      pId = parentItem?['parent_id'] as int?;
    }

    if (mounted) setState(() {});
    return null;
  }

  /// 打开 DeepSeek 反思面板；返回的正文由面板负责组织，这里只负责落库。
  Future _openDeepSeekAnalyzerSheet(String summaryText, List focusRows) async {
    final db = await AppDatabase.instance.database;
    final res = await showDeepSeekSheet(
      context: context,
      db: db,
      date: _date,
      summaryText: summaryText,
      focusRows: focusRows,
      defaultTarget: '反思',
    );
    if (res == null || !mounted) return null;
    final cleanedLines = res.content
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (cleanedLines.isEmpty) return null;

    final itemId = await _ensureStatusItem(res.fieldName, 'text');
    await db.update('status_items', {'allow_inherit': 0}, where: 'id = ?', whereArgs: [itemId]);
    await db.insert(
      'status_records',
      {'item_id': itemId, 'date': _date, 'value': cleanedLines.join('\n')},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (!mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导入今日「${res.fieldName}」（${cleanedLines.length} 行）')),
    );
    setState(() {});
    return null;
  }

  Future _importDailyDocx() async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.any);
      if (res == null || res.files.single.path == null) return null;
      final db = await AppDatabase.instance.database;
      final filePath = res.files.single.path!;
      final bytes = await File(filePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      ArchiveFile? docXmlFile;
      ArchiveFile? relsXmlFile;
      final Map mediaFiles = {};

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
        return null;
      }

      final Map relMap = {};
      if (relsXmlFile != null) {
        final List relsBytes = relsXmlFile.content as List;
        final relsXml = utf8.decode(relsBytes.cast(), allowMalformed: true);
        final relMatches = RegExp(r'\x3cRelationship\b[^\x3e]*\x3e').allMatches(relsXml);
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

      final List docBytes = docXmlFile.content as List;
      final docXml = utf8.decode(docBytes.cast(), allowMalformed: true);
      final pMatches = RegExp(r'\x3cw:p\b[^\x3e]*\x3e([\s\S]*?)\x3c\/w:p\x3e').allMatches(docXml);

      String currentDate = _date;
      String? lastimportedDate;
      String? currentField;
      final Map dateTextData = {};
      final Map dateImages = {};

      void addTextLine(String dateKey, String fieldName, String val) {
        final v = val.trim();
        if (v.isEmpty) return;
        dateTextData.putIfAbsent(dateKey, () => {});
        (dateTextData[dateKey] as Map).putIfAbsent(fieldName, () => []);
        ((dateTextData[dateKey] as Map)[fieldName] as List).add(v);
      }

      final dateHeaderRegex = RegExp(r'^【\s*(?:(\d{4})\s*年\s*)?(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]\s*】');
      final topFields = ['基础数据', '核心目标', '饮食记录', '打卡进度', '状态与异状', '状态和异状', 'AI 深度异状分析', 'AI深度异状分析', '反思', '复盘与分析', '今日总结'];

      for (final pm in pMatches) {
        final pXml = pm.group(1)!;
        final tMatches = RegExp(r'\x3cw:t(?:\s[^\x3e]*)?\x3e([\s\S]*?)\x3c\/w:t\x3e').allMatches(pXml);
        final rawText = _unescapeXml(tMatches.map((m) => m.group(1)!).join('')).trim();

        final blipMatches = RegExp(r'r:(?:embed|id)="([^"]+)"').allMatches(pXml);
        for (final bm in blipMatches) {
          final rId = bm.group(1)!;
          final mediaPath = relMap[rId];
          if (mediaPath != null && mediaFiles.containsKey(mediaPath)) {
            dateImages.putIfAbsent(currentDate, () => []);
            if (!(dateImages[currentDate] as List).contains(mediaPath)) {
              (dateImages[currentDate] as List).add(mediaPath);
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
        if (colonIdx >= 1 && colonIdx <= 14) {
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
                if (subColon >= 1) addTextLine(currentDate, pTrim.substring(0, subColon).trim(), pTrim.substring(subColon + 1).trim());
              }
            }
          } else {
            currentField = matchedField;
            if (remainder.isNotEmpty) addTextLine(currentDate, currentField, remainder);
          }
        } else {
          final targetField = currentField ?? '状态与异状';
          addTextLine(currentDate, targetField, cleanLine);
        }
      }

      int importedDays = 0;
      int importedImgs = 0;
      final Set allDates = {...dateTextData.keys, ...dateImages.keys};
      final appDir = await getApplicationDocumentsDirectory();

      for (final rawDKey in allDates) {
        final dKey = '$rawDKey';
        importedDays++;
        final fieldsMap = (dateTextData[dKey] as Map?) ?? {};
        for (final entry in fieldsMap.entries) {
          final fName = '${entry.key}';
          final fLines = (entry.value as List).map((e) => '$e').toList();
          if (fLines.isEmpty) continue;

          final isNumber = fName.contains('体重') && fLines.length == 1 && double.tryParse(fLines.first) != null;
          final itemId = (await _ensureStatusItem(fName, isNumber ? 'number' : 'text')) as int;
          final joinedVal = fLines.join('\n');

          await db.insert(
            'status_records',
            {'item_id': itemId, 'date': dKey, 'value': joinedVal},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        final imgList = (dateImages[dKey] as List?) ?? [];
        if (imgList.isNotEmpty) {
          final imgItemId = (await _ensureStatusItem('今日图片', 'image')) as int;
          await db.insert(
            'status_records',
            {'item_id': imgItemId, 'date': dKey, 'value': ''},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          final recs = await db.query('status_records', where: 'item_id = ? AND date = ?', whereArgs: [imgItemId, dKey]);
          final recId = recs.first['id'] as int;

          final dFolder = dKey.replaceAll('-', '');
          final targetDir = Directory(p.join(appDir.path, 'images', 'status', dFolder));
          if (!await targetDir.exists()) await targetDir.create(recursive: true);

          final existingImgs = await db.query('status_images', where: 'record_id = ?', whereArgs: [recId]);
          int nextSort = existingImgs.length;

          for (final rawMediaKey in imgList) {
            final mediaKey = '$rawMediaKey';
            final archFile = mediaFiles[mediaKey] as ArchiveFile;
            final List fileBytes = archFile.content as List;
            final ext = p.extension(mediaKey).isNotEmpty ? p.extension(mediaKey) : '.jpg';
            final fileName = '${recId}_${nextSort}_${DateTime.now().millisecondsSinceEpoch}$ext';
            final relPath = p.join('images', 'status', dFolder, fileName);
            await File(p.join(appDir.path, relPath)).writeAsBytes(fileBytes.cast());
            await db.insert('status_images', {
              'record_id': recId,
              'file_path': relPath,
              'sort_order': nextSort++,
            });
            importedImgs++;
          }
        }
      }

      if (lastimportedDate != null) _date = lastimportedDate;

      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('🎉 成功导入 $importedDays 天记录、$importedImgs 张图片！')));
      setState(() {});
    } catch (e) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入 Word 失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 46,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
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
      body: FutureBuilder(
        future: _load(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final dataMap = snap.data as Map;
          final items = dataMap['items'] as List;
          final disp = dataMap['disp'] as Map;
          final scheds = dataMap['scheds'] as List;
          final doneMap = dataMap['done'] as Map;
          final focusRows = dataMap['focus'] as List;
          final focusSignal = dataMap['signal'] as Map;
          final focusDoneCount =
              focusRows.where((f) => ((f as Map)['done'] as int?) == 1).length;

          for (final rawS in scheds) {
            final s = rawS as Map;
            final sid = s['id'] as int;
            final ch = scheds.where((c) => (c as Map)['parent_id'] == sid).toList();
            if (ch.isNotEmpty) {
              doneMap[sid] = ch.every((c) => doneMap[(c as Map)['id'] as int] == true);
            }
          }

          final doneCount = doneMap.values.where((v) => v == true).length;

          return ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
            buildDefaultDragHandles: false,
            itemCount: _sectionOrder.length,
            onReorder: (oldIdx, newIdx) async {
              if (newIdx.compareTo(oldIdx) == 1) newIdx -= 1;
              final moved = _sectionOrder.removeAt(oldIdx);
              _sectionOrder.insert(newIdx, moved);
              await _saveTodayUiState();
              setState(() {});
            },
            itemBuilder: (ctx, secIdx) {
              final secKey = '${_sectionOrder[secIdx]}';
              if (secKey == 'summary') {
                return Container(
                  key: const ValueKey('sec_summary'),
                  margin: const EdgeInsets.only(bottom: 14),
                  child: _buildSummaryCard(secIdx, items, disp, scheds, doneMap, focusRows),
                );
              } else if (secKey == 'status') {
                return Container(
                  key: const ValueKey('sec_status'),
                  margin: const EdgeInsets.only(bottom: 14),
                  child: _buildMajorSectionCard(
                    dragIndex: secIdx,
                    accentColor: const Color(0xFF4F46E5),
                    headerBgColor: const Color(0xFFEEF2FF),
                    icon: '📊',
                    title: '每日状态 (${items.length})',
                    isFolded: _foldStatusSection,
                    onToggleFold: () {
                      setState(() => _foldStatusSection = !_foldStatusSection);
                      _saveTodayUiState();
                    },
                    actionLabel: '新条目',
                    onAction: () => _addOrEditStatusItemDialog(),
                    child: items.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(20),
                            child: Center(child: Text('暂无状态条目，点击右上角「+ 新条目」添加', style: TextStyle(color: Colors.grey, fontSize: 13))),
                          )
                        : ReorderableListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            buildDefaultDragHandles: false,
                            itemCount: items.length,
                            onReorder: (oldIdx, newIdx) async {
                              if (newIdx.compareTo(oldIdx) == 1) newIdx -= 1;
                              final db = await AppDatabase.instance.database;
                              final moved = items.removeAt(oldIdx) as Map;
                              items.insert(newIdx, moved);
                              for (int i = 0; i != items.length; i++) {
                                await db.update('status_items', {'sort_order': i}, where: 'id = ?', whereArgs: [(items[i] as Map)['id']]);
                              }
                              setState(() {});
                            },
                            itemBuilder: (ctx, i) {
                              final it = items[i] as Map;
                              return Container(
                                key: ValueKey('status_item_${it['id']}'),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  border: i >= 1 ? const Border(top: BorderSide(color: Color(0xFFE2E8F0), width: 0.8)) : null,
                                ),
                                child: _buildCompactStatusRow(it, disp[it['id'] as int] as Map?, i),
                              );
                            },
                          ),
                  ),
                );
              } else if (secKey == 'focus') {
                return Container(
                  key: const ValueKey('sec_focus'),
                  margin: const EdgeInsets.only(bottom: 14),
                  child: _buildMajorSectionCard(
                    dragIndex: secIdx,
                    accentColor: const Color(0xFFBE185D),
                    headerBgColor: const Color(0xFFFDF2F8),
                    icon: '🎯',
                    title: '战略聚焦 ($focusDoneCount/${focusRows.length})',
                    isFolded: _foldFocusSection,
                    onToggleFold: () {
                      setState(() => _foldFocusSection = !_foldFocusSection);
                      _saveTodayUiState();
                    },
                    actionLabel: '新聚焦',
                    onAction: () { _addOrEditFocusDialog(null); },
                    child: _buildFocusBody(focusRows, focusSignal),
                  ),
                );
              } else {
                return Container(
                  key: const ValueKey('sec_schedule'),
                  margin: const EdgeInsets.only(bottom: 14),
                  child: _buildMajorSectionCard(
                    dragIndex: secIdx,
                    accentColor: const Color(0xFF0D9488),
                    headerBgColor: const Color(0xFFF0FDFA),
                    icon: '📅',
                    title: '日程打卡 ($doneCount/${scheds.length})',
                    isFolded: _foldSchedSection,
                    onToggleFold: () {
                      setState(() => _foldSchedSection = !_foldSchedSection);
                      _saveTodayUiState();
                    },
                    actionLabel: '新日程',
                    onAction: () => _addOrEditSchedDialog(),
                    child: scheds.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(20),
                            child: Center(child: Text('暂无日程，点击右上角「+ 新日程」添加', style: TextStyle(color: Colors.grey, fontSize: 13))),
                          )
                        : Padding(
                            padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Padding(
                                  padding: EdgeInsets.only(left: 4, bottom: 6),
                                  child: Text(
                                    '💡 长按右侧 ☰ 自由拖动：拖到其他日程中央变为其子日程，拖到上下边缘调序或升为主日程',
                                    style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                                  ),
                                ),
                                _buildScheduleTree(scheds, doneMap),
                              ],
                            ),
                          ),
                  ),
                );
              }
            },
          );
        },
      ),
    );
  }

  Widget _buildFocusBody(List rows, Map signal) {
    final double dayMul = (signal['day'] as num?)?.toDouble() ?? 1.0;
    final double totalMul = (signal['total'] as num?)?.toDouble() ?? 1.0;
    final int doneCount = (signal['count'] as int?) ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 9),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFCE7F3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFF9A8D4), width: 1),
            ),
            child: Row(
              children: [
                _focusKv('今日', '×${dayMul.toStringAsFixed(3)}'),
                _focusKv('累计', '×${totalMul.toStringAsFixed(3)}'),
                _focusKv('已突破', '$doneCount/${rows.length}'),
              ],
            ),
          ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text('暂无战略聚焦，点击右上角「+ 新聚焦」添加',
                    style: TextStyle(color: Colors.grey, fontSize: 13)),
              ),
            ),
          ...rows.map((raw) => _buildFocusRow(raw as Map)),
        ],
      ),
    );
  }

  Widget _focusKv(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(label,
              style: const TextStyle(fontSize: 9, color: Color(0xFFBE185D), letterSpacing: .5)),
          const SizedBox(height: 2),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF9D174D))),
        ],
      ),
    );
  }

  Widget _buildFocusRow(Map f) {
    final bool done = ((f['done'] as int?) ?? 0) == 1;
    final double mul = (f['multiplier'] as num?)?.toDouble() ?? 1.0;
    final String dim = '${f['title'] ?? ''}'.trim();
    final String step = '${f['next_step'] ?? ''}'.trim();
    final String primary = step.isEmpty ? (dim.isEmpty ? '未命名' : dim) : step;
    final bool showDim = dim.isNotEmpty && dim != primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: done ? const Color(0xFFFDF2F8) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: done ? const Color(0xFFF9A8D4) : const Color(0xFFFBCFE8),
          width: 1.1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 32,
                  height: 32,
                  child: Checkbox(
                    value: done,
                    activeColor: const Color(0xFFBE185D),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (_) { _toggleFocusDone(f); },
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Icon(Icons.subdirectory_arrow_right,
                              size: 13, color: Color(0xFFBE185D)),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            primary,
                            style: TextStyle(
                              fontSize: 13.5,
                              height: 1.35,
                              fontWeight: FontWeight.bold,
                              color: done ? const Color(0xFF9D174D) : const Color(0xFF0F172A),
                              decoration: done ? TextDecoration.lineThrough : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (done)
                  Container(
                    margin: const EdgeInsets.only(top: 4, left: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFBCFE8),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: const Text('已突破',
                        style: TextStyle(
                            fontSize: 9.5, fontWeight: FontWeight.bold, color: Color(0xFF831843))),
                  ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 16, color: Color(0xFFBE185D)),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () { _addOrEditFocusDialog(f); },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 16, color: Color(0xFF94A3B8)),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () { _deleteFocus(f); },
                ),
              ],
            ),
            if (showDim)
              Padding(
                padding: const EdgeInsets.only(left: 34, top: 4, bottom: 2),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFCE7F3),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.category_outlined, size: 9, color: Color(0xFF9D174D)),
                      const SizedBox(width: 3),
                      Text(dim,
                          style: const TextStyle(
                              fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF9D174D))),
                    ],
                  ),
                ),
              ),
            _focusField('完成标准', '${f['done_criteria'] ?? ''}', Icons.rule),
            _focusField('乘数效应', '×${mul.toStringAsFixed(3)}', Icons.trending_up),
            const SizedBox(height: 6),
            TextField(
              controller: TextEditingController(text: '${f['note'] ?? ''}'),
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                labelText: '今日文本记录',
                hintText: '记录推进过程、卡点或复盘…',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              onChanged: (v) { _saveFocusNote(f, v); },
            ),
          ],
        ),
      ),
    );
  }

  Widget _focusField(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(left: 34, top: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 12, color: const Color(0xFFBE185D)),
          const SizedBox(width: 5),
          Text('$label：',
              style: const TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF9D174D))),
          Expanded(
            child: Text(value.trim().isEmpty ? '—' : value,
                style: const TextStyle(fontSize: 11.5, height: 1.4, color: Color(0xFF475569))),
          ),
        ],
      ),
    );
  }

  Future _toggleFocusDone(Map row) async {
    final db = await AppDatabase.instance.database;
    final int cur = (row['done'] as int?) ?? 0;
    await db.update('focus_items', {'done': cur == 1 ? 0 : 1},
        where: 'id = ?', whereArgs: [row['id'] as int]);
    await AppDatabase.refreshFocusSignals(db, _date);
    if (mounted) setState(() {});
    return null;
  }

  Future _saveFocusNote(Map row, String text) async {
    final db = await AppDatabase.instance.database;
    await db.update('focus_items', {'note': text},
        where: 'id = ?', whereArgs: [row['id'] as int]);
    return null;
  }

  Future _deleteFocus(Map row) async {
    final String name = '${row['next_step'] ?? ''}'.trim().isEmpty
        ? '${row['title'] ?? ''}'
        : '${row['next_step']}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('删除这条战略聚焦？', style: TextStyle(fontSize: 16)),
        content: Text('「$name」将被删除，其乘数效应也会从帝国信号中退回。',
            style: const TextStyle(fontSize: 13, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFBE185D)),
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return null;
    final db = await AppDatabase.instance.database;
    await db.delete('focus_items', where: 'id = ?', whereArgs: [row['id'] as int]);
    await AppDatabase.refreshFocusSignals(db, _date);
    if (mounted) setState(() {});
    return null;
  }

  InputDecoration _focusDec(String label, [String? hint]) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8)),
      labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF9D174D)),
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFF9A8D4)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFBE185D), width: 1.3),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    );
  }

  Future _addOrEditFocusDialog([Map? existing]) async {
    // 老数据只有「名称」没有「下一步」：按新语义把名称当作具体要做的事
    final bool legacy = existing != null && '${existing['next_step'] ?? ''}'.trim().isEmpty;
    final dimCtrl = TextEditingController(
        text: (existing == null || legacy) ? '' : '${existing['title'] ?? ''}');
    final nextCtrl = TextEditingController(
        text: existing == null ? '' : (legacy ? '${existing['title'] ?? ''}' : '${existing['next_step'] ?? ''}'));
    final critCtrl = TextEditingController(text: existing == null ? '' : '${existing['done_criteria'] ?? ''}');
    final mulCtrl = TextEditingController(
        text: existing == null ? '1.05' : '${existing['multiplier'] ?? 1.05}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
        contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        title: Text(existing == null ? '新增战略聚焦' : '编辑战略聚焦',
            style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nextCtrl,
                minLines: 1,
                maxLines: 3,
                autofocus: existing == null,
                style: const TextStyle(fontSize: 13.5, height: 1.4),
                decoration: _focusDec('下一步 · 具体要做的事', '例：定义帝国系统的规则和架构'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: dimCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: _focusDec('聚焦维度 · 归属类别', '例：帝国系统 / 体能 / 关系'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: critCtrl,
                minLines: 1,
                maxLines: 3,
                style: const TextStyle(fontSize: 13, height: 1.4),
                decoration: _focusDec('完成标准 · 怎样算突破', '例：三状态推演都不崩，且过程不枯燥'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: mulCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(fontSize: 13),
                decoration: _focusDec('乘数效应', '如 1.05，突破后连乘进帝国'),
              ),
              const SizedBox(height: 8),
              const Text('突破只作用于这条「下一步」，不会影响整个聚焦维度。',
                  style: TextStyle(fontSize: 10.5, height: 1.4, color: Color(0xFF9D174D))),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFBE185D)),
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return null;
    final String step = nextCtrl.text.trim();
    final String dim = dimCtrl.text.trim();
    if (step.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请填写「下一步」——它才是要突破的那件事')),
        );
      }
      return null;
    }
    final parsed = double.tryParse(mulCtrl.text.trim()) ?? 1.0;
    final double mul = parsed > 0 ? parsed : 1.0;
    final String title = dim.isEmpty ? '未分类' : dim;
    final db = await AppDatabase.instance.database;
    if (existing == null) {
      final same = await db.query('focus_items',
          where: 'date = ? AND title = ? AND next_step = ?',
          whereArgs: [_date, title, step]);
      if (same.isNotEmpty) {
        // 同一天、同维度、同一步已经存在：合并到原条目，不再落第二条
        await db.update(
            'focus_items',
            {
              'done_criteria': critCtrl.text.trim(),
              'multiplier': mul,
            },
            where: 'id = ?',
            whereArgs: [same.first['id'] as int]);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('这条「下一步」已经存在，已合并为一条')),
          );
        }
      } else {
        final cnt = await db.query('focus_items', where: 'date = ?', whereArgs: [_date]);
        await db.insert(
          'focus_items',
          {
            'date': _date,
            'title': title,
            'next_step': step,
            'done_criteria': critCtrl.text.trim(),
            'multiplier': mul,
            'done': 0,
            'note': '',
            'rolled': 0,
            'sort_order': cnt.length,
            'created_at': DateTime.now().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    } else {
      await db.update('focus_items', {
        'title': title,
        'next_step': step,
        'done_criteria': critCtrl.text.trim(),
        'multiplier': mul,
      }, where: 'id = ?', whereArgs: [existing['id'] as int]);
    }
    await AppDatabase.refreshFocusSignals(db, _date);
    if (mounted) setState(() {});
    return null;
  }

  Widget _buildMajorSectionCard({
    required int dragIndex,
    required Color accentColor,
    required Color headerBgColor,
    required String icon,
    required String title,
    required bool isFolded,
    required VoidCallback onToggleFold,
    required String actionLabel,
    required VoidCallback onAction,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accentColor.withOpacity(0.32), width: 1.3),
        boxShadow: [
          BoxShadow(
            color: accentColor.withOpacity(0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: headerBgColor,
              borderRadius: BorderRadius.vertical(
                top: const Radius.circular(12.5),
                bottom: isFolded ? const Radius.circular(12.5) : Radius.zero,
              ),
              border: isFolded
                  ? null
                  : Border(bottom: BorderSide(color: accentColor.withOpacity(0.18), width: 1)),
            ),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 16,
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: onToggleFold,
                    child: Row(
                      children: [
                        Icon(isFolded ? Icons.chevron_right : Icons.expand_more, size: 20, color: accentColor),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(
                            '$icon $title',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  height: 28,
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: accentColor,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: Size.zero,
                    ),
                    onPressed: onAction,
                    icon: const Icon(Icons.add, size: 15),
                    label: Text(actionLabel, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 4),
                ReorderableDragStartListener(
                  index: dragIndex,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Icon(Icons.drag_indicator, size: 20, color: accentColor.withOpacity(0.7)),
                  ),
                ),
              ],
            ),
          ),
          if (!isFolded)
            ClipRRect(
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12.5)),
              child: child,
            ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(
    int dragIndex,
    List items,
    Map disp,
    List scheds,
    Map doneMap,
    List focusRows,
  ) {
    final List copyLines = [];
    final List summaryRows = [];

    for (final rawIt in items) {
      final it = rawIt as Map;
      final d = disp[it['id'] as int] as Map?;
      if (d == null) continue;
      final name = '${it['name']}';
      if (it['type'] == 'image') {
        final imgs = d['images'] as List;
        if (imgs.isNotEmpty) {
          copyLines.add('$name：[${imgs.length}张图片]');
          summaryRows.add(_buildSummarySingleLine(name, '[${imgs.length}张图片]'));
        }
      } else {
        final rawVal = '${d['value'] ?? ''}'.trim();
        if (rawVal.isEmpty) continue;
        final cols = _splitColumns(rawVal);
        if (cols.length <= 1) {
          copyLines.add('$name：${cols.first}');
          summaryRows.add(_buildSummarySingleLine(name, '${cols.first}'));
        } else {
          copyLines.add('$name：\n${cols.map((c) => '  • $c').join('\n')}');
          summaryRows.add(_buildSummaryMultiColRow(name, cols));
        }
      }
    }

    String fmtSched(Map s) {
      final p = '${s['plan_info'] ?? ''}'.trim();
      return p.isEmpty ? '${s['title']}' : '${s['title']} ($p)';
    }

    final Set validIds = scheds.map((s) => (s as Map)['id'] as int).toSet();
    final roots = scheds.where((s) {
      final pid = (s as Map)['parent_id'] as int?;
      return pid == null || !validIds.contains(pid);
    }).toList();

    List childrenOf(int pid) =>
        scheds.where((s) => (s as Map)['parent_id'] == pid).toList();

    List buildHierarchicalList(bool targetDone) {
      final List res = [];
      bool hasMatchInSubtree(Map node) {
        final id = node['id'] as int;
        if ((doneMap[id] == true) == targetDone) return true;
        for (final c in childrenOf(id)) {
          if (hasMatchInSubtree(c as Map)) return true;
        }
        return false;
      }

      void walk(Map node, int depth) {
        if (!hasMatchInSubtree(node)) return;
        final id = node['id'] as int;
        final selfMatches = (doneMap[id] == true) == targetDone;
        res.add({
          'text': fmtSched(node),
          'depth': depth,
          'isGroupHeaderOnly': !selfMatches,
        });
        for (final c in childrenOf(id)) {
          walk(c as Map, depth + 1);
        }
      }

      for (final r in roots) {
        walk(r as Map, 0);
      }
      return res;
    }

    final doneHierarchical = buildHierarchicalList(true);
    final todoHierarchical = buildHierarchicalList(false);
    final doneActualCount = scheds.where((s) => doneMap[(s as Map)['id']] == true).length;
    final todoActualCount = scheds.where((s) => doneMap[(s as Map)['id']] != true).length;

    String formatTreeForCopy(List list) {
      if (list.isEmpty) return '无';
      return '\n' +
          list.map((rawE) {
            final e = rawE as Map;
            final depth = e['depth'] as int;
            final indent = '  ' * (depth + 1);
            final prefix = depth == 0 ? '• ' : '↳ ';
            return '$indent$prefix${e['text']}';
          }).join('\n');
    }

    var copyText = '📋 $_date 状态记录';
    if (copyLines.isNotEmpty) copyText += '\n${copyLines.join('\n')}';
    if (scheds.isNotEmpty) {
      copyText += '\n\n✅ 已完成日程 ($doneActualCount)：${formatTreeForCopy(doneHierarchical)}';
      copyText += '\n⬜ 未完成日程 ($todoActualCount)：${formatTreeForCopy(todoHierarchical)}';
    }

    const accentColor = Color(0xFFD97706);
    const headerBgColor = Color(0xFFFFFBEB);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accentColor.withOpacity(0.35), width: 1.3),
        boxShadow: [
          BoxShadow(
            color: accentColor.withOpacity(0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: headerBgColor,
              borderRadius: BorderRadius.vertical(
                top: const Radius.circular(12.5),
                bottom: _foldSummary ? const Radius.circular(12.5) : Radius.zero,
              ),
              border: _foldSummary
                  ? null
                  : Border(bottom: BorderSide(color: accentColor.withOpacity(0.2), width: 1)),
            ),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 16,
                  decoration: BoxDecoration(color: accentColor, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() => _foldSummary = !_foldSummary);
                      _saveTodayUiState();
                    },
                    child: Row(
                      children: [
                        Icon(_foldSummary ? Icons.chevron_right : Icons.expand_more, size: 20, color: accentColor),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(
                            '📋 今日状态摘要 · $_date',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5, color: Color(0xFF0F172A)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  height: 28,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF4F46E5),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: Size.zero,
                    ),
                    onPressed: () => _openDeepSeekAnalyzerSheet(copyText, focusRows),
                    icon: const Icon(Icons.auto_awesome, size: 13),
                    label: const Text('AI 反思', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 4),
                ReorderableDragStartListener(
                  index: dragIndex,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Icon(Icons.drag_indicator, size: 20, color: accentColor.withOpacity(0.75)),
                  ),
                ),
              ],
            ),
          ),
          if (!_foldSummary)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: (summaryRows.isEmpty && scheds.isEmpty)
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(8.0),
                        child: Text('今日暂无状态或日程记录', style: TextStyle(fontSize: 12.5, color: Colors.grey)),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ...summaryRows,
                        if (scheds.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          _buildSummaryScheduleTreeBlock('✅ 已完成日程', doneActualCount, doneHierarchical, const Color(0xFF10B981)),
                          const SizedBox(height: 6),
                          _buildSummaryScheduleTreeBlock('⬜ 未完成日程', todoActualCount, todoHierarchical, const Color(0xFF64748B)),
                        ],
                      ],
                    ),
            ),
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

  Widget _buildSummaryMultiColRow(String name, List cols) {
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
              children: cols.map((rawCol) {
                final colText = '$rawCol';
                final colonIdx = colText.indexOf(RegExp(r'[:：]'));
                Widget content;
                if (colonIdx >= 1 && colonIdx < 14) {
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
                    color: const Color(0xFFF8FAFC),
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

  Widget _buildSummaryScheduleTreeBlock(
    String label,
    int count,
    List nodes,
    Color accentColor,
  ) {
    if (nodes.isEmpty) {
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
        Text('$label ($count)：', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF475569))),
        const SizedBox(height: 3),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: nodes.map((rawItem) {
              final item = rawItem as Map;
              final depth = item['depth'] as int;
              final isSub = depth >= 1;
              final isGroupHeaderOnly = item['isGroupHeaderOnly'] == true;
              return Padding(
                padding: EdgeInsets.only(left: depth * 16.0, bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (isSub)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(Icons.subdirectory_arrow_right, size: 14, color: accentColor.withOpacity(0.8)),
                      ),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: isSub ? Colors.white : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(5),
                          border: Border(
                            left: BorderSide(color: accentColor, width: isSub ? 2.0 : 3.5),
                            top: const BorderSide(color: Color(0xFFE2E8F0), width: 0.6),
                            right: const BorderSide(color: Color(0xFFE2E8F0), width: 0.6),
                            bottom: const BorderSide(color: Color(0xFFE2E8F0), width: 0.6),
                          ),
                        ),
                        child: Text(
                          '${item['text']}',
                          style: TextStyle(
                            fontSize: isSub ? 11.8 : 12.2,
                            fontWeight: isSub ? FontWeight.normal : FontWeight.w600,
                            color: isGroupHeaderOnly ? const Color(0xFF64748B) : const Color(0xFF1E293B),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildCompactStatusRow(Map it, Map? d, int dragIndex) {
    final id = it['id'] as int, name = '${it['name']}', type = '${it['type']}';
    final inh = d?['isInherited'] == true, val = '${d?['value'] ?? ''}';
    final imgs = (d?['images'] as List?)?.map((e) => '$e').toList() ?? [];
    final recId = (d?['recordId'] as int?) ?? id;
    final cols = type == 'image' ? [] : _splitColumns(val);
    final isItemFolded = _collapsedStatusIds.contains(id);

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (cols.length >= 2 || val.length >= 23 || imgs.isNotEmpty)
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
                  child: Text('承自${'${d!['inheritedFrom']}'.substring(5)}', style: TextStyle(fontSize: 10, color: Colors.amber[900])),
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
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Icon(Icons.delete_outline, size: 17, color: Colors.redAccent),
                ),
              ),
              ReorderableDragStartListener(
                index: dragIndex,
                child: const Padding(
                  padding: EdgeInsets.only(left: 4, right: 2, top: 2, bottom: 2),
                  child: Icon(Icons.drag_handle, size: 18, color: Colors.grey),
                ),
              ),
            ],
          ),
          if (!isItemFolded && type != 'image' && (cols.length >= 2 || val.length >= 19))
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 6),
              child: GestureDetector(
                onTap: () => _editValDialog(id, name, type, val),
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final useTwoCols = cols.length >= 2 && cols.every((c) => '$c'.length <= 16);
                    final itemWidth = useTwoCols ? (constraints.maxWidth - 6) / 2 : constraints.maxWidth;
                    return Wrap(
                      spacing: 6,
                      runSpacing: 5,
                      children: cols.map((rawCol) {
                        final colText = '$rawCol';
                        final colonIdx = colText.indexOf(RegExp(r'[:：]'));
                        Widget inner;
                        if (colonIdx >= 1 && colonIdx < 14) {
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
              padding: const EdgeInsets.only(top: 6, right: 6),
              child: _buildGrid(recId, imgs),
            ),
        ],
      ),
    );
  }

  Widget _buildScheduleTree(List allScheds, Map doneMap) {
    final Set validIds = allScheds.map((s) => (s as Map)['id'] as int).toSet();
    final roots = allScheds.where((s) {
      final pid = (s as Map)['parent_id'] as int?;
      return pid == null || !validIds.contains(pid);
    }).toList();

    List childrenOf(int pid) {
      return allScheds.where((s) => (s as Map)['parent_id'] == pid).toList();
    }

    Widget buildNode(Map s, int depth) {
      final sid = s['id'] as int;
      final children = childrenOf(sid);
      final hasChildren = children.isNotEmpty;
      final done = doneMap[sid] == true;
      final plan = '${s['plan_info'] ?? ''}'.trim();
      final isCollapsed = _collapsedSchedParents.contains(sid);
      final doneChildrenCount = children.where((c) => doneMap[(c as Map)['id'] as int] == true).length;

      final isHover = _hoverSchedTargetId == sid;
      final zone = isHover ? _hoverSchedZone : null;

      return Column(
        key: ValueKey('sched_tree_$sid'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(left: depth * 18.0, bottom: 5),
            child: Builder(
              builder: (itemCtx) => DragTarget(
                onWillAcceptWithDetails: (details) {
                  final dragId = details.data as int;
                  return !_isSchedDescendant(dragId, sid, allScheds);
                },
                onMove: (details) {
                  final box = itemCtx.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final localY = box.globalToLocal(details.offset).dy;
                  final h = box.size.height;
                  String z;
                  if (localY.compareTo(h * 0.28) <= 0) {
                    z = 'up';
                  } else if (localY.compareTo(h * 0.72) >= 0) {
                    z = 'down';
                  } else {
                    z = 'inside';
                  }
                  if (_hoverSchedTargetId != sid || _hoverSchedZone != z) {
                    setState(() {
                      _hoverSchedTargetId = sid;
                      _hoverSchedZone = z;
                    });
                  }
                },
                onLeave: (_) {
                  if (_hoverSchedTargetId == sid) {
                    setState(() {
                      _hoverSchedTargetId = null;
                      _hoverSchedZone = null;
                    });
                  }
                },
                onAcceptWithDetails: (details) async {
                  final z = _hoverSchedZone ?? 'inside';
                  setState(() {
                    _hoverSchedTargetId = null;
                    _hoverSchedZone = null;
                  });
                  await _handleScheduleDrop(
                    dragId: details.data as int,
                    targetId: sid,
                    zone: z,
                    allScheds: allScheds,
                  );
                },
                builder: (ctx, cand, rej) {
                  return Container(
                    decoration: BoxDecoration(
                      color: zone == 'inside'
                          ? const Color(0xFFCCFBF1)
                          : (depth == 0 ? const Color(0xFFF8FAFC) : Colors.white),
                      borderRadius: BorderRadius.circular(10),
                      border: Border(
                        top: BorderSide(
                          color: zone == 'up' ? const Color(0xFF0D9488) : const Color(0xFFE2E8F0),
                          width: zone == 'up' ? 3.0 : 1.0,
                        ),
                        bottom: BorderSide(
                          color: zone == 'down' ? const Color(0xFF0D9488) : const Color(0xFFE2E8F0),
                          width: zone == 'down' ? 3.0 : 1.0,
                        ),
                        left: BorderSide(
                          color: zone == 'inside'
                              ? const Color(0xFF0D9488)
                              : (depth == 0 ? const Color(0xFF0D9488) : const Color(0xFFE2E8F0)),
                          width: zone == 'inside' ? 2.0 : (depth == 0 ? 3.5 : 1.0),
                        ),
                        right: BorderSide(
                          color: zone == 'inside' ? const Color(0xFF0D9488) : const Color(0xFFE2E8F0),
                          width: zone == 'inside' ? 2.0 : 1.0,
                        ),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
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
                              child: Icon(isCollapsed ? Icons.chevron_right : Icons.expand_more, size: 19, color: const Color(0xFF0D9488)),
                            ),
                          )
                        else if (depth >= 1)
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
                            activeColor: const Color(0xFF0D9488),
                            visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                            onChanged: (v) => _toggleScheduleCheckbox(sid, v ?? false, allScheds, doneMap),
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
                                          fontWeight: depth == 0 ? FontWeight.w600 : FontWeight.normal,
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
                                          color: const Color(0xFFCCFBF1),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          '$doneChildrenCount/${children.length}',
                                          style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF0F766E)),
                                        ),
                                      ),
                                  ],
                                ),
                                if (plan.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      '🎯 $plan',
                                      style: const TextStyle(fontSize: 11, color: Color(0xFF4F46E5), height: 1.3),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: () => _addOrEditSchedDialog(parentId: sid, parentTitle: '${s['title']}'),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                            child: Icon(Icons.add_circle_outline, size: 17, color: Color(0xFF0D9488)),
                          ),
                        ),
                        InkWell(
                          onTap: () => _addOrEditSchedDialog(editSched: s),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                            child: Icon(Icons.edit_outlined, size: 16, color: Colors.blueGrey),
                          ),
                        ),
                        InkWell(
                          onTap: () async {
                            final Database db = await AppDatabase.instance.database;
                            final List subIds = [sid];
                            void collect(int p) {
                              for (final c in childrenOf(p)) {
                                final cid = (c as Map)['id'] as int;
                                subIds.add(cid);
                                collect(cid);
                              }
                            }
                            collect(sid);
                            for (final did in subIds) {
                              await db.delete('schedule_records', where: 'item_id = ?', whereArgs: [did]);
                              await db.delete('schedule_items', where: 'id = ?', whereArgs: [did]);
                            }
                            setState(() {});
                          },
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                            child: Icon(Icons.delete_outline, size: 17, color: Colors.redAccent),
                          ),
                        ),
                        LongPressDraggable(
                          data: sid,
                          feedback: Material(
                            elevation: 8,
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              width: 220,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFCCFBF1),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFF0D9488), width: 1.5),
                              ),
                              child: Text('${s['title']}', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
                            ),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.only(left: 4, right: 2, top: 3, bottom: 3),
                            child: Icon(Icons.drag_handle, size: 18, color: Colors.grey),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          if (hasChildren && !isCollapsed)
            ...children.map((c) => buildNode(c as Map, depth + 1)),
        ],
      );
    }

    return Column(
      children: roots.map((r) => buildNode(r as Map, 0)).toList(),
    );
  }

  Widget _buildGrid(int recId, List paths) {
    final exp = _expandedPhoto[recId] == true, total = paths.length;
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
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(backgroundColor: Colors.black, appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white), body: PageView.builder(controller: PageController(initialPage: i), itemCount: total, itemBuilder: (_, idx) => InteractiveViewer(child: Center(child: Image.file(File('${paths[idx]}')))))))),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.file(File('${paths[i]}'), fit: BoxFit.cover)),
                if (!exp && total >= 4 && i == 2)
                  Container(decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)), alignment: Alignment.center, child: Text('+${total - 3}', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
              ],
            ),
          ),
        ),
        if (total >= 4) TextButton(onPressed: () => setState(() => _expandedPhoto[recId] = !exp), child: Text(exp ? '收起' : '展开全部 $total 张')),
      ],
    );
  }

  Future _pickImgs(int itemId) async {
    final picked = await ImagePicker().pickMultiImage(imageQuality: 100);
    if (picked.isEmpty) return null;
    final Database db = await AppDatabase.instance.database;
    await db.insert('status_records', {'item_id': itemId, 'date': _date, 'value': ''}, conflictAlgorithm: ConflictAlgorithm.ignore);
    final recs = await db.query('status_records', where: 'item_id = ? AND date = ?', whereArgs: [itemId, _date]);
    final recId = recs.first['id'] as int;
    final appDir = await getApplicationDocumentsDirectory();
    final dStr = _date.replaceAll('-', '');
    final dir = Directory(p.join(appDir.path, 'images', 'status', dStr));
    if (!await dir.exists()) await dir.create(recursive: true);
    for (int i = 0; i != picked.length; i++) {
      final rel = p.join('images', 'status', dStr, '${recId}_${i}_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(picked[i].path).copy(p.join(appDir.path, rel));
      await db.insert('status_images', {'record_id': recId, 'file_path': rel, 'sort_order': i});
    }
    setState(() {});
    return null;
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
              final Database db = await AppDatabase.instance.database;
              await db.delete('status_records', where: 'item_id = ?', whereArgs: [id]);
              await db.delete('status_items', where: 'id = ?', whereArgs: [id]);
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _addOrEditStatusItemDialog({Map? editItem}) {
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
                decoration: const InputDecoration(labelText: '条目名称'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField(
                value: type,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '数据类型', isDense: true),
                items: const [
                  DropdownMenuItem(value: 'text', child: Text('文本（支持多行与分列展示）')),
                  DropdownMenuItem(value: 'number', child: Text('数字（支持趋势折线图）')),
                  DropdownMenuItem(value: 'image', child: Text('图片（九宫格原图）')),
                ],
                onChanged: (v) => setS(() => type = '$v'),
              ),
              const SizedBox(height: 6),
              CheckboxListTile(
                value: allowInherit,
                contentPadding: EdgeInsets.zero,
                title: const Text('允许跨天继承历史数据', style: TextStyle(fontSize: 13.5)),
                onChanged: (v) => setS(() => allowInherit = v ?? true),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                final txt = ctrl.text.trim();
                if (txt.isEmpty) return;
                final Database db = await AppDatabase.instance.database;
                if (isEdit) {
                  await db.update('status_items', {'name': txt, 'type': type, 'allow_inherit': allowInherit ? 1 : 0}, where: 'id = ?', whereArgs: [editItem['id']]);
                } else {
                  final all = await db.query('status_items');
                  await db.insert('status_items', {'name': txt, 'type': type, 'allow_inherit': allowInherit ? 1 : 0, 'sort_order': all.length});
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
      if (cols.length >= 2) formattedInit = cols.join('\n');
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
                const Text('💡 每一行会自动分列展示：', style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    ActionChip(visualDensity: const VisualDensity(horizontal: -4, vertical: -4), label: const Text('+ 新增分列行'), onPressed: () => appendTemplate('项目：')),
                    ActionChip(visualDensity: const VisualDensity(horizontal: -4, vertical: -4), label: const Text('早/午/晚模板'), onPressed: () => appendTemplate('早餐：\n午餐：\n晚餐：')),
                    ActionChip(visualDensity: const VisualDensity(horizontal: -4, vertical: -4), label: const Text('上/下/晚模板'), onPressed: () => appendTemplate('上午：\n下午：\n晚上：')),
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
                decoration: const InputDecoration(contentPadding: EdgeInsets.all(10), border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final Database db = await AppDatabase.instance.database;
              await db.insert('status_records', {'item_id': id, 'date': _date, 'value': ctrl.text.trim()}, conflictAlgorithm: ConflictAlgorithm.replace);
              if (mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future _addOrEditSchedDialog({Map? editSched, int? parentId, String? parentTitle}) async {
    final Database db = await AppDatabase.instance.database;
    final mms = await db.query('mindmaps', orderBy: 'id DESC');
    if (!mounted) return null;

    final isEdit = editSched != null;
    final ctrl = TextEditingController(text: isEdit ? '${editSched['title']}' : '');
    String selPlan = isEdit ? ('${editSched['plan_info'] ?? ''}') : '';
    final Set expandedPaths = {};

    for (final rawM in mms) {
      final m = rawM as Map;
      try {
        final root = jsonDecode('${m['root_json']}') as Map;
        final rt = '${root['text'] ?? ''}'.trim();
        if (rt.isNotEmpty) expandedPaths.add(rt);
      } catch (_) {}
    }
    if (selPlan.isNotEmpty) {
      final parts = selPlan.split(' > ');
      String acc = '';
      for (int i = 0; i != parts.length - 1; i++) {
        acc = acc.isEmpty ? parts[i] : '$acc > ${parts[i]}';
        expandedPaths.add(acc);
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          Widget buildTreePickerNode(Map node, String currentPath, int depth) {
            final t = '${node['text'] ?? ''}'.trim();
            if (t.isEmpty) return const SizedBox.shrink();
            final path = currentPath.isEmpty ? t : '$currentPath > $t';
            final children = (node['children'] as List? ?? []);
            final hasChildren = children.isNotEmpty;
            final isExpanded = expandedPaths.contains(path);
            final isSelected = selPlan == path;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    setS(() => selPlan = path);
                    if (ctrl.text.trim().isEmpty) ctrl.text = t;
                  },
                  child: Container(
                    width: double.infinity,
                    margin: EdgeInsets.only(left: depth * 14.0, bottom: 3),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFFEEF2FF) : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: isSelected ? Border.all(color: const Color(0xFF4F46E5)) : null,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (hasChildren)
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setS(() => isExpanded ? expandedPaths.remove(path) : expandedPaths.add(path)),
                            child: Padding(
                              padding: const EdgeInsets.only(right: 4, top: 1),
                              child: Icon(
                                isExpanded ? Icons.arrow_drop_down_circle : Icons.arrow_right,
                                size: 19,
                                color: const Color(0xFF4F46E5),
                              ),
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.only(right: 4, top: 2),
                            child: Icon(
                              depth == 0 ? Icons.folder_outlined : Icons.subdirectory_arrow_right,
                              size: 15,
                              color: Colors.blueGrey,
                            ),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t,
                                softWrap: true,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  height: 1.3,
                                  fontWeight: isSelected || depth == 0 ? FontWeight.bold : FontWeight.normal,
                                  color: isSelected ? const Color(0xFF4F46E5) : const Color(0xFF1E293B),
                                ),
                              ),
                              if (depth >= 1)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    path,
                                    softWrap: true,
                                    style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B), height: 1.25),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (hasChildren)
                          GestureDetector(
                            onTap: () => setS(() => isExpanded ? expandedPaths.remove(path) : expandedPaths.add(path)),
                            child: Container(
                              margin: const EdgeInsets.only(left: 4, right: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text('子项(${children.length})', style: const TextStyle(fontSize: 10.5, color: Color(0xFF475569))),
                            ),
                          ),
                        Icon(
                          isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                          size: 19,
                          color: isSelected ? const Color(0xFF4F46E5) : Colors.grey[400],
                        ),
                      ],
                    ),
                  ),
                ),
                if (hasChildren && isExpanded)
                  ...children.map((c) => buildTreePickerNode(c as Map, path, depth + 1)),
              ],
            );
          }

          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
            title: Text(
              isEdit ? '编辑日程' : (parentId != null ? '在「$parentTitle」下添加子日程' : '添加日程'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(ctx).size.height * 0.68,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '日程内容（支持多行自动换行）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (selPlan.isNotEmpty)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEEF2FF),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFC7D2FE)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('🎯 已选规划：', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF4F46E5))),
                          Expanded(
                            child: Text(
                              selPlan,
                              softWrap: true,
                              style: const TextStyle(fontSize: 12, color: Color(0xFF1E293B), height: 1.3),
                            ),
                          ),
                          InkWell(
                            onTap: () => setS(() => selPlan = ''),
                            child: const Icon(Icons.clear, size: 16, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  const Text(
                    '💡 选择关联规划（点击左侧箭头分级展开，长路径自动换行显示）：',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey),
                  ),
                  const Divider(height: 10),
                  Expanded(
                    child: ListView(
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => setS(() => selPlan = ''),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: selPlan.isEmpty ? const Color(0xFFEEF2FF) : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Text('🚫 不关联规划', style: TextStyle(fontSize: 13, color: Colors.blueGrey)),
                                const Spacer(),
                                Icon(
                                  selPlan.isEmpty ? Icons.check_box : Icons.check_box_outline_blank,
                                  size: 19,
                                  color: selPlan.isEmpty ? const Color(0xFF4F46E5) : Colors.grey[400],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (mms.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('暂无规划，请先在「规划」页创建或导入 XMind', style: TextStyle(fontSize: 12.5, color: Colors.grey)),
                          )
                        else
                          ...mms.map((rawM) {
                            final m = rawM as Map;
                            try {
                              final root = jsonDecode('${m['root_json']}') as Map;
                              return buildTreePickerNode(root, '', 0);
                            } catch (_) {
                              return const SizedBox.shrink();
                            }
                          }),
                      ],
                    ),
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
                    await db.update(
                      'schedule_items',
                      {'title': ctrl.text.trim(), 'plan_info': selPlan},
                      where: 'id = ?',
                      whereArgs: [editSched['id']],
                    );
                  } else {
                    final all = await db.query('schedule_items');
                    await db.insert('schedule_items', {
                      'title': ctrl.text.trim(),
                      'plan_info': selPlan,
                      'parent_id': parentId,
                      'sort_order': all.length,
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
          );
        },
      ),
    );
    return null;
  }

  Future _showTrend(int itemId, String name) async {
    final Database db = await AppDatabase.instance.database;
    final recs = await db.query('status_records', where: 'item_id = ? AND value != ""', whereArgs: [itemId], orderBy: 'date ASC');
    final List pts = [];
    for (final rawR in recs) {
      final r = rawR as Map;
      final v = double.tryParse('${r['value']}');
      if (v != null) pts.add({'date': '${r['date']}', 'value': v});
    }
    if (!mounted) return null;
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
              ...pts.reversed.map((rawP) {
                final p = rawP as Map;
                return ListTile(dense: true, title: Text('${p['date']}'), trailing: Text('${p['value']}', style: const TextStyle(fontWeight: FontWeight.bold)));
              }),
            ],
          ],
        ),
      ),
    );
    return null;
  }
}
