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
        vTp.paint(canvas, Offset(c.dx 
