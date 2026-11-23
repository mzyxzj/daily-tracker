// 医疗模块（Medical）
// 对应宪法导图里的「医疗建设」，与「规划 / 文化」同级：
//   预防：在电量掉下去之前拦一道（防电量过低 / 防暴食 / 防恐慌式学习）
//   急救：已经崩了怎么办（<15% 四步、暴食后、恐慌熬夜止损），一键进全屏急救模式
//   治疗：把电量补回来（恢复手段按「当前电量 + 可用时间」推荐，记录实际恢复量）
//   分级：不同电量档位下，哪些娱乐允许、哪些禁止（现在只能做这些）
//
// 顶部常驻「前额叶电量」血条，是整页的仪表；所有记录落到 medical_logs / medical_events，
// 既能回看趋势，也把 now / min / 急救次数写进 ui_states 供帝国页读取。

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:sqflite/sqflite.dart';

// ==================== 常量与纯函数 ====================

const Color kMedInk = Color(0xFF1E293B);
const Color kMedSub = Color(0xFF64748B);
const Color kMedLine = Color(0xFFE2E8F0);
const Color kMedAccent = Color(0xFFB91C1C); // 医疗用暗红，和规划/文化区分
const Color kMedSoft = Color(0xFFFEF2F2);

/// 电量四档：1 满血 / 2 尚可 / 3 吃紧 / 4 见底。
int medicalTierOf(int battery) {
  if (battery >= 60) return 1;
  if (battery >= 30) return 2;
  if (battery >= 15) return 3;
  return 4;
}

Color medicalBatteryColor(int battery) {
  if (battery >= 60) return const Color(0xFF0E7490);
  if (battery >= 30) return const Color(0xFFD97706);
  if (battery >= 15) return const Color(0xFFEA580C);
  return const Color(0xFFDC2626);
}

String medicalTierName(int tier) {
  switch (tier) {
    case 1:
      return '绿灯区';
    case 2:
      return '黄灯区';
    case 3:
      return '橙灯区';
    default:
      return '红灯区';
  }
}

/// 电量文案：不评价人，只说状态和下一步。
String medicalBatteryHint(int battery) {
  if (battery >= 60) return '血条充足，可以碰难一点的事';
  if (battery >= 30) return '还能推，但别再开新坑';
  if (battery >= 15) return '开始省电：只做已经排好的事';
  return '见底了：放空，只执行最低限度日程';
}

/// 恢复手段的推荐分：预计恢复高、耗时短、门槛低者优先。
/// 电量见底时只推 10 分钟内、能躺着做的。
double medicalTreatScore(Map plan, int battery) {
  final gain = (plan['gain'] as num?)?.toInt() ?? 10;
  final minutes = (plan['minutes'] as num?)?.toInt() ?? 15;
  var score = gain - minutes * 0.25;
  if (battery < 15) score += minutes <= 10 ? 8 : -12;
  if (battery < 30) score += minutes <= 20 ? 3 : -3;
  return score;
}

List<Map> medicalSortTreats(List plans, int battery) {
  final list = plans
      .map((e) => Map<String, dynamic>.from(e as Map))
      .where((e) => (e['active'] as num?)?.toInt() != 0)
      .toList();
  list.sort((a, b) => medicalTreatScore(b, battery).compareTo(medicalTreatScore(a, battery)));
  return list;
}

/// 当前电量落在哪一档，用来在分级表里标「你在这里」。
Map? medicalCurrentGrade(List grades, int battery) {
  for (final g in grades) {
    final lo = (g['min_b'] as num?)?.toInt() ?? 0;
    final hi = (g['max_b'] as num?)?.toInt() ?? 100;
    if (battery >= lo && battery <= hi) return Map<String, dynamic>.from(g as Map);
  }
  return null;
}

/// 一行一条：把多行文本拆成步骤，空行丢掉。
List<String> medicalSplitLines(String raw) => raw
    .split(RegExp(r'\r?\n'))
    .map((e) => e.replaceFirst(RegExp(r'^\s*[-·•]\s*'), '').trim())
    .where((e) => e.isNotEmpty)
    .toList();

// ---------- 内置预案 ----------

const List<Map<String, dynamic>> kMedicalBuiltinPlans = [
  // 预防
  {
    'kind': 'prevent',
    'title': '防止前额叶电量过低',
    'trigger': '连续开会 / 刷手机 2 小时后，注意力开始飘、看同一行字三遍',
    'steps': ['离开屏幕 5 分钟，站起来', '喝水，顺便走到窗边', '把下一件事降级成一个最小动作'],
    'tier': 0,
  },
  {
    'kind': 'prevent',
    'title': '防止暴饮暴食',
    'trigger': '下午 4 点后情绪发空，开始想点外卖 / 找甜的',
    'steps': ['先喝 300ml 水，等 5 分钟', '补一份蛋白或坚果', '等 15 分钟再决定要不要点'],
    'tier': 0,
  },
  {
    'kind': 'prevent',
    'title': '防止恐慌式学习 / 做事',
    'trigger': '同时打开一堆资料，心跳加快，越看越慌',
    'steps': ['只留一个文件 / 一个页面', '设 15 分钟计时，只做这一件', '先写一行输出，哪怕很烂'],
    'tier': 0,
  },
  // 急救
  {
    'kind': 'emergency',
    'title': '电量低于 15% 的急救',
    'trigger': '血条 <15%，脑子转不动、想发火、想刷到天亮',
    'steps': [
      '放空大脑：躺下或靠着，什么都不想',
      '放弃任何高耗能娱乐：短视频、游戏、争论都停',
      '不要提出什么提议，也别做任何决定',
      '仅默默执行打了「最低限度」标签的日程，维持秩序稳定',
    ],
    'tier': 4,
  },
  {
    'kind': 'emergency',
    'title': '暴饮暴食后的止损',
    'trigger': '已经吃超了，开始自责、想催吐或继续吃',
    'steps': ['先停止自责，这是一次事件不是人格', '散步 10 分钟，别躺下', '喝水，不加餐也不催吐', '在医疗页记一次，明天照常吃'],
    'tier': 0,
  },
  {
    'kind': 'emergency',
    'title': '恐慌式学习 / 熬夜的紧急止损',
    'trigger': '已经陷进去了：越学越慌，或已经熬过 1 点',
    'steps': ['立刻停，合上电脑 / 锁屏', '洗漱，把手机放到够不到的地方', '上床，允许自己今天没做完', '明天只补一件最重要的事'],
    'tier': 0,
  },
  // 治疗
  {'kind': 'treat', 'title': '闭眼放空', 'trigger': '', 'steps': [], 'minutes': 10, 'gain': 10, 'tier': 0},
  {'kind': 'treat', 'title': '户外快走', 'trigger': '', 'steps': [], 'minutes': 20, 'gain': 20, 'tier': 0},
  {'kind': 'treat', 'title': '力量训练', 'trigger': '', 'steps': [], 'minutes': 30, 'gain': 25, 'tier': 0},
  {'kind': 'treat', 'title': '晒太阳', 'trigger': '', 'steps': [], 'minutes': 15, 'gain': 12, 'tier': 0},
  {'kind': 'treat', 'title': '冷水洗脸 / 冲个澡', 'trigger': '', 'steps': [], 'minutes': 5, 'gain': 8, 'tier': 0},
  {'kind': 'treat', 'title': '23:00 前上床', 'trigger': '', 'steps': [], 'minutes': 30, 'gain': 30, 'tier': 0},
  {'kind': 'treat', 'title': '和人聊 15 分钟（不谈工作）', 'trigger': '', 'steps': [], 'minutes': 15, 'gain': 15, 'tier': 0},
  {'kind': 'treat', 'title': '断网 30 分钟', 'trigger': '', 'steps': [], 'minutes': 30, 'gain': 15, 'tier': 0},
];

