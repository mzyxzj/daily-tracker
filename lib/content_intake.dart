// 剪贴板引进：识别 → 确认 → 表单。
//
// 设计取舍：
//   - Android 12+ 每次读剪贴板都会弹系统提示，所以不做周期轮询：
//     只在「从别的 App 切回来」和「点开文化 tab」时各读一次，并做 2.5s 节流。
//   - 同一条链接只问一次（content_seen_urls，最多记 60 条），已经入库的也不再问。
//   - 抓不到元数据不算失败：标题用分享文案，封面用平台色块，仍然一键入库。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

import 'content_fetch.dart';
import 'culture_page.dart';

/// 剪贴板轮询器。由主壳持有，负责「什么时候该问用户」。
class ClipboardIntakeWatcher {
  final Database db;
  final void Function(ParsedShare share) onFound;

  String _lastText = '';
  bool _busy = false;
  bool _armed = false;
  DateTime _lastCheck = DateTime.fromMillisecondsSinceEpoch(0);

  ClipboardIntakeWatcher({required this.db, required this.onFound});

  bool get running => _armed;

  /// 只是「允许读」。真正的读取由 resume / 点文化 tab 触发。
  void start() {
    _armed = true;
  }

  void stop() {
    _armed = false;
  }

  /// 读一次剪贴板。默认 2.5 秒节流，避免连续切 tab 时反复弹系统粘贴提示。
  Future<void> checkNow({bool force = false}) async {
    if (!_armed || _busy) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastCheck).inMilliseconds < 2500) return;
    _lastCheck = now;
    _busy = true;
    try {
      if (!await CultureDb.isClipEnabled(db)) return;
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = (data?.text ?? '').trim();
      if (text.isEmpty || text == _lastText) return;
      _lastText = text;
      final share = parseShareText(text);
      if (share.isEmpty) return;
      if (await CultureDb.isSeenUrl(db, share.url)) return;
      if (await CultureDb.findItemByUrl(db, share.url) != null) {
        await CultureDb.addSeenUrl(db, share.url);
        return;
      }
      onFound(share);
    } catch (_) {
      // 读剪贴板在部分系统上会抛，静默跳过这一轮。
    } finally {
      _busy = false;
    }
  }

  void remember(String url) {
    _lastText = url;
    unawaited(CultureDb.addSeenUrl(db, url));
  }
}

/// 顶部「要不要引进」确认条。
class IntakeBanner extends StatelessWidget {
  final ParsedShare share;
  final VoidCallback onImport;
  final VoidCallback onDismiss;
  final VoidCallback onMute;

  const IntakeBanner({
    super.key,
    required this.share,
    required this.onImport,
    required this.onDismiss,
    required this.onMute,
  });

