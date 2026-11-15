// DeepSeek 反思面板（重构版）
// 设计要点：
//   1. 气泡式对话：首轮给结论，之后可就任意关注点继续追问（带上下文）
//   2. 「生成最终结论」把整段对话压成：关注点详答 + 其余维度简答，作为导出正文
//   3. 设置区整体折叠成一行摘要，展开后才是 Key / 模型 / 提示词 —— 不再堆一整屏
//   4. 结果按 Markdown 渲染成小标题 + 要点，不再是一大坨纯文本

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

import 'deepseek_service.dart';

const Color _ink = Color(0xFF0F172A);
const Color _sub = Color(0xFF64748B);
const Color _line = Color(0xFFE2E8F0);
const Color _accent = Color(0xFF4F46E5);
const Color _green = Color(0xFF10B981);

const String kDefaultRole = '每日状态系统分析师';

const String kLegacyPrompt =
    '请从最客观、最理性的第一性原理角度分析我今日的状态记录（饮食、体重波动、运动与情绪精力关联），无需单纯情感安慰，请分条给出：1. 生理与能量机制复盘；2. 系统秩序与潜在风险预警；3. 明日具体可执行改进建议。每条格式如“标题：具体分析”。';

const String kDefaultPrompt =
    '用第一性原理分析我今日的记录，不做情绪安慰。\n'
    '先给 3 条「核心判断」，每行一句、不超过 40 字；\n'
    '再用 ### 小标题分 3—5 个板块，每板块 2—4 句短句；\n'
    '涉及数字要给具体值与方向（升/降、超/欠）；\n'
    '不要复述我的原文，不要总结对话。';

const String kFinalPrompt =
    '【收口】请基于以上全部对话，输出可以直接归档的最终版。\n'
    '判断「关注点」的口径：① 我在追问里明确问过的；② 战略聚焦里列出的「下一步」。'
    '两类都算，追问过的优先级更高。\n\n'
    '## 重点关注 · 详细解答\n'
    '每个关注点单独一节（### 小标题），按「机制 → 动作 → 判断标准」写，3—6 句，'
    '要给具体数字或阈值。\n\n'
    '## 其余维度 · 简略结论\n'
    '每个维度一行，格式「维度：一句话结论」，不超过 25 字；没有新信息就写「维持原判断」。\n\n'
    '不要寒暄，不要重复我的原话，不要写“综上”。';

/// 导出结果：由调用方写库，避免面板直接操作页面状态。
class DeepSeekExport {
  final String fieldName;
  final String content;
  const DeepSeekExport({required this.fieldName, required this.content});
}

Future<DeepSeekExport?> showDeepSeekSheet({
  required BuildContext context,
  required Database db,
  required String date,
  required String summaryText,
  required List focusRows,
  String defaultTarget = '反思',
}) {
  return showModalBottomSheet<DeepSeekExport>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.42),
    builder: (_) => DeepSeekSheet(
      db: db,
      date: date,
      summaryText: summaryText,
      focusRows: focusRows,
      defaultTarget: defaultTarget,
    ),
  );
}

class _ChatMsg {
  final String role; // 'user' | 'assistant'
  String content;
  String reasoning;
  bool streaming;
  bool isFinal;

  _ChatMsg(
    this.role, {
    this.content = '',
    this.reasoning = '',
    this.streaming = false,
    this.isFinal = false,
  });
}

class DeepSeekSheet extends StatefulWidget {
  final Database db;
  final String date;
  final String summaryText;
  final List focusRows;
  final String defaultTarget;

  const DeepSeekSheet({
    super.key,
    required this.db,
    required this.date,
    required this.summaryText,
    required this.focusRows,
    this.defaultTarget = '反思',
  });

  @override
  State<DeepSeekSheet> createState() => _DeepSeekSheetState();
}

class _DeepSeekSheetState extends State<DeepSeekSheet> {
  final TextEditingController _keyCtrl = TextEditingController();
  final TextEditingController _roleCtrl = TextEditingController();
  final TextEditingController _promptCtrl = TextEditingController();
  final TextEditingController _targetCtrl = TextEditingController(text: '反思');
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  bool _ready = false;
  bool _showSettings = false;
  bool _showKey = false;
  bool _jsonMode = false;
  String _model = 'deepseek-flash';
  String _effort = 'high';
  bool _running = false;
  String _status = '';
  String _usage = '';