const List<Map<String, dynamic>> kMedicalBuiltinGrades = [
  {
    'tier': 1,
    'name': '绿灯区',
    'min_b': 60,
    'max_b': 100,
    'allow': '长视频 / 游戏 / 深度学习 / 正经社交',
    'forbid': '别熬过 12 点（这条永远生效）',
    'note': '血条够，难的事放这一档做',
  },
  {
    'tier': 2,
    'name': '黄灯区',
    'min_b': 30,
    'max_b': 59,
    'allow': '短内容 / 轻运动 / 整理桌面',
    'forbid': '开新坑 / 做重大决定 / 吵架',
    'note': '还能推，但别加负载',
  },
  {
    'tier': 3,
    'name': '橙灯区',
    'min_b': 15,
    'max_b': 29,
    'allow': '音乐 / 散步 / 洗澡 / 发呆',
    'forbid': '短视频 / 游戏 / 学习 / 刷购物',
    'note': '省电模式，只维持秩序',
  },
  {
    'tier': 4,
    'name': '红灯区',
    'min_b': 0,
    'max_b': 14,
    'allow': '躺下 / 闭眼 / 喝水 / 洗漱',
    'forbid': '一切屏幕 / 任何提议 / 任何决策',
    'note': '只执行最低限度日程',
  },
];

// ==================== 数据访问 ====================

class MedicalDb {
  static Future<String?> _getState(Database db, String key) async {
    try {
      final rows = await db.query('ui_states', where: 'state_key = ?', whereArgs: [key]);
      if (rows.isNotEmpty) return rows.first['state_val'] as String;
    } catch (_) {}
    return null;
  }

