// 帝国模块 · 界面（主模块页 / 繁荣度 / 乘数效应）
//
// 版式参照「仪表盘 + 领地」的克制风格：大留白、发丝线、等宽数字，
// 主模块页放 3D 领地，关键参数用两张小子模块卡片承载，纪事只留三行烘托氛围。
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'empire_assets.dart';
import 'empire_data.dart';

// ==================== 视觉 token ====================
const Color kInk = Color(0xFF0E110F);
const Color kInk2 = Color(0xFF3B413D);
const Color kSub = Color(0xFF7F857E);
const Color kMute = Color(0xFFA9AEA6);
const Color kPaper = Color(0xFFF4F5F1);
const Color kCard = Color(0xFFFFFFFF);
const Color kLine = Color(0xFFE5E6E0);
const Color kLine2 = Color(0xFFEFF0EA);
const Color kLime = Color(0xFFDFEB2E);
const Color kLime2 = Color(0xFFC6D21C);

const List<Color> kDimPalette = [
  Color(0xFF2F5D62),
  Color(0xFFA8823C),
  Color(0xFF4A6B4F),
  Color(0xFF7A5C7E),
  Color(0xFFA9523C),
  Color(0xFF4B5563),
];

const String kMono = 'monospace';

TextStyle mono(double size,
    {Color color = kMute, FontWeight w = FontWeight.w500, double ls = 0.4}) {
  return TextStyle(
    fontSize: size,
    color: color,
    fontWeight: w,
    letterSpacing: ls,
    fontFamily: kMono,
    fontFeatures: const [ui.FontFeature.tabularFigures()],
  );
}

TextStyle sans(double size,
    {Color color = kInk, FontWeight w = FontWeight.w400, double ls = 0, double h = 1.3}) {
  return TextStyle(
    fontSize: size,
    color: color,
    fontWeight: w,
    letterSpacing: ls,
    height: h,
    fontFeatures: const [ui.FontFeature.tabularFigures()],
  );
}

// ==================== 主模块页 ====================
class EmpirePage extends StatefulWidget {
  final Database db;

  /// 每次切到「帝国」时由 MainShell 递增，用来刷新战略聚焦信号
  final int reloadToken;
  const EmpirePage({super.key, required this.db, this.reloadToken = 0});

  @override
  State<EmpirePage> createState() => _EmpirePageState();
}

class _EmpirePageState extends State<EmpirePage> with TickerProviderStateMixin {
  EmpireState? _s;
  bool _loading = true;
  late final AnimationController _float;

  /// 转台：value.dx = 偏航（左右），value.dy = 俯仰（上下），单位弧度
  final ValueNotifier<Offset> _tilt = ValueNotifier<Offset>(Offset.zero);

  /// 松手回正
  late final AnimationController _settle;

  /// 合并监听，避免每帧重建时反复挂/摘 listener
  late final Listenable _tiltSignal = Listenable.merge(<Listenable>[_tilt, _settle]);
  late final Listenable _stageSignal = Listenable.merge(<Listenable>[_float, _tilt, _settle]);

  @override
  void initState() {
    super.initState();
    _float = AnimationController(vsync: this, duration: const Duration(milliseconds: 8000))
      ..repeat(reverse: true);
    _settle = AnimationController(vsync: this, duration: const Duration(milliseconds: 340));
    _settle.addStatusListener((AnimationStatus st) {
      if (st == AnimationStatus.completed) {
        _tilt.value = Offset.zero;
        _settle.value = 0;
      }
    });
    _load();
  }

  @override
  void didUpdateWidget(covariant EmpirePage old) {
    super.didUpdateWidget(old);
    if (old.reloadToken != widget.reloadToken) _load();
  }

  @override
  void dispose() {
    _float.dispose();
    _settle.dispose();
    _tilt.dispose();
    super.dispose();
  }

  /// 拖拽转台：只接管横向，纵向留给页面滚动
  void _onTiltDrag(DragUpdateDetails d) {
    if (_settle.isAnimating) {
      _settle.stop();
      _settle.value = 0;
      _tilt.value = Offset.zero;
    }
    final double yaw =
        (_tilt.value.dx + d.delta.dx * 0.0052).clamp(-0.46, 0.46).toDouble();
    // 转的同时带一点俯仰，像真的放在转台上，而不是纸片横移
    _tilt.value = Offset(yaw, yaw * 0.22);
  }

  /// 松手 / 双击 → 回到正视角
  void _settleBack() {
    if (_tilt.value == Offset.zero || _settle.isAnimating) return;
    _settle.forward(from: 0);
  }

  /// 回正进度：1 = 保持拖动姿态，0 = 完全回正
  double get _hold => 1.0 - Curves.easeOutCubic.transform(_settle.value);

  Future<void> _load() async {
    EmpireState s;
    try {
      s = await _buildFromToday();
    } catch (_) {
      s = await EmpireState.loadDemo();
    }
    if (mounted) {
      setState(() {
        _s = s;
        _loading = false;
      });
    }
  }

