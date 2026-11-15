// 帝国模块 · 数据与推演引擎
//
// 口径（与报告一致）：
//   每日基础流量 BASE = 500，乘数在突破当日生效，此后所有产出都乘以当前连乘。
//   繁荣度 = Σ(每日基础流量 × 当日乘数)，按 3650 天（十年）推演。
//   战略聚焦维度总乘数 = 该维度下所有「已突破」下一步的乘数逐个相乘。
//   「下一步」才是被突破的对象，维度本身只是归类别。
import 'dart:convert';
import 'dart:math' as math;

import 'empire_assets.dart';

const double kEmpireBase = 500.0;
const int kEmpireHorizon = 3650;

/// 九级领地：门槛按 ×5 递增（与十年推演同一套尺子）
const List<List<dynamic>> kEmpireLevels = [
  [1, '破败营地', 1000.0],
  [2, '边境村落', 5000.0],
  [3, '坚固小镇', 25000.0],
  [4, '繁华城邦', 125000.0],
  [5, '巍峨王都', 625000.0],
  [6, '不朽帝国', 3125000.0],
  [7, '天空之城', 15625000.0],
  [8, '神域', 78125000.0],
  [9, '永恒之境', 390625000.0],
];

class EmpireLevel {
  final int index;
  final String name;
  final double threshold;
  const EmpireLevel(this.index, this.name, this.threshold);
}

class EmpireDim {
  final String name;
  final int count;
  final double cum; // 该维度总乘数
  final double avgDelta; // 平均单次增幅 %
  final double share; // 复利份额 %
  final String step; // 最新已突破的下一步
  final String criteria;
  final String date;
  final String multLabel; // ×1.052
  final int day;
  const EmpireDim({
    required this.name,
    required this.count,
    required this.cum,
    required this.avgDelta,
    required this.share,
    required this.step,
    required this.criteria,
    required this.date,
    required this.multLabel,
    required this.day,
  });
}

class EmpireEvent {
  final int day;
  final String kind; // tech / level / war / chaos / rest / turn
  final String title;
  final String value;
  const EmpireEvent(this.day, this.kind, this.title, this.value);
}

class EmpireMilestone {
  final int level;
  final int day; // 0 = 未达成
  const EmpireMilestone(this.level, this.day);
}

/// 一条战略聚焦（对应 focus_items 一行）
class EmpireFocus {
  final int id;
  final String date; // yyyy-MM-dd
  final String dim; // 聚焦维度（原 title 字段）
  final String step; // 下一步（原 next_step 字段）
  final String criteria;
  final double mult;
  final bool done;
  const EmpireFocus({
    required this.id,
    required this.date,
    required this.dim,
    required this.step,
    required this.criteria,
    required this.mult,
    required this.done,
  });

  static EmpireFocus fromRow(Map row) {
    final String d = '${row['title'] ?? ''}'.trim();
    final String s = '${row['next_step'] ?? ''}'.trim();
    return EmpireFocus(
      id: (row['id'] as num?)?.toInt() ?? 0,
      date: '${row['date'] ?? ''}',
      dim: d.isEmpty ? '未分类' : d,
      step: s.isEmpty ? (d.isEmpty ? '未命名' : d) : s,
      criteria: '${row['done_criteria'] ?? ''}',
      mult: (row['multiplier'] as num?)?.toDouble() ?? 1.0,
      done: ((row['done'] as num?)?.toInt() ?? 0) == 1,
    );
  }
}

class EmpireState {
  final List<EmpireLevel> levels;
  final List<EmpireDim> dims;
  final List<EmpireEvent> events;
  final List<double> daily;
  final List<EmpireMilestone> milestones;
  final double composite;
  final int doneCount;
  final int dayNow;
  final double dailyGain;
  final bool demo;
  final String startDate;

  const EmpireState({
    required this.levels,
    required this.dims,
    required this.events,
    required this.daily,
    required this.milestones,
    required this.composite,
    required this.doneCount,
    required this.dayNow,
    required this.dailyGain,
    required this.demo,
    required this.startDate,
  });

  static List<EmpireLevel> _levels() =>
      kEmpireLevels.map((e) => EmpireLevel(e[0] as int, e[1] as String, e[2] as double)).toList();

  double get wealth => daily.isEmpty ? 0 : daily[(dayNow - 1).clamp(0, daily.length - 1)];

  EmpireLevel get level {
    EmpireLevel cur = levels.first;
    for (final l in levels) {
      if (wealth >= l.threshold) cur = l;
    }
    return cur;
  }