  static Future<void> _setState(Database db, String key, String val) async {
    try {
      await db.insert('ui_states', {'state_key': key, 'state_val': val},
          conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {}
  }

  static Future<void> ensureTables(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS medical_plans ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        "kind TEXT NOT NULL, "
        "title TEXT NOT NULL, "
        "trigger TEXT DEFAULT '', "
        "steps TEXT DEFAULT '', "
        "note TEXT DEFAULT '', "
        'tier INTEGER DEFAULT 0, '
        'minutes INTEGER DEFAULT 0, '
        'gain INTEGER DEFAULT 0, '
        'sort_order INTEGER DEFAULT 0, '
        'active INTEGER DEFAULT 1, '
        'builtin INTEGER DEFAULT 0, '
        'created_at TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS medical_grades ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'tier INTEGER NOT NULL, '
        "name TEXT NOT NULL, "
        'min_b INTEGER DEFAULT 0, '
        'max_b INTEGER DEFAULT 100, '
        "allow TEXT DEFAULT '', "
        "forbid TEXT DEFAULT '', "
        "note TEXT DEFAULT '', "
        'sort_order INTEGER DEFAULT 0)');
    await db.execute('CREATE TABLE IF NOT EXISTS medical_logs ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        "date TEXT NOT NULL, "
        'battery INTEGER NOT NULL, '
        "note TEXT DEFAULT '', "
        'created_at TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS medical_events ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        "date TEXT NOT NULL, "
        "kind TEXT NOT NULL, "
        'plan_id INTEGER DEFAULT 0, '
        'before_b INTEGER DEFAULT 0, '
        'after_b INTEGER DEFAULT 0, '
        "note TEXT DEFAULT '', "
        'created_at TEXT NOT NULL)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_med_logs_date ON medical_logs(date)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_med_events_date ON medical_events(date)');
    await seedBuiltins(db);
  }

  /// 内置只种一次；用户删掉的不再自动复活，可在菜单里「恢复内置」。
  static Future<void> seedBuiltins(Database db) async {
    final seeded = await _getState(db, 'medical_seeded');
    if (seeded == '1') return;
    final now = DateTime.now().toIso8601String();
    for (var i = 0; i < kMedicalBuiltinPlans.length; i++) {
      final p = kMedicalBuiltinPlans[i];
      await db.insert('medical_plans', {
        'kind': p['kind'],
        'title': p['title'],
        'trigger': p['trigger'] ?? '',
        'steps': jsonEncode(p['steps'] ?? []),
        'note': '',
        'tier': p['tier'] ?? 0,
        'minutes': p['minutes'] ?? 0,
        'gain': p['gain'] ?? 0,
        'sort_order': i,
        'active': 1,
        'builtin': 1,
        'created_at': now,
      });
    }
    for (var i = 0; i < kMedicalBuiltinGrades.length; i++) {
      final g = kMedicalBuiltinGrades[i];
      await db.insert('medical_grades', {
        'tier': g['tier'],
        'name': g['name'],
        'min_b': g['min_b'],
        'max_b': g['max_b'],
        'allow': g['allow'],
        'forbid': g['forbid'],
        'note': g['note'],
        'sort_order': i,
      });
    }
    await _setState(db, 'medical_seeded', '1');
  }

  /// 恢复内置预案（不动用户自己加的）。
  static Future<int> restoreBuiltins(Database db) async {
    final now = DateTime.now().toIso8601String();
    final existing = await db.query('medical_plans', where: 'builtin = 1');
    final titles = existing.map((e) => '${e['title']}').toSet();
    var added = 0;
    for (var i = 0; i < kMedicalBuiltinPlans.length; i++) {
      final p = kMedicalBuiltinPlans[i];
      if (titles.contains('${p['title']}')) continue;
      await db.insert('medical_plans', {
        'kind': p['kind'],
        'title': p['title'],
        'trigger': p['trigger'] ?? '',
        'steps': jsonEncode(p['steps'] ?? []),
        'note': '',
        'tier': p['tier'] ?? 0,
        'minutes': p['minutes'] ?? 0,
        'gain': p['gain'] ?? 0,
        'sort_order': 100 + i,
        'active': 1,
        'builtin': 1,
        'created_at': now,
      });
      added++;
    }
    final gradeCount = (await db.query('medical_grades')).length;
    if (gradeCount == 0) {
      for (var i = 0; i < kMedicalBuiltinGrades.length; i++) {
        final g = kMedicalBuiltinGrades[i];
        await db.insert('medical_grades', {
          'tier': g['tier'],
          'name': g['name'],
          'min_b': g['min_b'],
          'max_b': g['max_b'],
          'allow': g['allow'],
          'forbid': g['forbid'],
          'note': g['note'],
          'sort_order': i,
        });
        added++;
      }
    }
    return added;
  }

  static Future<int> addLog(Database db, int battery, {String note = ''}) async {
    final now = DateTime.now();
    return db.insert('medical_logs', {
      'date': DateFormat('yyyy-MM-dd').format(now),
      'battery': battery.clamp(0, 100),
      'note': note,
      'created_at': now.toIso8601String(),
    });
  }

  static Future<int> addEvent(
    Database db, {
    required String kind,
    int planId = 0,
    int beforeB = 0,
    int afterB = 0,
    String note = '',
  }) async {
    final now = DateTime.now();
    return db.insert('medical_events', {
      'date': DateFormat('yyyy-MM-dd').format(now),
      'kind': kind,
      'plan_id': planId,
      'before_b': beforeB,
      'after_b': afterB,
      'note': note,
      'created_at': now.toIso8601String(),
    });
  }

  /// 今日概览：最近一次电量、最低值、各动作次数。
  static Future<Map<String, dynamic>> todayStats(Database db) async {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final logs = await db.query('medical_logs',
        where: 'date = ?', whereArgs: [today], orderBy: 'id DESC');
    final events = await db.query('medical_events', where: 'date = ?', whereArgs: [today]);
    int? now;
    int? minB;
    for (final l in logs) {
      final b = (l['battery'] as num?)?.toInt() ?? 0;
      now ??= b;
      minB = minB == null ? b : math.min(minB, b);
    }
    final preventIds = <int>{};
    var emergency = 0, treat = 0;
    for (final e in events) {
      if (e['kind'] == 'prevent') preventIds.add((e['plan_id'] as num?)?.toInt() ?? 0);
      if (e['kind'] == 'emergency') emergency++;
      if (e['kind'] == 'treat') treat++;
    }
    return {
      'now': now,
      'min': minB,
      'count': logs.length,
      'preventDone': preventIds,
      'emergency': emergency,
      'treat': treat,
      'lastNote': logs.isEmpty ? '' : '${logs.first['note'] ?? ''}',
    };
  }

  /// 最近 7 天每天的最低电量，用于血条下面的小柱图。
  static Future<List<Map>> weeklyMin(Database db) async {
    final out = <Map>[];
    final today = DateTime.now();
    for (var i = 6; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      final key = DateFormat('yyyy-MM-dd').format(d);
      final rows = await db.rawQuery(
          'SELECT MIN(battery) m FROM medical_logs WHERE date = ?', [key]);
      final m = rows.isEmpty ? null : rows.first['m'];
      out.add({'date': key, 'label': DateFormat('MM/dd').format(d), 'min': m});
    }
    return out;
  }

  static Future<void> refreshSignals(Database db) async {
    try {
      final st = await todayStats(db);
      final now = st['now'];
      final m = st['min'];
      await _setState(db, 'medical_battery_now', now == null ? '' : '$now');
      await _setState(db, 'medical_battery_min', m == null ? '' : '$m');
      await _setState(db, 'medical_emergency_today', '${st['emergency']}');
      await _setState(db, 'medical_prevent_today', '${(st['preventDone'] as Set).length}');
      await _setState(db, 'medical_treat_today', '${st['treat']}');
    } catch (_) {}
  }
}

// ==================== 页面 ====================

class MedicalPage extends StatefulWidget {
  final Database db;
  const MedicalPage({super.key, required this.db});
  @override
  State createState() => _MedicalPageState();
}

class _MedicalPageState extends State<MedicalPage> {
  int _tab = 0; // 0 预防 1 急救 2 治疗 3 分级
  List _plans = [];
  List _grades = [];
  List _weekly = [];
  Map<String, dynamic> _stats = {};
  bool _loading = true;

