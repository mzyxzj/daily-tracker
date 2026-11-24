// App 内检查更新 + 下载 + 交给系统安装器。
//
// 为什么要有这个：以前每次改版都得「卸载 → 下载 → 重装 → 重新导数据」，
// 现在侧栏点一下「检查更新」，有新版就地下载并覆盖安装（签名固定，能直接盖）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const String kUpdateRepo = 'mzyxzj/daily-tracker';

class AppVersion {
  final String name;
  final int code;
  const AppVersion({this.name = '', this.code = 0});

  bool get isEmpty => name.isEmpty;
  String get display => name.isEmpty ? '未知' : name;
}

class AppUpdate {
  final String version;
  final String tag;
  final String notes;
  final String apkUrl;
  final String fileName;
  final int size;
  const AppUpdate({
    required this.version,
    required this.tag,
    required this.notes,
    required this.apkUrl,
    required this.fileName,
    required this.size,
  });
}

class AppNative {
  static const MethodChannel _ch = MethodChannel('daily_tracker/app');

  static Future<AppVersion> version() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('version');
      if (m == null) return const AppVersion();
      return AppVersion(
        name: '${m['name'] ?? ''}',
        code: (m['code'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return const AppVersion();
    }
  }

  static Future<bool> canInstall() async {
    try {
      return await _ch.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> install(String name) async {
    try {
      return await _ch.invokeMethod<bool>('installApk', {'name': name}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openInstallSettings() async {
    try {
      return await _ch.invokeMethod<bool>('openInstallSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openUrl(String url) async {
    try {
      return await _ch.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// 比较版本号：a > b 返回 1。
int compareVersion(String a, String b) {
  final pa = a.split(RegExp(r'[.+-]')).map((e) => int.tryParse(e) ?? 0).toList();
  final pb = b.split(RegExp(r'[.+-]')).map((e) => int.tryParse(e) ?? 0).toList();
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x > y ? 1 : -1;
  }
  return 0;
}

/// 查最新 Release。网络不通返回 null 并带上原因。
class UpdateCheck {
  final AppUpdate? update;
  final String error;
  const UpdateCheck(this.update, this.error);
}

Future<UpdateCheck> checkAppUpdate({String repo = kUpdateRepo}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$repo/releases/latest'));
    req.headers.set('Accept', 'application/vnd.github+json');
    req.headers.set('User-Agent', 'daily-tracker');
    final resp = await req.close().timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      return UpdateCheck(null, '接口返回 ${resp.statusCode}');
    }
    final body = await resp.transform(utf8.decoder).join();
    final m = jsonDecode(body) as Map<String, dynamic>;
    final tag = '${m['tag_name'] ?? ''}';
    final notes = '${m['body'] ?? ''}';
    String apk = '';
    String file = '';
    int size = 0;
    for (final a in (m['assets'] as List? ?? const [])) {
      final url = '${a['browser_download_url'] ?? ''}';
      if (url.toLowerCase().endsWith('.apk')) {
        apk = url;
        file = '${a['name'] ?? 'update.apk'}';
        size = (a['size'] as num?)?.toInt() ?? 0;
        break;
      }
    }
    if (apk.isEmpty) return UpdateCheck(null, '这个版本没挂 APK');
    final ver = tag.replaceAll(RegExp(r'^[vV]'), '');
    return UpdateCheck(
      AppUpdate(
        version: ver,
        tag: tag,
        notes: notes,
        apkUrl: apk,
        fileName: file,
        size: size,
      ),
      '',
    );
  } on TimeoutException {
    return UpdateCheck(null, '连不上 GitHub（超时），可以过会儿再试');
  } catch (e) {
    return UpdateCheck(null, '连不上 GitHub：$e');
  } finally {
    client.close(force: true);
  }
}

/// 下载到缓存目录（系统安装器只认这里），支持进度回调。
Future<File> downloadApk(
  AppUpdate u, {
  void Function(int got, int total)? onProgress,
  CancelToken? cancel,
}) async {
  final dir = await getTemporaryDirectory();
  // 文件名必须单层、无斜杠：原生 provider 只放行 cacheDir 下的单个文件。
  final safe = 'dt-update-${u.version}.apk';
  final f = File('${dir.path}/$safe');
  if (await f.exists()) {
    final len = await f.length();
    if (u.size <= 0 || len == u.size) {
      onProgress?.call(len, len);
      return f;
    }
    try {
      await f.delete();
    } catch (_) {}
  }

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  IOSink? sink;
  try {
    final req = await client.getUrl(Uri.parse(u.apkUrl));
    req.headers.set('User-Agent', 'daily-tracker');
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw Exception('下载失败 ${resp.statusCode}');
    }
    final total = resp.contentLength > 0 ? resp.contentLength : u.size;
    sink = f.openWrite();
    var got = 0;
    await for (final chunk in resp) {
      if (cancel?.cancelled == true) throw const _Cancelled();
      sink.add(chunk);
      got += chunk.length;
      onProgress?.call(got, total);
    }
    await sink.flush();
    await sink.close();
    sink = null;
    return f;
  } finally {
    try {
      await sink?.close();
    } catch (_) {}
    client.close(force: true);
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class CancelToken {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

/// 侧栏入口：一屏看完当前版本、最新版本、更新说明，再决定装不装。
Future<void> showUpdateDialog(
  BuildContext context, {
  String repo = kUpdateRepo,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _UpdateDialog(repo: repo),
  );
}

class _UpdateDialog extends StatefulWidget {
  final String repo;
  const _UpdateDialog({required this.repo});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  static const Color _bg = Color(0xFF141A26);
  static const Color _ink = Color(0xFFF8FAFC);

  String _phase = 'checking'; // checking / latest / available / error / downloading / ready
  String _msg = '';
  AppVersion _cur = const AppVersion();
  AppUpdate? _upd;
  int _got = 0;
  int _total = 0;
  final CancelToken _cancel = CancelToken();
  File? _file;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    final v = await AppNative.version();
    final r = await checkAppUpdate(repo: widget.repo);
    if (!mounted) return;
    if (r.update == null) {
      setState(() {
        _cur = v;
        _phase = 'error';
        _msg = r.error;
      });
      return;
    }
    final newer = compareVersion(r.update!.version, v.name) > 0;
    setState(() {
      _cur = v;
      _upd = r.update;
      _phase = newer ? 'available' : 'latest';
    });
  }

  Future<void> _download() async {
    final u = _upd;
    if (u == null) return;
    setState(() {
      _phase = 'downloading';
      _got = 0;
      _total = u.size;
      _msg = '';
    });
    try {
      final f = await downloadApk(u, cancel: _cancel, onProgress: (g, t) {
        if (!mounted) return;
        setState(() {
          _got = g;
          _total = t;
        });
      });
      if (!mounted) return;
      setState(() {
        _phase = 'ready';
        _file = f;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = 'error';
        _msg = '下载失败：$e';
      });
    }
  }

  Future<void> _install() async {
    final f = _file;
    if (f == null) return;
    final ok = await AppNative.canInstall();
    if (!ok) {
      await AppNative.openInstallSettings();
      if (!mounted) return;
      setState(() => _msg = '先允许「安装未知应用」，回来再点一次「安装」');
      return;
    }
    final name = f.path.split('/').last;
    final done = await AppNative.install(name);
    if (!mounted) return;
    if (!done) setState(() => _msg = '安装器没打开，可能被系统拦了');
  }

  Widget _line(String k, String v, {Color? c}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
            width: 78,
            child: Text(k,
                style: const TextStyle(fontSize: 11.5, color: Colors.white54))),
        Expanded(
          child: Text(v,
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: c ?? Colors.white)),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final u = _upd;
    Widget body;
    List<Widget> actions = [];

    switch (_phase) {
      case 'checking':
        body = const Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Center(
              child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white54))),
        );
        break;
      case 'latest':
        body = _line('当前版本', _cur.display, c: const Color(0xFF4ADE80));
        actions = [TextButton(onPressed: () => Navigator.pop(context), child: const Text('好'))];
        break;
      case 'error':
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _line('当前版本', _cur.display),
          const SizedBox(height: 6),
          Text(_msg, style: const TextStyle(fontSize: 11, color: Color(0xFFFCA5A5))),
        ]);
        actions = [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
          TextButton(
              onPressed: () {
                setState(() => _phase = 'checking');
                _run();
              },
              child: const Text('重试')),
          TextButton(
              onPressed: () => AppNative.openUrl(
                  'https://github.com/${widget.repo}/releases'),
              child: const Text('去网页看')),
        ];
        break;
      case 'available':
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _line('当前版本', _cur.display),
          _line('最新版本', u?.version ?? '', c: const Color(0xFF7DD3FC)),
          if ((u?.size ?? 0) > 0)
            _line('安装包', '${((u!.size) / 1024 / 1024).toStringAsFixed(1)} MB'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              (u?.notes ?? '').trim().isEmpty
                  ? '（这一版没写说明）'
                  : (u!.notes.length > 600
                      ? '${u.notes.substring(0, 600)}…'
                      : u.notes),
              style: const TextStyle(
                  fontSize: 10.5, height: 1.6, color: Colors.white60),
            ),
          ),
        ]);
        actions = [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('以后再说')),
          FilledButton(onPressed: _download, child: const Text('下载并安装')),
        ];
        break;
      case 'downloading':
        final p = _total > 0 ? (_got / _total).clamp(0.0, 1.0) : null;
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _line('下载中',
              '${(_got / 1024 / 1024).toStringAsFixed(1)} / ${(_total / 1024 / 1024).toStringAsFixed(1)} MB'),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: p, minHeight: 4),
          const SizedBox(height: 6),
          const Text('下完会自动调起系统安装器',
              style: TextStyle(fontSize: 10.5, color: Colors.white38)),
        ]);
        actions = [
          TextButton(
              onPressed: () {
                _cancel.cancel();
                Navigator.pop(context);
              },
              child: const Text('取消')),
        ];
        break;
      default: // ready
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _line('已下载', '${u?.version ?? ''}', c: const Color(0xFF4ADE80)),
          const SizedBox(height: 6),
          const Text('点「安装」会调起系统安装器；覆盖安装不会丢数据。',
              style: TextStyle(fontSize: 11, height: 1.6, color: Colors.white60)),
          if (_msg.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_msg,
                  style: const TextStyle(fontSize: 10.5, color: Color(0xFFFBBF24))),
            ),
        ]);
        actions = [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
          FilledButton(onPressed: _install, child: const Text('安装')),
        ];
    }

    return AlertDialog(
      backgroundColor: _bg,
      title: const Text('检查更新',
          style: TextStyle(fontSize: 15.5, color: _ink)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [body],
        ),
      ),
      actionsOverflowDirection: VerticalDirection.down,
      actions: actions,
    );
  }
}
