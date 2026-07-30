import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../models/models.dart';
import '../security/http_guard.dart';
import 'group_probe.dart';
import 'group_wire.dart';

GroupProbe createProbe(
    GroupTransport transport, ProbeConfig config, ProbeDeps deps) {
  switch (transport) {
    case GroupTransport.relay:
      return RelayProbe(config, deps);
    case GroupTransport.webrtc:
      return WebDavProbe(config, deps);
    case GroupTransport.frp:
      return FrpProbe(config, deps);
    case GroupTransport.lan:
    case GroupTransport.zerotier:
      return LanProbe(config, deps);
  }
}

/// Shared plumbing: elapsed-time stamping and the total-budget guard. Each
/// concrete probe is a sequence of named steps; this base runs them in order,
/// stops feeding new ones once the budget is spent, and guarantees `cleanUp`
/// runs exactly once — whether the run finishes normally, throws, or the
/// consumer calls `cancel()` mid-run.
abstract class _BaseProbe implements GroupProbe {
  final ProbeConfig cfg;
  final ProbeDeps deps;
  bool _cancelled = false;

  /// Guards [cleanUp]: both the normal end-of-`run()` `finally` block and an
  /// in-flight `cancel()` reach for teardown, and there's no ordering
  /// guarantee between them (cancel can land just before or after the loop
  /// notices `_cancelled` on its own). A concrete `cleanUp` that stops a
  /// temporary frpc or deletes a probe file is not safe to run twice, so the
  /// dedup lives here once rather than being a convention every subclass has
  /// to remember.
  bool _cleanedUp = false;

  _BaseProbe(this.cfg, this.deps);

  /// The steps to run, in order. Each returns the step it produced.
  List<Future<ProbeStep> Function()> steps();

  /// Best-effort teardown (stop a temporary frpc, delete a probe file, close
  /// sockets). Always awaited, even on cancel. Subclasses override this —
  /// not [_cleanUpOnce] — the once-only guarantee is enforced by the caller.
  Future<void> cleanUp() async {}

  Future<void> _cleanUpOnce() async {
    if (_cleanedUp) return;
    _cleanedUp = true;
    await cleanUp();
  }

  @override
  Stream<ProbeStep> run() async* {
    final sw = Stopwatch()..start();
    try {
      for (final make in steps()) {
        if (_cancelled) return;
        if (sw.elapsed > deps.timeouts.total) {
          yield ProbeStep(
            title: '其余步骤已跳过',
            outcome: ProbeOutcome.skip,
            detail: '总时长超限（${deps.timeouts.total.inSeconds}s）',
            elapsed: Duration.zero,
          );
          return;
        }
        yield await make();
      }
    } finally {
      await _cleanUpOnce();
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    await _cleanUpOnce();
  }

  /// Times a step body and turns any exception into a `fail` step rather than
  /// letting it escape into the UI.
  static Future<ProbeStep> timed(
    String title,
    Future<ProbeStep> Function() body, {
    String? failHint,
  }) async {
    final sw = Stopwatch()..start();
    try {
      return await body();
    } catch (e) {
      return ProbeStep(
        title: title,
        outcome: ProbeOutcome.fail,
        detail: '${e.runtimeType}: $e',
        elapsed: sw.elapsed,
        hint: failHint,
      );
    }
  }
}

/// Test-only harness for [_BaseProbe]'s shared plumbing — step sequencing,
/// the total-budget guard, and the cleanup-runs-once guarantee. `_BaseProbe`
/// is library-private on purpose (it's an implementation detail of the four
/// concrete probes below, not something outside code should depend on), so a
/// test file in a different library can't subclass it directly; this is the
/// narrow, `@visibleForTesting` door for that instead of making `_BaseProbe`
/// public just to satisfy a test.
@visibleForTesting
class DebugProbe extends _BaseProbe {
  final List<Future<ProbeStep> Function()> Function() stepsBuilder;
  final Future<void> Function()? onCleanUp;