  /// 把「今日」四个模块的历史记录汇总成帝国每日信号。
  ///
  ///   schedule_records → 打卡 / 战争 / 内政混乱 / 修养生息
  ///   status_records   → 每日状态 / 按时复盘
  ///   focus_items      → 科技突破 / 科技复利乘数
  Future<EmpireState> _buildFromToday() async {
    final Database db = widget.db;

    // 1) 日程打卡：按日汇总
    final Map<String, int> schedTotal = {};
    final Map<String, int> schedDone = {};
    final schedRows = await db.rawQuery(
        'SELECT date, COUNT(*) AS total, SUM(CASE WHEN done = 1 THEN 1 ELSE 0 END) AS dn '
        'FROM schedule_records GROUP BY date');
    for (final r in schedRows) {
      final String d = '${r['date']}';
      schedTotal[d] = (r['total'] as num?)?.toInt() ?? 0;
      schedDone[d] = (r['dn'] as num?)?.toInt() ?? 0;
    }

    // 2) 每日状态：按日汇总有效记录条数
    final Map<String, int> statusCount = {};
    final statRows = await db.rawQuery(
        "SELECT date, COUNT(*) AS c FROM status_records "
        "WHERE value IS NOT NULL AND value != '' GROUP BY date");
    for (final r in statRows) {
      statusCount['${r['date']}'] = (r['c'] as num?)?.toInt() ?? 0;
    }

    // 3) 按时复盘：优先匹配「复盘 / 总结 / 反思」类状态项
    final List<Map> items = List<Map>.from(await db.query('status_items'));
    final List<int> reviewIds = [];
    for (final it in items) {
      if ('${it['type']}' == 'image') continue;
      final String nm = '${it['name'] ?? ''}';
      if (nm.contains('复盘') || nm.contains('总结') || nm.contains('反思')) {
        reviewIds.add((it['id'] as num).toInt());
      }
    }
    final Set<String> reviewDates = {};
    if (reviewIds.isNotEmpty) {
      final String ph = List.filled(reviewIds.length, '?').join(',');
      final rr = await db.rawQuery(
          "SELECT date, COUNT(*) AS c FROM status_records "
          "WHERE value IS NOT NULL AND value != '' AND item_id IN ($ph) GROUP BY date",
          reviewIds);
      for (final r in rr) {
        reviewDates.add('${r['date']}');
      }
    }

    // 4) 战略聚焦：科技突破 + 科技复利
    final List<Map> fRows = List<Map>.from(await db.query('focus_items'));
    final List<EmpireFocus> focuses =
        fRows.map((r) => EmpireFocus.fromRow(r)).toList();
    final Map<String, int> focusCount = {};
    final Map<String, double> focusMult = {};
    for (final f in focuses) {
      if (!f.done) continue;
      focusCount[f.date] = (focusCount[f.date] ?? 0) + 1;
      focusMult[f.date] = (focusMult[f.date] ?? 1.0) * (f.mult > 0 ? f.mult : 1.0);
    }

    // 5) 时间轴：从最早记录日到今天，逐日结算
    final Set<String> allDates = {}
      ..addAll(schedTotal.keys)
      ..addAll(statusCount.keys)
      ..addAll(focusCount.keys);
    if (allDates.isEmpty) return EmpireState.loadDemo();

    final List<String> sorted = allDates.toList()..sort();
    DateTime start = DateTime.parse(sorted.first);
    final DateTime today = DateTime.now();
    final DateTime end = DateTime(today.year, today.month, today.day);
    if (start.isAfter(end)) start = end;

    final List<EmpireDay> days = [];
    final bool hasReviewItem = reviewIds.isNotEmpty;
    for (DateTime d = start;
        !d.isAfter(end);
        d = d.add(const Duration(days: 1))) {
      final String key = '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      final int st = schedTotal[key] ?? 0;
      final int sd = schedDone[key] ?? 0;
      final int sc = statusCount[key] ?? 0;
      days.add(EmpireDay(
        date: key,
        schedTotal: st,
        schedDone: sd,
        statusCount: sc,
        // 有复盘项就按复盘项算；没定义复盘项时，当天有状态记录即视为完成复盘
        reviewDone: hasReviewItem ? reviewDates.contains(key) : sc > 0,
        focusCount: focusCount[key] ?? 0,
        focusMult: focusMult[key] ?? 1.0,
      ));
    }

    return EmpireState.buildReal(days, focuses, today);
  }

  @override
  Widget build(BuildContext context) {
    final EmpireState? s = _s;
    return Scaffold(
      backgroundColor: kPaper,
      body: SafeArea(
        bottom: false,
        child: _loading || s == null
            ? const Center(
                child: SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.6)))
            : Column(
                children: [
                  _header(s),
                  Expanded(
                    child: RefreshIndicator(
                      color: kInk,
                      backgroundColor: kCard,
                      onRefresh: _load,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _stage(s),
                            const SizedBox(height: 2),
                            _params(s),
                            _chronicle(s),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _header(EmpireState s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('帝国', style: sans(26, w: FontWeight.w700, ls: -0.6, h: 1.05)),
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('D ${fmtInt(s.dayNow)}', style: mono(10, color: kInk2, w: FontWeight.w600, ls: 1.2)),
              const SizedBox(height: 3),
              Text(s.demo ? '示例推演' : '真实联动', style: mono(9, color: kMute, ls: 1.1)),
            ],
          ),
        ],
      ),
    );
  }

  /// 领地形态越低，模型越素、越小，避免「L1 却是一座天空之城」的违和
  ColorFilter _levelFilter(int idx) {
    final double sat = (0.32 + 0.1 * idx).clamp(0.32, 1.0).toDouble();
    const double lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final double r = (1 - sat) * lr, g = (1 - sat) * lg, b = (1 - sat) * lb;
    return ColorFilter.matrix(<double>[
      r + sat, g, b, 0, 0,
      r, g + sat, b, 0, 0,
      r, g, b + sat, 0, 0,
      0, 0, 0, 1, 0,
    ]);
  }

