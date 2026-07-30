import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:webdav_client/webdav_client.dart' as webdav;

import '../../models/models.dart';
import '../security/http_guard.dart';
import 'frp_config.dart';
import 'frp_engine.dart';
import 'group_probe.dart';
import 'group_wire.dart';
import 'multicast_lock_io.dart';

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
/// stops feeding new ones once the budget is spent, and drives `cleanUp`
/// whether the run finishes normally, throws, or the consumer calls `cancel()`
/// mid-run.
abstract class _BaseProbe implements GroupProbe {
  final ProbeConfig cfg;
  final ProbeDeps deps;

  /// Set by [cancel]. Steps that are about to acquire something expensive
  /// check it so a cancel that lands mid-run doesn't get followed by a fresh
  /// frpc start or a 12-second login wait nobody is listening to.
  bool _cancelled = false;

  _BaseProbe(this.cfg, this.deps);

  /// The steps to run, in order. Each returns the step it produced.
  List<Future<ProbeStep> Function()> steps();

  /// Best-effort teardown (stop a temporary frpc, delete a probe file, close
  /// sockets). Called unconditionally from `run()`'s `finally` AND from
  /// [cancel] — possibly twice, possibly concurrently, and possibly BEFORE the
  /// resource exists.
  ///
  /// That last case is why there is no once-only guard here any more. `cancel()`
  /// is routinely invoked without `await` (see `ProbeController.dispose`) while
  /// an `await openDatagram()` / `await engine.start()` is still in flight: at
  /// that instant the probe owns nothing, so teardown has nothing to do — and a
  /// guard that recorded "cleanup already happened" would make the `finally`,
  /// which runs after the acquire lands, skip the only teardown that could have
  /// released it. A temporary frpc left running forever is the expensive
  /// version of that leak.
  ///
  /// So: implementations must be IDEMPOTENT instead. Take the field into a
  /// local, clear the field, then release the local — that is safe to run any
  /// number of times, in any interleaving, and it still cleans up a resource
  /// that only appeared after the first attempt.
  Future<void> cleanUp() async {}

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
      await cleanUp();
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    await cleanUp();
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
/// the total-budget guard, and the cleanup-always-runs guarantee. `_BaseProbe`
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
            // No branching on e.code: dart:io throws away the HTTP status (see
            // WebSocketRejected), so there is nothing to branch on. Order the
            // suspects by how often they're the answer instead — a wrong token
            // is the common one, and our own relay answers it with a bare 401
            // that never reaches us.
            return ProbeStep(
              title: 'WebSocket 升级',
              outcome: ProbeOutcome.fail,
              detail: e.code == null
                  ? '被拒绝（dart:io 不提供拒绝时的状态码，拿不到具体原因）'
                  : '被拒绝（状态码 ${e.code}）',
              elapsed: sw.elapsed,
              hint: '最常见的原因是中继令牌不对：它必须与服务端 compose 里的 '
                  'GROUP_TOKEN 完全一致（不一致时服务端直接回 401）。'
                  '令牌确认没问题的话，经 Cloudflare 时确认 WebSocket 没被关；'
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
  } on WebSocketException {
    // Deliberately code-less. `e.message` is
    // `Connection to '<uri>' was not upgraded to websocket` — the HTTP status is
    // never in there. Scraping digits out of it (which this used to do) picks
    // them out of the URI instead: `peer=probe-48213` yields 4821 and `:48081`
    // yields 192, so the UI printed a close code that was really a slice of its
    // own query string. Worse, a URL that happens to contain 4401 (port 44010,
    // say) would have been reported as "bad token" no matter the real cause.
    throw const WebSocketRejected(null);
  }
}

class WebDavProbe extends _BaseProbe {
  WebDavProbe(super.cfg, super.deps);

  late final ProbeDav _dav = (deps.davClient ?? _defaultDavClient)(cfg);

  String get _root => '${cfg.signalingPath}/${cfg.groupId}';
  final String _probeName = '.ej-probe-${_rand8()}';
  String get _probePath => '$_root/$_probeName';
  bool _wrote = false;

