// 推荐流（feed）构建 + 正文抓取。
//
// 与 content_fetch.dart 的分工：
//   - content_fetch：把「一段分享文案」变成「一条结构化的内容」；
//   - content_feed ：把「一库内容」变成「一条可以一直往下刷的流」，并负责把
//     视频/文章的正文取回来，喂给 DeepSeek 生成工具包。
//
// 排序目标是「现在这一刻值得看什么」，不是「最新的」：
//   档位匹配 > 今天聚焦 > 未看 > 新鲜度 > 收藏，扣掉「已经反复打开过」的。
// 呈现在 UI 上是全屏一页一条，所以这里额外做「相邻两页不同库/不同平台」，
// 避免连续四条全是同一个 UP 主，刷起来像掉进一个频道出不来。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'content_fetch.dart';

/// 一页推荐。
class FeedEntry {
  final Map<String, dynamic> item;
  final double score;
  final String reason;
  final bool isCurrentTier;

  const FeedEntry({
    required this.item,
    required this.score,
    required this.reason,
    required this.isCurrentTier,
  });

  String get id => '${item['id'] ?? ''}';
}

/// 整条流的元信息：顶部的电量胶囊、空态文案都从这里取。
class CultureFeedResult {
  final List<FeedEntry> entries;
  final Map<String, dynamic>? tier;
  final int? battery;
  final bool blocked;
  final String headline;
  final String subline;

  const CultureFeedResult({
    this.entries = const [],
    this.tier,
    this.battery,
    this.blocked = false,
    this.headline = '',
    this.subline = '',
  });

  bool get isEmpty => entries.isEmpty;
  int get count => entries.length;
}

int _n(dynamic v, [int def = 0]) {
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}'.trim()) ?? def;
}

/// 构建整条流。
///
/// [onlyCurrentTier] 为 true 时，比当前档「更耗电」的内容直接不进流；
/// 关掉后它们排在后面，但仍然可见（红灯区允许用户自己决定）。
CultureFeedResult buildCultureFeed({
  required List items,
  required List libs,
  required List grades,
  List<String> focusDims = const [],
  int? battery,
  bool onlyCurrentTier = true,
  bool includeRead = false,
  DateTime? now,
}) {
  final tier = tierForBattery(grades, battery);
  final cur = tier == null ? 0 : _n(tier['tier']);
  final blocked = cur >= 4;
  final nowT = now ?? DateTime.now();

  final libName = <int, String>{};
  final libIcon = <int, String>{};
  for (final l in libs) {
    if (l is! Map) continue;
    libName[_n(l['id'])] = '${l['name'] ?? ''}'.trim();
    libIcon[_n(l['id'])] = '${l['icon'] ?? ''}'.trim();
  }
  final focus =
      focusDims.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();

  final scored = <FeedEntry>[];
  for (final raw in items) {
    if (raw is! Map) continue;
    final e = Map<String, dynamic>.from(raw);
    if (!includeRead && _n(e['state']) == 2) continue;

    final t = _n(e['grade_tier']);
    // tier 越大越耗电（1 绿灯 → 4 红灯）。比当前档更耗电的默认不进候选。
    if (onlyCurrentTier && tier != null && t > 0 && t > cur) continue;

    var score = 0.0;
    final reasons = <String>[];

    if (tier != null && t > 0) {
      if (t == cur) {
        score += 92;
        reasons.add('正对得上${tier['name']}');
      } else if (t < cur) {
        // 比现在这档更轻，能看得动但不是最匹配
        score += 44;
        reasons.add('比现在这档轻');
      }
    } else if (t == 0) {
      score += 10;
    }

    final libId = _n(e['lib_id']);
    final name = libName[libId] ?? '';
    if (name.isNotEmpty && focus.contains(name)) {
      score += 30;
      reasons.add('今天聚焦「$name」');
    }

    final state = _n(e['state']);
    if (state == 0) {
      score += 18;
      reasons.add('还没看');
    } else if (state == 1) {
      score += 5;
    }
    if (_n(e['fav']) == 1) {
      score += 10;
      reasons.add('你收藏过');
    }

    // 反复打开过的往下压，避免每次都推同一条。
    final opens = _n(e['open_count']);
    if (opens > 0) score -= (opens * 5).clamp(0, 20).toDouble();

    final created = DateTime.tryParse('${e['created_at'] ?? ''}');
    if (created != null) {
      final days = nowT.difference(created).inDays;
      if (days >= 0 && days <= 30) score += (30 - days) * 0.5;
    }

    // 收藏夹里的东西如果已经看了两遍以上，让它沉下去。
    if (_n(e['fav']) == 1 && opens >= 3) score -= 12;

    scored.add(FeedEntry(
      item: e,
      score: score,
      reason: reasons.isEmpty ? '库里随手捞的' : reasons.take(2).join(' · '),
      isCurrentTier: tier != null && t == cur && t > 0,
    ));
  }

  scored.sort((a, b) {
    final d = b.score.compareTo(a.score);
    if (d != 0) return d;
    return _n(a.item['id']).compareTo(_n(b.item['id']));
  });

  // 相邻去重：每步都优先挑「分数最高、且和上一条不同库/不同平台」的，
  // 挑不到才退回分数最高的那条。这样既不打乱大顺序，又不会连着刷到同一个频道。
  final pool = List<FeedEntry>.from(scored);
  final out = <FeedEntry>[];
  while (pool.isNotEmpty) {
    var pick = -1;
    if (out.isNotEmpty) {
      final prev = out.last;
      final lastTwo = out.length >= 2 ? out[out.length - 2] : null;
      bool sameLib(FeedEntry e) =>
          _n(prev.item['lib_id']) == _n(e.item['lib_id']) &&
          _n(e.item['lib_id']) != 0;
      bool triplePlatform(FeedEntry e) =>
          lastTwo != null &&
          '${lastTwo.item['platform']}' == '${prev.item['platform']}' &&
          '${prev.item['platform']}' == '${e.item['platform']}' &&
          '${e.item['platform']}'.isNotEmpty;

      // 第一优先：不同库且不连着三条同平台。
      for (var i = 0; i < pool.length; i++) {
        if (!sameLib(pool[i]) && !triplePlatform(pool[i])) {
          pick = i;
          break;
        }
      }
      // 第二优先：只要不同库（内容全来自一个平台时这条兜住）。
      if (pick < 0) {
        for (var i = 0; i < pool.length; i++) {
          if (!sameLib(pool[i])) {
            pick = i;
            break;
          }
        }
      }
    }
    if (pick < 0) pick = 0;
    out.add(pool.removeAt(pick));
  }

  final tierName = '${tier?['name'] ?? ''}'.trim();
  final forbid = '${tier?['forbid'] ?? ''}'.trim();
  final allow = '${tier?['allow'] ?? ''}'.trim();
  final String headline;
  final String subline;
  if (battery == null) {
    headline = '还没记电量';
    subline = '先去「医疗」记一次，我就知道现在该给你推哪一档。';
  } else if (blocked) {
    headline = '$battery% · $tierName';
    subline = forbid.isEmpty ? '这一档先别刷内容，去睡。' : '别碰：$forbid';
  } else if (tier == null) {
    headline = '$battery%';
    subline = '没配分级，按「未看 + 收藏」排。';
  } else {
    headline = '$battery% · $tierName';
    subline = allow.isEmpty ? '只推这一档能承接的内容。' : '现在能做：$allow';
  }

  return CultureFeedResult(
    entries: out,
    tier: tier,
    battery: battery,
    blocked: blocked,
    headline: headline,
    subline: subline,
  );
}

