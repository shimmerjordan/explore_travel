import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/backup/backup_service.dart';

/// The user's exact repro — "新建 → 导出 → 删除 → 导入，期望被删的东西回来" — and
/// the same cycle for EVERY tombstoned module (journal / song_favorites /
/// track_points). A per-item delete records a tombstone; the importer used to
/// apply every local tombstone as an unconditional skip-set, so a backup could
/// never bring a locally-deleted row back. `restore: true` treats the archive
/// as authoritative: only tombstones the ARCHIVE carries suppress rows, and the
/// stale local marker is cleared once the row exists again. Default (sync) mode
/// is untouched — a local tombstone still blocks resurrection from an old copy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // ignore: invalid_use_of_visible_for_testing_member
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDb db;
  late BackupService svc;
  late int layerId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDb.forTesting(NativeDatabase.memory());
    svc = BackupService(db);
    layerId = (await db.allLayers()).first.id;
  });
  tearDown(() async => db.close());

  Future<int> journalCount() async => (await db
          .customSelect('SELECT count(*) c FROM journal_entries')
          .getSingle())
      .read<int>('c');

  group('restore=true 复活本地删除的行（删除后再导入必须恢复）', () {
    test('journal：新建→导出→删除→导入(restore)=回来；默认(sync)仍不复活', () async {
      final id = await db.insertJournal(JournalEntriesCompanion.insert(
        uuid: const Value('j-1'),
        time: DateTime(2026, 7, 1),
        lat: 30.0,
        lng: 104.0,
        richContent: const Value(""),
        title: '成都火锅',
        layerId: layerId,
      ));
      final files = await svc.exportToFiles({'journal'});

      await db.deleteJournalById(id); // per-item delete → local tombstone
      expect(await journalCount(), 0);
      expect(await db.tombstonedUuids('journal_entries'), contains('j-1'));

      // Default (sync) import MUST still block — this is the deliberate
      // "local tombstone must block resurrection from old cloud" guarantee.
      await svc.importFromFiles(files, modules: {'journal'});
      expect(await journalCount(), 0, reason: 'sync 语义：本地墓碑阻止复活，不能回归');

      // Restore import brings it back AND clears the now-stale tombstone.
      final s =
          await svc.importFromFiles(files, modules: {'journal'}, restore: true);
      expect(await journalCount(), 1, reason: '恢复语义：文件为准，手账必须回来');
      expect(s.imported['journal'], 1);
      expect(await db.tombstonedUuids('journal_entries'), isEmpty,
          reason: '复活后清掉本地墓碑，否则下次 syncUp 会把它又删掉');
    });

    test('song_favorites：同样的删除→恢复循环', () async {
      await db.into(db.songFavorites).insert(SongFavoritesCompanion.insert(
            uuid: const Value('s-1'),
            songId: '111',
            title: '晴天',
            artist: '周杰伦',
            source: 'gd',
            addedAt: DateTime(2026, 7, 1),
          ));
      final files = await svc.exportToFiles({'song_favorites'});

      final row = (await db.select(db.songFavorites).get()).single;
      await db.deleteSongFavoriteById(row.id);
      expect(await db.select(db.songFavorites).get(), isEmpty);
      expect(await db.tombstonedUuids('song_favorites'), contains('s-1'));

      await svc.importFromFiles(files,
          modules: {'song_favorites'}, restore: true);
      expect((await db.select(db.songFavorites).get()).map((f) => f.uuid),
          contains('s-1'));
      expect(await db.tombstonedUuids('song_favorites'), isEmpty);
    });

    test('track_points：擦除后恢复把点带回来', () async {
      await db.insertPoints([
        TrackPointsCompanion.insert(
          uuid: const Value('tp-1'),
          lat: 30.0,
          lng: 104.0,
          time: DateTime(2026, 7, 1),
          layerId: layerId,
        ),
      ]);
      final files = await svc.exportToFiles({'track_points', 'layers'});

      await db.erasePointsAround(30.0, 104.0, 50); // → tombstone tp-1
      expect(await db.select(db.trackPoints).get(), isEmpty);
      expect(await db.tombstonedUuids('track_points'), contains('tp-1'));

      await svc.importFromFiles(files,
          modules: {'track_points', 'layers'}, restore: true);
      expect((await db.select(db.trackPoints).get()).map((p) => p.uuid),
          contains('tp-1'));
      expect(await db.tombstonedUuids('track_points'), isEmpty);
    });
  });

  test('restore 不复活 ARCHIVE 自带墓碑标记的删除（真实删除仍传播）', () async {
    // Snapshot taken AFTER the delete: the archive carries j-del's tombstone and
    // omits its row. Restoring onto a device that still has j-del must delete it
    // — restore ignores LOCAL-only tombstones, NOT archive-carried ones.
    await db.insertJournal(JournalEntriesCompanion.insert(
        uuid: const Value('j-keep'),
        time: DateTime(2026, 7, 1),
        lat: 1,
        lng: 2,
        richContent: const Value(""),
        title: 'keep',
        layerId: layerId));
    await db.insertJournal(JournalEntriesCompanion.insert(
        uuid: const Value('j-del'),
        time: DateTime(2026, 7, 2),
        lat: 3,
        lng: 4,
        richContent: const Value(""),
        title: 'del',
        layerId: layerId));
    await db.deleteJournalById((await db.select(db.journalEntries).get())
        .firstWhere((j) => j.uuid == 'j-del')
        .id);
    final files =
        await svc.exportToFiles({'journal'}); // carries j-del tombstone

    // Device B still holds BOTH entries.
    final db2 = AppDb.forTesting(NativeDatabase.memory());
    final svc2 = BackupService(db2);
    addTearDown(() async => db2.close());
    final l2 = (await db2.allLayers()).first.id;
    for (final u in const ['j-keep', 'j-del']) {
      await db2.insertJournal(JournalEntriesCompanion.insert(
          uuid: Value(u),
          time: DateTime(2026, 7, 1),
          lat: 1,
          lng: 2,
          richContent: const Value(""),
          title: u,
          layerId: l2));
    }

    await svc2.importFromFiles(files, modules: {'journal'}, restore: true);
    final uuids =
        (await db2.select(db2.journalEntries).get()).map((j) => j.uuid).toSet();
    expect(uuids, contains('j-keep'));
    expect(uuids, isNot(contains('j-del')), reason: 'archive 携带的墓碑在恢复模式下仍然生效');
  });
}
