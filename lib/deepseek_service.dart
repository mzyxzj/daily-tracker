// DeepSeek API 服务层（零第三方依赖，仅使用 Dart SDK 自带的 dart:io）
// 官方文档：https://api-docs.deepseek.com
//   base_url   : https://api.deepseek.com （OpenAI 兼容格式）
//   endpoint   : POST /chat/completions
//   auth       : Authorization: Bearer <API_KEY>
//   models     : deepseek-flash (V4.1-Flash) / deepseek-v4-pro (V4-Pro)
//   thinking   : {"thinking":{"type":"enabled|disabled"}} + reasoning_effort low/high/max
//   响应       : message.content（结论）、message.reasoning_content（思维链 / 反思过程）
//   json mode  : response_format {"type":"json_object"}
//   stream     : SSE，data: {...} / data: [DONE]

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// API Key 单独存放在应用文档目录的文件里，不写入 ui_states 表。
/// 原因：自带的「导出备份」会把 ui_states 整表 dump 进 data.json 并分享出去，
/// 把密钥放数据库会随备份文件外泄；独立文件不会被该备份打包。
class DeepSeekKeyStore {
  static const String _fileName = 'deepseek_api_key.txt';

  static Future<File> _file() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _fileName));
  }

  static Future<String> read() async {
    try {
      final File f = await _file();
      if (!await f.exists()) return '';
      return (await f.readAsString()).trim();
    } catch (_) {
      return '';
    }
  }

  static Future<void> write(String key) async {
    try {
      final File f = await _file();
      if (key.trim().isEmpty) {
        if (await f.exists()) await f.delete();
      } else {
        await f.writeAsString(key.trim(), flush: true);
      }
    } catch (_) {}
  }
}

class DeepSeekException implements Exception {
  final String message;
  const DeepSeekException(this.message);

  @override
  String toString() => message;
}

class DeepSeekConfig {
  final String apiKey;
  final String model;
  final String effort; // 'disabled' | 'low' | 'high' | 'max'
  final bool jsonMode;
  final String baseUrl;

  const DeepSeekConfig({
    required this.apiKey,
    this.model = 'deepseek-flash',
    this.effort = 'high',
    this.jsonMode = false,
    this.baseUrl = 'https://api.deepseek.com',
  });

  static const List<String> models = <String>['deepseek-flash', 'deepseek-v4-pro'];
  static const List<String> efforts = <String>['disabled', 'low', 'high', 'max'];
}

class DeepSeekResult {
  String content;
  String reasoning;
  Map<String, dynamic>? usage;

  DeepSeekResult({this.content = '', this.reasoning = '', this.usage});
}

typedef DeepSeekDelta = void Function(String content, String reasoning);