  // Address/account missing means every later step would hit the same empty
  // config anyway — short-circuit to the one step that explains it, same as
  // RelayProbe does for a missing relay server URL.
  @override
  List<Future<ProbeStep> Function()> steps() {
    final missingConfig = (cfg.webdavUrl ?? '').trim().isEmpty ||
        (cfg.webdavUser ?? '').isEmpty ||
        (cfg.webdavPass ?? '').isEmpty;
    if (missingConfig) {
      return [_checkConfig];
    }
    return [
      _checkConfig,
      _checkDir,
      _checkWrite,
      _checkReadBack,
    ];
  }

  // Idempotent: clearing the flag before the remove means a second call (or a
  // concurrent one from cancel()) is a no-op, while a call that arrives before
  // _checkWrite finished leaves the flag alone so the later `finally` still
  // deletes the file.
  @override
  Future<void> cleanUp() async {
    if (!_wrote) return;
    _wrote = false;
    try {
      await _dav.remove(_probePath);
    } catch (_) {/* best effort */}
  }

  Future<ProbeStep> _checkConfig() async {
    final missing = <String>[
      if ((cfg.webdavUrl ?? '').trim().isEmpty) '地址',
      if ((cfg.webdavUser ?? '').isEmpty) '用户名',
      if ((cfg.webdavPass ?? '').isEmpty) '口令',
    ];
    if (missing.isNotEmpty) {
      return ProbeStep(
        title: '配置完整性',
        outcome: ProbeOutcome.fail,
        detail: '缺少：${missing.join(' / ')}',
        elapsed: Duration.zero,
        hint: '这条通道用 WebDAV 交换信令，三项都必填（与备份用的可以是同一个账户）',
      );
    }
    return ProbeStep(
      title: '配置完整性',
      outcome: ProbeOutcome.pass,
      detail: '${cfg.webdavUrl} · 信令目录 $_root',
      elapsed: Duration.zero,
    );
  }

  Future<ProbeStep> _checkDir() => _BaseProbe.timed(
        '信令目录可用',
        () async {
          final sw = Stopwatch()..start();
          try {
            await _dav.ensureDir(_root).timeout(deps.timeouts.webdav);
            return ProbeStep(
                title: '信令目录可用',
                outcome: ProbeOutcome.pass,
                detail: _root,
                elapsed: sw.elapsed);
          } on DavStatus catch (e) {
            return ProbeStep(
              title: '信令目录可用',
              outcome: ProbeOutcome.fail,
              detail: 'HTTP ${e.status}',
              elapsed: sw.elapsed,
              hint: switch (e.status) {
                401 => '用户名或口令不对（有的网盘要用「应用专用口令」而不是登录口令）',
                403 => '账号对但没权限：这个目录对你是只读的，换一个可写路径',
                404 => '路径不存在且自动创建失败，先在网盘里手工建好这一层',
                _ => '服务端返回 ${e.status}，确认地址是 WebDAV 根而不是网页版地址',
              },
            );
          }
        },
        failHint: '连不上 WebDAV：确认地址可从手机网络访问',
      );

  Future<ProbeStep> _checkWrite() => _BaseProbe.timed(
        '写入探针文件',
        () async {
          final sw = Stopwatch()..start();
          try {
            await _dav
                .write(_probePath, utf8.encode(_probeName))
                .timeout(deps.timeouts.webdav);
            _wrote = true;
            return ProbeStep(
                title: '写入探针文件',
                outcome: ProbeOutcome.pass,
                detail: _probeName,
                elapsed: sw.elapsed);
          } on DavStatus catch (e) {
            return ProbeStep(
              title: '写入探针文件',
              outcome: ProbeOutcome.fail,
              detail: 'HTTP ${e.status}',
              elapsed: sw.elapsed,
              hint: e.status == 403
                  ? '目录只读 —— 信令需要写权限，换一个可写目录或改账号权限'
                  : '写入被拒（${e.status}）：检查配额与路径',
            );
          }
        },
      );

  Future<ProbeStep> _checkReadBack() => _BaseProbe.timed(
        '读回校验',
        () async {
          final sw = Stopwatch()..start();
          final got = await _dav.read(_probePath).timeout(deps.timeouts.webdav);
          final same = utf8.decode(got, allowMalformed: true) == _probeName;
          return ProbeStep(
            title: '读回校验',
            outcome: same ? ProbeOutcome.pass : ProbeOutcome.fail,
            detail: same ? '内容一致，可以当信令用' : '读回的内容与写入的不一致',
            elapsed: sw.elapsed,
            hint: same
                ? null
                : '网盘可能做了转码或缓存 —— 这样的目录不能当信令用，换一个',
          );
        },
        failHint: '读回失败：写进去了但取不回来，这条通道不可用',
      );
}