  final List<_ChatMsg> _msgs = [];
  final List<Map<String, String>> _api = [];
  final Set<int> _openThink = <int>{};
  DeepSeekCall? _call;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _call?.cancel();
    _keyCtrl.dispose();
    _roleCtrl.dispose();
    _promptCtrl.dispose();
    _targetCtrl.dispose();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ---------------- 配置读写（只碰 ui_states / 独立密钥文件） ----------------
  Future<String?> _getState(String key) async {
    try {
      final rows = await widget.db.query('ui_states',
          where: 'state_key = ?', whereArgs: [key]);
      if (rows.isNotEmpty) return rows.first['state_val'] as String?;
    } catch (_) {}
    return null;
  }

  Future<void> _putState(String key, String val) async {
    try {
      await widget.db.insert('ui_states', {'state_key': key, 'state_val': val},
          conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {}
  }

  Future<void> _load() async {
    Map cfg = {};
    try {
      final raw = await _getState('deepseek_ai_config');
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) cfg = Map.from(decoded);
      }
    } catch (_) {}

    _model = DeepSeekConfig.models.contains('${cfg['model']}')
        ? '${cfg['model']}'
        : 'deepseek-flash';
    _effort = DeepSeekConfig.efforts.contains('${cfg['effort']}')
        ? '${cfg['effort']}'
        : 'high';
    _jsonMode = cfg['jsonMode'] == true || cfg['jsonMode'] == 'true';

    final role = (cfg['gemName'] ?? '').toString().trim();
    _roleCtrl.text = role.isEmpty ? kDefaultRole : role;

    final prompt = (cfg['gemPrompt'] ?? '').toString().trim();
    _promptCtrl.text =
        (prompt.isEmpty || prompt == kLegacyPrompt) ? kDefaultPrompt : prompt;

    final target = (cfg['targetField'] ?? '').toString().trim();
    _targetCtrl.text = (target.isEmpty ||
            target == 'AI 深度异状分析' ||
            target == 'AI深度异状分析')
        ? widget.defaultTarget
        : target;

    String key = '';
    try {
      key = await DeepSeekKeyStore.read();
    } catch (_) {}
    if (key.isEmpty) key = (cfg['apiKey'] ?? '').toString();
    _keyCtrl.text = key;

    if (mounted) setState(() => _ready = true);
  }

  Future<void> _save() async {
    try {
      await _putState(
        'deepseek_ai_config',
        jsonEncode({
          'model': _model,
          'effort': _effort,
          'jsonMode': _jsonMode,
          'gemName': _roleCtrl.text.trim(),
          'gemPrompt': _promptCtrl.text.trim(),
          'targetField': _targetName(),
        }),
      );
      await DeepSeekKeyStore.write(_keyCtrl.text.trim());
    } catch (_) {}
  }

  String _targetName() {
    final t = _targetCtrl.text.trim();
    return t.isEmpty ? widget.defaultTarget : t;
  }

  // ---------------- 上下文拼装 ----------------
  String _focusBlock() {
    final rows = widget.focusRows.where((e) => e is Map).toList();
    if (rows.isEmpty) return '（今日未设置战略聚焦）';
    final buf = StringBuffer();
    int i = 0;
    for (final raw in rows) {
      final f = raw as Map;
      i++;
      final dim = (f['title'] ?? '').toString().trim();
      final step = (f['next_step'] ?? '').toString().trim();
      final crit = (f['done_criteria'] ?? '').toString().trim();
      final mul = (f['multiplier'] as num?)?.toDouble() ?? 1.0;
      final done = ((f['done'] as int?) ?? 0) == 1;
      final note = (f['note'] ?? '').toString().trim();
      buf.writeln('$i) 维度：${dim.isEmpty ? '未分类' : dim}'
          '｜下一步：${step.isEmpty ? '—' : step}'
          '｜完成标准：${crit.isEmpty ? '—' : crit}'
          '｜乘数：×${mul.toStringAsFixed(3)}'
          '｜状态：${done ? '已突破' : '进行中'}');
      if (note.isNotEmpty) buf.writeln('   当日记录：$note');
    }
    return buf.toString().trim();
  }

