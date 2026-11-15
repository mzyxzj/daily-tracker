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

// ============ 繁荣度规则常量（与《帝国规则》一致） ============
/// 战争：当天全部打卡 **或** 按时复盘 → +50
const int kWarGain = 50;

/// 战争加成：打卡与复盘同时完成 → 额外 +100
const int kBothBonus = 100;

/// 科技突破：完成一条战略聚焦 → +500
const int kTechGain = 500;

/// 内政混乱：当天一卡没打 **且** 一条每日状态都没记录 → -100
const int kChaosLoss = 100;

/// 修养生息：两者仅发生其一 → 建设度 -10
const int kRestLoss = 10;

/// 系统修补上限
const int kRepairMax = 5;

/// 一天的原始信号（全部来自「今日」四个模块的真实记录）
///
/// 今日模块 → 帝国模块 的映射：
///   日程打卡 schedule_records → 军队执行力（战争、内政混乱、修养生息）
///   每日状态 status_records   → 秩序（内政混乱、修养生息、按时复盘）
///   战略聚焦 focus_items      → 科技复利（科技突破 + 全局乘数）
class EmpireDay {
  final String date; // yyyy-MM-dd
  final int schedTotal; // 当日日程总数
  final int schedDone; // 当日已打卡数
  final int statusCount; // 当日有效状态记录条数
  final bool reviewDone; // 当日是否复盘
  final int focusCount; // 当日完成的战略聚焦条数
  final double focusMult; // 当日突破的科技乘数连乘
  const EmpireDay({
    required this.date,
    required this.schedTotal,
    required this.schedDone,
    required this.statusCount,
    required this.reviewDone,
    required this.focusCount,
    required this.focusMult,
  });

  /// 当天全部打卡
  bool get allChecked => schedTotal > 0 && schedDone >= schedTotal;

  bool get anyCheck => schedDone > 0;