String _rand8() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = Random.secure();
  return List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
}

ProbeDav _defaultDavClient(ProbeConfig cfg) => _WebDavClientAdapter(
      webdav.newClient(
        cfg.webdavUrl!.trim(),
        user: cfg.webdavUser ?? '',
        password: cfg.webdavPass ?? '',
      ),
    );

class _WebDavClientAdapter implements ProbeDav {
  final webdav.Client _c;
  _WebDavClientAdapter(this._c);

  @override
  Future<void> ensureDir(String path) => _wrap(() async {
        try {
          await _c.readDir(path);
        } catch (_) {
          await _c.mkdirAll(path);
        }
      });

  @override
  Future<void> write(String path, List<int> bytes) =>
      _wrap(() => _c.write(path, Uint8List.fromList(bytes)));

  @override
  Future<List<int>> read(String path) async {
    List<int>? out;
    await _wrap(() async => out = await _c.read(path));
    return out ?? const [];
  }

  @override
  Future<void> remove(String path) => _wrap(() => _c.remove(path));

  /// Turns the package's DioException into [DavStatus] so the probe can branch
  /// on 401/403/404 instead of matching strings.
  Future<void> _wrap(Future<void> Function() body) async {
    try {
      await body();
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code != null) throw DavStatus(code);
      rethrow;
    }
  }
}

class FrpProbe extends _BaseProbe {
  FrpProbe(super.cfg, super.deps);

  FrpEngine? _engine;
  bool _startedByUs = false;

  /// Set false when [_checkTcp] can't reach frps. `run()` executes every
  /// step regardless of earlier outcomes (so the report is as complete as
  /// possible), but starting a temporary frpc against a server we already
  /// know is unreachable would just burn the login timeout for nothing.
  bool _tcpOk = true;

  // Address missing means every later step would fail against an empty
  // config anyway — short-circuit to the one step that explains it, same as
  // RelayProbe and WebDavProbe do for their own missing-address case.
  @override
  List<Future<ProbeStep> Function()> steps() {
    final addr = (cfg.frpServerAddr ?? '').trim();
    if (addr.isEmpty) {
      return [_checkConfig];
    }
    return [
      _checkConfig,
      _checkTcp,
      _checkLoginAndProxy,
      _checkDashboard,
    ];
  }

  // Idempotent, and deliberately keyed on _startedByUs rather than on _engine
  // being non-null: the engine is a handle on a PROCESS-WIDE frpc, so stopping
  // one we didn't start would take the real group's tunnel down with it.
  @override
  Future<void> cleanUp() async {
    if (!_startedByUs) return;
    _startedByUs = false;
    final engine = _engine;
    _engine = null;
    try {
      await engine?.stop();
    } catch (_) {}
  }

  Future<ProbeStep> _checkConfig() async {
    final addr = (cfg.frpServerAddr ?? '').trim();
    if (addr.isEmpty) {
      return ProbeStep(
        title: '配置完整性',
        outcome: ProbeOutcome.fail,
        detail: '未填 frp 服务器地址',
        elapsed: Duration.zero,
        hint: '填 frps 的地址与端口（本仓库示例用 17000）',
      );
    }
    return ProbeStep(
      title: '配置完整性',
      outcome: ProbeOutcome.pass,
      detail: '$addr:${cfg.frpServerPort} · '
          '令牌${(cfg.frpToken ?? '').isEmpty ? "未设" : "已设"} · '
          '共享口令${(cfg.passphrase ?? '').isEmpty ? "未设（xtcp 需要它派生 sk）" : "已设"}',
      elapsed: Duration.zero,
    );
  }