  int get _battery => (_stats['now'] as int?) ?? 50;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future _load() async {
    try {
      final db = widget.db;
      await MedicalDb.seedBuiltins(db);
      final plans = await db.query('medical_plans',
          where: 'active = 1', orderBy: 'sort_order ASC, id ASC');
      final grades =
          await db.query('medical_grades', orderBy: 'sort_order ASC, tier ASC');
      final weekly = await MedicalDb.weeklyMin(db);
      final stats = await MedicalDb.todayStats(db);
      await MedicalDb.refreshSignals(db);
      if (!mounted) return;
      setState(() {
        _plans = plans;
        _grades = grades;
        _weekly = weekly;
        _stats = stats;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List _byKind(String kind) => _plans.where((e) => e['kind'] == kind).toList();

  // ---------- 电量记录 ----------

  Future _recordBattery({int? preset}) async {
    var value = (preset ?? _battery).toDouble().clamp(0, 100).toDouble();
    final noteCtrl = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          ),
          padding: EdgeInsets.fromLTRB(
              18, 14, 18, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('现在还剩多少电',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const Spacer(),
              Text('${value.round()}%',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: medicalBatteryColor(value.round()))),
            ]),
            const SizedBox(height: 6),
            Text(medicalBatteryHint(value.round()),
                style: const TextStyle(fontSize: 11.5, color: kMedSub)),
            const SizedBox(height: 12),
            SliderTheme(
              data: SliderTheme.of(ctx).copyWith(
                trackHeight: 10,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
              ),
              child: Slider(
                value: value,
                min: 0,
                max: 100,
                divisions: 20,
                activeColor: medicalBatteryColor(value.round()),
                label: '${value.round()}%',
                onChanged: (v) => setD(() => value = v),
              ),
            ),
            Row(children: [
              for (final b in [10, 15, 30, 50, 70, 90])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onTap: () => setD(() => value = b.toDouble()),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: value.round() == b
                            ? medicalBatteryColor(b).withOpacity(0.12)
                            : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('$b',
                          style: TextStyle(
                              fontSize: 11.5,
                              color: value.round() == b
                                  ? medicalBatteryColor(b)
                                  : kMedSub,
                              fontWeight: value.round() == b
                                  ? FontWeight.w700
                                  : FontWeight.w400)),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: noteCtrl,
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration(
                hintText: '发生了什么（可选）：开会 3 小时 / 没睡好 / 刚运动完',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: kMedAccent,
                    padding: const EdgeInsets.symmetric(vertical: 12)),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('记下来',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      ),
    );
    if (ok == true) {
      await MedicalDb.addLog(widget.db, value.round(), note: noteCtrl.text.trim());
      await _load();
    }
    noteCtrl.dispose();
    if (ok == true && value.round() < 15 && mounted) {
      _toast('血条见底，建议直接进急救模式', action: '进入急救', onAction: _openWorstEmergency);
    }
  }

  Future _openWorstEmergency() async {
    final list = _byKind('emergency');
    if (list.isEmpty) return;
    final picked = list.firstWhere(
      (e) => ((e['tier'] as num?)?.toInt() ?? 0) == 4,
      orElse: () => list.first,
    );
    _openEmergency(Map<String, dynamic>.from(picked as Map));
  }

  // ---------- 急救 ----------

  Future _openEmergency(Map plan) async {
    final steps = medicalParseSteps(plan['steps'] as String?);
    if (steps.isEmpty) {
      _toast('这条预案还没有步骤，先编辑补上');
      return;
    }
    await MedicalDb.addEvent(widget.db,
        kind: 'emergency',
        planId: plan['id'] as int? ?? 0,
        beforeB: _battery,
        note: '${plan['title']}');
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MedicalEmergencyPage(
        title: '${plan['title']}',
        steps: steps,
        battery: _battery,
      ),
    ));
    _load();
  }

  // ---------- 预防打卡 ----------

  Future _togglePrevent(Map plan, bool done) async {
    final db = widget.db;
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    if (done) {
      await db.delete('medical_events',
          where: 'date = ? AND kind = ? AND plan_id = ?',
          whereArgs: [today, 'prevent', plan['id']]);
    } else {
      await MedicalDb.addEvent(db, kind: 'prevent', planId: plan['id'] as int? ?? 0);
    }
    _load();
  }

  // ---------- 治疗 ----------

  Future _useTreat(Map plan) async {
    var after = math.min(100, _battery + ((plan['gain'] as num?)?.toInt() ?? 10));
    final before = _battery;
    var value = after.toDouble();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('${plan['title']}', style: const TextStyle(fontSize: 16)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('用之前 $before% → 用之后',
                style: const TextStyle(fontSize: 12.5, color: kMedSub)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Slider(
                  value: value,
                  min: 0,
                  max: 100,
                  divisions: 20,
                  activeColor: medicalBatteryColor(value.round()),
                  label: '${value.round()}%',
                  onChanged: (v) => setD(() => value = v),
                ),
              ),
              Text('${value.round()}%',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ]),
            Text(
              (value.round() - before) >= 0
                  ? '实际恢复 +${value.round() - before}%'
                  : '反而掉了 ${value.round() - before}%，记下来，下次别选它',
              style: TextStyle(
                  fontSize: 11.5,
                  color: (value.round() - before) >= 0
                      ? const Color(0xFF15803D)
                      : const Color(0xFFDC2626)),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kMedAccent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('记这次'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await MedicalDb.addLog(widget.db, value.round(), note: '治疗后：${plan['title']}');
      await MedicalDb.addEvent(widget.db,
          kind: 'treat',
          planId: plan['id'] as int? ?? 0,
          beforeB: before,
          afterB: value.round(),
          note: '${plan['title']}');
      await _load();
      if (mounted) _toast('已记录：${plan['title']}');
    }
  }

  // ---------- 预案编辑 ----------

  Future _editPlan({String kind = 'prevent', Map? plan}) async {
    final titleCtrl = TextEditingController(text: '${plan?['title'] ?? ''}');
    final triggerCtrl = TextEditingController(text: '${plan?['trigger'] ?? ''}');
    final stepsCtrl = TextEditingController(
        text: medicalParseSteps(plan?['steps'] as String?).join('\n'));
    var minutes = (plan?['minutes'] as num?)?.toInt() ?? 15;
    var gain = (plan?['gain'] as num?)?.toInt() ?? 15;
    var tier = (plan?['tier'] as num?)?.toInt() ?? 0;
    final isTreat = kind == 'treat';

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          ),
          padding: EdgeInsets.fromLTRB(
              16, 14, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(plan == null ? '新增预案' : '编辑预案',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              TextField(
                controller: titleCtrl,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                    labelText: '名字（动词开头）', isDense: true, border: OutlineInputBorder()),
              ),
              if (!isTreat) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: triggerCtrl,
                  minLines: 1,
                  maxLines: 3,
                  style: const TextStyle(fontSize: 12.5),
                  decoration: const InputDecoration(
                      labelText: '触发信号：怎么知道它要来了',
                      isDense: true,
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: stepsCtrl,
                  minLines: 3,
                  maxLines: 8,
                  style: const TextStyle(fontSize: 12.5, height: 1.5),
                  decoration: const InputDecoration(
                      labelText: '步骤（一行一条）',
                      hintText: '离开屏幕 5 分钟\n喝水\n把下一件事降级',
                      isDense: true,
                      border: OutlineInputBorder()),
                ),
              ],
              if (isTreat) ...[
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: Text('耗时 $minutes 分钟',
                        style: const TextStyle(fontSize: 12.5, color: kMedSub)),
                  ),
                  Expanded(
                    child: Slider(
                      value: minutes.toDouble(),
                      min: 5,
                      max: 60,
                      divisions: 11,
                      activeColor: kMedAccent,
                      label: '$minutes',
                      onChanged: (v) => setD(() => minutes = v.round()),
                    ),
                  ),
                ]),
                Row(children: [
                  Expanded(
                    child: Text('预计恢复 +$gain%',
                        style: const TextStyle(fontSize: 12.5, color: kMedSub)),
                  ),
                  Expanded(
                    child: Slider(
                      value: gain.toDouble(),
                      min: 5,
                      max: 40,
                      divisions: 7,
                      activeColor: kMedAccent,
                      label: '$gain',
                      onChanged: (v) => setD(() => gain = v.round()),
                    ),
                  ),
                ]),
              ],
              if (kind == 'emergency') ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Text('生效档位', style: TextStyle(fontSize: 12, color: kMedSub)),
                  const SizedBox(width: 10),
                  DropdownButton<int>(
                    value: tier,
                    isDense: true,
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('任何电量', style: TextStyle(fontSize: 12))),
                      DropdownMenuItem(value: 4, child: Text('仅 <15%', style: TextStyle(fontSize: 12))),
                    ],
                    onChanged: (v) => setD(() => tier = v ?? 0),
                  ),
                ]),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: kMedAccent,
                      padding: const EdgeInsets.symmetric(vertical: 12)),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('保存',
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    if (ok != true) return;
    if (titleCtrl.text.trim().isEmpty) {
      _toast('名字不能为空');
      return;
    }
    final data = {
      'kind': kind,
      'title': titleCtrl.text.trim(),
      'trigger': triggerCtrl.text.trim(),
      'steps': jsonEncode(medicalSplitLines(stepsCtrl.text)),
      'tier': tier,
      'minutes': minutes,
      'gain': gain,
      'active': 1,
      'builtin': plan?['builtin'] ?? 0,
    };
    if (plan == null) {
      data['sort_order'] = 200 + _plans.length;
      data['created_at'] = DateTime.now().toIso8601String();
      await widget.db.insert('medical_plans', data);
    } else {
      await widget.db.update('medical_plans', data,
          where: 'id = ?', whereArgs: [plan['id']]);
    }
    _load();
  }

  Future _deletePlan(Map plan) async {
    final ok = await _confirm('删除这条预案？', '「${plan['title']}」会被移除，历史记录保留。');
    if (!ok) return;
    final db = widget.db;
    if ((plan['builtin'] as num?)?.toInt() == 1) {
      // 内置的只停用，方便「恢复内置」找回
      await db.update('medical_plans', {'active': 0},
          where: 'id = ?', whereArgs: [plan['id']]);
    } else {
      await db.delete('medical_plans', where: 'id = ?', whereArgs: [plan['id']]);
    }
    _load();
  }

  Future _editGrade(Map g) async {
    final allowCtrl = TextEditingController(text: '${g['allow'] ?? ''}');
    final forbidCtrl = TextEditingController(text: '${g['forbid'] ?? ''}');
    final noteCtrl = TextEditingController(text: '${g['note'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${g['name']} · ${g['min_b']}–${g['max_b']}%',
            style: const TextStyle(fontSize: 15)),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: allowCtrl,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration(
                  labelText: '允许做什么（顿号或换行分隔）',
                  isDense: true,
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: forbidCtrl,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration(
                  labelText: '禁止做什么',
                  isDense: true,
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: noteCtrl,
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration(
                  labelText: '一句话说明', isDense: true, border: OutlineInputBorder()),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kMedAccent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok == true) {
      await widget.db.update(
        'medical_grades',
        {
          'allow': allowCtrl.text.trim(),
          'forbid': forbidCtrl.text.trim(),
          'note': noteCtrl.text.trim(),
        },
        where: 'id = ?',
        whereArgs: [g['id']],
      );
      _load();
    }
    allowCtrl.dispose();
    forbidCtrl.dispose();
    noteCtrl.dispose();
  }

  // ---------- 界面 ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        toolbarHeight: 50,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        titleSpacing: 16,
        title: Row(children: [
          const Text('🩺 医疗',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
                color: kMedSoft, borderRadius: BorderRadius.circular(6)),
            child: Text(
              _stats['now'] == null ? '未记录电量' : '血条 ${_stats['now']}%',
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: _stats['now'] == null
                      ? kMedSub
                      : medicalBatteryColor(_stats['now'] as int)),
            ),
          ),
        ]),
        actions: [
          IconButton(
            tooltip: '记录电量',
            icon: const Icon(Icons.battery_charging_full, size: 21),
            onPressed: () => _recordBattery(),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'plan') _editPlan(kind: _tab == 3 ? 'prevent' : _byKindName(_tab));
              if (v == 'restore') {
                final n = await MedicalDb.restoreBuiltins(widget.db);
                _load();
                _toast(n == 0 ? '内置预案都在' : '已恢复 $n 条内置预案');
              }
              if (v == 'help') _showHelp();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'plan', child: Text('新增预案', style: TextStyle(fontSize: 13))),
              const PopupMenuItem(
                  value: 'restore', child: Text('恢复内置预案', style: TextStyle(fontSize: 13))),
              const PopupMenuItem(
                  value: 'help', child: Text('这一页怎么用', style: TextStyle(fontSize: 13))),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              _batteryCard(),
              _tabBar(),
              Expanded(child: _body()),
            ]),
      floatingActionButton: _tab == 3
          ? null
          : FloatingActionButton.extended(
              backgroundColor: kMedAccent,
              onPressed: () {
                if (_tab == 1) {
                  _openWorstEmergency();
                } else if (_tab == 2) {
                  _editPlan(kind: 'treat');
                } else {
                  _editPlan(kind: 'prevent');
                }
              },
              icon: Icon(_tab == 1 ? Icons.emergency : Icons.add, size: 18),
              label: Text(_tab == 1 ? '急救' : (_tab == 2 ? '加一种恢复' : '加一条预防'),
                  style: const TextStyle(fontSize: 12.5)),
            ),
    );
  }

  String _byKindName(int tab) {
    switch (tab) {
      case 1:
        return 'emergency';
      case 2:
        return 'treat';
      default:
        return 'prevent';
    }
  }

  Widget _batteryCard() {
    final hasBattery = _stats['now'] != null;
    final b = _battery;
    final color = medicalBatteryColor(b);
    final low = hasBattery && b < 15;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 11),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: low
              ? [const Color(0xFF991B1B), const Color(0xFF7F1D1D)]
              : [Colors.white, const Color(0xFFFCFCFD)],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: low ? const Color(0xFF7F1D1D) : kMedLine),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.battery_charging_full,
              size: 16, color: low ? Colors.white : kMedSub),
          const SizedBox(width: 5),
          Text('前额叶电量',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: low ? Colors.white : kMedSub)),
          const Spacer(),
          if (hasBattery)
            Text('$b%',
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    height: 1,
                    color: low ? Colors.white : color))
          else
            Text('未记录',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: low ? Colors.white70 : kMedSub)),
        ]),
        const SizedBox(height: 9),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: hasBattery ? (b / 100).clamp(0.02, 1.0) : 0.0,
            minHeight: 12,
            backgroundColor: low ? Colors.white24 : const Color(0xFFF1F5F9),
            valueColor: AlwaysStoppedAnimation(low ? Colors.white : color),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: Text(
              hasBattery ? medicalBatteryHint(b) : '先记一次，才有血条可看',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11.5, color: low ? Colors.white70 : kMedSub),
            ),
          ),
          const SizedBox(width: 6),
          _miniStat('今日最低', _stats['min'] == null ? '—' : '${_stats['min']}%', low),
          const SizedBox(width: 10),
          _miniStat('急救', '${_stats['emergency'] ?? 0}', low),
          const SizedBox(width: 10),
          _miniStat('治疗', '${_stats['treat'] ?? 0}', low),
        ]),
        const SizedBox(height: 9),
        Row(children: [
          for (final w in _weekly)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 3),
                child: Column(children: [
                  Container(
                    height: 22,
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      height: w['min'] == null
                          ? 3
                          : math.max(3, ((w['min'] as int) / 100) * 22),
                      decoration: BoxDecoration(
                        color: w['min'] == null
                            ? const Color(0xFFE2E8F0)
                            : medicalBatteryColor(w['min'] as int)
                                .withOpacity(low ? 0.55 : 0.75),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text('${w['label']}'.substring(3),
                      style: TextStyle(
                          fontSize: 8,
                          color: low ? Colors.white54 : const Color(0xFF94A3B8))),
                ]),
              ),
            ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: low ? Colors.white : kMedAccent,
                side: BorderSide(
                    color: low ? Colors.white54 : kMedAccent.withOpacity(0.4)),
                padding: const EdgeInsets.symmetric(vertical: 8),
                minimumSize: const Size(0, 34),
              ),
              onPressed: () => _recordBattery(),
              icon: const Icon(Icons.add, size: 15),
              label: const Text('记录电量', style: TextStyle(fontSize: 12)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: low ? Colors.white : kMedAccent,
                foregroundColor: low ? const Color(0xFF991B1B) : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 8),
                minimumSize: const Size(0, 34),
              ),
              onPressed: () {
                if (low) {
                  _openWorstEmergency();
                } else {
                  setState(() => _tab = 3);
                }
              },
              icon: Icon(low ? Icons.emergency : Icons.tune, size: 15),
              label: Text(low ? '进入急救' : '现在该做什么',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _miniStat(String label, String value, bool low) {
    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text(value,
          style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: low ? Colors.white : kMedInk)),
      Text(label,
          style: TextStyle(
              fontSize: 8.5, color: low ? Colors.white54 : const Color(0xFF94A3B8))),
    ]);
  }

  Widget _tabBar() {
    const labels = ['预防', '急救', '治疗', '分级'];
    const icons = [Icons.shield_outlined, Icons.emergency_outlined, Icons.healing_outlined, Icons.signal_cellular_alt];
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(children: List.generate(labels.length, (i) {
        final on = _tab == i;
        final isEm = i == 1;
        final activeColor = isEm ? const Color(0xFFDC2626) : kMedAccent;
        return Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _tab = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: EdgeInsets.only(right: i == 3 ? 0 : 6),
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: on ? activeColor : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icons[i], size: 15, color: on ? Colors.white : kMedSub),
                const SizedBox(width: 3),
                Text(labels[i],
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: on ? Colors.white : kMedSub)),
              ]),
            ),
          ),
        );
      })),
    );
  }

  Widget _body() {
    switch (_tab) {
      case 0:
        return _preventBody();
      case 1:
        return _emergencyBody();
      case 2:
        return _treatBody();
      default:
        return _gradeBody();
    }
  }

  // ---------- 预防 ----------

  Widget _preventBody() {
    final list = _byKind('prevent');
    final done = (_stats['preventDone'] as Set?) ?? <int>{};
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 90),
      children: [
        _tipCard(
          Icons.shield_outlined,
          '预防的目标不是「忍住」，是提前把场景拆掉',
          '每条预案都有一个触发信号。信号一出现就执行，不等到靠意志力硬扛。'
          '今天做到几条，就在下面点几个勾。',
        ),
        const SizedBox(height: 10),
        if (list.isEmpty) _emptyCard('还没有预防预案', '点右下角「加一条预防」'),
        for (final p in list) _planCard(Map<String, dynamic>.from(p as Map),
            done: done.contains((p['id'] as num?)?.toInt())),
      ],
    );
  }

  // ---------- 急救 ----------

  Widget _emergencyBody() {
    final list = _byKind('emergency');
    final sorted = List<Map<String, dynamic>>.from(
        list.map((e) => Map<String, dynamic>.from(e as Map)));
    sorted.sort((a, b) {
      final ta = (a['tier'] as num?)?.toInt() ?? 0;
      final tb = (b['tier'] as num?)?.toInt() ?? 0;
      if (ta == tb) return 0;
      if (ta == 0) return 1;
      if (tb == 0) return -1;
      return tb - ta;
    });
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 90),
      children: [
        _tipCard(
          Icons.emergency_outlined,
          '已经崩了就别分析，按顺序做完这几步',
          '急救模式会一步一步放大显示，一次只让你看一条，不用做选择。'
          '血条 <15% 时红色那条会排在最前。',
        ),
        const SizedBox(height: 10),
        if (sorted.isEmpty) _emptyCard('还没有急救预案', '点右下角「急救」新增一条'),
        for (final p in sorted) _emergencyCard(p),
      ],
    );
  }

  Widget _emergencyCard(Map<String, dynamic> plan) {
    final steps = medicalParseSteps(plan['steps'] as String?);
    final tier = (plan['tier'] as num?)?.toInt() ?? 0;
    final critical = tier == 4;
    final active = !critical || _battery < 15;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: critical && _battery < 15
                ? const Color(0xFFFCA5A5)
                : kMedLine),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(13, 11, 8, 4),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: critical
                    ? const Color(0xFFDC2626).withOpacity(0.1)
                    : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(critical ? '血条 <15%' : '任何时候',
                  style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: critical ? const Color(0xFFDC2626) : kMedSub)),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text('${plan['title']}',
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w700, color: kMedInk)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.more_horiz, size: 18, color: kMedSub),
              onPressed: () => _planMenu(plan, 'emergency'),
            ),
          ]),
        ),
        if ('${plan['trigger'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 0, 13, 6),
            child: Text('触发：${plan['trigger']}',
                style: const TextStyle(fontSize: 11, height: 1.5, color: kMedSub)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(13, 0, 13, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < steps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${i + 1}.',
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF94A3B8))),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(steps[i],
                          style: const TextStyle(
                              fontSize: 12, height: 1.5, color: kMedInk)),
                    ),
                  ]),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(13, 2, 13, 11),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: critical ? const Color(0xFFDC2626) : kMedAccent,
                padding: const EdgeInsets.symmetric(vertical: 9),
                minimumSize: const Size(0, 36),
              ),
              onPressed: active ? () => _openEmergency(plan) : null,
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(
                active ? '现在启动（${steps.length} 步）' : '血条 ≥15% 时不需要它',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  // ---------- 治疗 ----------

  Widget _treatBody() {
    final list = medicalSortTreats(_byKind('treat'), _battery);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 90),
      children: [
        _tipCard(
          Icons.healing_outlined,
          '先补电，再谈效率',
          _battery < 30
              ? '现在 ${_battery}%，只推 20 分钟以内、门槛低的。用完顺手记一下实际恢复多少，以后就按你自己的数据排序。'
              : '按「预计恢复 ÷ 耗时」排的。实际恢复比预计更重要，记两次就能看出哪种对你真有用。',
        ),
        const SizedBox(height: 10),
        if (list.isEmpty) _emptyCard('还没有恢复手段', '点右下角「加一种恢复」'),
        for (final p in list) _treatCard(Map<String, dynamic>.from(p)),
      ],
    );
  }

  Widget _treatCard(Map<String, dynamic> plan) {
    final gain = (plan['gain'] as num?)?.toInt() ?? 10;
    final minutes = (plan['minutes'] as num?)?.toInt() ?? 15;
    final quick = minutes <= 15;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(13, 10, 8, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: kMedLine),
      ),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
              color: const Color(0xFFF0FDF4), borderRadius: BorderRadius.circular(9)),
          child: const Icon(Icons.eco_outlined, size: 18, color: Color(0xFF15803D)),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${plan['title']}',
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600, color: kMedInk)),
            const SizedBox(height: 3),
            Row(children: [
              _pill('+$gain%', const Color(0xFF15803D)),
              const SizedBox(width: 5),
              _pill('$minutes 分钟', kMedSub),
              if (quick) ...[
                const SizedBox(width: 5),
                _pill('现在能做', const Color(0xFFD97706)),
              ],
            ]),
          ]),
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: kMedAccent,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: () => _useTreat(plan),
          child: const Text('用了', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }

  // ---------- 分级 ----------

  Widget _gradeBody() {
    final current = medicalCurrentGrade(_grades, _battery);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 90),
      children: [
        _tipCard(
          Icons.signal_cellular_alt,
          '不是所有娱乐都适合所有电量',
          '同一件事，满血时是放松，见底时是透支。先看自己在哪一档，再看这一档允许什么。',
        ),
        const SizedBox(height: 10),
        for (final g in _grades)
          _gradeCard(Map<String, dynamic>.from(g as Map),
              isCurrent: current != null && current['id'] == g['id']),
      ],
    );
  }

  Widget _gradeCard(Map<String, dynamic> g, {required bool isCurrent}) {
    final color = medicalBatteryColor(((g['max_b'] as num?)?.toInt() ?? 100));
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isCurrent ? color.withOpacity(0.05) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isCurrent ? color.withOpacity(0.5) : kMedLine,
            width: isCurrent ? 1.4 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(13, 10, 6, 2),
          child: Row(children: [
            Container(width: 8, height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 7),
            Text('${g['name']}',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: kMedInk)),
            const SizedBox(width: 6),
            Text('${g['min_b']}–${g['max_b']}%',
                style: const TextStyle(fontSize: 11, color: kMedSub)),
            if (isCurrent) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                    color: color, borderRadius: BorderRadius.circular(4)),
                child: const Text('你在这里',
                    style: TextStyle(
                        fontSize: 9, color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ],
            const Spacer(),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.edit_outlined, size: 16, color: kMedSub),
              onPressed: () => _editGrade(g),
            ),
          ]),
        ),
        if ('${g['note'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 13, 4),
            child: Text('${g['note']}',
                style: const TextStyle(fontSize: 10.5, color: kMedSub)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(13, 4, 13, 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.check_circle_outline, size: 14, color: Color(0xFF15803D)),
            const SizedBox(width: 6),
            Expanded(
              child: Text('可以：${g['allow'] ?? '—'}',
                  style: const TextStyle(fontSize: 11.5, height: 1.55, color: kMedInk)),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(13, 0, 13, 11),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.block, size: 14, color: Color(0xFFDC2626)),
            const SizedBox(width: 6),
            Expanded(
              child: Text('别碰：${g['forbid'] ?? '—'}',
                  style: const TextStyle(fontSize: 11.5, height: 1.55, color: kMedInk)),
            ),
          ]),
        ),
      ]),
    );
  }

  // ---------- 通用组件 ----------

  Widget _planCard(Map<String, dynamic> plan, {required bool done}) {
    final steps = medicalParseSteps(plan['steps'] as String?);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: done ? const Color(0xFFBBF7D0) : kMedLine),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(13, 11, 6, 2),
          child: Row(children: [
            Expanded(
              child: Text('${plan['title']}',
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w700, color: kMedInk)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.more_horiz, size: 18, color: kMedSub),
              onPressed: () => _planMenu(plan, 'prevent'),
            ),
          ]),
        ),
        if ('${plan['trigger'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 0, 13, 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                  color: const Color(0xFFFFFBEB),
                  borderRadius: BorderRadius.circular(6)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.bolt, size: 13, color: Color(0xFFD97706)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text('${plan['trigger']}',
                      style: const TextStyle(
                          fontSize: 10.5, height: 1.5, color: Color(0xFF92400E))),
                ),
              ]),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(13, 2, 13, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final s in steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 5, right: 6),
                    child: Icon(Icons.circle, size: 5, color: Color(0xFF94A3B8)),
                  ),
                  Expanded(
                    child: Text(s,
                        style: const TextStyle(fontSize: 12, height: 1.5, color: kMedInk)),
                  ),
                ]),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
          child: Row(children: [
            Expanded(
              child: Text(
                done ? '今天已经做过一次' : '信号出现时就做，别等意志力',
                style: TextStyle(
                    fontSize: 10.5,
                    color: done ? const Color(0xFF15803D) : const Color(0xFF94A3B8)),
              ),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: done ? const Color(0xFF15803D) : kMedAccent,
                padding: const EdgeInsets.symmetric(horizontal: 9),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => _togglePrevent(plan, done),
              icon: Icon(done ? Icons.check_circle : Icons.check_circle_outline,
                  size: 16),
              label: Text(done ? '已做到' : '今天做到',
                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _tipCard(IconData icon, String title, String body) {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
      decoration: BoxDecoration(
        color: kMedSoft,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0xFFFEE2E2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 15, color: kMedAccent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF7F1D1D))),
          ),
        ]),
        const SizedBox(height: 5),
        Text(body,
            style: const TextStyle(fontSize: 11, height: 1.6, color: Color(0xFF9F1239))),
      ]),
    );
  }

  Widget _emptyCard(String title, String action) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kMedLine),
      ),
      child: Column(children: [
        const Icon(Icons.medical_information_outlined, size: 34, color: Color(0xFFCBD5E1)),
        const SizedBox(height: 8),
        Text(title,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: kMedSub)),
        const SizedBox(height: 4),
        Text(action, style: const TextStyle(fontSize: 10.5, color: Color(0xFF94A3B8))),
      ]),
    );
  }

  Widget _pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
          color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
      child: Text(text,
          style: TextStyle(fontSize: 9.5, color: color, fontWeight: FontWeight.w700)),
    );
  }

  Future _planMenu(Map plan, String kind) async {
    final act = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text('${plan['title']}',
                  maxLines: 2,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: kMedSub)),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.edit_outlined, size: 19),
              title: const Text('编辑', style: TextStyle(fontSize: 13)),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.delete_outline, size: 19, color: Color(0xFFDC2626)),
              title: const Text('删除',
                  style: TextStyle(fontSize: 13, color: Color(0xFFDC2626))),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
    if (act == 'edit') _editPlan(kind: kind, plan: plan);
    if (act == 'delete') _deletePlan(plan);
  }

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: Text(body, style: const TextStyle(fontSize: 13, height: 1.6)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return r == true;
  }

  void _toast(String msg, {String? action, VoidCallback? onAction}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 12.5)),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
      action: action == null
          ? null
          : SnackBarAction(
              label: action,
              textColor: Colors.white,
              onPressed: onAction ?? () {},
            ),
    ));
  }

  void _showHelp() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: const [
              Text('医疗这一栏在解决什么',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              SizedBox(height: 12),
              _MedHelpLine('预防', '在电量掉下去之前拦一道。每条都有触发信号，信号出现就执行，不靠意志力。'),
              _MedHelpLine('急救', '已经崩了就别分析。全屏一步一步走，一次只看一条，不用做选择。'),
              _MedHelpLine('治疗', '把电量补回来。按当前电量推荐，记录实际恢复量，慢慢形成你自己的排序。'),
              _MedHelpLine('分级', '不同电量档位，哪些娱乐允许、哪些禁止。先看自己在哪一档。'),
              SizedBox(height: 4),
              Text('顶部血条可以随时记录；低于 15% 会变红并直接给急救入口。',
                  style: TextStyle(fontSize: 11.5, height: 1.6, color: kMedSub)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _MedHelpLine extends StatelessWidget {
  final String title;
  final String body;
  const _MedHelpLine(this.title, this.body);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w700, color: kMedAccent)),
        const SizedBox(height: 2),
        Text(body, style: const TextStyle(fontSize: 11.5, height: 1.6, color: kMedSub)),
      ]),
    );
  }
}