  DebugProbe(
    super.cfg,
    super.deps, {
    required this.stepsBuilder,
    this.onCleanUp,
  });

  @override
  List<Future<ProbeStep> Function()> steps() => stepsBuilder();

  @override
  Future<void> cleanUp() async {
    final cb = onCleanUp;
    if (cb != null) await cb();
  }
}

class RelayProbe extends _BaseProbe {
  RelayProbe(super.cfg, super.deps);

  Uri get _base => Uri.parse(
      (cfg.relayServerUrl ?? '').trim().replaceAll(RegExp(r'/+$'), ''));

  // Address missing means every later step would fail against an empty URI
  // anyway (and _checkUpgrade would hit a null-assertion on relayServerUrl) —
  // short-circuit to the one step that actually explains the problem instead
  // of emitting four more useless failures.
  @override
  List<Future<ProbeStep> Function()> steps() {
    if ((cfg.relayServerUrl ?? '').trim().isEmpty) {
      return [_checkConfig];
    }
    return [
      _checkConfig,
      _checkHealth,
      _checkModules,
      _checkUpgrade,
      _passphraseUnverifiable,
    ];
  }

  Future<ProbeStep> _checkConfig() async {
    final sw = Stopwatch()..start();
    final url = (cfg.relayServerUrl ?? '').trim();
    if (url.isEmpty) {
      return ProbeStep(
        title: '配置完整性',
        outcome: ProbeOutcome.fail,
        detail: '未填中继服务器地址',
        elapsed: sw.elapsed,
        hint: '在「服务器地址」里填 https://ej-backend.<你的域名>，'
            '或局域网直连的 http://<NAS>:48081',
      );
    }
    return ProbeStep(
      title: '配置完整性',
      outcome: ProbeOutcome.pass,
      detail: '$url（令牌${(cfg.relayToken ?? '').isEmpty ? "未设" : "已设"}）',
      elapsed: sw.elapsed,
    );
  }

  Future<ProbeStep> _checkHealth() => _BaseProbe.timed(
        '服务可达（/healthz）',
        () async {
          final sw = Stopwatch()..start();
          final get = deps.httpGet ?? _defaultHttpGet;
          final r = await get(_base.resolve('/healthz'),
              timeout: deps.timeouts.net);
          final ok = r.status == 200;
          return ProbeStep(
            title: '服务可达（/healthz）',
            outcome: ok ? ProbeOutcome.pass : ProbeOutcome.fail,
            detail: 'HTTP ${r.status}${ok ? "" : " · ${_clip(r.body)}"}',
            elapsed: sw.elapsed,
            hint: ok
                ? null
                : '地址或端口不对，或反代没把 /healthz 透传到 ej-backend',
          );
        },
        failHint: '连不上这个地址：确认服务在跑、端口开着、隧道 ingress 指对了',
      );

  Future<ProbeStep> _checkModules() => _BaseProbe.timed(
        '组队模块已启用',
        () async {
          final sw = Stopwatch()..start();
          final get = deps.httpGet ?? _defaultHttpGet;
          final r = await get(_base.resolve('/api/status'),
              timeout: deps.timeouts.net);
          final on = r.body.contains('"group"');
          return ProbeStep(
            title: '组队模块已启用',
            outcome: on ? ProbeOutcome.pass : ProbeOutcome.fail,
            detail: on ? '/api/status 报告 group 已启用' : '/api/status 里没有 group',
            elapsed: sw.elapsed,
            hint: on
                ? null
                : '服务端把组队模块关了：检查 compose 的 EJ_MODULE_GROUP，'
                    '设为 1（或删掉这一行）后重启容器',
          );
        },
        failHint: '拿不到 /api/status —— 服务端版本过旧或被反代拦了',
      );