// ==================== 正文抓取（喂给 DeepSeek） ====================

Future<String?> _httpGet(String url,
    {Duration timeout = const Duration(seconds: 9),
    Map<String, String>? headers}) async {
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = timeout;
    final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
    req.headers.set(HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/122.0 Mobile Safari/537.36');
    headers?.forEach(req.headers.set);
    final resp = await req.close().timeout(timeout);
    if (resp.statusCode >= 400) return null;
    final body = await resp.transform(utf8.decoder).join().timeout(timeout);
    return body;
  } catch (_) {
    return null;
  } finally {
    try {
      client?.close(force: true);
    } catch (_) {}
  }
}

String _stripHtml(String html) {
  var s = html;
  s = s.replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'<noscript[\s\S]*?</noscript>', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ');
  s = s.replaceAll(RegExp(r'</(p|div|br|li|h[1-6]|tr)>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
  s = s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');
  s = s.replaceAll(RegExp(r'[ \t\u3000]+'), ' ');
  s = s.replaceAll(RegExp(r'\n\s*\n+'), '\n');
  return s.trim();
}

/// 从 B 站链接里取 BV 号（含短链，短链需要先跳一次）。
String? biliBvidOf(String url) {
  final m = RegExp(r'(BV[0-9A-Za-z]{10})').firstMatch(url);
  if (m != null) return m.group(1);
  return null;
}

/// 取一条内容的「正文/简介」，给 DeepSeek 当材料。
///
/// 能拿到的：
///   - B站：`view` 接口的 desc（简介），标题 + 分P 也带上；
///   - 其它站点：页面 og:description + 剥标签后的正文前若干字；
///   - 抖音：网页大多要登录，通常只能拿到 og:description，拿不到就返回空。
/// 拿不到不报错，返回空串，调用方用「标题 + 我的笔记」照样能生成。
Future<String> fetchContentText(String rawUrl, {int maxChars = 6000}) async {
  final url = contentNormalizeUrl(rawUrl);
  if (url.isEmpty) return '';
  final platform = contentDetectPlatform(url);

  if (platform == 'B站') {
    var bv = biliBvidOf(url);
    if (bv == null && url.contains('b23.tv')) {
      // 短链：跟随跳转拿最终地址。
      final hop = await _followRedirect(url);
      if (hop != null) bv = biliBvidOf(hop);
    }
    if (bv != null) {
      final body = await _httpGet(
          'https://api.bilibili.com/x/web-interface/view?bvid=$bv');
      if (body != null) {
        try {
          final m = jsonDecode(body) as Map;
          final d = m['data'];
          if (d is Map) {
            final parts = <String>[];
            final title = '${d['title'] ?? ''}'.trim();
            final desc = '${d['desc'] ?? ''}'.trim();
            if (title.isNotEmpty) parts.add('标题：$title');
            if (desc.isNotEmpty) parts.add('简介：$desc');
            final owner = d['owner'];
            if (owner is Map && '${owner['name'] ?? ''}'.isNotEmpty) {
              parts.add('作者：${owner['name']}');
            }
            final stat = d['stat'];
            if (stat is Map) {
              parts.add('播放 ${stat['view'] ?? 0} · 点赞 ${stat['like'] ?? 0}');
            }
            if (parts.isNotEmpty) {
              final s = parts.join('\n');
              return s.length > maxChars ? s.substring(0, maxChars) : s;
            }
          }
        } catch (_) {}
      }
    }
  }

  final html = await _httpGet(url);
  if (html == null || html.isEmpty) return '';
  final og = parseOgTags(html);
  final buf = StringBuffer();
  final title = '${og['og:title'] ?? og['title'] ?? ''}'.trim();
  final desc = '${og['og:description'] ?? og['description'] ?? ''}'.trim();
  if (title.isNotEmpty) buf.writeln('标题：$title');
  if (desc.isNotEmpty) buf.writeln('简介：$desc');
  final bodyText = _stripHtml(html);
  if (bodyText.isNotEmpty) {
    buf.writeln('正文：');
    buf.write(bodyText);
  }
  var s = buf.toString().trim();
  if (s.length > maxChars) s = s.substring(0, maxChars);
  return s;
}

Future<String?> _followRedirect(String url) async {
  HttpClient? client;
  try {
    final c = HttpClient();
    c.connectionTimeout = const Duration(seconds: 8);
    client = c;
    final req = await c.getUrl(Uri.parse(url));
    req.followRedirects = false; // 只看第一跳的 Location
    req.headers.set(HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/122.0 Mobile Safari/537.36');
    final resp = await req.close();
    final loc = resp.headers.value(HttpHeaders.locationHeader);
    return loc;
  } catch (_) {
    return null;
  } finally {
    try {
      client?.close(force: true);
    } catch (_) {}
  }
}

/// 从一串数字里猜「这条值不值得现在看」——只用于 UI 上的一句话提示。
String feedDurationHint(dynamic raw) {
  final s = '${raw ?? ''}'.trim();
  return s.isEmpty ? '长度未知' : s;
}

/// 给「生成工具包」拼 user prompt。抽出来是为了能单测。
String buildKitPrompt({
  required Map item,
  required String contentText,
  required String myNote,
  required String want,
}) {
  final title = '${item['title'] ?? ''}'.trim();
  final author = '${item['author'] ?? ''}'.trim();
  final platform = '${item['platform'] ?? ''}'.trim();
  final b = StringBuffer();
  b.writeln('【来源】${platform.isEmpty ? '网页' : platform} · $title'
      '${author.isEmpty ? '' : ' · $author'}');
  if (contentText.trim().isNotEmpty) {
    b.writeln('\n【内容原文/简介】');
    b.writeln(contentText.trim());
  } else {
    b.writeln('\n【内容原文/简介】（没抓到，只能靠标题和我的笔记）');
  }
  if (myNote.trim().isNotEmpty) {
    b.writeln('\n【我自己的笔记】');
    b.writeln(myNote.trim());
  }
  b.writeln('\n【我想要的产出】');
  b.writeln(want.trim().isEmpty
      ? '把它变成我今天/本周就能照着做的东西：具体到步骤、模板、检查清单。'
      : want.trim());
  return b.toString();
}

const String kKitSystemPrompt = '''
你是一个「把内容变成工具」的编辑。用户会给你一条视频或文章的标题、简介/正文，
以及他自己写的笔记。你的任务不是总结，而是产出可以直接照着执行的东西。

硬性要求：
1. 先给一句话判断：这条内容最值得留下的那一件事是什么。
2. 给 3-5 个步骤，每一步都要能在 30 分钟内动手，写清「做什么 / 怎么做 / 做完的标准」。
3. 给至少 1 个可复制的模板或清单（用 Markdown 代码块或表格）。
4. 指出这条内容里「听起来有道理但我不该照搬」的部分，最多 2 条。
5. 最后给「下一步」，一句话，今天就能开始。
不要写套话，不要复述原文。用简体中文。
''';

/// 是否像「可播放的视频」，UI 用它决定按钮写「播放」还是「阅读」。
bool looksLikeVideo(Map item) {
  final kind = '${item['kind'] ?? ''}';
  if (kind.contains('视频')) return true;
  final p = '${item['platform'] ?? ''}';
  return p == 'B站' || p == '抖音' || p == 'YouTube' || p == '小红书';
}