  Future<ProbeStep> _checkTcp() => _BaseProbe.timed(
        '连接 frps',
        () async {
          final sw = Stopwatch()..start();
          final connect = deps.tcpConnect ?? _defaultTcpConnect;
          try {
            await connect(cfg.frpServerAddr!.trim(), cfg.frpServerPort,
                deps.timeouts.net);
          } catch (_) {
            _tcpOk = false;
            rethrow;
          }
          return ProbeStep(
            title: '连接 frps',
            outcome: ProbeOutcome.pass,
            detail: 'TCP ${cfg.frpServerAddr}:${cfg.frpServerPort} 可达',
            elapsed: sw.elapsed,
          );
        },
        failHint: '连不上 frps：确认服务在跑、安全组放行了这个端口、'
            '地址没写成 dashboard 的端口',
      );

  Future<ProbeStep> _checkLoginAndProxy() => _BaseProbe.timed(
        'frpc 登录并注册 xtcp proxy',
        () async {
          final sw = Stopwatch()..start();

          // TCP 都连不上，再启一次 frpc 也只是白白等满登录超时。
          if (!_tcpOk) {
            return ProbeStep(
              title: 'frpc 登录并注册 xtcp proxy',
              outcome: ProbeOutcome.skip,
              detail: '上一步连不上 frps，跳过',
              elapsed: sw.elapsed,
            );
          }

          final engine = _engine = (deps.frpEngine ?? FrpEngine.create)();

          // Something already running: read its state, don't touch it.
          // "figure out why it won't connect WHILE I'm using it" is the common
          // case, and tearing the tunnel down to measure it is the worst
          // possible answer.
          //
          // Asking the ENGINE, not just cfg.groupRunning, is the load-bearing
          // part. FrpEngine is a thin handle on a process-wide frpc where
          // start() is effectively a reload, so starting a probe config evicts
          // the real group's proxy/visitor set and cleanUp's stop() then kills
          // it outright. cfg.groupRunning comes from a UI provider that only
          // flips true AFTER GroupLifecycle.start() returns — port bind + frpc
          // launch + first roster query, several seconds during which it reads
          // false. Tapping "test connection" right after switching the group on
          // landed exactly in that window. The engine is the ground truth, and
          // it also covers an frpc nobody in this process started.
          final alreadyRunning = await engine.isRunning();
          if (cfg.groupRunning || alreadyRunning) {
            return ProbeStep(
              title: 'frpc 登录并注册 xtcp proxy',
              outcome: alreadyRunning ? ProbeOutcome.pass : ProbeOutcome.fail,
              detail: alreadyRunning
                  ? 'frpc 已在运行（未重启，避免打断现有隧道）'
                  : '组队标记为运行中，但 frpc 不在线',
              elapsed: sw.elapsed,
              hint: alreadyRunning ? null : '先在组队页停止再重新开启，或看诊断日志里 frpc 的报错',
            );
          }

          // 未组队：用只含自己 proxy 的最小配置临时启一次。
          final builder = FrpConfigBuilder(
            serverAddr: cfg.frpServerAddr!.trim(),
            serverPort: cfg.frpServerPort,
            token: cfg.frpToken,
            protocol: 'quic',
            groupPrefix: 'ej-${groupSafeId(cfg.groupId)}',
            selfPeerId: cfg.selfId,
            localMeshPort: kMeshPortBase,
            secretKey: cfg.passphrase ?? '',
          );
          final lines = <String>[];
          final done = Completer<ProbeOutcome>();
          final sub = engine.events.listen((l) {
            lines.add(l);
            final low = l.toLowerCase();
            if (low.contains('login') && low.contains('fail')) {
              if (!done.isCompleted) done.complete(ProbeOutcome.fail);
            } else if (low.contains('start proxy success') ||
                low.contains('proxy added')) {
              if (!done.isCompleted) done.complete(ProbeOutcome.pass);
            }
          });
          try {
            await engine.start(builder.build(const []).toml);
            _startedByUs = true;
            // A cancel that landed while start() was in flight: bail before
            // sitting out the login timeout nobody is waiting for. cleanUp
            // still stops the frpc we just brought up — it is idempotent and
            // both `cancel()` and `run()`'s `finally` call it.
            if (_cancelled) {
              return ProbeStep(
                title: 'frpc 登录并注册 xtcp proxy',
                outcome: ProbeOutcome.skip,
                detail: '已取消',
                elapsed: sw.elapsed,
              );
            }
            final outcome = await done.future.timeout(deps.timeouts.frpLogin,
                onTimeout: () => ProbeOutcome.fail);
            final loginFailed = lines.any((l) =>
                l.toLowerCase().contains('login') &&
                l.toLowerCase().contains('fail'));
            return ProbeStep(
              title: 'frpc 登录并注册 xtcp proxy',
              outcome: outcome,
              detail: lines.isEmpty
                  ? '${deps.timeouts.frpLogin.inSeconds}s 内没有任何 frpc 事件'
                  : lines.last,
              elapsed: sw.elapsed,
              hint: outcome == ProbeOutcome.pass
                  ? null
                  : loginFailed
                      ? 'frps 拒绝登录：auth.token 必须与服务端 frps.toml 里的完全一致'
                      : '没等到 proxy 注册成功：确认 frps 允许 xtcp、'
                          '共享口令已设（它派生 xtcp 的 secretKey）',
            );
          } on FrpUnsupported catch (e) {
            return ProbeStep(
              title: 'frpc 登录并注册 xtcp proxy',
              outcome: ProbeOutcome.skip,
              detail: '当前平台没有内置 frpc：${e.message}',
              elapsed: sw.elapsed,
            );
          } finally {
            await sub.cancel();
          }
        },
      );