  Future<ProbeStep> _checkUpgrade() => _BaseProbe.timed(
        'WebSocket 升级',
        () async {
          final sw = Stopwatch()..start();
          final uri = relayWsUri(
            serverUrl: cfg.relayServerUrl!,
            groupId: cfg.groupId,
            selfId: cfg.selfId,
            token: cfg.relayToken,
          );
          final connect = deps.wsConnect ?? _defaultWsConnect;
          ProbeSocket? sock;
          try {
            sock = await connect(uri, deps.timeouts.net);
            final frame = await sock.firstFrame(deps.timeouts.net);
            return ProbeStep(
              title: 'WebSocket 升级',
              outcome: ProbeOutcome.pass,
              detail: frame == null
                  ? '已连接（服务端未主动发帧，属正常）'
                  : '已连接，收到首帧 ${_clip(frame)}',
              elapsed: sw.elapsed,
            );
          } on WebSocketRejected catch (e) {
            return ProbeStep(
              title: 'WebSocket 升级',
              outcome: ProbeOutcome.fail,
              detail: '被拒绝（close code ${e.code}）',
              elapsed: sw.elapsed,
              hint: e.code == 4401
                  ? '中继令牌不对：与服务端 compose 里的 GROUP_TOKEN 必须完全一致'
                  : '升级被拒。经 Cloudflare 时确认 WebSocket 没被关；'
                      '经 Nginx 时确认转发了 Upgrade / Connection 头',
            );
          } finally {
            await sock?.close();
          }
        },
        failHint: '升级失败：中间的反代可能不支持 WebSocket',
      );

  Future<ProbeStep> _passphraseUnverifiable() async => ProbeStep(
        title: '共享口令一致性',
        outcome: ProbeOutcome.skip,
        detail: '单机无法验证',
        elapsed: Duration.zero,
        hint: '口令与别人不一致的症状是「能连上但看不到消息」。'
            '真出现时去组队设置 → 诊断日志看有没有解密失败。',
      );
}

String _clip(String s) => s.length <= 80 ? s : '${s.substring(0, 80)}…';

Future<ProbeHttpResponse> _defaultHttpGet(
  Uri url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final dio = guardedDio()
    ..options.connectTimeout = timeout
    ..options.receiveTimeout = timeout
    ..options.validateStatus = (_) => true; // 状态码由探针自己判定
  final r = await dio.getUri<String>(url,
      options: Options(headers: headers, responseType: ResponseType.plain));
  return ProbeHttpResponse(r.statusCode ?? 0, r.data ?? '');
}

class _IoProbeSocket implements ProbeSocket {
  final WebSocket _ws;
  _IoProbeSocket(this._ws);
  @override
  int? get closeCode => _ws.closeCode;
  @override
  Future<String?> firstFrame(Duration timeout) async {
    try {
      final first = await _ws.first.timeout(timeout);
      return first is String ? first : first.toString();
    } on TimeoutException {
      return null; // 服务端不主动发帧是允许的
    } on StateError {
      return null; // 流已关闭
    }
  }

  @override
  Future<void> close() async {
    try {
      await _ws.close();
    } catch (_) {}
  }
}

Future<ProbeSocket> _defaultWsConnect(Uri url, Duration timeout) async {
  try {
    final ws = await WebSocket.connect(url.toString()).timeout(timeout);
    return _IoProbeSocket(ws);
  } on WebSocketException catch (e) {
    // dart:io 把 HTTP 层的拒绝塞进 message，close code 拿不到；用 -1 表示未知。
    throw WebSocketRejected(_codeFromMessage(e.message));
  }
}

int? _codeFromMessage(String m) {
  final match = RegExp(r'(\d{3,4})').firstMatch(m);
  return match == null ? null : int.tryParse(match.group(1)!);
}

class WebDavProbe extends _BaseProbe {
  WebDavProbe(super.cfg, super.deps);
  @override
  List<Future<ProbeStep> Function()> steps() => [];
}

class FrpProbe extends _BaseProbe {
  FrpProbe(super.cfg, super.deps);
  @override
  List<Future<ProbeStep> Function()> steps() => [];
}

class LanProbe extends _BaseProbe {
  LanProbe(super.cfg, super.deps);
  @override
  List<Future<ProbeStep> Function()> steps() => [];
}
