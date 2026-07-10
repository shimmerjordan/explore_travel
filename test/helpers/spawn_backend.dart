// Shared helper: spawn the real `backends/` node server for integration
// tests. Skips cleanly when node isn't installed (CI without node still
// passes the rest of the suite).
import 'dart:io';
import 'dart:math';

class SpawnedBackend {
  final Process process;
  final int port;
  final Directory dataDir;
  SpawnedBackend(this.process, this.port, this.dataDir);

  String get baseUrl => 'http://127.0.0.1:$port';

  Future<void> stop({bool deleteData = true}) async {
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    });
    if (deleteData) {
      try {
        await dataDir.delete(recursive: true);
      } catch (_) {}
    }
  }
}

Future<bool> hasNode() async {
  try {
    final r = await Process.run('node', ['--version']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Start the backend on a random port. [port]/[dataDir] pin them instead
/// (used by restart tests that must resume the same state).
Future<SpawnedBackend> spawnBackend({
  int? port,
  Directory? dataDir,
  Map<String, String> env = const {},
}) async {
  final p = port ?? 21000 + Random().nextInt(20000);
  final dir =
      dataDir ?? await Directory.systemTemp.createTemp('ej-backend-test-');
  final proc = await Process.start(
    'node',
    ['backends/server/server.js'],
    environment: {
      'PORT': '$p',
      'HOST': '127.0.0.1',
      'DATA_DIR': dir.path,
      'LOG_LEVEL': 'error',
      ...env,
    },
  );
  final client = HttpClient();
  try {
    for (var i = 0; i < 100; i++) {
      try {
        final req =
            await client.getUrl(Uri.parse('http://127.0.0.1:$p/healthz'));
        final resp = await req.close();
        await resp.drain<void>();
        if (resp.statusCode == 200) return SpawnedBackend(proc, p, dir);
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 50));
    }
  } finally {
    client.close(force: true);
  }
  proc.kill(ProcessSignal.sigkill);
  throw StateError('backend did not start on port $p');
}