  Future<ProbeStep> _checkDashboard() async {
    final url = (cfg.frpDashboardUrl ?? '').trim();
    if (url.isEmpty) {
      return ProbeStep(
        title: 'frps dashboard 查询',
        outcome: ProbeOutcome.skip,
        detail: '未配置 dashboard（成员发现将只能靠手动添加）',
        elapsed: Duration.zero,
      );
    }
    return _BaseProbe.timed('frps dashboard 查询', () async {
      final sw = Stopwatch()..start();
      final get = deps.httpGet ?? _defaultHttpGet;
      final basic = base64Encode(utf8.encode(
          '${cfg.frpDashboardUser ?? ''}:${cfg.frpDashboardPass ?? ''}'));
      final r = await get(
        Uri.parse('${url.replaceAll(RegExp(r'/+$'), '')}/api/proxy/xtcp'),
        headers: {'Authorization': 'Basic $basic'},
        timeout: deps.timeouts.net,
      );
      if (r.status != 200) {
        return ProbeStep(
          title: 'frps dashboard 查询',
          outcome: ProbeOutcome.fail,
          detail: 'HTTP ${r.status}',
          elapsed: sw.elapsed,
          hint: r.status == 401
              ? 'dashboard 账号或口令不对（frps.toml 的 webServer.user/password）'
              : '拿不到 /api/proxy/xtcp：确认 dashboard 端口已放行且地址填对',
        );
      }
      final prefix = 'ej-${groupSafeId(cfg.groupId)}.';
      final mine = RegExp('"name"\\s*:\\s*"${RegExp.escape(prefix)}')
          .allMatches(r.body)
          .length;
      return ProbeStep(
        title: 'frps dashboard 查询',
        outcome: ProbeOutcome.pass,
        detail: '可查询；本组在线 proxy $mine 个',
        elapsed: sw.elapsed,
      );
    });
  }
}

Future<void> _defaultTcpConnect(String host, int port, Duration timeout) async {
  final s = await Socket.connect(host, port, timeout: timeout);
  await s.close();
  s.destroy();
}

/// LAN has no server to shake hands with — only the other member. Everything
/// this probe can honestly establish is about THIS device: interfaces,
/// MulticastLock, mesh port, and that a multicast datagram actually leaves.
/// Whether a peer is online is not answerable from here — the probe's socket
/// sits on an ephemeral port and a peer's beacon goes to [kDiscoveryPort], so
/// the last step says so instead of reporting a zero it could never beat (see
/// [ProbeDatagram]).
class LanProbe extends _BaseProbe {
  LanProbe(super.cfg, super.deps);

  ProbeDatagram? _dg;

  /// True only when THIS probe acquired the MulticastLock. Stays false when the
  /// lock was already held, because the native lock is process-wide and not
  /// reference-counted: releasing someone else's would silently kill multicast
  /// reception for the live group session.
  bool _lockHeld = false;

  ProbeMulticastLock get _lock =>
      deps.multicastLock ?? const _PlatformMulticastLock();