  // ---------- 3D 领地 ----------
  Widget _stage(EmpireState s) {
    final EmpireLevel lv = s.level;
    final EmpireLevel? nx = s.nextLevel;
    return SizedBox(
      height: 352,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.06),
                  radius: 0.72,
                  colors: [Colors.white.withOpacity(0.85), kPaper.withOpacity(0)],
                ),
              ),
            ),
          ),
          // 光环
          Positioned(
            left: 0,
            right: 0,
            top: 196,
            child: Center(
              child: Container(
                width: 300,
                height: 66,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(160),
                  border: Border.all(color: kInk.withOpacity(0.035)),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 200,
            child: Center(
              child: Container(
                width: 240,
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(160),
                  border: Border.all(color: kInk.withOpacity(0.055)),
                ),
              ),
            ),
          ),
          // 落地投影：跟着转台位移，转动时重心才不像贴在纸上
          Positioned(
            left: 0,
            right: 0,
            bottom: 58,
            child: AnimatedBuilder(
              animation: _tiltSignal,
              builder: (ctx, child) => Transform.translate(
                offset: Offset(-_tilt.value.dx * _hold * 96, 0),
                child: child,
              ),
              child: Center(
              child: Container(
                width: 190,
                height: 20,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(100),
                  gradient: RadialGradient(
                    colors: [kInk.withOpacity(0.26), kInk.withOpacity(0)],
                  ),
                ),
              ),
            ),
            ),
          ),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: _onTiltDrag,
              onHorizontalDragEnd: (_) => _settleBack(),
              onHorizontalDragCancel: _settleBack,
              onDoubleTap: _settleBack,
              child: AnimatedBuilder(
              animation: _stageSignal,
              builder: (ctx, child) {
                final double t = Curves.easeInOut.transform(_float.value);
                final double h = _hold;
                final Matrix4 m = Matrix4.identity()
                  ..setEntry(3, 2, 0.0013)
                  ..rotateX(_tilt.value.dy * h)
                  ..rotateY(_tilt.value.dx * h);
                return Transform.translate(
                  offset: Offset(0, -6 * t),
                  child: Transform(alignment: Alignment.center, transform: m, child: child),
                );
              },
              child: Center(
                child: ColorFiltered(
                  colorFilter: _levelFilter(lv.index),
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (Rect r) => RadialGradient(
                      radius: 0.80,
                      stops: const [0.84, 0.94, 1.0],
                      colors: [
                        Colors.black,
                        Colors.black.withOpacity(0.62),
                        Colors.black.withOpacity(0),
                      ],
                    ).createShader(r),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 520),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: Image.memory(
                        realmBytes(lv.index),
                        key: ValueKey<int>(lv.index),
                        width: 340 * (0.90 + 0.014 * lv.index),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ),
          ),
          // 等级
          Positioned(
            left: 20,
            top: 2,
            child: Container(
              padding: const EdgeInsets.fromLTRB(7, 5, 11, 5),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.78),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.white.withOpacity(0.95)),
                boxShadow: [
                  BoxShadow(color: kInk.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 2))
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    decoration: BoxDecoration(color: kInk, borderRadius: BorderRadius.circular(11)),
                    child: Text('L${lv.index.toString().padLeft(2, '0')}',
                        style: mono(9.5, color: const Color(0xFFF6F7F2), w: FontWeight.w700, ls: 0.8)),
                  ),
                  const SizedBox(width: 6),
                  Text(lv.name, style: sans(11.5, w: FontWeight.w600)),
                  const SizedBox(width: 5),
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: kLime2,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: kLime.withOpacity(0.30), blurRadius: 0, spreadRadius: 3)
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 复利乘数
          Positioned(
            right: 20,
            top: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('×${s.composite.toStringAsFixed(2)}',
                    style: mono(10, color: kInk2, w: FontWeight.w600, ls: 0.8)),
                const SizedBox(height: 3),
                Text('复利乘数', style: mono(8.5, color: kMute, ls: 1.4)),
              ],
            ),
          ),
          // 转动提示
          Positioned(
            left: 0,
            right: 0,
            bottom: 2,
            child: IgnorePointer(
              child: Center(
                child: Text('左右拖拽转动 · 双击回正',
                    style: mono(8.5, color: kMute.withOpacity(0.75), ls: 0.6)),
              ),
            ),
          ),
          // 进度
          Positioned(
            left: 20,
            right: 20,
            bottom: 26,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(nx == null ? '已达最高形态' : '距 L${nx.index.toString().padLeft(2, '0')} · ${nx.name}',
                        style: mono(9.5, color: kSub, ls: 1)),
                    const Spacer(),
                    Text('${(s.progress * 100).toStringAsFixed(1)}%',
                        style: mono(10, color: kInk, w: FontWeight.w600, ls: 0.4)),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: Stack(
                    children: [
                      Container(height: 2, color: kInk.withOpacity(0.09)),
                      FractionallySizedBox(
                        widthFactor: s.progress.clamp(0.001, 1.0).toDouble(),
                        child: Container(height: 2, color: kLime),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 关键参数 ----------
  Widget _params(EmpireState s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _prosCard(s)),
          const SizedBox(width: 9),
          Expanded(child: _mulCard(s)),
        ],
      ),
    );
  }

  Widget _cardShell({required Widget child, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: kLine),
          boxShadow: [BoxShadow(color: kInk.withOpacity(0.03), blurRadius: 2, offset: const Offset(0, 1))],
        ),
        child: child,
      ),
    );
  }

  Widget _cardLabel(String t) {
    return Row(
      children: [
        Text(t, style: mono(9.5, color: kSub, w: FontWeight.w600, ls: 1.3)),
        const Spacer(),
        const Icon(Icons.chevron_right, size: 13, color: kMute),
      ],
    );
  }

  Widget _prosCard(EmpireState s) {
    final EmpireLevel lv = s.level;
    return _cardShell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ProsperityPage(state: s)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardLabel('繁荣度'),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(fmtMoney(s.wealth),
                    style: sans(28, w: FontWeight.w600, ls: -1.1, h: 1.0)),
              ],
            ),
          ),
          const SizedBox(height: 7),
          SizedBox(
            height: 38,
            child: CustomPaint(
              painter: _SparkPainter(s.daily),
              size: const Size(double.infinity, 38),
            ),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Text('日均 ', style: mono(8.5, color: kMute, ls: 0.6)),
              Text('+${fmtInt(s.dailyGain)}',
                  style: mono(8.5, color: kInk2, w: FontWeight.w600, ls: 0.6)),
              const Spacer(),
              Text('L${lv.index.toString().padLeft(2, '0')} / 09', style: mono(8.5, color: kMute, ls: 0.6)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _mulCard(EmpireState s) {
    final List<EmpireDim> dims = s.dims;
    return _cardShell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MultiplierPage(state: s)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardLabel('乘数效应'),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('×${s.composite.toStringAsFixed(2)}',
                    style: sans(28, w: FontWeight.w600, ls: -1.1, h: 1.0)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _dimStrip(dims, height: 5, radius: 3),
          const SizedBox(height: 22),
          Row(
            children: [
              Text('六维连乘', style: mono(8.5, color: kMute, ls: 0.6)),
              const Spacer(),
              Text('${s.doneCount}', style: mono(8.5, color: kInk2, w: FontWeight.w600, ls: 0.6)),
              Text(' 项突破', style: mono(8.5, color: kMute, ls: 0.6)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dimStrip(List<EmpireDim> dims, {required double height, required double radius}) {
    final List<Widget> kids = [];
    for (int i = 0; i < dims.length; i++) {
      if (i > 0) kids.add(const SizedBox(width: 1.5));
      kids.add(Expanded(
        flex: math.max(8, (dims[i].share * 10).round()),
        child: Container(color: kDimPalette[i % kDimPalette.length]),
      ));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(height: height, child: Row(children: kids)),
    );
  }

  // ---------- 纪事 ----------
  Widget _chronicle(EmpireState s) {
    final List<EmpireEvent> recent = s.recent;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: kLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => _openChronicle(s),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Row(
                children: [
                  Text('纪 事', style: mono(9, color: kSub, w: FontWeight.w600, ls: 2.2)),
                  const Spacer(),
                  Text('${s.events.length} 条', style: mono(9, color: kMute, ls: 0.5)),
                  const SizedBox(width: 2),
                  const Icon(Icons.chevron_right, size: 11, color: kMute),
                ],
              ),
            ),
          ),
          Container(height: 1, color: kLine2),
          ...List.generate(recent.length, (i) {
            final EmpireEvent e = recent[i];
            return InkWell(
              onTap: () => _openChronicle(s),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  border: i == 0 ? null : Border(top: BorderSide(color: kLine2, width: 1)),
                ),
                child: Row(
                  children: [
                    Container(width: 2.5, height: 10, color: _eventColor(e.kind)),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 34,
                      child: Text('D${e.day}', style: mono(8.5, color: kMute, ls: 0.2)),
                    ),
                    Expanded(
                      child: Text(
                        e.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sans(11.5, color: kInk2, w: FontWeight.w500),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(_eventValue(e.value), style: mono(8.5, color: kSub, w: FontWeight.w600, ls: 0.2)),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  static Color _eventColor(String kind) {
    switch (kind) {
      case 'war':
        return const Color(0xFFA9523C);
      case 'level':
        return kLime2;
      case 'tech':
        return const Color(0xFF7A5C7E);
      case 'turn':
        return kInk;
      case 'chaos':
        return const Color(0xFFB4795F);
      case 'rest':
        return const Color(0xFF9FB28F);
      default:
        return kLine;
    }
  }

  static String _eventValue(String raw) {
    final String t = raw.trim();
    final double? n = double.tryParse(t.replaceAll('+', ''));
    if (n != null) {
      if (n.abs() >= 1e4) return '${t.startsWith('+') ? '+' : (t.startsWith('-') ? '-' : '')}${fmtWan(n.abs())} 万';
      return fmtInt(n);
    }
    return t;
  }

  void _openChronicle(EmpireState s) {
    final List<EmpireEvent> list = List<EmpireEvent>.from(s.events)
      ..sort((a, b) => b.day.compareTo(a.day));
    showModalBottomSheet(
      context: context,
      backgroundColor: kPaper,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.72,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 32,
              height: 3,
              decoration: BoxDecoration(color: kLine, borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 9),
              child: Row(
                children: [
                  Text('纪事', style: sans(13.5, w: FontWeight.w700)),
                  const Spacer(),
                  Text('${list.length} 条', style: mono(8.5, color: kMute, ls: 0.6)),
                ],
              ),
            ),
            Container(height: 1, color: kLine),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 18),
                itemCount: list.length,
                itemBuilder: (c, i) {
                  final EmpireEvent e = list[i];
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    decoration: BoxDecoration(
                      border: i == list.length - 1
                          ? null
                          : Border(bottom: BorderSide(color: kLine2, width: 1)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 36,
                          child: Text('D${e.day}', style: mono(8.5, color: kMute, ls: 0.2)),
                        ),
                        Expanded(
                          child: Text(e.title, style: sans(11, color: kInk2, h: 1.5)),
                        ),
                        const SizedBox(width: 8),
                        Text(_eventValue(e.value), style: mono(8.5, color: kSub, w: FontWeight.w600)),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 繁荣度页 ====================
class ProsperityPage extends StatefulWidget {
  final EmpireState state;
  const ProsperityPage({super.key, required this.state});

  @override
  State<ProsperityPage> createState() => _ProsperityPageState();
}

class _ProsperityPageState extends State<ProsperityPage> {
  int _win = 3650;
  bool _autoAxis = false;
  bool _logAxis = true;

  @override
  Widget build(BuildContext context) {
    final EmpireState s = widget.state;
    return Scaffold(
      backgroundColor: kPaper,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _header(s),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _hero(s),
                    _mapCard(s),
                    _curveCard(s),
                    _mileCard(s),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(EmpireState s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 18, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: 29,
              height: 29,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.72),
                border: Border.all(color: kLine),
              ),
              child: const Icon(Icons.chevron_left, size: 17, color: kInk),
            ),
          ),
          const SizedBox(width: 8),
          Text('繁荣度', style: sans(21, w: FontWeight.w700, ls: -0.4)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.66),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kLine),
            ),
            child: Text('L${s.level.index.toString().padLeft(2, '0')} ${s.level.name}',
                style: mono(9, color: kInk2, w: FontWeight.w600, ls: 0.6)),
          ),
        ],
      ),
    );
  }

  Widget _hero(EmpireState s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('领 地 繁 荣 度', style: mono(9, color: kSub, w: FontWeight.w600, ls: 2.0)),
          const SizedBox(height: 9),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(fmtMoney(s.wealth), style: sans(40, w: FontWeight.w600, ls: -1.8, h: 0.95)),
              const SizedBox(width: 6),
              Text('当前疆域', style: mono(9, color: kMute, ls: 1.1)),
            ],
          ),
          const SizedBox(height: 11),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                _kv('乘数', '×${s.composite.toStringAsFixed(2)}'),
                _sep(),
                _kv('突破', '${s.doneCount}'),
                _sep(),
                _kv('日均', '+${fmtInt(s.dailyGain)}'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Row(
      children: [
        Text('$k ', style: mono(9, color: kMute, ls: 0.4)),
        Text(v, style: mono(9, color: kInk2, w: FontWeight.w600, ls: 0.4)),
      ],
    );
  }

  Widget _sep() {
    return Container(
      width: 1,
      height: 8,
      color: kLine,
      margin: const EdgeInsets.symmetric(horizontal: 10),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: kLine),
        boxShadow: [BoxShadow(color: kInk.withOpacity(0.03), blurRadius: 2, offset: const Offset(0, 1))],
      ),
      child: child,
    );
  }

  Widget _cardHead(String t, String n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Row(
        children: [
          Text(t, style: mono(9, color: kSub, w: FontWeight.w600, ls: 2.0)),
          const Spacer(),
          Text(n, style: mono(8.5, color: kMute, ls: 0.4)),
        ],
      ),
    );
  }

  Widget _mapCard(EmpireState s) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardHead('领 地 平 面', '顶层 · 王城'),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
            child: AspectRatio(
              aspectRatio: 340 / 150,
              child: CustomPaint(painter: _MapPainter(dims: s.dims)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Row(
              children: [
                Text('九级形态 · ${s.dims.length} 处建筑群', style: mono(8, color: kMute, ls: 0.8)),
                const Spacer(),
                Text('1 格 ≈ 500', style: mono(8, color: kMute, ls: 0.8)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _curveCard(EmpireState s) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 12, 8),
            child: Row(
              children: [
                Expanded(child: _seg()),
                const SizedBox(width: 6),
                _axisToggle(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 2, 0),
            child: AspectRatio(
              aspectRatio: 364 / 186,
              child: CustomPaint(
                painter: _CurvePainter(
                  daily: s.daily,
                  win: _win,
                  autoAxis: _autoAxis,
                  logAxis: _logAxis,
                  levels: s.levels,
                  miles: s.milestones,
                  dayNow: s.dayNow,
                ),
              ),
            ),
          ),
          Container(height: 1, color: kLine2),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: _foot(s),
          ),
        ],
      ),
    );
  }

  Widget _seg() {
    const List<MapEntry<int, String>> opts = [
      MapEntry(30, '30 天'),
      MapEntry(90, '90 天'),
      MapEntry(365, '1 年'),
      MapEntry(1095, '3 年'),
      MapEntry(3650, '10 年'),
    ];
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F3EE),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kLine2),
      ),
      child: Row(
        children: opts.map((o) {
          final bool on = _win == o.key;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _win = o.key),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 5),
                decoration: BoxDecoration(
                  color: on ? kInk : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Text(o.value,
                    maxLines: 1,
                    style: mono(9, color: on ? const Color(0xFFF7F8F3) : kSub, w: FontWeight.w600, ls: 0.2)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _axisToggle() {
    Widget b(String t, bool on, VoidCallback tap) {
      return GestureDetector(
        onTap: tap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            color: on ? kLime : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(t, style: mono(9, color: on ? kInk : kMute, w: FontWeight.w600, ls: 0.2)),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        b('自动', _autoAxis, () => setState(() => _autoAxis = true)),
        b('对数', !_autoAxis && _logAxis, () => setState(() {
              _autoAxis = false;
              _logAxis = true;
            })),
      ],
    );
  }

  Widget _foot(EmpireState s) {
    final int end = math.min(s.daily.length - 1, math.max(0, s.dayNow - 1));
    final int start = math.max(0, math.min(end, _win == 3650 ? 0 : end - _win + 1));
    final int n = end - start + 1;
    return Wrap(
      spacing: 11,
      runSpacing: 3,
      children: [
        _footItem('区间', 'D$start–D$end'),
        _footItem('轴', _autoAxis ? '自动' : '对数 log10'),
        _footItem('终值', fmtMoney(s.daily[end])),
        _footItem('取点', '$n'),
      ],
    );
  }

  Widget _footItem(String k, String v) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$k ', style: mono(8, color: kMute, ls: 0.4)),
        Text(v, style: mono(8, color: kInk2, w: FontWeight.w600, ls: 0.4)),
      ],
    );
  }

  Widget _mileCard(EmpireState s) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardHead('形 态 进 程', '${s.milestones.where((m) => m.day > 0).length} / 9 已达成'),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
            child: AspectRatio(
              aspectRatio: 340 / 74,
              child: CustomPaint(painter: _MilePainter(s.milestones, s.level.index)),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 乘数效应页 ====================
class MultiplierPage extends StatefulWidget {
  final EmpireState state;
  const MultiplierPage({super.key, required this.state});

  @override
  State<MultiplierPage> createState() => _MultiplierPageState();
}

class _MultiplierPageState extends State<MultiplierPage> {
  int _sel = -1;

  @override
  Widget build(BuildContext context) {
    final EmpireState s = widget.state;
    return Scaffold(
      backgroundColor: kPaper,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _header(s),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _hero(s),
                    const SizedBox(height: 12),
                    ...List.generate(s.dims.length, (i) => _row(s, i)),
                    _recent(s),
                    _formula(s),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(EmpireState s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 18, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: 29,
              height: 29,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.72),
                border: Border.all(color: kLine),
              ),
              child: const Icon(Icons.chevron_left, size: 17, color: kInk),
            ),
          ),
          const SizedBox(width: 8),
          Text('乘数效应', style: sans(21, w: FontWeight.w700, ls: -0.4)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.66),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kLine),
            ),
            child: Text('${s.dims.length} 维 · ${s.doneCount} 项',
                style: mono(9, color: kInk2, w: FontWeight.w600, ls: 0.5)),
          ),
        ],
      ),
    );
  }

  Widget _hero(EmpireState s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('复 合 乘 数', style: mono(9, color: kSub, w: FontWeight.w600, ls: 2.0)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('×${s.composite.toStringAsFixed(2)}',
                  style: sans(41, w: FontWeight.w600, ls: -1.9, h: 0.95)),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${s.dims.length}', style: mono(12, color: kInk2, w: FontWeight.w600, ls: 0.2)),
                  Text('维度连乘', style: mono(8.5, color: kMute, ls: 0.5)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 13),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 4.5,
              child: Row(
                children: _stripKids(s.dims),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _stripKids(List<EmpireDim> dims) {
    final List<Widget> kids = [];
    for (int i = 0; i < dims.length; i++) {
      if (i > 0) kids.add(const SizedBox(width: 1.5));
      kids.add(Expanded(
        flex: math.max(8, (dims[i].share * 10).round()),
        child: Container(color: kDimPalette[i % kDimPalette.length]),
      ));
    }
    return kids;
  }

  Widget _row(EmpireState s, int i) {
    final EmpireDim d = s.dims[i];
    final bool sel = _sel == i;
    final bool dimmed = _sel >= 0 && !sel;
    final double maxCum = s.dims.first.cum;
    final double ratio = maxCum <= 1 ? 0 : (d.cum - 1) / (maxCum - 1);
    final Color c = kDimPalette[i % kDimPalette.length];

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 220),
      opacity: dimmed ? 0.4 : 1,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _sel = sel ? -1 : i),
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 2, 12, 2),
          padding: const EdgeInsets.fromLTRB(11, 11, 11, 10),
          decoration: BoxDecoration(
            color: sel ? kCard : Colors.transparent,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: sel ? kLine : Colors.transparent),
            boxShadow: sel
                ? [BoxShadow(color: kInk.withOpacity(0.06), blurRadius: 14, offset: const Offset(0, 3))]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(d.name, style: sans(13.5, color: kInk, w: FontWeight.w700, ls: 0.1)),
                  const Spacer(),
                  Text('${d.count} 项 · 均 +${d.avgDelta.toStringAsFixed(2)}%',
                      style: mono(8, color: kMute, ls: 0.2)),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 54,
                    child: Text('×${d.cum.toStringAsFixed(3)}',
                        textAlign: TextAlign.right,
                        style: mono(12.5, color: kInk, w: FontWeight.w600, ls: -0.2)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                height: dimmed ? 2 : 7,
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F2EC),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: ratio.clamp(0.06, 1.0).toDouble(),
                  child: Container(
                    decoration: BoxDecoration(
                      color: c,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: sel ? _detail(d, c) : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detail(EmpireDim d, Color c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.only(top: 9),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: kLine2, width: 1))),
          child: Row(
            children: [
              Text('最 新 已 突 破', style: mono(8, color: kMute, w: FontWeight.w600, ls: 1.6)),
              const Spacer(),
              Text('D${d.day}', style: mono(8, color: kMute, ls: 0.4)),
            ],
          ),
        ),
        const SizedBox(height: 7),
        Text(d.step, style: sans(13, color: kInk, w: FontWeight.w600, h: 1.4)),
        if (d.criteria.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('完成标准 · ${d.criteria}', style: sans(10, color: kSub, h: 1.55)),
        ],
        const SizedBox(height: 9),
        Row(
          children: [
            Text(d.date, style: mono(8.5, color: kMute, ls: 0.3)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F2EC),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text('${d.multLabel} 已入账',
                  style: mono(8.5, color: kInk2, w: FontWeight.w600, ls: 0.2)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _recent(EmpireState s) {
    final List<EmpireDim> list = List<EmpireDim>.from(s.dims)
      ..sort((a, b) => b.day.compareTo(a.day));
    final List<EmpireDim> top = list.take(5).toList();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: kLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
            child: Row(
              children: [
                Text('最 近 突 破', style: mono(9, color: kSub, w: FontWeight.w600, ls: 1.8)),
                const Spacer(),
                Text('近 ${top.length} 条', style: mono(8.5, color: kMute, ls: 0.4)),
              ],
            ),
          ),
          ...List.generate(top.length, (i) {
            final EmpireDim d = top[i];
            final int idx = s.dims.indexOf(d);
            return Container(
              padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: kLine2, width: 1)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: kDimPalette[(idx < 0 ? 0 : idx) % kDimPalette.length],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 28,
                    child: Text(d.name, style: mono(8.5, color: kMute, ls: 0.4)),
                  ),
                  Expanded(
                    child: Text(d.step,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sans(10.5, color: kInk2, h: 1.3)),
                  ),
                  const SizedBox(width: 6),
                  Text(d.multLabel, style: mono(8.5, color: kSub, w: FontWeight.w600, ls: 0.2)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _formula(EmpireState s) {
    final String expr = s.dims.map((d) => d.cum.toStringAsFixed(3)).join(' × ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Text(
        '$expr = ${s.composite.toStringAsFixed(2)}',
        textAlign: TextAlign.center,
        style: mono(8, color: kMute, ls: 0.4),
      ),
    );
  }
}

// ==================== 绘制 ====================
class _SparkPainter extends CustomPainter {
  final List<double> daily;
  _SparkPainter(this.daily);

  @override
  void paint(Canvas canvas, Size size) {
    if (daily.isEmpty) return;
    final int end = daily.length - 1;
    final int step = math.max(1, (daily.length / 120).floor());
    final List<double> pts = [];
    for (int i = 0; i <= end; i += step) {
      pts.add(daily[i]);
    }
    pts.add(daily[end]);
    if (pts.length < 2) return;

    double lg(double v) => math.log(math.max(1.0, v)) / math.ln10;
    double mn = lg(pts.first), mx = lg(pts.first);
    for (final v in pts) {
      final double l = lg(v);
      if (l < mn) mn = l;
      if (l > mx) mx = l;
    }
    final double rg = (mx - mn) == 0 ? 1 : mx - mn;
    final double W = size.width, H = size.height;

    final Path line = Path();
    for (int i = 0; i < pts.length; i++) {
      final double x = i / (pts.length - 1) * W;
      final double y = H - 3 - (lg(pts[i]) - mn) / rg * (H - 8);
      if (i == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
    }
    final Path area = Path.from(line)
      ..lineTo(W, H)
      ..lineTo(0, H)
      ..close();

    canvas.drawPath(
      area,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, 0),
          Offset(0, H),
          [kInk.withOpacity(0.15), kInk.withOpacity(0)],
        ),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = kInk
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.25
        ..strokeJoin = StrokeJoin.round,
    );

    final double lx = W;
    final double ly = H - 3 - (lg(pts.last) - mn) / rg * (H - 8);
    canvas.drawCircle(Offset(lx, ly), 2.9, Paint()..color = kLime);
    canvas.drawCircle(
      Offset(lx, ly),
      2.9,
      Paint()
        ..color = kInk
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

class _MapPainter extends CustomPainter {
  final List<EmpireDim> dims;
  _MapPainter({required this.dims});

  static const double W = 340, H = 150, cx = 170, cy = 75, KX = 1.92, KY = 0.86;
  static const List<double> rad = [76, 58, 42, 23];
  static const List<double> sect = [-1.72, -1.05, -0.34, 0.42, 1.16, 2.42];

  void _text(Canvas c, String s, Offset at,
      {double size = 6, Color color = kMute, TextAlign align = TextAlign.center, double ls = 1.2}) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, letterSpacing: ls)),
      textDirection: TextDirection.ltr,
    )..layout();
    double dx = at.dx;
    if (align == TextAlign.center) dx -= tp.width / 2;
    if (align == TextAlign.right) dx -= tp.width;
    tp.paint(c, Offset(dx, at.dy - tp.height / 2));
  }

  List<Offset> _shape(double r, double ph) {
    final List<Offset> pts = [];
    for (int j = 0; j < 88; j++) {
      final double a = j / 88 * math.pi * 2;
      final double w = 1 +
          0.052 * math.sin(a * 3 + ph) +
          0.028 * math.sin(a * 5 - ph * 1.4) +
          0.016 * math.cos(a * 9 + ph * 0.7);
      pts.add(Offset(cx + math.cos(a) * r * w * KX, cy + math.sin(a) * r * w * KY));
    }
    return pts;
  }

  Path _path(List<Offset> pts) {
    final Path p = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (int i = 1; i < pts.length; i++) {
      p.lineTo(pts[i].dx, pts[i].dy);
    }
    return p..close();
  }

  void _dash(Canvas c, Path p, Paint paint, {double dash = 4, double gap = 5}) {
    for (final ui.PathMetric m in p.computeMetrics()) {
      double d = 0;
      while (d < m.length) {
        final double next = math.min(d + dash, m.length);
        c.drawPath(m.extractPath(d, next), paint);
        d = next + gap;
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / W, size.height / H);

    // 网格
    final Paint grid = Paint()
      ..color = const Color(0xFFEAEBE3)
      ..strokeWidth = 0.5;
    for (double x = 8; x < W; x += 13) {
      canvas.drawLine(Offset(x, 3), Offset(x, H - 3), grid);
    }
    for (double y = 4; y < H; y += 13) {
      canvas.drawLine(Offset(3, y), Offset(W - 3, y), grid);
    }

    final List<Offset> p0 = _shape(rad[0], 0.4);
    final List<Offset> p1 = _shape(rad[1], 1.7);
    final List<Offset> p2 = _shape(rad[2], 2.9);
    final List<Offset> p3 = _shape(rad[3], 4.1);

    // 投影
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 6), width: rad[0] * KX * 2, height: rad[0] * KY * 2),
      Paint()..color = kInk.withOpacity(0.07),
    );

    final List<List<Offset>> rings = [p0, p1, p2, p3];
    const List<Color> fills = [
      Color(0xFFE2E5D4),
      Color(0xFFEAECDD),
      Color(0xFFF3F4EB),
      Color(0xFFFBFCF6),
    ];
    const List<Color> strokes = [
      Color(0xFFAEB49B),
      Color(0xFFC6C9B4),
      Color(0xFFCFD2BE),
      Color(0xFFD9DBC9),
    ];
    for (int i = 0; i < rings.length; i++) {
      canvas.drawPath(
        _path(rings[i]),
        Paint()
          ..color = fills[i]
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        _path(rings[i]),
        Paint()
          ..color = strokes[i]
          ..style = PaintingStyle.stroke
          ..strokeWidth = i == 0 ? 0.9 : 0.6,
      );
    }

    // 六分区虚线
    final Paint sectPaint = Paint()
      ..color = const Color(0xFFCFD2BE)
      ..strokeWidth = 0.5;
    for (final a in sect) {
      _dash(
        canvas,
        Path()
          ..moveTo(cx + math.cos(a) * rad[3] * KX, cy + math.sin(a) * rad[3] * KY)
          ..lineTo(cx + math.cos(a) * rad[0] * KX, cy + math.sin(a) * rad[0] * KY),
        sectPaint,
        dash: 2.6,
        gap: 3.4,
      );
    }

    // 主街（内环之外的四段）
    const double sIn = 26, sOut = 76;
    final Paint street = Paint()
      ..color = const Color(0xFFFCFDF8)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final Paint streetLine = Paint()
      ..color = const Color(0xFFD6D9C6)
      ..strokeWidth = 0.45;
    void streetSeg(Offset a, Offset b) {
      canvas.drawLine(a, b, street);
      canvas.drawLine(a, b, streetLine);
    }

    streetSeg(Offset(cx - sIn * KX, cy), Offset(cx - sOut * KX, cy));
    streetSeg(Offset(cx + sIn * KX, cy), Offset(cx + sOut * KX, cy));
    streetSeg(Offset(cx, cy - sIn * KY), Offset(cx, cy - sOut * KY));
    streetSeg(Offset(cx, cy + sIn * KY), Offset(cx, cy + sOut * KY));

    // 建筑
    final math.Random rnd = math.Random(47);
    final Paint blk = Paint()..color = const Color(0xFF2C322B).withOpacity(0.66);
    for (int i = 0; i < sect.length; i++) {
      final double a1 = sect[i];
      final double a2 = i == sect.length - 1 ? sect[0] + math.pi * 2 : sect[i + 1];
      final double mid = (a1 + a2) / 2;
      for (final double rr in <double>[30, 40, 50, 62, 72]) {
        final int cnt = rr < 46 ? 2 : 3;
        for (int k = 0; k < cnt; k++) {
          final double aa = mid + (k - (cnt - 1) / 2) * 0.135;
          final double r = rr + (rnd.nextDouble() - 0.5) * 5;
          final double x = cx + math.cos(aa) * r * KX;
          final double y = cy + math.sin(aa) * r * KY;
          if ((y - cy).abs() < 4.5 || (x - cx).abs() < 4) continue;
          final double bw = 1.8 + rnd.nextDouble() * 3.0;
          final double bh = 1.5 + rnd.nextDouble() * 2.4;
          canvas.save();
          canvas.translate(x, y);
          canvas.rotate(aa);
          canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: bw, height: bh), blk);
          canvas.restore();
        }
      }
    }

    // 六维标注
    for (int i = 0; i < sect.length; i++) {
      final double a1 = sect[i];
      final double a2 = i == sect.length - 1 ? sect[0] + math.pi * 2 : sect[i + 1];
      final double mid = (a1 + a2) / 2;
      final double x = cx + math.cos(mid) * 68 * KX;
      final double y = cy + math.sin(mid) * 68 * KY;
      final String name = i < dims.length ? dims[i].name : '';
      if (name.isEmpty || name.length > 4) continue;
      // 白色描边让字压在建筑上也能读
      _text(canvas, name, Offset(x + 0.8, y + 0.8), size: 6, color: const Color(0xFFF7F8F2));
      _text(canvas, name, Offset(x, y), size: 6.2, color: const Color(0xFF4E554C), ls: 1.3);
    }

    // 当前形态：L07 边界（虚线圈）
    _dash(
      canvas,
      _path(p1),
      Paint()
        ..color = kLime2.withOpacity(0.92)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.45,
      dash: 4,
      gap: 5,
    );
    final Offset q = p1[(p1.length * 0.70).round() % p1.length];
    canvas.drawLine(
        Offset(q.dx, q.dy - 2), Offset(q.dx, q.dy - 6), Paint()..color = kInk..strokeWidth = 0.9);
    final RRect chip = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(q.dx, q.dy - 11), width: 20, height: 9),
      const Radius.circular(2),
    );
    canvas.drawRRect(chip, Paint()..color = kInk);
    _text(canvas, 'L07', Offset(q.dx, q.dy - 11), size: 5.6, color: kLime, ls: 1);

    // 王城
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 2.5), width: 28, height: 14),
      Paint()..color = kInk.withOpacity(0.16),
    );
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(math.pi / 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: 12, height: 12),
        const Radius.circular(1.2),
      ),
      Paint()..color = kInk,
    );
    canvas.restore();
    canvas.drawCircle(Offset(cx, cy), 1.9, Paint()..color = kLime);

    // 指北 / 比例尺
    _text(canvas, 'N', const Offset(9, 9), size: 5.6, color: kMute, align: TextAlign.left, ls: 1);
    canvas.drawLine(const Offset(11.4, 15), const Offset(11.4, 21), Paint()..color = const Color(0xFFBFC3B3)..strokeWidth = 0.7);
    final Paint scale = Paint()
      ..color = const Color(0xFFBFC3B3)
      ..strokeWidth = 0.8;
    canvas.drawLine(const Offset(250, 150 - 0), const Offset(286, 150), scale);
    canvas.drawLine(const Offset(250, 147.6), const Offset(250, 152.4), scale);
    canvas.drawLine(const Offset(286, 147.6), const Offset(286, 152.4), scale);
    _text(canvas, '500', const Offset(268, 143), size: 5.6, color: kMute, ls: 1);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

