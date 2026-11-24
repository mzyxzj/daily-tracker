// 内容引进的「识别 + 抓取 + 排序」层。
//
// 目标：从一段平台分享文本里拿到链接，再把封面、标题、作者、时长抓回来，
// 用户只需要决定「归到哪个库」和「这条属于哪一档」。
//
// 这一层只用 dart:io，不依赖 Flutter，全部逻辑都可以单测：
//   - parseShareText     纯文本解析（抖音 / B站 / 小红书 / 公众号…）
//   - fetchContentMeta   联网抓元数据（B站公开 API + og:meta 兜底）
//   - tierForBattery     电量落在哪一档
//   - recommendContent   按「当前档位 + 今日聚焦 + 未看」排序推荐
//
// 网络失败一律降级：用分享文本里的标题 + 平台色块封面，绝不阻塞引进流程。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// 从分享文本里拆出来的东西。url 为空表示这段文本不是分享链接。
class ParsedShare {
  final String url;
  final String platform;
  final String textTitle;
  final String author;
  final List<String> tags;

  const ParsedShare({
    this.url = '',
    this.platform = '',
    this.textTitle = '',
    this.author = '',
    this.tags = const [],
  });

  bool get isEmpty => url.isEmpty;
  String get displayTitle => textTitle.isEmpty ? url : textTitle;

  Map<String, dynamic> toJson() => {
        'url': url,
        'platform': platform,
        'title': textTitle,
        'author': author,
        'tags': tags,
      };

  static ParsedShare fromJson(Map m) => ParsedShare(
        url: '${m['url'] ?? ''}',
        platform: '${m['platform'] ?? ''}',
        textTitle: '${m['title'] ?? ''}',
        author: '${m['author'] ?? ''}',
        tags: (m['tags'] is List)
            ? (m['tags'] as List).map((e) => '$e').toList()
            : const [],
      );
}

/// 抓回来的元数据。fetched=false 表示只拿到了分享文本里的信息。
class ContentMeta {
  final String url;
  final String platform;
  final String title;
  final String cover;
  final String author;
  final String duration;
  final String extId;
  final bool fetched;
  final String note;

  const ContentMeta({
    required this.url,
    this.platform = '',
    this.title = '',
    this.cover = '',
    this.author = '',
    this.duration = '',
    this.extId = '',
    this.fetched = false,
    this.note = '',
  });

  ContentMeta copyWith({
    String? title,
    String? cover,
    String? author,
    String? duration,
    String? extId,
    bool? fetched,
    String? note,
  }) =>
      ContentMeta(
        url: url,
        platform: platform,
        title: title ?? this.title,
        cover: cover ?? this.cover,
        author: author ?? this.author,
        duration: duration ?? this.duration,
        extId: extId ?? this.extId,
        fetched: fetched ?? this.fetched,
        note: note ?? this.note,
      );
}

// ==================== 平台识别 ====================

String contentDetectPlatform(String url) {
  final u = url.toLowerCase();
  if (u.contains('bilibili.com') || u.contains('b23.tv')) return 'B站';
  if (u.contains('douyin.com') || u.contains('iesdouyin.com')) return '抖音';
  if (u.contains('youtube.com') || u.contains('youtu.be')) return 'YouTube';
  if (u.contains('xiaohongshu.com') || u.contains('xhslink.com')) return '小红书';
  if (u.contains('mp.weixin.qq.com')) return '公众号';
  if (u.contains('zhihu.com')) return '知乎';
  if (u.contains('github.com')) return 'GitHub';
  if (u.contains('weibo.com')) return '微博';
  if (u.contains('twitter.com') || u.contains('x.com/')) return 'X';
  if (u.contains('notion.')) return 'Notion';
  return url.trim().isEmpty ? '' : '网页';
}

/// 补协议头、去掉空白；不改变路径本身。
String contentNormalizeUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  s = s.replaceAll(RegExp(r'\s+'), '');
  if (s.startsWith('//')) s = 'https:$s';
  if (!s.contains('://')) s = 'https://$s';
  return s;
}

