import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/db/database.dart';

/// 启动期 DB 维护（从 app 的 post-frame 回调调用一次，不放在 [dbProvider] 里，
/// 让 provider 保持无副作用）。
///
/// 三件事，成本分三档：
///  * **uuid 回填**（5 张表的全表 UPDATE … WHERE uuid=''）——只是对旧代码路径的
///    兜底，新写入的行都带 uuid。以前每次冷启动都跑，在 DB isolate 上排在迷雾首次
///    加载前面；现在按 schema 版本只跑一次（标记存 prefs）。
///  * **孤儿图层自愈**——每次都跑。所有渲染层都按图层驱动，图层丢了内容就是一张
///    空地图；有了 (layer_id) 索引后三次 DISTINCT 只是索引扫描，毫秒级。
///  * **队友轨迹 GC**——每次都跑，先探针再删，没过期行时零写入。
///
/// 行数探针只在 debug 构建或 [probe] 显式打开时输出：8 次 COUNT(*)（含 track_points
/// 与 fog_tiles 两张大表）只为一行日志，release 用户不该为它付这笔启动开销。
abstract final class StartupMaintenance {
  static const prefsKey = 'startup_maint_schema_v';

  static bool needsHeal(SharedPreferences prefs, int schemaVersion) =>
      prefs.getInt(prefsKey) != schemaVersion;
}

Future<void> runStartupDbMaintenance(
  AppDb db, {
  SharedPreferences? prefs,
  bool probe = kDebugMode,
}) async {
  try {
    final p = prefs ?? await SharedPreferences.getInstance();
    if (StartupMaintenance.needsHeal(p, db.schemaVersion)) {
      final fixedIds = await db.backfillMissingUuids();
      if (fixedIds > 0) {
        debugPrint('[DB] backfilled $fixedIds missing uuid(s)');
      }
      await p.setInt(StartupMaintenance.prefsKey, db.schemaVersion);
    }
    final healed = await db.ensureLayersForContent();
    if (healed > 0) {
      debugPrint('[DB] recreated $healed orphaned layer(s) on startup');
    }
    final gced = await db.gcPeerLocations();
    if (gced > 0) debugPrint('[DB] gc peer_locations: $gced');

    if (!probe) return;
    // The probe splits "synced but nothing shows" in one look: zeros → the
    // data never landed (sync); non-zero → data is here and RENDERING is off.
    Future<int> count(String t, [String where = '']) async =>
        (await db.customSelect('SELECT COUNT(*) c FROM $t $where').getSingle())
            .read<int>('c');
    debugPrint('[DB] rows — journal=${await count('journal_entries')} '
        'layers=${await count('track_layers')} '
        'points=${await count('track_points')} '
        'fog=${await count('fog_tiles')} '
        'chat=${await count('chat_messages')} '
        'favorites=${await count('song_favorites')}');
    // uuid coverage on the two identity-critical, low-volume tables — a
    // non-zero "no-uuid" count means sync identity is broken for those rows.
    debugPrint('[DB] no-uuid — '
        "journal=${await count('journal_entries', "WHERE uuid IS NULL OR uuid=''")} "
        "layers=${await count('track_layers', "WHERE uuid IS NULL OR uuid=''")}");
  } catch (e) {
    debugPrint('[DB] startup self-heal/probe failed: $e');
  }
}