  EmpireLevel? get nextLevel {
    for (final l in levels) {
      if (l.index == level.index + 1) return l;
    }
    return null;
  }

  double get progress {
    final n = nextLevel;
    if (n == null) return 1.0;
    return (wealth / n.threshold).clamp(0.0, 1.0);
  }

  double get tenYear => daily.isEmpty ? 0 : daily[daily.length - 1];

  /// 最近三条纪事（新 → 旧）
  List<EmpireEvent> get recent {
    final List<EmpireEvent> copy = List<EmpireEvent>.from(events);
    copy.sort((a, b) => b.day.compareTo(a.day));
    return copy.take(3).toList();
  }

  /// 真实数据：由 focus_items 推演
  static EmpireState build(List<EmpireFocus> rows, DateTime today) {
    final List<EmpireFocus> done = rows.where((r) => r.done).toList()
      ..sort((a, b) {
        final c = a.date.compareTo(b.date);
        return c != 0 ? c : a.id.compareTo(b.id);
      });

    if (done.isEmpty) return const EmpireState.empty();

    final DateTime start = _parseDate(done.first.date) ?? today;
    final List<int> itemDay = [];
    for (final f in done) {
      final DateTime? d = _parseDate(f.date);
      int day = d == null ? 1 : d.difference(start).inDays + 1;
      if (day < 1) day = 1;
      if (day > kEmpireHorizon) day = kEmpireHorizon;
      itemDay.add(day);
    }

    final List<double> daily = List<double>.filled(kEmpireHorizon, 0);
    double wealth = 0;
    double mult = 1.0;
    int cursor = 0;
    for (int day = 1; day <= kEmpireHorizon; day++) {
      while (cursor < done.length && itemDay[cursor] <= day) {
        mult *= done[cursor].mult > 0 ? done[cursor].mult : 1.0;
        cursor++;
      }
      wealth += kEmpireBase * mult;
      daily[day - 1] = wealth;
    }

    int dayNow = today.difference(start).inDays + 1;
    if (dayNow < 1) dayNow = 1;
    if (dayNow > kEmpireHorizon) dayNow = kEmpireHorizon;

    final List<EmpireLevel> levels = _levels();
    final List<EmpireMilestone> miles = [];
    for (final l in levels) {
      int hit = 0;
      for (int i = 0; i < daily.length; i++) {
        if (daily[i] >= l.threshold) {
          hit = i + 1;
          break;
        }
      }
      miles.add(EmpireMilestone(l.index, hit));
    }

    // 维度聚合
    final Map<String, List<EmpireFocus>> groups = {};
    for (final f in done) {
      groups.putIfAbsent(f.dim, () => []).add(f);
    }
    double totalLn = 0;
    final Map<String, double> lnOf = {};
    for (final entry in groups.entries) {
      double cum = 1.0;
      for (final f in entry.value) {
        cum *= f.mult > 0 ? f.mult : 1.0;
      }
      final double ln = cum > 0 ? math.log(cum) : 0;
      lnOf[entry.key] = ln;
      totalLn += ln;
    }

    final List<EmpireDim> dims = [];
    int doneCount = 0;
    double composite = 1.0;
    for (final entry in groups.entries) {
      final List<EmpireFocus> items = entry.value;
      double cum = 1.0;
      double sumDelta = 0;
      for (final f in items) {
        cum *= f.mult > 0 ? f.mult : 1.0;
        sumDelta += (f.mult - 1) * 100;
      }
      composite *= cum;
      doneCount += items.length;
      final EmpireFocus last = items.last;
      final int lastDay = itemDay[done.indexOf(last)] >= 1 ? itemDay[done.indexOf(last)] : 1;
      dims.add(EmpireDim(
        name: entry.key,
        count: items.length,
        cum: cum,
        avgDelta: sumDelta / items.length,
        share: totalLn > 0 ? lnOf[entry.key]! / totalLn * 100 : 0,
        step: last.step,
        criteria: last.criteria,
        date: last.date,
        multLabel: '×${last.mult.toStringAsFixed(3)}',
        day: lastDay,
      ));
    }
    dims.sort((a, b) => b.cum.compareTo(a.cum));

    // 纪事
    final List<EmpireEvent> events = [];
    for (int i = 0; i < done.length; i++) {
      events.add(EmpireEvent(itemDay[i], 'tech', done[i].step, '×${done[i].mult.toStringAsFixed(3)}'));
    }
    for (final m in miles) {
      if (m.day > 0) {
        final l = levels[m.day == 0 ? 0 : m.level - 1];
        events.add(EmpireEvent(m.day, 'level', '晋入 L${m.level} · ${l.name}', 'L${m.level}'));
      }
    }
    events.sort((a, b) => b.day.compareTo(a.day));

    final double gain = dayNow >= 2 ? daily[dayNow - 1] - daily[dayNow - 2] : daily[0];
    return EmpireState(
      levels: levels,
      dims: dims,
      events: events,
      daily: daily,
      milestones: miles,
      composite: composite,
      doneCount: doneCount,
      dayNow: dayNow,
      dailyGain: gain,
      demo: false,
      startDate: '${start.year}-${_two(start.month)}-${_two(start.day)}',
    );
  }