/// 去掉粘贴时粘在链接尾巴上的中文 / 标点。
String _cleanUrlTail(String raw) {
  var s = raw.trim();
  s = s.replaceAll(RegExp(r'[\)）】\]>，。、；！？,;!?"\u2019\u201d]+$'), '');
  s = s.replaceAll(RegExp(r'[\u4e00-\u9fa5\u3000-\u303f\uff00-\uffef]+$'), '');
  return s;
}

// ==================== 分享文本解析 ====================

final RegExp _urlRe = RegExp(r'https?://[^\s]+', caseSensitive: false);
final RegExp _tagRe = RegExp(r'#\s*([^\s#，。！？、]+)');

String _pickTitle(String raw) {
  var t = raw;
  // 分享文案的正文通常在第一个 # 之前；后面全是话题和平台尾巴。
  final hashAt = t.indexOf('#');
  if (hashAt > 0) t = t.substring(0, hashAt);
  // 抖音尾巴会有「.... r@e.BG :8pm ufo:/ 09/30」这种口令，截在省略号。
  t = t.split(RegExp(r'\.{2,}|。{2,}')).first;
  t = t.replaceAll(RegExp(r'\s+r@\S+.*$'), ' ');
  t = t.replaceAll(_urlRe, ' ');
  t = t.replaceAll(
      RegExp(r'(复制打开抖音|打开抖音|复制打开|看看|抖音|哔哩哔哩|bilibili|网页链接|点击链接|戳链接)',
          caseSensitive: false),
      ' ');
  t = t.replaceAll(RegExp(r'[，,、|·;；]+'), ' ');
  t = t.replaceAll(RegExp(r'[\r\n\t]+'), ' ');
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  t = t.replaceAll(RegExp(r'^[.。…\-\s]+|[.。…\-\s]+$'), '').trim();
  if (t.length > 90) t = t.substring(0, 90).trim();
  return t;
}

/// 【】里的内容按平台惯例拆成「作者 + 标题」。
/// 抖音是「【小猫店长的作品】正文」，B站是「【视频标题-哔哩哔哩】」。
ParsedShare parseShareText(String raw) {
  final text = raw.replaceAll('\u200b', ' ').trim();
  if (text.isEmpty) return const ParsedShare();

  final m = _urlRe.firstMatch(text);
  if (m == null) return const ParsedShare();

  final url = _cleanUrlTail(m.group(0)!);
  if (url.isEmpty) return const ParsedShare();
  final platform = contentDetectPlatform(url);
  final rest = text.replaceRange(m.start, m.end, ' ');

  var author = '';
  var title = '';

  final bm = RegExp(r'【([^】]{1,120})】').firstMatch(rest);
  if (bm != null) {
    final inner = bm.group(1)!.trim();
    final before = rest.substring(0, bm.start);
    final after = rest.substring(bm.end);
    if (inner.contains('的作品')) {
      author = inner.split('的作品').first.trim();
      title = _pickTitle(after.trim().isEmpty ? before : after);
    } else {
      title = _pickTitle(inner
          .replaceAll(RegExp(r'[-_]?\s*哔哩哔哩$'), '')
          .replaceAll(RegExp(r'[-_]?\s*抖音$'), '')
          .trim());
      if (title.isEmpty) title = _pickTitle(after);
    }
  } else {
    title = _pickTitle(rest);
  }

  // 标题太脏（只剩数字 / 表情）时，宁可用链接的域名兜底。
  if (title.replaceAll(RegExp(r'[0-9\s.。…\-]'), '').isEmpty) title = '';

  final tags = <String>[];
  for (final t in _tagRe.allMatches(text)) {
    final v = t.group(1)!.trim();
    if (v.isNotEmpty && !tags.contains(v)) tags.add(v);
  }

  return ParsedShare(
    url: url,
    platform: platform,
    textTitle: title,
    author: author,
    tags: tags,
  );
}

// ==================== 元数据抓取 ====================

const String _kUa =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

String? extractBvid(String text) {
  final m = RegExp(r'(BV[0-9A-Za-z]{10})').firstMatch(text);
  return m?.group(1);
}

String? extractDouyinId(String text) {
  for (final re in [
    RegExp(r'/video/(\d{8,})'),
    RegExp(r'modal_id=(\d{8,})'),
    RegExp(r'/note/(\d{8,})'),
    RegExp(r'aweme_id=(\d{8,})'),
    RegExp(r'item_ids=(\d{8,})'),
  ]) {
    final m = re.firstMatch(text);
    if (m != null) return m.group(1);
  }
  return null;
}

