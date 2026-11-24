// 和 Android 原生层的「复制即弹」通道。
//
// 为什么需要原生：
// Android 10 起，普通 App 在后台读剪贴板会被系统拦掉（还会弹「已粘贴」提示）。
// 所以「复制链接的那一刻就问我」只能由系统级组件来做：
//   - AccessibilityService（无障碍）在任意 App 里监听剪贴板变化，
//   - 再起一个透明 Activity（需要 SYSTEM_ALERT_WINDOW 才能后台起）在屏幕上方弹提示卡，
//   - 点「整理」才启动 App，并把链接作为 Intent extra 传进来。
//
// 这个文件只是 Flutter 侧的薄封装：
//   getInitial()  冷启动时读 Intent 里的链接
//   events        运行中服务读到链接时推过来
//   isEnabled     无障碍服务有没有被用户打开
//   status()      自检：开没开、服务连没连上、最近一次读到剪贴板是多久前
//   test()        立刻弹一条示例提示卡，验证到底能不能显示
//   openSettings  跳到系统的无障碍设置页
//
// 原生没注入（iOS / 桌面 / 单元测试）时全部静默失败，不抛异常。

import 'dart:async';

import 'package:flutter/services.dart';

/// 原生侧的自检快照。
///
/// 「设置里开了」不等于「服务活着」——MIUI 之类会在后台把无障碍服务掐掉，
/// 但系统设置里的开关仍然是开着的。这就是用户「复制了却没弹」的常见原因，
/// 所以这里把 enabled / connected 分开看。
class ClipStatus {
  final bool enabled;
  final bool connected;
  final bool overlayPermission;
  final bool notifyPermission;

  /// 距离上次事件 / 读到剪贴板 / 弹出提示卡 / 识别到「复制」动作过了多少秒；-1 表示从未。
  final int lastEventAgo;
  final int lastClipAgo;
  final int lastOverlayAgo;
  final int lastCopySignalAgo;
  final String lastPkg;
  final String error;

  /// 上次提示走通了哪条通道：activity / notification / overlay / none
  final String promptVia;

  const ClipStatus({
    this.enabled = false,
    this.connected = false,
    this.overlayPermission = false,
    this.notifyPermission = false,
    this.lastEventAgo = -1,
    this.lastClipAgo = -1,
    this.lastOverlayAgo = -1,
    this.lastCopySignalAgo = -1,
    this.lastPkg = '',
    this.error = '',
    this.promptVia = '',
  });

  /// 真正能用：开关开着，服务也在跑。
  bool get working => enabled && connected;

  /// 一句话结论，直接显示在侧边栏卡片上。
  String get headline {
    if (!enabled) return '复制链接就弹窗（未开启）';
    if (!connected) return '已开启，但服务被系统停了';
    return '复制即弹已开启';
  }

  String get detail {
    if (!enabled) return '点一下，开一次无障碍权限就行';
    if (!connected) return '去系统设置把它关掉再打开一次';
    if (!notifyPermission) return '先允许通知：弹不出卡时会改发通知，否则你会什么都看不到';
    if (!overlayPermission) return '能用；给个「显示在其他应用上层」会更稳';
    return '复制抖音/B站分享文案，屏幕上方会直接问你要不要整理';
  }

  /// 上次提示实际走通的通道，给自检面板用。
  String get viaLabel {
    switch (promptVia) {
      case 'activity':
        return '提示卡';
      case 'notification':
        return '通知（提示卡被系统拦了）';
      case 'overlay':
        return '悬浮条';
      case 'none':
        return '全部被拦';
      default:
        return '还没弹过';
    }
  }

  static ClipStatus from(Object? v) {
    if (v is! Map) return const ClipStatus();
    int i(String k) {
      final x = v[k];
      if (x is num) return x.toInt();
      return int.tryParse('${x ?? ''}') ?? -1;
    }

    bool b(String k) => v[k] == true || '${v[k]}' == 'true';

    return ClipStatus(
      enabled: b('enabled'),
      connected: b('connected'),
      overlayPermission: b('overlayPermission'),
      notifyPermission: b('notifyPermission'),
      lastEventAgo: i('lastEventAgo'),
      lastClipAgo: i('lastClipAgo'),
      lastOverlayAgo: i('lastOverlayAgo'),
      lastCopySignalAgo: i('lastCopySignalAgo'),
      lastPkg: '${v['lastPkg'] ?? ''}',
      error: '${v['error'] ?? ''}',
      promptVia: '${v['promptVia'] ?? ''}',
    );
  }
}

class NativeClip {
  static const MethodChannel _m = MethodChannel('daily_tracker/clip');
  static const EventChannel _e = EventChannel('daily_tracker/clip_events');

  static Stream<String>? _stream;

  /// 冷启动：主壳把链接通过 Intent extra 传进来，这里取一次。
  /// 没有就返回空串。
  static Future<String> getInitial() async {
    try {
      final v = await _m.invokeMethod<String>('getInitial');
      return (v ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  /// 无障碍服务是否已开启。没开就说明「复制即弹」不会生效，
  /// UI 上要引导用户去系统设置里打开。
  static Future<bool> isEnabled() async {
    try {
      final v = await _m.invokeMethod<bool>('isEnabled');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 自检快照。拿不到（非 Android / 原生没注入）时返回全 false。
  static Future<ClipStatus> status() async {
    try {
      final v = await _m.invokeMethod<Object?>('status');
      return ClipStatus.from(v);
    } catch (_) {
      return const ClipStatus();
    }
  }

  /// 让服务立刻弹一条示例，用来确认提示卡真的能显示。
  /// 返回 false 说明服务没在跑。
  static Future<bool> test() async {
    try {
      final v = await _m.invokeMethod<bool>('test');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 前台读一次剪贴板（盲弹进来时用：服务读不到，App 一定读得到）。
  static Future<String> readClip() async {
    try {
      final v = await _m.invokeMethod<String>('readClip');
      return (v ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  /// 请求通知权限（Android 13+ 运行时权限）。返回 false 表示系统版本不需要，
  /// 或已经授过权。
  static Future<bool> requestNotify() async {
    try {
      final v = await _m.invokeMethod<bool>('requestNotify');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 通知权限当前是否可用。
  static Future<bool> notifyReady() async {
    try {
      final v = await _m.invokeMethod<bool>('notifyReady');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳系统「无障碍」设置页，让用户自己点开这个服务。
  static Future<bool> openSettings() async {
    try {
      final v = await _m.invokeMethod<bool>('openSettings');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳「显示在其他应用上层」授权页（可选，给了之后后台才能起提示卡）。
  static Future<bool> openOverlaySettings() async {
    try {
      final v = await _m.invokeMethod<bool>('openOverlaySettings');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 运行中：服务读到新链接时推过来（App 在前台时直接弹确认条）。
  static Stream<String> get events {
    _stream ??= _e.receiveBroadcastStream().map((e) => '${e ?? ''}'.trim());
    return _stream!;
  }
}