// ==================== 急救模式（全屏） ====================

/// 一次只显示一步，只有一个「下一步」按钮。
/// 目的：把决策次数降到 0，让电量见底时也能执行。
class MedicalEmergencyPage extends StatefulWidget {
  final String title;
  final List<String> steps;
  final int battery;
  const MedicalEmergencyPage({
    super.key,
    required this.title,
    required this.steps,
    required this.battery,
  });
  @override
  State createState() => _MedicalEmergencyPageState();
}

class _MedicalEmergencyPageState extends State<MedicalEmergencyPage> {
  int _step = 0;

  @override
  Widget build(BuildContext context) {
    final total = widget.steps.length;
    final last = _step >= total - 1;
    return Scaffold(
      backgroundColor: const Color(0xFF7F1D1D),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.emergency, color: Colors.white, size: 20),
              const SizedBox(width: 7),
              const Text('急救模式',
                  style: TextStyle(
                      fontSize: 13, color: Colors.white70, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('${_step + 1} / $total',
                  style: const TextStyle(fontSize: 12.5, color: Colors.white70)),
              const SizedBox(width: 10),
              TextButton(
                onPressed: () => Navigator.pop(context),
                style: TextButton.styleFrom(foregroundColor: Colors.white70),
                child: const Text('退出', style: TextStyle(fontSize: 12)),
              ),
            ]),
            const SizedBox(height: 8),
            Text(widget.title,
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w800, color: Colors.white)),
            const SizedBox(height: 4),
            Text('当前血条 ${widget.battery}% · 不用想，按顺序做',
                style: const TextStyle(fontSize: 11.5, color: Colors.white54)),
            Expanded(
              child: Center(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(20, 26, 20, 26),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text('${_step + 1}',
                        style: const TextStyle(
                            fontSize: 44,
                            fontWeight: FontWeight.w800,
                            color: Colors.white24,
                            height: 1)),
                    const SizedBox(height: 12),
                    Text(
                      widget.steps[_step],
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 21, height: 1.5, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF7F1D1D),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  if (last) {
                    Navigator.pop(context);
                  } else {
                    setState(() => _step++);
                  }
                },
                child: Text(last ? '做完了，回到最低日程' : '下一步',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                '现在不做任何决定，也不回任何消息',
                style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.45)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ==================== 步骤解析 ====================

List<String> medicalParseSteps(String? raw) {
  if (raw == null || raw.trim().isEmpty) return [];
  try {
    final d = jsonDecode(raw);
    if (d is List) {
      return d.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList();
    }
  } catch (_) {}
  return medicalSplitLines(raw);
}
