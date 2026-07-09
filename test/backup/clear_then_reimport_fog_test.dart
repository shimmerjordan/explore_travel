import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';
import 'package:explore_journal/services/fog/fog_engine.dart';

/// The user's EXACT failing sequence: import FOW fog → 「清除本机迷雾」
/// (clearModule('fog_tiles')) → import FOW again → "就没了". Reproduce it at the
/// persistence layer to decide whether the DB drops it or it's a render issue.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // ignore: invalid_use_of_visible_for_testing_member
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<int> fogCount(AppDb db) async => (await db
          .customSelect('SELECT count(*) c FROM fog_tiles')
          .getSingle())
      .read<int>('c');

  test('import fog → clearModule(fog_tiles) → re-import → fog is BACK',
      () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDb.forTesting(NativeDatabase.memory());
    final fog = FogEngine(db);
    final svc = BackupService(db);
    final lid = (await db.allLayers()).first.id;

    List<({int tileX, int tileY, int blockX, int blockY, Uint8List bitmap})>
        blocks() {
      final b = Uint8List(FogEngine.bitmapBytes);
      FogEngine.setBit(b, 3, 4);
      FogEngine.setBit(b, 10, 20);
      return [(tileX: 100, tileY: 200, blockX: 3, blockY: 4, bitmap: b)];
    }

    // 1) first import
    final w1 = await fog.importBlocks(layerId: lid, blocks: blocks());
    final c1 = await fogCount(db);
    // ignore: avoid_print
    print('after 1st import: written=$w1 fog_tiles=$c1');
    expect(c1, greaterThan(0));

    // 2) clear the fog module (the trash icon the user tapped)
    final msg = await svc.clearModule('fog_tiles');
    final c2 = await fogCount(db);
    // ignore: avoid_print
    print('after clearModule: "$msg" fog_tiles=$c2');
    expect(c2, 0);

    // 3) re-import the SAME fog into the SAME engine — must come back
    final w2 = await fog.importBlocks(layerId: lid, blocks: blocks());
    final c3 = await fogCount(db);
    // ignore: avoid_print
    print('after 2nd import: written=$w2 fog_tiles=$c3');
    expect(c3, greaterThan(0),
        reason: '清除迷雾后再导入，fog_tiles 仍为空 → 复现用户的 bug');

    await db.close();
  });

  test('fog imported onto an ALL-HIDDEN layer set renders after setLayerVisible',
      () async {
    // The one code path that reproduces "导入不生效/没了": every layer's eye is
    // off, so effectiveActiveLayerId falls back to a HIDDEN layer, the fog lands
    // there, and the map (which draws only VISIBLE layers) shows nothing. The
    // FOW-import fix un-hides the target — proven here at the DB level.
    SharedPreferences.setMockInitialValues({});
    final db = AppDb.forTesting(NativeDatabase.memory());
    final fog = FogEngine(db);
    final def = (await db.allLayers()).first;

    await db.setLayerVisible(def.id, false);
    expect((await db.allLayers()).every((l) => !l.visible), isTrue);

    final b = Uint8List(FogEngine.bitmapBytes);
    FogEngine.setBit(b, 3, 4);
    await fog.importBlocks(layerId: def.id, blocks: [
      (tileX: 100, tileY: 200, blockX: 3, blockY: 4, bitmap: b),
    ]);

    // Before the fix: the map reads only visible layers → none → renders nothing.
    var visible =
        (await db.allLayers()).where((l) => l.visible).map((l) => l.id).toList();
    expect(visible, isEmpty);
    var rendered = await db.fogTilesForLayers(visible, FogEngine.tileZoom);
    expect(rendered, isEmpty, reason: 'fog exists but no visible layer to draw it');

    // The fix: FOW import un-hides its target.
    await db.setLayerVisible(def.id, true);
    visible =
        (await db.allLayers()).where((l) => l.visible).map((l) => l.id).toList();
    expect(visible, [def.id]);
    rendered = await db.fogTilesForLayers(visible, FogEngine.tileZoom);
    expect(rendered, isNotEmpty, reason: '现在地图能读到并渲染这块迷雾了');

    await db.close();
  });
}