  const EmpireState.empty()
      : levels = const [],
        dims = const [],
        events = const [],
        daily = const [],
        milestones = const [],
        composite = 1,
        doneCount = 0,
        dayNow = 1,
        dailyGain = 0,
        demo = false,
        startDate = '';

  /// 示例数据（本地库还没有「已突破」的下一步时用来撑起界面）
  ///
  /// 数据编在 lib/empire_assets.dart 里，不走 asset bundle —— 构建机上
  /// 少带一个 json 也不会让 APK 打包失败。
  static Future<EmpireState> loadDemo() async {
    final Map m = jsonDecode(kEmpireDemoJson) as Map;
    final List<EmpireLevel> levels = _levels();
    final List<EmpireDim> dims = [];
    for (final d in (m['dims'] as List)) {
      dims.add(EmpireDim(
        name: '${d['name']}',
        count: (d['count'] as num).toInt(),
        cum: (d['cum'] as num).toDouble(),
        avgDelta: (d['avgDelta'] as num).toDouble(),
        share: (d['share'] as num).toDouble(),
        step: '${d['latestStep']}',
        criteria: '${d['latestCriteria']}',
        date: '${d['latestDate']}',
        multLabel: '${d['latestMult']}',
        day: (d['latestDay'] as num).toInt(),
      ));
    }
    final List<double> daily = [];
    for (final v in (m['daily'] as List)) {
      daily.add((v as num).toDouble());
    }
    final List<EmpireMilestone> miles = [];
    for (final x in (m['milestones'] as List)) {
      miles.add(EmpireMilestone((x['level'] as num).toInt(),
          x['day'] == null ? 0 : (x['day'] as num).toInt()));
    }
    final List<EmpireEvent> events = [];
    for (final e in (m['chronicle'] as List)) {
      events.add(EmpireEvent(
          (e['day'] as num).toInt(), '${e['kind']}', '${e['title']}', '${e['value']}'));
    }
    events.sort((a, b) => b.day.compareTo(a.day));
    return EmpireState(
      levels: levels,
      dims: dims,
      events: events,
      daily: daily,
      milestones: miles,
      composite: (m['composite'] as num).toDouble(),
      doneCount: (m['doneCount'] as num).toInt(),
      dayNow: daily.length,
      dailyGain: (m['dailyGain'] as num).toDouble(),
      demo: true,
      startDate: 'D1',
    );
  }

  static DateTime? _parseDate(String s) {
    try {
      final List<String> p = s.split('-');
      if (p.length < 3) return null;
      return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
    } catch (_) {
      return null;
    }
  }

  static String _two(int v) => v < 10 ? '0$v' : '$v';
}

// ==================== 格式化 ====================

String fmtInt(num v) {
  final String s = v.round().abs().toString();
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return (v < 0 ? '-' : '') + b.toString();
}

/// 17409639.4 → 1,741.0
String fmtWan(num v) {
  final double w = v / 1e4;
  final String s = w.toStringAsFixed(1);
  final List<String> p = s.split('.');
  return '${fmtInt(int.parse(p[0]))}.${p[1]}';
}

/// 自动单位：万 / 亿 / 原值
String fmtMoney(num v) {
  final num a = v.abs();
  if (a >= 1e8) return '${(v / 1e8).toStringAsFixed(2)} 亿';
  if (a >= 1e4) return '${fmtWan(v)} 万';
  return fmtInt(v);
}

/// 坐标轴刻度：小值原数，大值万
String fmtAxis(num v, bool wanUnit) {
  if (v.abs() >= 1e8) return '${(v / 1e8).toStringAsFixed(1)} 亿';
  if (wanUnit && v.abs() >= 1e4) return '${fmtInt(v / 1e4)} 万';
  if (!wanUnit && v.abs() >= 1e4) return '${(v / 1e4).toStringAsFixed(1)} 万';
  return fmtInt(v);
}
