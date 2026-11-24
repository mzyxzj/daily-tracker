// 播放地址解析：把「分享链接」翻译成在我们 App 内部真的能播起来的地址。
//
// 为什么需要这一层：
//   - m.bilibili.com/video/BVxxx 是给手机浏览器看的落地页，页面里全是
//     「打开App，流畅又高清」的引导，点了就跳出 App，等于没在站内播放。
//   - B站给第三方嵌入用的是自己的 HTML5 播放器页（blackboard/html5mobileplayer），
//     只有播放器、没有 App 引导，这才是「站内播放」该加载的地址。
//   - 抖音同理，官方开放平台的 player 页没有下载引导。
//
// 短链（b23.tv / v.douyin.com）需要先跟一次 302 拿到真实 id，所以入口是异步的。

import 'dart:async';
import 'dart:io';

/// 一次播放所需的全部地址。
class PlayTarget {
  /// 首选地址：平台自己的纯净播放器页。
  final String primary;

  /// 首选出不来画面时的第二选择。
  final String fallback;

  /// 最后兜底：桌面版页面（新版播放器，兼容性最好，但布局不适合手机）。
  final String desktop;

  /// 'bili' / 'douyin' / 'web'
  final String kind;

  /// 给用户看的一句话：这条是怎么播的、为什么可能播不了。
  final String note;

  const PlayTarget({
    required this.primary,
    this.fallback = '',
    this.desktop = '',
    this.kind = 'web',
    this.note = '',
  });

  bool get isPlatformPlayer => kind != 'web';
}

const String _kUa =
    'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';

/// BV 号：长度固定 12（BV + 10 位），大小写混排。
String? extractBvId(String text) {
  final m = RegExp(r'(BV[0-9A-Za-z]{10})').firstMatch(text);
  return m?.group(1);
}

/// 抖音 aweme id：一串 18~20 位数字。
String? extractAwemeId(String text) {
  for (final re in [
    RegExp(r'/video/(\d{8,})'),
    RegExp(r'/note/(\d{8,})'),
    RegExp(r'modal_id=(\d{8,})'),
    RegExp(r'aweme_id=(\d{8,})'),
    RegExp(r'item_ids=(\d{8,})'),
  ]) {
    final m = re.firstMatch(text);
    if (m != null) return m.group(1);
  }
  return null;
}

/// B站移动端 HTML5 播放器（无 App 引导，可直接在 WebView 里播）。
///
/// [quality] 是 B站 的 quality 码（80=1080P、64=720P、32=480P、16=360P），
/// 0 表示不指定。页面自己会读 URL 里的 `quality` / `qn` 作为初始档位，
/// 所以在播放器 API 调不动时，重新加载带这个参数的地址是更稳的兜底。
String biliPlayerUrl(String bvid, {bool autoplay = true, int quality = 0}) {
  final q = <String>[
    'bvid=$bvid',
    'page=1',
    'as_wide=1',
    'high_quality=1',
    'danmaku=1',
    if (quality > 0) 'quality=$quality',
    if (autoplay) 'autoplay=1',
  ].join('&');
  return 'https://www.bilibili.com/blackboard/html5mobileplayer.html?$q';
}

/// B站官方 iframe 播放器，作为第二选择。
String biliEmbedUrl(String bvid, {bool autoplay = true}) {
  final q = <String>[
    'bvid=$bvid',
    'page=1',
    'as_wide=1',
    'high_quality=1',
    'danmaku=1',
    if (autoplay) 'autoplay=1',
  ].join('&');
  return 'https://player.bilibili.com/player.html?$q';
}

/// B站桌面版视频页：新版播放器（bpx）走带签名的取流接口，
/// 前两个源都被挡时用它兜底。
String biliDesktopUrl(String bvid) => 'https://www.bilibili.com/video/$bvid';

/// 抖音开放平台播放器页。
String douyinPlayerUrl(String vid, {bool autoplay = true}) {
  return 'https://open.douyin.com/player/video?vid=$vid'
      '${autoplay ? '&autoplay=1' : ''}';
}

/// 跟一次 302，拿到短链真正指向的地址。
/// 失败就原样返回——后面还有「按域名兜底」的逻辑，不会卡死。
Future<String> resolveShareUrl(String url, {Duration timeout = const Duration(seconds: 4)}) async {
  final u = url.trim();
  if (u.isEmpty) return '';
  if (!u.startsWith('http')) return u;
  final client = HttpClient()..connectionTimeout = timeout;
  client.userAgent = _kUa;
  try {
    final req = await client.getUrl(Uri.parse(u)).timeout(timeout);
    req.followRedirects = true;
    req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
    final resp = await req.close().timeout(timeout);
    var out = u;
    try {
      if (resp.redirects.isNotEmpty) {
        out = resp.redirects.last.location.toString();
      }
    } catch (_) {}
    // 只要响应头里的跳转链，不读 body（close(force) 会直接掐断连接）。
    return out;
  } catch (_) {
    return u;
  } finally {
    client.close(force: true);
  }
}

/// 主入口：给一条链接（可能是短链），返回能站内播的地址。
///
/// [knownExtId] 是入库时抓到的 bvid / aweme id，有就直接用，省一次网络请求。
Future<PlayTarget> buildPlayTarget({
  required String url,
  String platform = '',
  String knownExtId = '',
}) async {
  final raw = url.trim();
  if (raw.isEmpty) return const PlayTarget(primary: '', note: '没有链接');
  final u = raw.contains('://') ? raw : 'https://$raw';
  final p = platform.isNotEmpty ? platform : _platformOf(u);

  if (p == 'B站') {
    var bv = extractBvId(knownExtId) ?? '';
    if (bv.isEmpty) bv = extractBvId(u) ?? '';
    var target = u;
    if (bv.isEmpty) {
      target = await resolveShareUrl(u);
      bv = extractBvId(target) ?? extractBvId(u) ?? '';
    }
    if (bv.isNotEmpty) {
      return PlayTarget(
        primary: biliPlayerUrl(bv),
        fallback: biliEmbedUrl(bv),
        desktop: biliDesktopUrl(bv),
        kind: 'bili',
        note: 'B站站内播放器 · 未登录最高 480P',
      );
    }
    return PlayTarget(
      primary: target,
      kind: 'web',
      note: '没认出 BV 号，只能打开网页版',
    );
  }

  if (p == '抖音') {
    var id = extractAwemeId(knownExtId) ?? extractAwemeId(u) ?? '';
    if (id.isEmpty) {
      final t = await resolveShareUrl(u);
      id = extractAwemeId(t) ?? extractAwemeId(u) ?? '';
    }
    if (id.isNotEmpty) {
      return PlayTarget(
        primary: douyinPlayerUrl(id),
        fallback: 'https://www.iesdouyin.com/share/video/$id/',
        kind: 'douyin',
        note: '抖音开放播放器 · 部分视频要作者授权',
      );
    }
    return PlayTarget(primary: u, note: '没认出视频 id');
  }

  return PlayTarget(primary: u);
}

String _platformOf(String u) {
  final s = u.toLowerCase();
  if (s.contains('bilibili.com') || s.contains('b23.tv')) return 'B站';
  if (s.contains('douyin.com') || s.contains('iesdouyin.com')) return '抖音';
  if (s.contains('xiaohongshu.com') || s.contains('xhslink.com')) return '小红书';
  if (s.contains('youtube.com') || s.contains('youtu.be')) return 'YouTube';
  if (s.contains('zhihu.com')) return '知乎';
  return '';
}