class DeepSeekCall {
  HttpClient? _client;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    try {
      _client?.close(force: true);
    } catch (_) {}
  }

  /// [history] 传给多轮对话：形如 [{'role': 'user', 'content': ...}, ...]，
  /// 不含 system 与本次的 userPrompt（这两项由此函数自己拼）。
  Future<DeepSeekResult> run({
    required DeepSeekConfig config,
    required String systemPrompt,
    String userPrompt = '',
    List<Map<String, String>> history = const <Map<String, String>>[],
    bool stream = true,
    DeepSeekDelta? onDelta,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (config.apiKey.trim().isEmpty) {
      throw const DeepSeekException('尚未填写 DeepSeek API Key，请在上方输入后再开始分析。');
    }
    if (!DeepSeekConfig.models.contains(config.model)) {
      throw const DeepSeekException('模型名称不合法。');
    }

    final bool thinkingEnabled = config.effort != 'disabled';
    final List<Map<String, String>> messages = <Map<String, String>>[
      <String, String>{'role': 'system', 'content': systemPrompt},
    ];
    for (final Map<String, String> h in history) {
      final String role = (h['role'] ?? '').toString();
      final String content = (h['content'] ?? '').toString();
      if (content.trim().isEmpty) continue;
      if (role != 'user' && role != 'assistant') continue;
      messages.add(<String, String>{'role': role, 'content': content});
    }
    if (userPrompt.trim().isNotEmpty) {
      messages.add(<String, String>{'role': 'user', 'content': userPrompt});
    }

    final Map<String, dynamic> body = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      'stream': stream,
      'thinking': <String, String>{'type': thinkingEnabled ? 'enabled' : 'disabled'},
      'max_tokens': 4096,
    };
    if (thinkingEnabled) {
      body['reasoning_effort'] = config.effort;
    }
    if (config.jsonMode) {
      body['response_format'] = <String, String>{'type': 'json_object'};
    }

    _client = HttpClient();
    _client!.connectionTimeout = const Duration(seconds: 15);
    try {
      final String root = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
      final Uri uri = Uri.parse('$root/chat/completions');
      final HttpClientRequest req = await _client!.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey.trim()}');
      req.headers.set(HttpHeaders.acceptHeader, stream ? 'text/event-stream' : 'application/json');
      req.add(utf8.encode(jsonEncode(body)));

      final HttpClientResponse resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) {
        final String text = await resp.transform(utf8.decoder).join();
        throw DeepSeekException(_friendlyError(resp.statusCode, text));
      }
      return stream
          ? await _readStream(resp, onDelta)
          : await _readOnce(resp, onDelta);
    } on DeepSeekException {
      rethrow;
    } on SocketException catch (e) {
      throw DeepSeekException('网络连接失败：${e.message}（请确认已开启联网权限）');
    } on TimeoutException {
      throw const DeepSeekException('请求超时，请检查网络或稍后重试。');
    } catch (e) {
      if (_cancelled) throw const DeepSeekException('分析已取消。');
      throw DeepSeekException('调用失败：$e');
    } finally {
      try {
        _client?.close(force: true);
      } catch (_) {}
      _client = null;
    }
  }

  Future<DeepSeekResult> _readOnce(
      HttpClientResponse resp, DeepSeekDelta? onDelta) async {
    final String text = await resp.transform(utf8.decoder).join();
    final Map<String, dynamic> obj = jsonDecode(text) as Map<String, dynamic>;
    final List<dynamic> choices = (obj['choices'] as List<dynamic>?) ?? <dynamic>[];
    Map<String, dynamic> msg = <String, dynamic>{};
    if (choices.isNotEmpty) {
      final dynamic first = choices.first;
      if (first is Map) {
        final dynamic raw = first['message'] ?? first['delta'];
        if (raw is Map) msg = Map<String, dynamic>.from(raw);
      }
    }
    final String content = (msg['content'] ?? '').toString();
    final String reasoning = (msg['reasoning_content'] ?? '').toString();
    final DeepSeekResult res = DeepSeekResult(
      content: content,
      reasoning: reasoning,
      usage: obj['usage'] is Map
          ? Map<String, dynamic>.from(obj['usage'] as Map)
          : null,
    );
    if (onDelta != null) onDelta(content, reasoning);
    return res;
  }

  Future<DeepSeekResult> _readStream(
      HttpClientResponse resp, DeepSeekDelta? onDelta) async {
    final DeepSeekResult res = DeepSeekResult();
    String buffer = '';
    bool done = false;
    await for (final String chunk in resp.transform(utf8.decoder)) {
      if (_cancelled || done) break;
      buffer += chunk;
      while (buffer.contains('\n')) {
        final int idx = buffer.indexOf('\n');
        final String line = buffer.substring(0, idx).trimRight();
        buffer = buffer.substring(idx + 1);
        if (!line.startsWith('data:')) continue;
        final String data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') {
          done = true;
          break;
        }

        final Map<String, dynamic> obj;
        try {
          obj = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        if (obj['usage'] is Map) {
          res.usage = Map<String, dynamic>.from(obj['usage'] as Map);
        }
        final List<dynamic>? choices = obj['choices'] as List<dynamic>?;
        if (choices == null || choices.isEmpty) continue;
        final dynamic first = choices.first;
        if (first is! Map) continue;
        final dynamic delta = first['delta'];
        if (delta is! Map) continue;

        final String c = (delta['content'] ?? '').toString();
        final String r = (delta['reasoning_content'] ?? '').toString();
        if (c.isNotEmpty) res.content += c;
        if (r.isNotEmpty) res.reasoning += r;
        if ((c.isNotEmpty || r.isNotEmpty) && onDelta != null) {
          onDelta(res.content, res.reasoning);
        }
      }
    }
    return res;
  }

  String _friendlyError(int code, String text) {
    String detail = '';
    try {
      final dynamic decoded = jsonDecode(text);
      if (decoded is Map) {
        final dynamic err = decoded['error'];
        detail = (err is Map ? err['message'] : decoded['message'])?.toString() ?? '';
      }
    } catch (_) {}
    final String suffix = detail.isEmpty ? '' : '：$detail';
    switch (code) {
      case 400:
        return '请求参数有误（400）$suffix';
      case 401:
        return 'API Key 无效或已过期（401），请核对后重新填写。';
      case 402:
        return '账户余额不足（402），请到 DeepSeek 开放平台充值后再试。';
      case 422:
        return '请求内容不合法（422）$suffix';
      case 429:
        return '请求过于频繁或额度不足（429），请稍后重试。';
      default:
        if (code >= 500) return 'DeepSeek 服务暂时不可用（$code），请稍后重试。';
        return '调用失败（$code）$suffix';
    }
  }

  /// 把 JSON 结构化输出转换为「标题：具体分析」的多行文本，
  /// 使原有的「导出到每日状态」逻辑无需任何改动即可继续使用。
  static String? structuredToLines(String raw) {
    String s = raw.trim();
    if (s.startsWith('```')) {
      s = s.replaceAll(RegExp(r'^```[a-zA-Z]*\s*'), '');
      s = s.replaceAll(RegExp(r'\s*```\s*$'), '');
    }
    try {
      final dynamic obj = jsonDecode(s);
      dynamic items;
      if (obj is Map) {
        items = obj['items'] ?? obj['analyses'] ?? obj['sections'] ?? obj['result'];
        if (items == null) {
          final StringBuffer buf = StringBuffer();
          obj.forEach((k, v) {
            final String val = v is List ? v.join('；') : v.toString();
            buf.writeln('$k：$val');
          });
          final String out = buf.toString().trim();
          return out.isEmpty ? null : out;
        }
      } else if (obj is List) {
        items = obj;
      }
      if (items is! List) return null;
      final StringBuffer buf = StringBuffer();
      for (final dynamic it in items) {
        if (it is Map) {
          final String t = (it['title'] ?? it['name'] ?? it['标题'] ?? '')
              .toString()
              .trim();
          final String a = (it['analysis'] ??
                  it['content'] ??
                  it['detail'] ??
                  it['内容'] ??
                  '')
              .toString()
              .trim();
          if (t.isEmpty && a.isEmpty) continue;
          buf.writeln(t.isEmpty ? a : (a.isEmpty ? t : '$t：$a'));
        } else if (it != null) {
          buf.writeln(it.toString().trim());
        }
      }
      final String out = buf.toString().trim();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }
}