/// 秒 → 12:30 / 1:02:03。
String formatContentDuration(int seconds) {
  if (seconds <= 0) return '';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return '$m:${s.toString().padLeft(2, '0')}';
}

String _decodeEntities(String s) {
  var t = s;
  t = t.replaceAll('&amp;', '&').replaceAll('&quot;', '"');
  t = t.replaceAll('&#39;', "'").replaceAll('&apos;', "'");
  t = t.replaceAll('&lt;', '<').replaceAll('&gt;', '>');
  t = t.replaceAll('&nbsp;', ' ');
  t = t.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    return code == null ? m.group(0)! : String.fromCharCode(code);
  });
  return t;
}

/// 抓 og:meta。两种属性顺序都认（property 在前 / content 在前）。
Map<String, String> parseOgTags(String html) {
  final out = <String, String>{};
  final patterns = [
    RegExp(
        r'<meta[^>]+(?:property|name)\s*=\s*["\x27]([^"\x27]+)["\x27][^>]*content\s*=\s*["\x27]([^"\x27]*)["\x27]',
        caseSensitive: false),
    RegExp(
        r'<meta[^>]+content\s*=\s*["\x27]([^"\x27]*)["\x27][^>]*(?:property|name)\s*=\s*["\x27]([^"\x27]+)["\x27]',
        caseSensitive: false),
  ];
  for (final re in patterns) {
    for (final m in re.allMatches(html)) {
      final a = _decodeEntities(m.group(1)!.trim());
      final b = _decodeEntities(m.group(2)!.trim());
      // 第一个正则：key, value；第二个：value, key
      final key = re == patterns.first ? a : b;
      final val = re == patterns.first ? b : a;
      if (key.isEmpty || val.isEmpty) continue;
      out.putIfAbsent(key.toLowerCase(), () => val);
    }
  }
  if (!out.containsKey('title')) {
    final t = RegExp(r'<title[^>]*>([\s\S]{1,300}?)</title>', caseSensitive: false)
        .firstMatch(html);
    if (t != null) {
      final v = _decodeEntities(t.group(1)!.trim());
      if (v.isNotEmpty) out['title'] = v;
    }
  }
  return out;
}

String _cleanMetaTitle(String raw) {
  var t = raw.trim();
  t = t.replaceAll(RegExp(r'[-_]\s*哔哩哔哩.*$'), '');
  t = t.replaceAll(RegExp(r'[-_]\s*抖音.*$'), '');
  t = t.replaceAll(RegExp(r'[-_]\s*小红书.*$'), '');
  t = t.replaceAll(RegExp(r'^\s*【[^】]*】\s*'), '');
  return t.trim();
}

/// B站 view 接口的 JSON → ContentMeta。抽成纯函数方便单测。
ContentMeta? metaFromBiliJson(Map json, String url) {
  try {
    if (json['code'] != 0) return null;
    final data = json['data'];
    if (data is! Map) return null;
    final title = '${data['title'] ?? ''}'.trim();
    if (title.isEmpty) return null;
    final owner = data['owner'];
    final pic = '${data['pic'] ?? ''}'.trim();
    final sec = (data['duration'] as num?)?.toInt() ?? 0;
    return ContentMeta(
      url: url,
      platform: 'B站',
      title: title,
      cover: pic.isEmpty ? '' : _https(pic),
      author: owner is Map ? '${owner['name'] ?? ''}'.trim() : '',
      duration: formatContentDuration(sec),
      extId: '${data['bvid'] ?? ''}',
      fetched: true,
      note: 'B站接口',
    );
  } catch (_) {
    return null;
  }
}