  int get _focusDone => widget.focusRows
      .where((e) => e is Map && ((e['done'] as int?) ?? 0) == 1)
      .length;

  String _firstPayload() {
    final n = widget.focusRows.length;
    return '【日期】${widget.date}\n\n'
        '【今日记录】\n${widget.summaryText.trim()}\n\n'
        '【战略聚焦 · $n 项，已突破 $_focusDone 项】\n${_focusBlock()}\n\n'
        '请据此做今日反思：先给 3 条核心判断；再分板块分析「精力与执行的错配」'
        '「战略聚焦的推进实况」「系统性风险」「明日最小动作」。';
  }

  String _systemPrompt() {
    final role = _roleCtrl.text.trim();
    final instr = _promptCtrl.text.trim();
    final base = role.isEmpty ? instr : '你是「$role」。$instr';
    if (_jsonMode) {
      return '$base\n\n【输出格式】严格输出 json 对象：'
          '{"items":[{"title":"板块名","analysis":"具体分析"}]}，'
          '不要 Markdown 代码块，不要额外说明。';
    }
    return '$base\n\n【排版】使用 Markdown：板块标题用 ###，要点用「- 」，关键判断加粗；'
        '单段不超过 4 句。';
  }

  // ---------------- 运行 ----------------
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent + 80,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _runTurn({
    required String userPrompt,
    required String bubbleText,
    bool isFinal = false,
  }) async {
    if (_running) return;
    if (_keyCtrl.text.trim().isEmpty) {
      setState(() {
        _showSettings = true;
        _status = '请先在设置里填写 DeepSeek API Key';
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _showSettings = false;
      _running = true;
      _status = '正在连接 DeepSeek…';
      _usage = '';
      _msgs.add(_ChatMsg('user', content: bubbleText));
    });
    final msg = _ChatMsg('assistant', streaming: true);
    setState(() => _msgs.add(msg));
    _scrollToEnd();

    final history = _api.length > 16
        ? List<Map<String, String>>.from(_api.sublist(_api.length - 16))
        : List<Map<String, String>>.from(_api);
    final call = DeepSeekCall();
    _call = call;
    try {
      await _save();
      final res = await call.run(
        config: DeepSeekConfig(
          apiKey: _keyCtrl.text.trim(),
          model: _model,
          effort: _effort,
          jsonMode: _jsonMode,
        ),
        systemPrompt: _systemPrompt(),
        userPrompt: userPrompt,
        history: history,
        stream: true,
        onDelta: (c, r) {
          if (!mounted || call.cancelled) return;
          setState(() {
            msg.content = c;
            msg.reasoning = r;
            _status = '正在生成…';
          });
          _scrollToEnd();
        },
      );
      if (!mounted) return;
      if (call.cancelled) {
        setState(() {
          msg.streaming = false;
          _running = false;
          _status = '已停止';
        });
        return;
      }
      String text = res.content.trim();
      if (_jsonMode && text.isNotEmpty) {
        final lines = DeepSeekCall.structuredToLines(text);
        if (lines != null) text = lines;
      }
      final u = res.usage;
      setState(() {
        msg.content = text;
        msg.reasoning = res.reasoning;
        msg.streaming = false;
        msg.isFinal = isFinal && text.isNotEmpty;
        _running = false;
        _usage = u == null
            ? ''
            : '　${u['prompt_tokens'] ?? '-'}/${u['completion_tokens'] ?? '-'} tok';
        _status = text.isEmpty ? '模型未返回内容，可重试或换 v4-pro' : '';
        if (text.isNotEmpty && !text.startsWith('⚠️')) {
          _api.add({'role': 'user', 'content': userPrompt});
          _api.add({'role': 'assistant', 'content': text});
        }
      });
      _scrollToEnd();
    } on DeepSeekException catch (e) {
      if (!mounted) return;
      setState(() {
        msg.streaming = false;
        msg.content = '⚠️ ${e.message}';
        _running = false;
        _status = '调用失败';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        msg.streaming = false;
        msg.content = '⚠️ 调用失败：$e';
        _running = false;
        _status = '调用失败';
      });
    } finally {
      _call = null;
      if (mounted && _running) setState(() => _running = false);
    }
  }

  void _start() {
    if (_msgs.isNotEmpty && !_running) {
      // 已经有对话：重开一轮前先确认，避免误触覆盖上下文
      _msgs.clear();
      _api.clear();
      _openThink.clear();
    }
    _runTurn(
      userPrompt: _firstPayload(),
      bubbleText: '开始今日反思 · 今日记录 + ${widget.focusRows.length} 项战略聚焦',
    );
  }

  void _followUp([String? preset]) {
    final text = (preset ?? _inputCtrl.text).trim();
    if (text.isEmpty || _running) return;
    _inputCtrl.clear();
    _runTurn(
      userPrompt: '【追问】$text\n\n请只回答这一点，不要重复前面的内容，给具体做法或判断标准。',
      bubbleText: text,
    );
  }

  void _composeFinal() {
    if (_running) return;
    final hasAssistant =
        _msgs.any((m) => m.role == 'assistant' && m.content.trim().isNotEmpty);
    if (!hasAssistant) {
      setState(() => _status = '先跑一次分析，再收口');
      return;
    }
    _runTurn(
      userPrompt: kFinalPrompt,
      bubbleText: '收口：关注点详答 + 其余维度简答',
      isFinal: true,
    );
  }

  // ---------------- 导出 ----------------
  String _finalText() {
    for (int i = _msgs.length - 1; i >= 0; i--) {
      final m = _msgs[i];
      if (m.role == 'assistant' && m.isFinal && m.content.trim().isNotEmpty) {
        return m.content.trim();
      }
    }
    for (int i = _msgs.length - 1; i >= 0; i--) {
      final m = _msgs[i];
      final c = m.content.trim();
      if (m.role == 'assistant' && c.isNotEmpty && !c.startsWith('⚠️')) return c;
    }
    return '';
  }

  /// Markdown → 每日状态里能直接读的纯文本：小标题换成【】，列表换成 ·。
  String _plain(String md) {
    final out = <String>[];
    for (final raw in md.split('\n')) {
      var l = raw.trimRight();
      if (l.trim().isEmpty) continue;
      l = l.replaceAll('**', '').replaceAll('__', '');
      final h = RegExp(r'^#{1,6}\s*').firstMatch(l);
      if (h != null) {
        final t = l.substring(h.end).trim();
        if (t.isNotEmpty) {
          out.add('');
          out.add('【$t】');
        }
        continue;
      }
      if (RegExp(r'^[-*_]{3,}$').hasMatch(l.trim())) continue;
      l = l.replaceAllMapped(RegExp(r'^[-*•·]\s+'), (m) => '· ');
      out.add(l.trim());
    }
    return out.join('\n').trim();
  }

  void _export() {
    final raw = _finalText();
    if (raw.isEmpty) {
      setState(() => _status = '还没有可导出的内容，先跑一次分析');
      return;
    }
    _save();
    Navigator.pop(
      context,
      DeepSeekExport(fieldName: _targetName(), content: _plain(raw)),
    );
  }

  // ---------------- 视图 ----------------
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final double h = (mq.size.height - mq.viewInsets.bottom) * 0.94;
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Container(
        height: h < 320 ? 320 : h,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: Column(
          children: [
            _handleBar(),
            if (!_ready)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (_showSettings) ...[
              _header(),
              _settingsBar(),
              Expanded(child: _settingsBody()),
              _footer(),
            ] else ...[
              _header(),
              _settingsBar(),
              _scopeRow(),
              const Divider(height: 1, color: _line),
              Expanded(child: _conversation()),
              if (_msgs.isNotEmpty) _quickChips(),
              _composer(),
              _footer(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _handleBar() {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Container(
        width: 38,
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0xFFE2E8F0),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 8),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: _accent.withOpacity(0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.auto_awesome, size: 17, color: _accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('深度反思',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700, color: _ink)),
                const SizedBox(height: 1),
                Text('${widget.date} · DeepSeek 多轮追问',
                    style: const TextStyle(fontSize: 10.5, color: _sub)),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 20, color: _sub),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  String get _effortLabel =>
      {'disabled': '关闭思考', 'low': 'low', 'high': 'high', 'max': 'max'}[_effort] ??
      'high';

  /// 收起态：一行摘要，点开才进设置页。
  Widget _settingsBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: _running
            ? null
            : () => setState(() => _showSettings = !_showSettings),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              const Icon(Icons.tune, size: 15, color: _sub),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '$_model · $_effortLabel · 导出「${_targetName()}」',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: _sub),
                ),
              ),
              Icon(_showSettings ? Icons.expand_less : Icons.expand_more,
                  size: 17, color: _sub),
            ],
          ),
        ),
      ),
    );
  }

  /// 展开态：整页设置，独立滚动，不会把对话区挤爆。
  Widget _settingsBody() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 14),
      children: [
        const Text('修改即自动保存；密钥写在独立文件里，不随备份导出。',
            style: TextStyle(fontSize: 10, color: _sub)),
        const SizedBox(height: 10),
        _keyField(),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(flex: 3, child: _modelDrop()),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: _effortDrop()),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Transform.scale(
              scale: 0.76,
              child: Switch(
                value: _jsonMode,
                activeColor: _accent,
                onChanged: (v) {
                  setState(() => _jsonMode = v);
                  _save();
                },
              ),
            ),
            const SizedBox(width: 4),
            const Expanded(
              child: Text('结构化 JSON（自动拆成「标题：分析」）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: _sub)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _roleField()),
            const SizedBox(width: 8),
            _presetButton(),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _promptCtrl,
          minLines: 3,
          maxLines: 7,
          style: const TextStyle(fontSize: 12, height: 1.45),
          decoration: _dec('反思指令'),
          onChanged: (_) => _save(),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _targetCtrl,
          style: const TextStyle(fontSize: 12.5),
          decoration: _dec('导出到今日的条目名'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => setState(() => _showSettings = false),
            icon: const Icon(Icons.arrow_back, size: 14),
            label: const Text('返回对话', style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
  }

  InputDecoration _dec(String label, {bool dense = true}) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontSize: 11.5, color: _sub),
      isDense: true,
      filled: true,
      fillColor: Colors.white,
      contentPadding: dense
          ? const EdgeInsets.symmetric(horizontal: 9, vertical: 9)
          : const EdgeInsets.all(8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _accent, width: 1.2),
      ),
    );
  }

  Widget _keyField() {
    return TextField(
      controller: _keyCtrl,
      obscureText: !_showKey,
      style: const TextStyle(fontSize: 12),
      decoration: _dec('DeepSeek API Key').copyWith(
        suffixIcon: IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility,
              size: 17, color: _sub),
          onPressed: () => setState(() => _showKey = !_showKey),
        ),
      ),
      onChanged: (_) => _save(),
    );
  }

  Widget _modelDrop() {
    return DropdownButtonFormField<String>(
      value: _model,
      isExpanded: true,
      style: const TextStyle(fontSize: 11.5, color: _ink),
      decoration: _dec('模型'),
      items: const [
        DropdownMenuItem(
            value: 'deepseek-flash',
            child: Text('flash · 快',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5))),
        DropdownMenuItem(
            value: 'deepseek-v4-pro',
            child: Text('v4-pro · 深',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5))),
      ],
      onChanged: (v) {
        setState(() => _model = v ?? 'deepseek-flash');
        _save();
      },
    );
  }

  Widget _effortDrop() {
    return DropdownButtonFormField<String>(
      value: _effort,
      isExpanded: true,
      style: const TextStyle(fontSize: 11.5, color: _ink),
      decoration: _dec('思考'),
      items: const [
        DropdownMenuItem(
            value: 'disabled',
            child: Text('关闭',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5))),
        DropdownMenuItem(
            value: 'low',
            child: Text('low',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5))),
        DropdownMenuItem(
            value: 'high',
            child: Text('high',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5))),
        DropdownMenuItem(
            value: 'max',
            child: Text('max',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5))),
      ],
      onChanged: (v) {
        setState(() => _effort = v ?? 'high');
        _save();
      },
    );
  }

  Widget _roleField() {
    return TextField(
      controller: _roleCtrl,
      style: const TextStyle(fontSize: 12),
      decoration: _dec('分析角色'),
      onChanged: (_) => _save(),
    );
  }

  Widget _presetButton() {
    return PopupMenuButton<Map>(
      tooltip: '预设',
      padding: EdgeInsets.zero,
      onSelected: (p) {
        setState(() {
          _roleCtrl.text = '${p['name']}';
          _promptCtrl.text = '${p['prompt']}';
        });
        _save();
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: {
            'name': '每日状态系统分析师',
            'prompt': kDefaultPrompt,
          },
          child: Text('系统分析师（默认）', style: TextStyle(fontSize: 13)),
        ),
        PopupMenuItem(
          value: {
            'name': '代谢与营养精算师',
            'prompt': '聚焦今日饮食结构（碳水/蛋白质/钠）与体重、训练表现，'
                '先判断水肿或热量缺口，再给明日三餐的具体调整量。用 ### 分板块。',
          },
          child: Text('代谢与营养精算师', style: TextStyle(fontSize: 13)),
        ),
        PopupMenuItem(
          value: {
            'name': '精力与执行教练',
            'prompt': '结合今日日程完成度与战略聚焦，找出精力与任务的错配点，'
                '给明日单线程的减法方案。用 ### 分板块，每条给可执行动作。',
          },
          child: Text('精力与执行教练', style: TextStyle(fontSize: 13)),
        ),
      ],
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: _accent.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _accent.withOpacity(0.22)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmarks_outlined, size: 14, color: _accent),
            SizedBox(width: 4),
            Text('预设',
                style: TextStyle(
                    fontSize: 11.5, color: _accent, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _scopeRow() {
    final String rec = widget.summaryText.trim().isEmpty ? '今日记录 0' : '今日记录 已载入';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _chip(Icons.description_outlined, rec),
                  const SizedBox(width: 6),
                  _chip(Icons.flag_outlined, '战略聚焦 ${widget.focusRows.length}'),
                  const SizedBox(width: 6),
                  _chip(Icons.bolt_outlined, '已突破 $_focusDone'),
                ],
              ),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _previewPayload,
            child: const Text('查看原文', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: _sub),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 10.5, color: _sub)),
        ],
      ),
    );
  }

  void _previewPayload() {
    showDialog(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: Text('将发送给 DeepSeek 的内容', style: TextStyle(fontSize: 15)),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              _firstPayload(),
              style: const TextStyle(fontSize: 11.5, height: 1.55, color: _ink),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  Widget _conversation() {
    if (_msgs.isEmpty) return _emptyState();
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      itemCount: _msgs.length,
      itemBuilder: (_, i) => _bubble(_msgs[i], i),
    );
  }

  Widget _emptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: _accent.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.auto_awesome, size: 24, color: _accent),
            ),
            const SizedBox(height: 14),
            const Text('把今天交给它复盘',
                style: TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w700, color: _ink)),
            const SizedBox(height: 6),
            const Text(
              '会一起读今日记录、战略聚焦与日程完成度。\n先出结论，之后可就某一点继续追问。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, height: 1.6, color: _sub),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 42,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(21)),
                ),
                onPressed: _running ? null : _start,
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('开始分析',
                    style:
                        TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(_ChatMsg m, int index) {
    final bool isUser = m.role == 'user';
    final double maxW = MediaQuery.of(context).size.width * 0.86;
    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, left: 32),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          constraints: BoxConstraints(maxWidth: maxW),
          decoration: BoxDecoration(
            color: _accent.withOpacity(0.08),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(12),
              topRight: Radius.circular(12),
              bottomLeft: Radius.circular(12),
              bottomRight: Radius.circular(3),
            ),
            border: Border.all(color: _accent.withOpacity(0.18)),
          ),
          child: Text(m.content,
              style: const TextStyle(fontSize: 12.5, height: 1.5, color: _ink)),
        ),
      );
    }

    final bool thinking = m.reasoning.trim().isNotEmpty;
    final bool open = _openThink.contains(index);
    return Container(
      margin: const EdgeInsets.only(bottom: 12, right: 20),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 11),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(3),
          topRight: Radius.circular(12),
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
        border: Border.all(color: _line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 12, color: _accent),
              const SizedBox(width: 4),
              const Text('DeepSeek',
                  style: TextStyle(
                      fontSize: 10, color: _sub, fontWeight: FontWeight.w600)),
              if (m.isFinal) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: _green.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('最终结论',
                      style: TextStyle(
                          fontSize: 9,
                          color: _green,
                          fontWeight: FontWeight.w700)),
                ),
              ],
              const Spacer(),
              if (m.content.trim().isNotEmpty && !m.streaming)
                InkWell(
                  onTap: () async {
                    final data = ClipboardData(text: m.content.trim());
                    await Clipboard.setData(data);
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('已复制这一段'),
                          duration: Duration(seconds: 1)),
                    );
                  },
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.copy_all_outlined,
                        size: 13, color: _sub),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (thinking)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                onTap: () => setState(() {
                  if (open) {
                    _openThink.remove(index);
                  } else {
                    _openThink.add(index);
                  }
                }),
                child: Row(
                  children: [
                    Icon(open ? Icons.expand_less : Icons.expand_more,
                        size: 14, color: _sub),
                    const SizedBox(width: 2),
                    Text(open ? '收起思考过程' : '思考过程（${m.reasoning.length} 字）',
                        style: const TextStyle(fontSize: 10, color: _sub)),
                  ],
                ),
              ),
            ),
          if (thinking && open)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(m.reasoning.trim(),
                  style: const TextStyle(
                      fontSize: 10.5, height: 1.5, color: _sub)),
            ),
          if (m.content.trim().isEmpty && m.streaming)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.6)),
                  SizedBox(width: 8),
                  Text('正在思考…',
                      style: TextStyle(fontSize: 11, color: _sub)),
                ],
              ),
            )
          else
            ..._mdWidgets(m.content, streaming: m.streaming),
        ],
      ),
    );
  }

  Widget _quickChips() {
    const presets = [
      '展开第 2 点，给具体执行清单',
      '哪些事可以直接砍掉',
      '明日最小的三步是什么',
      '判断标准怎么量化',
    ];
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: presets.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) => ActionChip(
          label: Text(presets[i], style: const TextStyle(fontSize: 11)),
          labelPadding: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          backgroundColor: const Color(0xFFF8FAFC),
          side: const BorderSide(color: _line),
          onPressed: _running ? null : () => _followUp(presets[i]),
        ),
      ),
    );
  }

  Widget _composer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 40),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _line),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                controller: _inputCtrl,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _followUp(),
                style: const TextStyle(fontSize: 12.5, height: 1.4),
                decoration: const InputDecoration(
                  hintText: '就某一点继续追问，例如「第二条再展开」',
                  hintStyle: TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8)),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 11),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (_running)
            SizedBox(
              width: 40,
              height: 40,
              child: IconButton(
                tooltip: '停止',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFFEE2E2),
                  shape: const CircleBorder(),
                ),
                icon: const Icon(Icons.stop_rounded,
                    size: 18, color: Color(0xFFDC2626)),
                onPressed: () {
                  _call?.cancel();
                  setState(() {
                    _running = false;
                    _status = '已停止';
                  });
                },
              ),
            )
          else
            SizedBox(
              width: 40,
              height: 40,
              child: IconButton(
                tooltip: '发送',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                style: IconButton.styleFrom(
                  backgroundColor:
                      _msgs.isEmpty ? const Color(0xFFE2E8F0) : _accent,
                  shape: const CircleBorder(),
                ),
                icon: Icon(Icons.arrow_upward_rounded,
                    size: 18,
                    color: _msgs.isEmpty ? _sub : Colors.white),
                onPressed: _msgs.isEmpty ? _start : () => _followUp(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _footer() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        child: Column(
          children: [
            if (_status.isNotEmpty || _usage.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    if (_running)
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: SizedBox(
                            width: 11,
                            height: 11,
                            child: CircularProgressIndicator(strokeWidth: 1.6)),
                      ),
                    Expanded(
                      child: Text(
                        '$_status$_usage',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: _status.contains('失败') ||
                                  _status.contains('⚠') ||
                                  _status.contains('请先')
                              ? const Color(0xFFDC2626)
                              : _sub,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  flex: 4,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      side: const BorderSide(color: _line),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: _running || _msgs.isEmpty ? null : _composeFinal,
                    icon: const Icon(Icons.auto_fix_high, size: 15),
                    label: const Text('最终结论',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 6,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _green,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: _export,
                    icon: const Icon(Icons.download_done, size: 16),
                    label: Text('导出到今日「${_targetName()}」',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 极简 Markdown ----------------
  List<TextSpan> _inline(String s) {
    final spans = <TextSpan>[];
    final re = RegExp(r'\*\*([^*]+)\*\*');
    int idx = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > idx) spans.add(TextSpan(text: s.substring(idx, m.start)));
      spans.add(TextSpan(
          text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w700)));
      idx = m.end;
    }
    if (idx < s.length) spans.add(TextSpan(text: s.substring(idx)));
    if (spans.isEmpty) spans.add(TextSpan(text: s));
    return spans;
  }

  Widget _bulletRow(String mark, String body) {
    return Padding(
      padding: const EdgeInsets.only(left: 1, bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 15,
            child: Text(mark,
                style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.62,
                    color: _sub,
                    fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Text.rich(TextSpan(
              children: _inline(body),
              style: const TextStyle(fontSize: 12.5, height: 1.62, color: _ink),
            )),
          ),
        ],
      ),
    );
  }

  List<Widget> _mdWidgets(String text, {bool streaming = false}) {
    final out = <Widget>[];
    final lines = text.split('\n');
    for (int i = 0; i < lines.length; i++) {
      final l = lines[i].trim();
      if (l.isEmpty) {
        out.add(const SizedBox(height: 6));
        continue;
      }
      final h = RegExp(r'^(#{1,6})\s*(.+)$').firstMatch(l);
      if (h != null) {
        final int lv = h.group(1)!.length;
        out.add(Padding(
          padding: EdgeInsets.only(top: out.isEmpty ? 0 : 10, bottom: 4),
          child: Text(
            h.group(2)!.replaceAll('**', '').trim(),
            style: TextStyle(
              fontSize: lv <= 2 ? 14 : 13,
              fontWeight: FontWeight.w700,
              color: _ink,
              height: 1.35,
            ),
          ),
        ));
        continue;
      }
      if (RegExp(r'^[-*_]{3,}$').hasMatch(l)) {
        out.add(const Divider(height: 14, color: _line));
        continue;
      }
      final bullet = RegExp(r'^[-*•·]\s+(.+)$').firstMatch(l);
      if (bullet != null) {
        out.add(_bulletRow('·', bullet.group(1)!));
        continue;
      }
      final numM = RegExp(r'^(\d{1,2})[.、\)]\s+(.+)$').firstMatch(l);
      if (numM != null) {
        out.add(_bulletRow('${numM.group(1)}.', numM.group(2)!));
        continue;
      }
      final quote = RegExp(r'^>\s?(.*)$').firstMatch(l);
      if (quote != null) {
        out.add(Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: _line, width: 2.5)),
          ),
          child: Text.rich(TextSpan(
            children: _inline(quote.group(1)!),
            style: const TextStyle(fontSize: 12, height: 1.55, color: _sub),
          )),
        ));
        continue;
      }
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Text.rich(TextSpan(
          children: _inline(l),
          style: const TextStyle(fontSize: 12.5, height: 1.62, color: _ink),
        )),
      ));
    }
    if (streaming) {
      out.add(const Padding(
        padding: EdgeInsets.only(top: 2),
        child: Text('▌', style: TextStyle(fontSize: 11, color: _accent)),
      ));
    }
    return out;
  }
}