  @override
  List<Future<ProbeStep> Function()> steps() => [
        _ifaces,
        _mcastLock,
        _meshPort,
        _sendMulticast,
        _peersUnverifiable,
      ];

  // Idempotent (take-then-release), so it's safe to run from both cancel() and
  // run()'s finally, in either order, and it still releases a socket that only
  // got assigned after the first attempt.
  @override
  Future<void> cleanUp() async {
    final dg = _dg;
    _dg = null;
    try {
      await dg?.close();
    } catch (_) {}
    if (_lockHeld) {
      _lockHeld = false;
      try {
        await _lock.release();
      } catch (_) {}
    }
  }

  Future<ProbeStep> _ifaces() => _BaseProbe.timed('网络接口', () async {
        final sw = Stopwatch()..start();
        final list = await (deps.listInterfaces ?? _defaultIfaces)();
        return ProbeStep(
          title: '网络接口',
          outcome: ProbeOutcome.info,
          detail: list.isEmpty
              ? '没有可用的 IPv4 接口'
              : list.map((i) => '${i.name} ${i.address}').join('；'),
          elapsed: sw.elapsed,
        );
      });

  Future<ProbeStep> _mcastLock() => _BaseProbe.timed('MulticastLock', () async {
        final sw = Stopwatch()..start();
        final lock = _lock;
        if (!lock.needed) {
          return ProbeStep(
            title: 'MulticastLock',
            outcome: ProbeOutcome.skip,
            detail: '仅 Android 需要',
            elapsed: sw.elapsed,
          );
        }
        // Held already? Then the answer to "is multicast reception enabled" is
        // yes, and the correct action is to touch nothing. Same shape as the frp
        // step: check state first, never disturb a live session. Acquiring here
        // would be a no-op that nonetheless made us believe we owned the lock,
        // and the release in cleanUp would drop the REAL service's lock —
        // _LanGroupService acquires once in start() and never again, so it would
        // quietly stop seeing beacons for the rest of the session while its
        // existing TCP connections stayed up. Silent, and precisely in the
        // scenario this feature exists for.
        if (await lock.isHeld()) {
          return ProbeStep(
            title: 'MulticastLock',
            outcome: ProbeOutcome.pass,
            detail: '已持有（锁由组队服务持有，未重复获取，也不会在测试结束时释放）',
            elapsed: sw.elapsed,
          );
        }
        await lock.acquire();
        _lockHeld = true;
        return ProbeStep(
          title: 'MulticastLock',
          outcome: ProbeOutcome.pass,
          detail: '已获取（省电模式下系统会丢多播，拿住它才收得到）',
          elapsed: sw.elapsed,
        );
      });

  Future<ProbeStep> _meshPort() => _BaseProbe.timed('绑定 mesh 端口', () async {
        final sw = Stopwatch()..start();
        try {
          final port = await (deps.bindMesh ?? _defaultBindMesh)(
              kMeshPortBase, kMeshPortProbeCount);
          return ProbeStep(
            title: '绑定 mesh 端口',
            outcome: ProbeOutcome.pass,
            detail: '$port 可用',
            elapsed: sw.elapsed,
          );
        } on MeshPortUnavailable {
          // 正在组队时端口是被自己的服务占着的，那正是它该在的状态。
          if (cfg.groupRunning) {
            return ProbeStep(
              title: '绑定 mesh 端口',
              outcome: ProbeOutcome.pass,
              detail: '端口被正在运行的组队服务占用（符合预期）',
              elapsed: sw.elapsed,
            );
          }
          return ProbeStep(
            title: '绑定 mesh 端口',
            outcome: ProbeOutcome.fail,
            detail:
                '$kMeshPortBase..${kMeshPortBase + kMeshPortProbeCount - 1} 全部不可用',
            elapsed: sw.elapsed,
            hint: '有别的程序占了这段端口。先关掉它，或重启 App 释放残留监听',
          );
        }
      });