  bool get anyStatus => statusCount > 0;
}

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

  // ---- 真实数据联动统计（来自「今日」四个模块）----
  final int daysTracked; // 已统计天数
  final int warDays; // 战争（全部打卡 或 按时复盘）天数
  final int chaosDays; // 内政混乱天数
  final int restDays; // 修养生息天数
  final int checkinDays; // 有打卡的天数
  final int statusDays; // 有状态记录的天数
  final int gainTotal; // 累计获取繁荣度
  final int lossTotal; // 累计扣除繁荣度
  final int warGain; // 战争累计获取
  final int techGain; // 科技突破累计获取
  final int chaosLoss; // 内政混乱累计扣除
  final int restLoss; // 修养生息累计扣除
  final int repairUsed; // 系统修补次数 0..5
  final double techMult; // 当前科技复利连乘
  final int focusDone; // 已完成战略聚焦总数

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
    this.daysTracked = 0,
    this.warDays = 0,
    this.chaosDays = 0,
    this.restDays = 0,
    this.checkinDays = 0,
    this.statusDays = 0,
    this.gainTotal = 0,
    this.lossTotal = 0,
    this.warGain = 0,
    this.techGain = 0,
    this.chaosLoss = 0,
    this.restLoss = 0,
    this.repairUsed = 0,
    this.techMult = 1.0,
    this.focusDone = 0,
  });

  /// 打卡率
  double get checkinRate => daysTracked > 0 ? checkinDays / daysTracked : 0;

  /// 状态记录率
  double get statusRate => daysTracked > 0 ? statusDays / daysTracked : 0;

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

  /// 真实数据推演：繁荣度完全由「今日」四个模块的历史记录累加而成。
  ///
  /// 每日结算：
  ///   · 战争      全部打卡 或 按时复盘            +50 × 科技复利
  ///              打卡与复盘同时完成               +100 × 科技复利
  ///   · 科技突破  完成一条战略聚焦                +500 × 科技复利
  ///   · 内政混乱  一卡没打 且 一条状态都没记录     -100 × 科技复利
  ///   · 修养生息  两者仅发生其一                  -10  × 科技复利
  ///   · 繁荣度下限 0
  /// 科技复利按「突破当日生效」逐日连乘，且只乘不加。
  static EmpireState buildReal(
      List<EmpireDay> dayInputs, List<EmpireFocus> focuses, DateTime today) {
    final List<EmpireDay> days = List<EmpireDay>.from(dayInputs);
    if (days.isEmpty) return const EmpireState.empty();
    days.sort((a, b) => a.date.compareTo(b.date));

    final DateTime start = _parseDate(days.first.date) ?? today;
    final List<EmpireFocus> done = focuses.where((r) => r.done).toList()
      ..sort((a, b) {
        final c = a.date.compareTo(b.date);
        return c != 0 ? c : a.id.compareTo(b.id);
      });

    // 每条突破落在第几天（供维度/纪事用）
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
    int warDays = 0, chaosDays = 0, restDays = 0;
    int checkinDays = 0, statusDays = 0;
    int gainTotal = 0, lossTotal = 0;
    int warTotalGain = 0, techTotalGain = 0;
    int chaosTotalLoss = 0, restTotalLoss = 0;
    int lastIdx = 0;
    final List<EmpireEvent> events = [];

    for (final d in days) {
      final DateTime? dd = _parseDate(d.date);
      int idx = dd == null ? lastIdx : dd.difference(start).inDays;
      if (idx < 0) idx = 0;
      if (idx >= kEmpireHorizon) idx = kEmpireHorizon - 1;
      // 缺口填平（理论上日期连续，这里防御）
      for (int k = lastIdx + 1; k < idx; k++) {
        daily[k] = wealth;
      }

      // 科技复利：突破当日生效
      if (d.focusCount > 0 && d.focusMult > 1.0) mult *= d.focusMult;

      final bool allChecked = d.allChecked;
      final bool review = d.reviewDone;
      final bool anyCheck = d.anyCheck;
      final bool anyStatus = d.anyStatus;

      double g = 0;
      if (allChecked || review) {
        final int v = (kWarGain * mult).round();
        g += v;
        warTotalGain += v;
        warDays++;
      }
      if (allChecked && review) {
        final int v = (kBothBonus * mult).round();
        g += v;
        warTotalGain += v;
      }
      if (d.focusCount > 0) {
        final int v = (kTechGain * d.focusCount * mult).round();
        g += v;
        techTotalGain += v;
      }

      if (!anyCheck && !anyStatus) {
        final int v = (kChaosLoss * mult).round();
        g -= v;
        chaosTotalLoss += v;
        chaosDays++;
      } else if (!anyCheck || !anyStatus) {
        final int v = (kRestLoss * mult).round();
        g -= v;
        restTotalLoss += v;
        restDays++;
      }
      if (anyCheck) checkinDays++;
      if (anyStatus) statusDays++;

      final int gi = g.round();
      if (gi >= 0) {
        gainTotal += gi;
      } else {
        lossTotal += -gi;
      }
      wealth = math.max(0.0, wealth + gi);
      daily[idx] = wealth;
      lastIdx = idx;
    }
    for (int i = lastIdx + 1; i < kEmpireHorizon; i++) {
      daily[i] = wealth;
    }

    int dayNow = today.difference(start).inDays + 1;
    if (dayNow < 1) dayNow = 1;
    if (dayNow > kEmpireHorizon) dayNow = kEmpireHorizon;

    final List<EmpireLevel> levels = _levels();

    // 晋阶（黄线）判定 —— 同时驱动「系统修补次数」
    final List<EmpireMilestone> miles = [];
    int repairUsed = 0;
    for (final l in levels) {
      int hit = 0;
      for (int i = 0; i < daily.length; i++) {
        if (daily[i] >= l.threshold) {
          hit = i + 1;
          break;
        }
      }
      miles.add(EmpireMilestone(l.index, hit));
      if (hit > 0) repairUsed++;
    }
    if (repairUsed > kRepairMax) repairUsed = kRepairMax;

    // 维度聚合（科技复利来源）
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
      final int lastDay =
          itemDay[done.indexOf(last)] >= 1 ? itemDay[done.indexOf(last)] : 1;
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
    for (int i = 0; i < done.length; i++) {
      events.add(EmpireEvent(itemDay[i], 'tech', done[i].step,
          '×${done[i].mult.toStringAsFixed(3)}'));
    }
    for (final m in miles) {
      if (m.day > 0) {
        final l = levels[m.level - 1];
        events.add(EmpireEvent(m.day, 'level', '晋入 L${m.level} · ${l.name}', 'L${m.level}'));
      }
    }
    if (chaosDays > 0) {
      events.add(EmpireEvent(dayNow, 'chaos', '内政混乱 $chaosDays 日', '-${fmtInt(lossTotal)}'));
    }
    if (restDays > 0) {
      events.add(EmpireEvent(dayNow, 'rest', '修养生息 $restDays 日', '-${fmtInt(restTotalLoss)}'));
    }
    if (warDays > 0) {
      events.add(EmpireEvent(dayNow, 'war', '战争 $warDays 日', '+${fmtInt(warTotalGain)}'));
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
      daysTracked: days.length,
      warDays: warDays,
      chaosDays: chaosDays,
      restDays: restDays,
      checkinDays: checkinDays,
      statusDays: statusDays,
      gainTotal: gainTotal,
      lossTotal: lossTotal,
      warGain: warTotalGain,
      techGain: techTotalGain,
      chaosLoss: chaosTotalLoss,
      restLoss: restTotalLoss,
      repairUsed: repairUsed,
      techMult: mult,
      focusDone: done.length,
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
        startDate = '',
        daysTracked = 0,
        warDays = 0,
        chaosDays = 0,
        restDays = 0,
        checkinDays = 0,
        statusDays = 0,
        gainTotal = 0,
        lossTotal = 0,
        warGain = 0,
        techGain = 0,
        chaosLoss = 0,
        restLoss = 0,
        repairUsed = 0,
        techMult = 1,
        focusDone = 0;

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
