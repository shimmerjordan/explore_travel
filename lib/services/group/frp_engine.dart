import 'frp_engine_stub.dart'
    if (dart.library.io) 'frp_engine_io.dart' as impl;

/// Thin Dart-side handle to the embedded frp client (frpc), which is compiled
/// into the app as a gomobile library (AAR on Android, XCFramework on iOS) and
/// reached over a platform channel. See [docs/frp_embed.md] for the native
/// build. On platforms without the native lib (desktop/web), the stub throws
/// [FrpUnsupported] so callers can fall back gracefully.
abstract class FrpEngine {
  /// Start frpc with the given TOML config. Idempotent-ish: calling start
  /// while already running should be treated as a [reload] by the impl.
  Future<void> start(String configToml);

  /// Hot-apply a new config (e.g. when the roster changed and visitors were
  /// added/removed) without tearing down established tunnels.
  Future<void> reload(String configToml);

  Future<void> stop();
  Future<bool> isRunning();

  /// frpc log / status lines (one per event). Used for diagnostics and to
  /// learn when a visitor's tunnel becomes usable.
  Stream<String> get events;

  static FrpEngine create() => impl.createEngine();
}

class FrpUnsupported implements Exception {
  final String message;
  const FrpUnsupported(this.message);
  @override
  String toString() => 'FrpUnsupported: $message';
}
