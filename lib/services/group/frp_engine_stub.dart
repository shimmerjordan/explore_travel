import 'frp_engine.dart';

/// Web / unsupported fallback — there's no embedded frpc here.
FrpEngine createEngine() => _StubFrpEngine();

class _StubFrpEngine implements FrpEngine {
  static const _err = FrpUnsupported('当前平台不支持内置 frpc');

  @override
  Stream<String> get events => const Stream.empty();

  @override
  Future<void> start(String configToml) async => throw _err;
  @override
  Future<void> reload(String configToml) async => throw _err;
  @override
  Future<void> stop() async {}
  @override
  Future<bool> isRunning() async => false;
}
