import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';

/// Guard for the "导入不生效" confusion: a Fog of World `Sync.zip` (raw FoW
/// tiles, no manifest) picked in the BACKUP importer used to fail with a
/// cryptic "manifest.json 不存在，这可能不是一个 explore_journal 备份". FOW data
/// must go through the dedicated "导入 FOW 数据" path (which was verified on the
/// real device to restore 46872 fog blocks). The backup importer now detects a
/// FoW tile set and points the user at the right button.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // ignore: invalid_use_of_visible_for_testing_member
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('backup importer rejects a FoW Sync.zip with a HELPFUL message',
      () async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final svc = BackupService(db);
    // A FoW "Sync" folder: raw obfuscated tile files, no manifest — exactly
    // what the user picked in the WRONG (backup) importer. The names are real
    // FoW tile names (from an actual Sync.zip) so looksLikeFowTileName matches.
    final files = <String, List<int>>{
      'Sync/01ddloohkwkx': [1, 2, 3, 4],
      'Sync/0380lorjsiwo': [5, 6, 7, 8],
    };
    await expectLater(
      svc.importFromFiles(files, modules: {'fog_tiles'}),
      throwsA(isA<FormatException>().having(
          (e) => e.message.toString(), 'message', contains('导入 FOW 数据'))),
    );
    await db.close();
  });

  test('a genuinely foreign zip still gets the generic "not a backup" message',
      () async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final svc = BackupService(db);
    final files = <String, List<int>>{
      'random.txt': [1, 2, 3],
      'photo.jpg': [4, 5, 6],
    };
    await expectLater(
      svc.importFromFiles(files, modules: {'journal'}),
      throwsA(isA<FormatException>().having(
          (e) => e.message.toString(), 'message', contains('explore_journal'))),
    );
    await db.close();
  });
}
