import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'pages_extra.dart';
import 'today_page.dart';

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
        await db.execute(
          'CREATE TABLE status_items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, type TEXT NOT NULL, sort_order INTEGER DEFAULT 0)',
        );
        await db.execute(
          'CREATE TABLE status_records (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, date TEXT NOT NULL, value TEXT DEFAULT "", UNIQUE(item_id, date))',
        );
        await db.execute(
          'CREATE TABLE status_images (id INTEGER PRIMARY KEY AUTOINCREMENT, record_id INTEGER NOT NULL, file_path TEXT NOT NULL, sort_order INTEGER DEFAULT 0)',
        );
        await db.execute(
          'CREATE TABLE schedule_items (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, plan_info TEXT DEFAULT "", parent_id INTEGER, sort_order INTEGER DEFAULT 0)',
        );
        await db.execute(
          'CREATE TABLE schedule_records (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, date TEXT NOT NULL, done INTEGER DEFAULT 0, UNIQUE(item_id, date))',
        );
        await db.execute(
          'CREATE TABLE modules (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, parent_id INTEGER, sort_order INTEGER DEFAULT 0, created_at TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE module_entries (id INTEGER PRIMARY KEY AUTOINCREMENT, module_id INTEGER NOT NULL, seq INTEGER NOT NULL, content TEXT NOT NULL, sort_order INTEGER DEFAULT 0, created_at TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE module_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, module_ids TEXT NOT NULL, created_at TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE mindmaps (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, root_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)',
        );
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          try {
            await db.execute("ALTER TABLE schedule_items ADD COLUMN plan_info TEXT DEFAULT ''");
          } catch (_) {}
        }
        if (oldV < 3) {
          try {
            await db.execute("ALTER TABLE modules ADD COLUMN parent_id INTEGER");
          } catch (_) {}
          try {
            await db.execute("ALTER TABLE modules ADD COLUMN sort_order INTEGER DEFAULT 0");
          } catch (_) {}
          try {
            await db.execute("ALTER TABLE module_entries ADD COLUMN sort_order INTEGER DEFAULT 0");
          } catch (_) {}
        }
        if (oldV < 4) {
          try {
            await db.execute("ALTER TABLE schedule_items ADD COLUMN parent_id INTEGER");
          } catch (_) {}
        }
      },
    );
  }
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
  int _idx = 2;
  @override
  Widget build(BuildContext context) {
    final pages = [
      SearchPage(db: widget.db),
      FamilyPage(db: widget.db),
      TodayPage(db: widget.db),
      PlanPage(db: widget.db),
    ];
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
