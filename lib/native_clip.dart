// 和 Android 原生层的「复制即弹」通道。
//
// 为什么需要原生：
// Android 10 起，普通 App 在后台读剪贴板会被系统拦掉（还会弹「已粘贴」提示）。
// 所以「复制链接的那一刻就问我」只能由系统级组件来做：
//   - AccessibilityService（无障碍）在任意 App 里监听剪贴板变化，
//   - 再用悬浮窗（SYSTEM_ALERT_WINDOW）在屏幕上方弹一个小条，
//   - 点「整理」才启动 App，并把链接作为 Intent extra 传进来。
//
// 这个文件只是 Flutter 侧的薄封装：
//   getInitial()  冷启动时读 Intent 里的链接
//   events        运行中服务读到链接时推过来
//   isEnabled     无障碍服务有没有被用户打开
//   openSettings  跳到系统的无障碍设置页
//
// 原生没注入（iOS / 桌面 / 单元测试）时全部静默失败，不抛异常。

import 'dart:async';

import 'package:flutter/services.dart';

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

  /// 跳系统「无障碍」设置页，让用户自己点开这个服务。
  static Future<bool> openSettings() async {
    try {
      final v = await _m.invokeMethod<bool>('openSettings');
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
