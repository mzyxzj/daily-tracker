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

 