/// 抖音 iteminfo 接口的 JSON → ContentMeta。
ContentMeta? metaFromDouyinJson(Map json, String url) {
  try {
    final list = json['item_list'];
    if (list is! List || list.isEmpty) return null;
    final item = list.first;
    if (item is! Map) return null;
    final title = '${item['desc'] ?? ''}'.trim();
    final video = item['video'];
    var cover = '';
    var sec = 0;
    if (video is Map) {
      final c = video['cover'];
      if (c is Map) {
        final urls = c['url_list'];
        if (urls is List && urls.isNotEmpty) cover = '${urls.first}';
      }
      sec = ((video['duration'] as num?)?.toInt() ?? 0) ~/ 1000;
    }
    final author = item['author'];
    return ContentMeta(
      url: url,
      platform: '抖音',
      title: title,
      cover: cover.isEmpty ? '' : _https(cover),
      author: author is Map ? '${author['nickname'] ?? ''}'.trim() : '',
      duration: formatContentDuration(sec),
      extId: '${item['aweme_id'] ?? ''}',
      fetched: title.isNotEmpty,
      note: title.isEmpty ? '抖音接口没返回文案' : '抖音接口',
    );
  } catch (_) {
    return null;
  }
}

String _https(String u) {
  if (u.startsWith('http://')) return 'https://${u.substring(7)}';
  if (u.startsWith('//')) return 'https:$u';
  return u;
}

class _Page {
  final String finalUrl;
  final String body;
  final int status;
  const _Page(this.finalUrl, this.body, this.status);
}