  Future<ProbeStep> _sendMulticast() =>
      _BaseProbe.timed('发出多播', () async {
        final sw = Stopwatch()..start();
        final dg = _dg = await (deps.openDatagram ?? _defaultDatagram)();
        if (!dg.joinMulticast()) {
          return ProbeStep(
            title: '发出多播',
            outcome: ProbeOutcome.fail,
            detail: '无法加入多播组 $kMcastGroup',
            elapsed: sw.elapsed,
            hint: '这个网络丢多播：家用路由器的 AP 隔离 / 访客网络 / 部分公司网络。'
                '改用手机热点，或换成中继与 frp 通道',
          );
        }
        final sent = dg.send(utf8.encode(
            '{"g":"${groupSafeId(cfg.groupId)}","id":"${cfg.selfId}","probe":1}'));
        return ProbeStep(
          title: '发出多播',
          outcome: sent > 0 ? ProbeOutcome.pass : ProbeOutcome.fail,
          detail: sent > 0
              ? '已发往 $kMcastGroup:$kDiscoveryPort（$sent 字节）'
              : '发送返回 0 字节',
          elapsed: sw.elapsed,
          hint: sent > 0 ? null : '多播被系统拦下了：确认 App 有本地网络权限',
        );
      });

  /// Honest non-answer, in the same spirit as the relay probe's
  /// "shared passphrase" step.
  ///
  /// This used to count peers, and it could only ever count zero: the probe
  /// socket is bound to an ephemeral port (it must not steal [kDiscoveryPort]
  /// from a running group service), multicast delivery matches on destination
  /// port, and every real beacon is addressed to [kDiscoveryPort] — so no peer
  /// traffic can reach this socket. The real service has no unicast reply path
  /// either: a `probe:1` datagram lacks the `p` field, so `_onDatagram` logs one
  /// warning and returns. Reporting "no members found" with a hint telling the
  /// user to go check the other phone was therefore worse than saying nothing:
  /// it sent people chasing a problem the tool had invented. Counting peers for
  /// real means teaching the group service to unicast a reply — a protocol
  /// change, not a probe change.
  Future<ProbeStep> _peersUnverifiable() async => const ProbeStep(
        title: '对端应答',
        outcome: ProbeOutcome.skip,
        detail: '探测用的是临时端口，收不到对端发往 $kDiscoveryPort 的常规信标，'
            '「有几个成员在线」这一项单机测不出来',
        elapsed: Duration.zero,
      );
}

Future<List<ProbeIface>> _defaultIfaces() async {
  final out = <ProbeIface>[];
  for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4, includeLoopback: false)) {
    for (final a in i.addresses) {
      out.add(ProbeIface(name: i.name, address: a.address));
    }
  }
  return out;
}

Future<int> _defaultBindMesh(int base, int count) async {
  for (var i = 0; i < count; i++) {
    try {
      final s = await ServerSocket.bind(InternetAddress.anyIPv4, base + i,
          shared: true);
      final port = s.port;
      await s.close();
      return port;
    } catch (_) {/* try next */}
  }
  throw const MeshPortUnavailable();
}

class _IoDatagram implements ProbeDatagram {
  final RawDatagramSocket _s;
  _IoDatagram(this._s) {
    // Drain only. Nothing addressed to a peer can land here (see
    // [ProbeDatagram]); the listener exists so anything that does arrive —
    // our own loopback copy, a stray sender — doesn't sit in the socket buffer.
    _s.listen((e) {
      if (e == RawSocketEvent.read) _s.receive();
    });
  }

  @override
  bool joinMulticast() {
    try {
      _s.joinMulticast(InternetAddress(kMcastGroup));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  int send(List<int> data) =>
      _s.send(data, InternetAddress(kMcastGroup), kDiscoveryPort);

  @override
  Future<void> close() async => _s.close();
}

Future<ProbeDatagram> _defaultDatagram() async {
  // 端口 0：借一个临时端口，绝不与正在运行的组队服务抢 kDiscoveryPort。
  final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  s.multicastLoopback = false;
  s.multicastHops = 8;
  return _IoDatagram(s);
}

/// Production [ProbeMulticastLock]: the same platform channel
/// `_LanGroupService.start()` uses, plus the `status` query that tells the probe
/// whether the (process-wide, non-reference-counted) lock is already someone
/// else's.
class _PlatformMulticastLock implements ProbeMulticastLock {
  const _PlatformMulticastLock();
  @override
  bool get needed => Platform.isAndroid;
  @override
  Future<bool> isHeld() => MulticastLock.isHeld();
  @override
  Future<void> acquire() => MulticastLock.acquire();
  @override
  Future<void> release() => MulticastLock.release();
}
