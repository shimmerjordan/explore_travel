import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:flutter/foundation.dart';

/// Drift on Web uses a WASM build of sqlite3 stored under `web/sqlite3.wasm`.
/// Persistence: IndexedDB or OPFS depending on browser support; Drift picks
/// automatically with [WasmDatabase.open].
QueryExecutor openConnection() {
  return DatabaseConnection.delayed(Future(() async {
    final result = await WasmDatabase.open(
      databaseName: 'explore_journal',
      sqlite3Uri: Uri.parse('sqlite3.wasm'),
      driftWorkerUri: Uri.parse('drift_worker.js'),
    );
    if (result.missingFeatures.isNotEmpty && kDebugMode) {
      debugPrint(
          'Drift web missing features: ${result.missingFeatures}; using fallback storage.');
    }
    return result.resolvedExecutor;
  }));
}