Future<String?> _getText(String url, Duration timeout, {Map<String, String>? headers}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  client.userAgent = _kUa;
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
    req.followRedirects = true;
    req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
    headers?.forEach((k, v) => req.headers.set(k, v));
    final resp = await req.close().timeout(timeout);
    final chunks = <int>[];
    await for (final c in resp.timeout(timeout)) {
      chunks.addAll(c);
      if (chunks.length >= 600000) break;
    }
    return utf8.decode(chunks, allowMalformed: true);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<_Page?> _getPage(String url, Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  client.userAgent = _kUa;
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
    req.followRedirects = true;
    req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
    final resp = await req.close().timeout(timeout);
    var finalUrl = url;
    try {
      if (resp.redirects.isNotEmpty) {
        finalUrl = resp.redirects.last.location.toString();
      }
    } catch (_) {}
    final chunks = <int>[];
    await for (final c in resp.timeout(timeout)) {
      chunks.addAll(c);
      if (chunks.length >= 600000) break;
    }
    return _Page(
      finalUrl,
      utf8.decode(chunks, allowMalformed: true),
      resp.statusCode,
    );
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>?> _getJson(String url, Duration timeout) async {
  final text = await _getText(url, timeout, headers: {'Referer': 'https://www.bilibili.com/'});
  if (text == null || text.trim().isEmpty) return null;
  try {
    final d = jsonDecode(text);
    return d is Map ? Map<String, dynamic>.from(d) : null;
  } catch (_) {
    return null;
  }
}

/// 抓一条链接的封面 / 标题 / 作者 / 时长。
/// 失败不抛异常：返回带 fallbackTitle 的 ContentMeta，note 说明降级原因。
Future<ContentMeta> fetchContentMeta(
  String rawUrl, {
  String fallbackTitle = '',
  String fallbackAuthor = '',
  Duration timeout = const Duration(seconds: 9),
}) async {
  final url = contentNormalizeUrl(rawUrl);
  final platform = contentDetectPlatform(url);
  ContentMeta base(String note) => ContentMeta(
        url: url,
        platform: platform,
        title: fallbackTitle.trim(),
        author: fallbackAuthor.trim(),
        fetched: false,
        note: note,
      );

  if (url.isEmpty) return const ContentMeta(url: '', note: '没有链接');

  // B站：短链先跳转拿 BV 号，再走公开 view 接口（标题/封面/时长最准）。
  if (platform == 'B站') {
    var bvid = extractBvid(url);
    var pageHtml = '';
    if (bvid == null) {
      final page = await _getPage(url, timeout);
      if (page != null) {
        pageHtml = page.body;
        bvid = extractBvid(page.finalUrl) ?? extractBvid(page.body);
      }
    }
    if (bvid != null) {
      final json = await _getJson(
          'https://api.bilibili.com/x/web-interface/view?bvid=$bvid', timeout);
      final meta = json == null ? null : metaFromBiliJson(json, url);
      if (meta != null) return meta;
    }
    if (pageHtml.isNotEmpty) {
      final og = parseOgTags(pageHtml);
      final t = _cleanMetaTitle('${og['og:title'] ?? ''}');
      final cover = '${og['og:image'] ?? ''}';
      if (t.isNotEmpty) {
        return ContentMeta(
          url: url,
          platform: platform,
          title: t,
          cover: _https(cover),
          author: fallbackAuthor,
          fetched: true,
          note: 'B站网页',
        );
      }
    }
    return base('B站没抓到，先用分享标题');
  }

  // 抖音：短链跳转后拿 aweme id，先试 iteminfo，再退回 og:meta。
  if (platform == '抖音') {
    final page = await _getPage(url, timeout);
    var id = page == null ? null : extractDouyinId(page.finalUrl);
    var html = page?.body ?? '';
    id ??= extractDouyinId(html);
    if (id != null) {
      final json = await _getJson(
          'https://www.iesdouyin.com/web/api/v2/aweme/iteminfo/?item_ids=$id', timeout);
      final meta = json == null ? null : metaFromDouyinJson(json, url);
      if (meta != null && meta.title.isNotEmpty) return meta;
    }
    if (html.isNotEmpty) {
      final og = parseOgTags(html);
      final t = _cleanMetaTitle('${og['og:title'] ?? ''}'.replaceAll(RegExp(r'^抖音\s*[-—]\s*'), ''));
      final cover = '${og['og:image'] ?? ''}';
      if (t.isNotEmpty && t != '抖音') {
        return ContentMeta(
          url: url,
          platform: platform,
          title: t,
          cover: _https(cover),
          author: fallbackAuthor,
          fetched: true,
          note: '抖音网页',
        );
      }
    }
    return base('抖音要登录才给数据，先用分享标题');
  }

  // 其它平台：og:meta 通用抓法。
  final page = await _getPage(url, timeout);
  if (page != null) {
    final og = parseOgTags(page.body);
    final t = _cleanMetaTitle('${og['og:title'] ?? ''}');
    if (t.isNotEmpty) {
      return ContentMeta(
        url: url,
        platform: platform,
        title: t,
        cover: _https('${og['og:image'] ?? ''}'),
        author: fallbackAuthor,
        fetched: true,
        note: '网页 meta',
      );
    }
  }
  return base('没抓到封面，先用分享标题');
}

// ==================== 分级 & 推荐 ====================

int _i(dynamic v, [int def = 0]) {
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}') ?? def;
}

/// 电量落在哪一档：按 min_b 升序找区间；越界时贴到最近的一档。
Map<String, dynamic>? tierForBattery(List grades, int? battery) {
  final rows = <Map<String, dynamic>>[];
  for (final g in grades) {
    if (g is Map) rows.add(Map<String, dynamic>.from(g));
  }
  if (rows.isEmpty) return null;
  rows.sort((a, b) => _i(a['min_b']).compareTo(_i(b['min_b'])));
  if (battery == null) return null;
  for (final g in rows) {
    final min = _i(g['min_b']);
    final max = _i(g['max_b'], 100);
    if (battery >= min && battery <= max) return g;
  }
  if (battery < _i(rows.first['min_b'])) return rows.first;
  return rows.last;
}

int? tierNumber(Map? g) => g == null ? null : _i(g['tier']);

/// 推荐结果：items 里每条都带了 _score / _reason，UI 直接展示。
class RecommendResult {
  final List<Map<String, dynamic>> items;
  final Map<String, dynamic>? tier;
  final int? battery;
  final bool blocked;
  final String note;

  const RecommendResult({
    this.items = const [],
    this.tier,
    this.battery,
    this.blocked = false,
    this.note = '',
  });

  bool get isEmpty => items.isEmpty;
}

/// 推荐算法：
///   1. 档位命中 > 更轻的档 > 未标级；比当前档更耗电的直接不进候选（可以关掉这个硬过滤）。
///   2. 今日聚焦维度 +32，未看 +14，收藏 +8，优质源平台加权。
///   3. 同一库最多 2 条，保证三条不是同一个维度。
///   4. offset 做确定性轮转，「换一批」不会抖成随机。
RecommendResult recommendContent({
  required List items,
  required List libs,
  required List grades,
  List sources = const [],
  List<String> focusDims = const [],
  int? battery,
  int limit = 3,
  int offset = 0,
  bool onlyCurrentTier = true,
  DateTime? now,
}) {
  final tier = tierForBattery(grades, battery);
  final cur = tierNumber(tier) ?? 0;
  final blocked = tier != null && cur >= 4;
  final nowT = now ?? DateTime.now();

  final libName = <int, String>{};
  for (final l in libs) {
    if (l is Map) libName[_i(l['id'])] = '${l['name'] ?? ''}'.trim();
  }
  final focus = focusDims.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
  final weightByPlatform = <String, int>{};
  for (final s in sources) {
    if (s is! Map) continue;
    final p = '${s['platform'] ?? ''}';
    if (p.isEmpty) continue;
    weightByPlatform[p] = math.max(weightByPlatform[p] ?? 0, _i(s['weight'], 3));
  }

  final scored = <Map<String, dynamic>>[];
  for (final raw in items) {
    if (raw is! Map) continue;
    final e = Map<String, dynamic>.from(raw);
    if (_i(e['state']) == 2) continue; // 看完的不再推

    final t = _i(e['grade_tier']);
    if (onlyCurrentTier && tier != null && t > 0 && t < cur) continue; // 比现在这档更耗电

    var s = 0.0;
    final reasons = <String>[];

    if (tier != null && t > 0) {
      if (t == cur) {
        s += 90;
        reasons.add('正对得上${tier['name']}');
      } else if (t > cur) {
        s += 46;
        reasons.add('比现在这档更轻');
      }
    } else if (t == 0) {
      s += 12;
    }

    final libId = _i(e['lib_id']);
    final name = libName[libId] ?? '';
    if (name.isNotEmpty && focus.contains(name)) {
      s += 32;
      reasons.add('今天聚焦「$name」');
    }

    if (_i(e['state']) == 0) {
      s += 14;
      reasons.add('还没看');
    }
    if (_i(e['fav']) == 1) {
      s += 8;
      reasons.add('收藏');
    }
    s += math.min(_i(e['open_count']), 3).toDouble();
    s += (weightByPlatform['${e['platform'] ?? ''}'] ?? 0) * 3;

    final created = DateTime.tryParse('${e['created_at'] ?? ''}');
    if (created != null) {
      final days = nowT.difference(created).inDays;
      if (days >= 0 && days <= 45) s += (45 - days) * 0.4;
    }

    e['_score'] = s;
    e['_reason'] = reasons.isEmpty ? '库里随手捞的' : reasons.take(2).join(' · ');
    scored.add(e);
  }

  scored.sort((a, b) {
    final d = (b['_score'] as double).compareTo(a['_score'] as double);
    return d != 0 ? d : _i(a['id']).compareTo(_i(b['id']));
  });

  if (scored.isEmpty) {
    return RecommendResult(
      tier: tier,
      battery: battery,
      blocked: blocked,
      note: tier == null
          ? '还没记今天的前额叶电量。去「医疗」记一次，就知道该给你推哪一档。'
          : '「${tier['name']}」下还没有内容。去「内容引进」存两条，标上这档。',
    );
  }

  final start = scored.isEmpty ? 0 : (offset * limit) % scored.length;
  final rotated = <Map<String, dynamic>>[
    ...scored.sublist(start),
    ...scored.sublist(0, start),
  ];

  final picked = <Map<String, dynamic>>[];
  final perLib = <int, int>{};
  for (final e in rotated) {
    if (picked.length >= limit) break;
    final libId = _i(e['lib_id']);
    if ((perLib[libId] ?? 0) >= 2) continue;
    picked.add(e);
    perLib[libId] = (perLib[libId] ?? 0) + 1;
  }
  for (final e in rotated) {
    if (picked.length >= limit) break;
    if (!picked.any((p) => p['id'] == e['id'])) picked.add(e);
  }

  final String tierName = '${tier?['name'] ?? ''}';
  final String forbid = '${tier?['forbid'] ?? ''}'.trim();
  final String note;
  if (blocked) {
    note = '$tierName：${forbid.isEmpty ? '这一档先别喂内容。' : forbid}';
  } else if (tier == null) {
    note = '没记电量，默认按「未看 + 收藏」排，不按档位过滤。';
  } else {
    note = '只推「$tierName」能承接的内容，比这档更耗电的已隐藏。';
  }

  return RecommendResult(
    items: picked,
    tier: tier,
    battery: battery,
    blocked: blocked,
    note: note,
  );
}
