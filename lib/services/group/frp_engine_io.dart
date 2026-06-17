import 'dart:async';
import 'package:flutter/services.dart';
import 'frp_engine.dart';

/// Native-backed engine. Bridges to the gomobile frpc library via:
///   * MethodChannel `explorejournal/frp`      — start / reload / stop / status
///   * EventChannel  `explorejournal/frp_events` — frpc log + tunnel events
///
/// The native handlers live in:
///   android/app/src/main/kotlin/.../FrpPlugin.kt
///   ios/Runner/FrpPlugin.swift
/// both calling into the gomobile `Frpmobile` package. See docs/frp_embed.md.
FrpEngine createEngine() => _IoFrpEngine();

class _IoFrpEngine implements FrpEngine {
  static const _method = MethodChannel('explorejournal/frp');
  static const _eventCh = EventChannel('explorejournal/frp_events');

  Stream<String>? _events;

  @override
  Stream<String> get events => _events ??= _eventCh
      .receiveBroadcastStream()
      .map((e) => e?.toString() ?? '')
      .handleError((_) {}); // a missing native side just yields no events

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on MissingPluginException {
      throw const FrpUnsupported('当前平台未内置 frpc（缺少原生库）');
    } on PlatformException catch (e) {
      throw FrpUnsupported(e.message ?? 'frp 原生调用失败');
    }
  }

  @override
  Future<void> start(String configToml) =>
      _guard(() => _method.invokeMethod<void>('start', {'config': configToml}));

  @override
  Future<void> reload(String configToml) =>
      _guard(() => _method.invokeMethod<void>('reload', {'config': configToml}));

  @override
  Future<void> stop() => _guard(() => _method.invokeMethod<void>('stop'));

  @override
  Future<bool> isRunning() =>
      _guard(() async => await _method.invokeMethod<bool>('status') ?? false);
}