  @override
  Widget build(BuildContext context) {
    final color = culturePlatformColor(share.platform);
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.22),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(13, 11, 10, 10),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color == const Color(0xFF111827) ? Colors.white : color,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                share.platform.isEmpty ? '链接' : share.platform,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  color: color == const Color(0xFF111827) ? const Color(0xFF0F172A) : Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 7),
            const Text('检测到一条内容，要引进吗？',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white)),
            const Spacer(),
            GestureDetector(
              onTap: onDismiss,
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close, size: 16, color: Color(0xFF94A3B8)),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            share.displayTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, height: 1.4, color: Color(0xFFCBD5E1)),
          ),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: kCultureAccent,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                minimumSize: Size.zero,
              ),
              onPressed: onImport,
              icon: const Icon(Icons.add_link, size: 16),
              label: const Text('引进', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 6),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFCBD5E1),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onDismiss,
              child: const Text('这次不用', style: TextStyle(fontSize: 11)),
            ),
            const Spacer(),
            GestureDetector(
              onTap: onMute,
              child: const Text('以后别自动弹',
                  style: TextStyle(
                      fontSize: 10,
                      color: Color(0xFF64748B),
                      decoration: TextDecoration.underline)),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// 引进表单：封面 / 标题自动填好，只让用户选「分级」和「库」。
class ContentIntakeSheet extends StatefulWidget {
  final Database db;
  final ParsedShare share;
  final List libs;
  final List grades;
  final int? battery;

  const ContentIntakeSheet({
    super.key,
    required this.db,
    required this.share,
    required this.libs,
    required this.grades,
    this.battery,
  });

  @override
  State<ContentIntakeSheet> createState() => _ContentIntakeSheetState();
}

class _ContentIntakeSheetState extends State<ContentIntakeSheet> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _tags = TextEditingController();
  final TextEditingController _author = TextEditingController();

  ContentMeta? _meta;
  Map? _existing;
  bool _loading = true;
  bool _saving = false;
  late int _libId;
  late int _tier;

  @override
  void initState() {
    super.initState();
    _libId = _guessLib();
    _tier = (tierForBattery(widget.grades, widget.battery)?['tier'] as num?)?.toInt() ?? 0;
    _title.text = widget.share.textTitle;
    _tags.text = widget.share.tags.join(' ');
    _author.text = widget.share.author;
    _fetch();
  }

  @override
  void dispose() {
    _title.dispose();
    _tags.dispose();
    _author.dispose();
    super.dispose();
  }

  int _guessLib() {
    if (widget.libs.isEmpty) return 0;
    final hay = '${widget.share.textTitle} ${widget.share.tags.join(' ')}'.toLowerCase();
    int best = 0, bestScore = 0;
    for (final l in widget.libs) {
      if (l is! Map) continue;
      final name = '${l['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      if (hay.contains(name.toLowerCase())) {
        final score = name.length;
        if (score > bestScore) {
          bestScore = score;
          best = (l['id'] as num?)?.toInt() ?? 0;
        }
      }
    }
    if (best != 0) return best;
    for (final l in widget.libs) {
      if (l is Map && '${l['name'] ?? ''}'.trim() == '其他') {
        return (l['id'] as num?)?.toInt() ?? 0;
      }
    }
    return (widget.libs.first as Map)['id'] as int? ?? 0;
  }

  Future<void> _fetch() async {
    final existing = await CultureDb.findItemByUrl(widget.db, widget.share.url);
    final meta = await fetchContentMeta(
      widget.share.url,
      fallbackTitle: widget.share.textTitle,
      fallbackAuthor: widget.share.author,
    );
    if (!mounted) return;
    setState(() {
      _existing = existing;
      _meta = meta;
      _loading = false;
      if (_title.text.trim().isEmpty || _title.text.trim() == widget.share.textTitle) {
        _title.text = meta.title.isNotEmpty ? meta.title : widget.share.textTitle;
      }
      if (_author.text.trim().isEmpty && meta.author.isNotEmpty) {
        _author.text = meta.author;
      }
    });
  }

  String get _kind {
    final p = widget.share.platform;
    if (p == '公众号' || p == '知乎' || p == 'Notion') return '文章';
    return '视频';
  }

  Future<void> _save() async {
    if (_libId == 0) {
      _snack('先选一个库');
      return;
    }
    final title = _title.text.trim();
    if (title.isEmpty) {
      _snack('标题不能为空，抓不到就自己写一句');
      return;
    }
    setState(() => _saving = true);
    final meta = _meta;
    final data = {
      'lib_id': _libId,
      'title': title,
      'url': meta?.url ?? widget.share.url,
      'platform': meta?.platform ?? widget.share.platform,
      'kind': _kind,
      'tags': _tags.text.trim(),
      'note': '',
      'cover': meta?.cover ?? '',
      'duration': meta?.duration ?? '',
      'grade_tier': _tier,
      'author': _author.text.trim(),
      'ext_id': meta?.extId ?? '',
      'from_share': 1,
    };
    try {
      final existing = _existing;
      if (existing != null) {
        await widget.db.update(
          'culture_items',
          {...data, 'updated_at': DateTime.now().toIso8601String()},
          where: 'id = ?',
          whereArgs: [existing['id']],
        );
      } else {
        await CultureDb.addItem(widget.db, data);
      }
      await CultureDb.addSeenUrl(widget.db, '${data['url']}');
      await CultureDb.refreshSignals(widget.db);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _snack('存失败：$e');
      }
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg, style: const TextStyle(fontSize: 12.5)), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final share = widget.share;
    final meta = _meta;
    final platformColor = culturePlatformColor(share.platform);

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      padding: EdgeInsets.fromLTRB(16, 10, 16, 12 + bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                  color: const Color(0xFFE2E8F0), borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Row(children: [
            const Text('内容引进',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: kCultureInk)),
            const SizedBox(width: 7),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: platformColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(share.platform.isEmpty ? '网页' : share.platform,
                  style: TextStyle(
                      fontSize: 9.5, fontWeight: FontWeight.w700, color: platformColor)),
            ),
            const Spacer(),
            if (_loading)
              const Row(children: [
                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6)),
                SizedBox(width: 5),
                Text('抓封面…', style: TextStyle(fontSize: 10.5, color: kCultureSub)),
              ])
            else if (meta != null && meta.fetched)
              const Row(children: [
                Icon(Icons.check_circle, size: 13, color: Color(0xFF22C55E)),
                SizedBox(width: 3),
                Text('已抓取', style: TextStyle(fontSize: 10.5, color: Color(0xFF16A34A))),
              ]),
          ]),
          const SizedBox(height: 10),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(fit: StackFit.expand, children: [
                if (meta != null && meta.cover.isNotEmpty)
                  Image.network(
                    meta.cover,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _coverFallback(platformColor),
                    loadingBuilder: (ctx, child, p) =>
                        p == null ? child : _coverFallback(platformColor, loading: true),
                  )
                else
                  _coverFallback(platformColor, loading: _loading),
                if (meta != null && meta.duration.isNotEmpty)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(4)),
                      child: Text(meta.duration,
                          style: const TextStyle(fontSize: 10, color: Colors.white)),
                    ),
                  ),
              ]),
            ),
          ),
          if (meta != null && !meta.fetched && meta.note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(meta.note,
                style: const TextStyle(fontSize: 10, color: Color(0xFFB45309))),
          ],
          const SizedBox(height: 10),
          TextField(
            controller: _title,
            minLines: 1,
            maxLines: 2,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(
              labelText: '标题（已自动填，可改）',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 9),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _author,
                style: const TextStyle(fontSize: 12.5),
                decoration: const InputDecoration(
                    labelText: '作者 / UP 主', isDense: true, border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 102,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                decoration: BoxDecoration(
                    border: Border.all(color: kCultureLine), borderRadius: BorderRadius.circular(4)),
                child: Text(
                  (meta?.duration ?? '').isEmpty ? '时长未知' : '时长 ${meta!.duration}',
                  style: const TextStyle(fontSize: 11, color: kCultureSub),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 14),
          const Row(children: [
            Text('分级标签',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: kCultureInk)),
            SizedBox(width: 6),
            Text('只选这一个', style: TextStyle(fontSize: 10, color: kCultureSub)),
          ]),
          const SizedBox(height: 7),
          Wrap(spacing: 7, runSpacing: 7, children: [
            for (final g in widget.grades)
              _tierChip(Map<String, dynamic>.from(g as Map)),
            _unratedChip(),
          ]),
          if (_tier > 0) _tierHint(),
          const SizedBox(height: 14),
          const Row(children: [
            Text('归到哪个库',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: kCultureInk)),
            SizedBox(width: 6),
            Text('按聚焦维度自动猜的，可改', style: TextStyle(fontSize: 10, color: kCultureSub)),
          ]),
          const SizedBox(height: 7),
          Wrap(spacing: 7, runSpacing: 7, children: [
            for (final l in widget.libs)
              GestureDetector(
                onTap: () => setState(() => _libId = (l['id'] as num).toInt()),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _libId == l['id'] ? kCultureSoft : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                        color: _libId == l['id'] ? kCultureAccent : kCultureLine),
                  ),
                  child: Text('${l['icon'] ?? ''} ${l['name']}'.trim(),
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: _libId == l['id'] ? FontWeight.w700 : FontWeight.w500,
                          color: _libId == l['id'] ? kCultureAccent : kCultureInk)),
                ),
              ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            style: const TextStyle(fontSize: 12.5),
            decoration: const InputDecoration(
              labelText: '标签（空格分隔，已从分享文案带过来）',
              hintText: '增肌 早餐',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          if (_existing != null) ...[
            const SizedBox(height: 9),
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFDE68A)),
              ),
              child: Text(
                '这条链接已经在库里了（${_existing!['title'] ?? ''}）。保存会更新它，不会再多一条。',
                style: const TextStyle(fontSize: 10.5, height: 1.5, color: Color(0xFF92400E)),
              ),
            ),
          ],
          const SizedBox(height: 13),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: kCultureAccent,
                  padding: const EdgeInsets.symmetric(vertical: 13)),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '保存中…' : '存进库',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _coverFallback(Color color, {bool loading = false}) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withOpacity(0.9), color.withOpacity(0.55)],
        ),
      ),
      child: Center(
        child: loading
            ? const SizedBox(
                width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Text(
                widget.share.displayTitle.isEmpty ? '·' : widget.share.displayTitle.substring(0, 1),
                style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    color: Colors.white.withOpacity(0.92)),
              ),
      ),
    );
  }

  Widget _tierChip(Map g) {
    final t = (g['tier'] as num?)?.toInt() ?? 0;
    final on = _tier == t;
    final color = cultureGradeColor(((g['max_b'] as num?)?.toInt() ?? 100));
    return GestureDetector(
      onTap: () => setState(() => _tier = on ? 0 : t),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: on ? color : color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: on ? color : color.withOpacity(0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
                color: on ? Colors.white : color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text('${g['name'] ?? ''}',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                  color: on ? Colors.white : color)),
        ]),
      ),
    );
  }

  Widget _unratedChip() {
    final on = _tier == 0;
    return GestureDetector(
      onTap: () => setState(() => _tier = 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: on ? const Color(0xFF475569) : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: on ? const Color(0xFF475569) : kCultureLine),
        ),
        child: Text('先不标',
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: on ? Colors.white : kCultureSub)),
      ),
    );
  }

  Widget _tierHint() {
    Map? g;
    for (final e in widget.grades) {
      if ((e['tier'] as num?)?.toInt() == _tier) g = e as Map;
    }
    if (g == null) return const SizedBox.shrink();
    final allow = '${g['allow'] ?? ''}'.trim();
    final forbid = '${g['forbid'] ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        [if (allow.isNotEmpty) '能做：$allow', if (forbid.isNotEmpty) '别碰：$forbid'].join('　'),
        style: const TextStyle(fontSize: 10, height: 1.5, color: kCultureSub),
      ),
    );
  }
}