class _MilePainter extends CustomPainter {
  final List<EmpireMilestone> miles;
  final int curLevel;
  _MilePainter(this.miles, this.curLevel);

  void _text(Canvas c, String s, Offset at,
      {double size = 6, Color color = kMute, double ls = 0.3, FontWeight w = FontWeight.w400}) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
          text: s, style: TextStyle(fontSize: size, color: color, letterSpacing: ls, fontWeight: w)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(at.dx - tp.width / 2, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (miles.isEmpty) return;
    const double W = 340, H = 74, y = 30;
    canvas.save();
    canvas.scale(size.width / W, size.height / H);
    const double l = 16, r = 16;
    final double gap = (W - l - r) / (miles.length - 1);

    canvas.drawLine(
        const Offset(l, y), Offset(W - r, y), Paint()..color = const Color(0xFFE7E8DF)..strokeWidth = 1);

    int curIdx = -1;
    for (int i = 0; i < miles.length; i++) {
      if (miles[i].day > 0) curIdx = i;
    }
    if (curIdx > 0) {
      canvas.drawLine(Offset(l, y), Offset(l + gap * curIdx, y),
          Paint()..color = kInk..strokeWidth = 1.2);
    }

    for (int i = 0; i < miles.length; i++) {
      final double x = l + gap * i;
      final EmpireMilestone m = miles[i];
      final bool ok = m.day > 0;
      final bool isCur = i == curIdx;
      if (ok) {
        canvas.drawCircle(Offset(x, y), isCur ? 4.6 : 3.2, Paint()..color = isCur ? kLime : kInk);
        if (isCur) {
          canvas.drawCircle(
            Offset(x, y),
            4.6,
            Paint()
              ..color = kInk
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4,
          );
        }
      } else {
        canvas.drawCircle(Offset(x, y), 3, Paint()..color = const Color(0xFFFCFCF8));
        canvas.drawCircle(
          Offset(x, y),
          3,
          Paint()
            ..color = const Color(0xFFCFD2BE)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
      _text(canvas, 'L${m.level}', Offset(x, y - 11),
          size: 7, color: ok ? kInk2 : kMute, w: ok ? FontWeight.w600 : FontWeight.w400);
      _text(canvas, ok ? 'D${m.day}' : '—', Offset(x, y + 13),
          size: 5.4, color: isCur ? kInk2 : kMute);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

class _CurvePainter extends CustomPainter {
  final List<double> daily;
  final int win;
  final bool autoAxis;
  final bool logAxis;
  final List<EmpireLevel> levels;
  final List<EmpireMilestone> miles;
  final int dayNow;

  _CurvePainter({
    required this.daily,
    required this.win,
    required this.autoAxis,
    required this.logAxis,
    required this.levels,
    required this.miles,
    required this.dayNow,
  });

  void _text(Canvas c, String s, Offset at,
      {double size = 8,
      Color color = kMute,
      TextAlign align = TextAlign.left,
      double ls = 0.3,
      FontWeight w = FontWeight.w400}) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
          text: s, style: TextStyle(fontSize: size, color: color, letterSpacing: ls, fontWeight: w)),
      textDirection: TextDirection.ltr,
    )..layout();
    double dx = at.dx;
    if (align == TextAlign.center) dx -= tp.width / 2;
    if (align == TextAlign.right) dx -= tp.width;
    tp.paint(c, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (daily.length < 2) return;
    const double W = 364, H = 186, l = 44, r = 76, t = 9, b = 25;
    final int end = math.min(daily.length - 1, math.max(0, dayNow - 1));
    final int start = win >= 3650 ? 0 : math.max(0, end - win + 1);
    final List<double> ser = <double>[];
    for (int i = start; i <= end; i++) {
      ser.add(daily[i]);
    }
    if (ser.length < 2) return;

    canvas.save();
    canvas.scale(size.width / W, size.height / H);
    final double cw = W - l - r, ch = H - t - b;

    double mn = double.infinity, mx = -double.infinity;
    for (final v in ser) {
      if (v > 0 && v < mn) mn = v;
      if (v > mx) mx = v;
    }
    if (mn.isInfinite) mn = 1;
    final bool useLog = autoAxis ? (mx / math.max(1.0, mn) >= 400) : logAxis;
    if (useLog) mn = math.max(1.0, mn * 0.82);
    final double lmn = math.log(mn), lmx = math.log(math.max(mx, mn + 1));

    double yOf(double v) {
      if (useLog) {
        final double lv = math.log(math.max(v, mn));
        return t + ch - (lv - lmn) / (lmx - lmn) * ch;
      }
      return t + ch - (v - mn) / (mx - mn) * ch;
    }

    double xOf(int i) => l + (i - start) / math.max(1, end - start) * cw;
    final bool wanUnit = mx >= 1e5;

    // 网格与 y 轴
    for (int i = 0; i <= 4; i++) {
      final double ratio = i / 4;
      final double v = useLog
          ? math.exp(lmn + (lmx - lmn) * ratio)
          : mn + (mx - mn) * ratio;
      final double y = yOf(v);
      final Paint p = Paint()
        ..color = const Color(0xFFEBECE5)
        ..strokeWidth = 0.7;
      if (i == 0) {
        canvas.drawLine(Offset(l, y), Offset(W - r, y), p);
      } else {
        _dashLine(canvas, Offset(l, y), Offset(W - r, y), p, 1.6, 3.6);
      }
      _text(canvas, fmtAxis(v, wanUnit), Offset(l - 8, y), size: 8, align: TextAlign.right);
    }

    // x 轴
    const List<int> nice = [7, 14, 30, 60, 90, 120, 180, 270, 365, 540, 730, 1095, 1825];
    int xStep = 3650;
    for (final n in nice) {
      if (n >= (end - start) / 4.5) {
        xStep = n;
        break;
      }
    }
    for (int d = start; d <= end; d += xStep) {
      final double x = xOf(d);
      canvas.drawLine(Offset(x, t + ch), Offset(x, t + ch + 3.5),
          Paint()..color = const Color(0xFFD7D9CC)..strokeWidth = 0.7);
      _text(canvas, 'D$d', Offset(x, t + ch + 13), size: 7.5, align: TextAlign.center);
    }

    // 面积与折线
    final Path line = Path();
    for (int i = 0; i < ser.length; i++) {
      final Offset o = Offset(xOf(start + i), yOf(ser[i]));
      if (i == 0) {
        line.moveTo(o.dx, o.dy);
      } else {
        line.lineTo(o.dx, o.dy);
      }
    }
    final Path area = Path.from(line)
      ..lineTo(xOf(end), t + ch)
      ..lineTo(xOf(start), t + ch)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, t),
          Offset(0, t + ch),
          [kInk.withOpacity(0.12), kInk.withOpacity(0)],
        ),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = kInk
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.45
        ..strokeJoin = StrokeJoin.round,
    );

    final Offset endPt = Offset(xOf(end), yOf(ser.last));

    // 等级线与穿越点
    final List<double> usedY = [];
    for (final lv in levels) {
      if (lv.threshold > mx * 1.02) continue;
      final double y = yOf(lv.threshold);
      if (y < t - 4) continue;
      final bool clash =
          usedY.any((v) => (v - y).abs() < 11) || (y - endPt.dy).abs() < 13;
      usedY.add(y);
      canvas.drawLine(Offset(l, y), Offset(W - r, y),
          Paint()..color = const Color(0xFFCCCFC0)..strokeWidth = 0.65);
      if (!clash) {
        _text(canvas, 'L${lv.index} ${lv.name}', Offset(W - r + 6, y), size: 7.5);
      }

      for (final m in miles) {
        if (m.level != lv.index || m.day <= 0) continue;
        if (m.day - 1 < start || m.day - 1 > end) continue;
        final double x = xOf(m.day - 1);
        final Path dia = Path()
          ..moveTo(x, y - 3.6)
          ..lineTo(x + 3.6, y)
          ..lineTo(x, y + 3.6)
          ..lineTo(x - 3.6, y)
          ..close();
        canvas.drawPath(dia, Paint()..color = Colors.white);
        canvas.drawPath(
          dia,
          Paint()
            ..color = kInk
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.9,
        );
        final double ty = (y - 9 < t + 11) ? y + 15 : y - 8;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(x, ty), width: 17, height: 9.5),
            const Radius.circular(2),
          ),
          Paint()..color = kPaper,
        );
        _text(canvas, 'L${lv.index}', Offset(x, ty),
            size: 7, color: kInk2, align: TextAlign.center, w: FontWeight.w600);
      }
    }

    // 末点
    canvas.drawCircle(endPt, 3.3, Paint()..color = kLime);
    canvas.drawCircle(
      endPt,
      3.3,
      Paint()
        ..color = kInk
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );
    _text(canvas, fmtMoney(ser.last), Offset(endPt.dx - 6, endPt.dy - 9),
        size: 9.5, color: kInk, align: TextAlign.right, w: FontWeight.w600);

    canvas.restore();
  }

  void _dashLine(Canvas c, Offset a, Offset b, Paint p, double dash, double gap) {
    final double len = (b - a).distance;
    final Offset dir = (b - a) / len;
    double d = 0;
    while (d < len) {
      final double nd = math.min(d + dash, len);
      c.drawLine(a + dir * d, a + dir * nd, p);
      d = nd + gap;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}
