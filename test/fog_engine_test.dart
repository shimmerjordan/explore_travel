import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/data/db/database.dart';
import 'package:explore_journal/services/fog/fog_engine.dart';

int _popcount(Uint8List b) {
  int n = 0;
  for (var byte in b) {
    while (byte != 0) {
      byte &= byte - 1;
      n++;
    }
  }
  return n;
}

void main() {
  // ───────────────────── pure grid / projection math ─────────────────────
  group('FogEngine grid constants', () {
    test('full grid is exactly 2^22 and factors match FOW', () {
      expect(FogEngine.full, 1 << 22);
      expect(FogEngine.full, 4194304);
      expect(
        FogEngine.mapWidth * FogEngine.tileWidth * FogEngine.bitmapWidth,
        FogEngine.full,
      );
    });

    test('a 64×64 block packs into 512 MSB-first bytes', () {
      expect(FogEngine.bitmapBytes,
          FogEngine.bitmapWidth * FogEngine.bitmapWidth ~/ 8);
      expect(FogEngine.bitmapBytes, 512);
    });
  });

  group('FogEngine Web-Mercator projection', () {
    test('lng/lat anchors land on the expected global pixels', () {
      expect(FogEngine.lngToGlobalX(-180.0), 0);
      expect(FogEngine.lngToGlobalX(0.0), FogEngine.full ~/ 2);
      // +180 maps to `full` which is clamped back into range.
      expect(FogEngine.lngToGlobalX(180.0), FogEngine.full - 1);
      // The equator is the vertical centre of the Mercator square.
      expect(FogEngine.latToGlobalY(0.0), FogEngine.full ~/ 2);
    });

    test('Y grows southward (north latitude → smaller Y)', () {
      expect(FogEngine.latToGlobalY(45.0),
          lessThan(FogEngine.latToGlobalY(-45.0)));
    });

    test('lng round-trips to within one pixel', () {
      for (final lng in [-179.9, -73.99, 0.0, 116.39124, 151.2093]) {
        final back = FogEngine.globalXToLng(FogEngine.lngToGlobalX(lng));
        expect((back - lng).abs(), lessThan(1e-4),
            reason: 'lng $lng round-tripped to $back');
      }
    });

    test('lat round-trips to within one pixel', () {
      for (final lat in [-60.0, -33.8688, 0.0, 39.9075, 60.0]) {
        final back = FogEngine.globalYToLat(FogEngine.latToGlobalY(lat));
        expect((back - lat).abs(), lessThan(1e-3),
            reason: 'lat $lat round-tripped to $back');
      }
    });

    test('out-of-range coordinates clamp instead of throwing', () {
      expect(FogEngine.lngToGlobalX(999.0), FogEngine.full - 1);
      expect(FogEngine.lngToGlobalX(-999.0), 0);
      expect(FogEngine.latToGlobalY(89.9999),
          inInclusiveRange(0, FogEngine.full - 1));
    });
  });

  group('FogEngine decompose/compose', () {
    test('compose(decompose(x)) is the identity across the range', () {
      for (final g in [
        0,
        1,
        63,
        64,
        65,
        8191,
        8192,
        (1 << 13) + 5,
        1234567,
        FogEngine.full - 1,
      ]) {
        final d = FogEngine.decompose(g);
        expect(FogEngine.compose(d.tile, d.block, d.pixel), g,
            reason: 'failed to reconstruct global pixel $g');
      }
    });

    test('field boundaries split at the documented bit positions', () {
      // pixel = low 6 bits, block = next 7 bits, tile = the rest.
      expect(FogEngine.decompose(63), (tile: 0, block: 0, pixel: 63));
      expect(FogEngine.decompose(64), (tile: 0, block: 1, pixel: 0));
      expect(FogEngine.decompose(8192), (tile: 1, block: 0, pixel: 0));
    });
  });

  group('FogEngine bitmap bit ops (MSB-first, matches FOW)', () {
    test('setBit writes the most-significant bit first', () {
      final b = Uint8List(FogEngine.bitmapBytes);
      FogEngine.setBit(b, 0, 0);
      expect(b[0], 0x80, reason: 'pixel (0,0) must be the top bit of byte 0');

      final b2 = Uint8List(FogEngine.bitmapBytes);
      FogEngine.setBit(b2, 7, 0);
      expect(b2[0], 0x01, reason: 'pixel (7,0) must be the bottom bit of byte 0');

      final b3 = Uint8List(FogEngine.bitmapBytes);
      FogEngine.setBit(b3, 0, 1);
      expect(b3[8], 0x80, reason: 'row stride is 8 bytes (64 bits)');
    });

    test('set → isSet → clear leaves neighbours untouched', () {
      final b = Uint8List(FogEngine.bitmapBytes);
      expect(FogEngine.isSet(b, 5, 6), isFalse);

      FogEngine.setBit(b, 5, 6);
      expect(FogEngine.isSet(b, 5, 6), isTrue);
      expect(FogEngine.isSet(b, 4, 6), isFalse);
      expect(FogEngine.isSet(b, 6, 6), isFalse);
      expect(FogEngine.isSet(b, 5, 5), isFalse);
      expect(_popcount(b), 1);

      FogEngine.clearBit(b, 5, 6);
      expect(FogEngine.isSet(b, 5, 6), isFalse);
      expect(_popcount(b), 0);
    });

    test('the corner pixel (63,63) is the bottom bit of the last byte', () {
      final b = Uint8List(FogEngine.bitmapBytes);
      FogEngine.setBit(b, 63, 63);
      expect(b[511], 0x01);
      expect(FogEngine.isSet(b, 63, 63), isTrue);
    });
  });

  group('FogEngine.bboxAreaKm2', () {
    test('a 1°×1° box near the equator is ~12,400 km²', () {
      final area = FogEngine.bboxAreaKm2(0, 0, 1, 1);
      expect(area, greaterThan(12000));
      expect(area, lessThan(12500));
    });

    test('the same box shrinks toward the poles (Mercator narrowing)', () {
      final equator = FogEngine.bboxAreaKm2(0, 0, 1, 1);
      final high = FogEngine.bboxAreaKm2(60, 0, 61, 1);
      expect(high, lessThan(equator));
      expect(high, greaterThan(0));
    });

    test('argument order does not matter (uses absolute spans)', () {
      expect(FogEngine.bboxAreaKm2(1, 1, 0, 0),
          closeTo(FogEngine.bboxAreaKm2(0, 0, 1, 1), 1e-6));
    });
  });

  // ──────────────── DB-backed reveal / import behaviour ────────────────
  group('FogEngine reveal/erase/import (in-memory DB)', () {
    late AppDb db;
    late FogEngine fog;

    setUp(() {
      db = AppDb.forTesting(NativeDatabase.memory());
      fog = FogEngine(db);
    });
    tearDown(() => db.close());

    Future<int> newLayer(String name) => db.insertLayer(
          TrackLayersCompanion.insert(
            name: name,
            colorValue: 0xFF00BCD4,
            createdAt: DateTime.now(),
          ),
        );

    // Resolve a WGS-84 point to its (dbX, dbY, pixelX, pixelY) so a test can
    // read the bit back through the public engine API.
    ({int dbX, int dbY, int px, int py}) locate(double lat, double lng) {
      final dx = FogEngine.decompose(FogEngine.lngToGlobalX(lng));
      final dy = FogEngine.decompose(FogEngine.latToGlobalY(lat));
      return (
        dbX: dx.tile * FogEngine.tileWidth + dx.block,
        dbY: dy.tile * FogEngine.tileWidth + dy.block,
        px: dx.pixel,
        py: dy.pixel,
      );
    }

    test('revealSinglePixel lights exactly one cell, erase clears it',
        () async {
      const lat = 39.9075, lng = 116.39124;
      final lid = await newLayer('A');
      final loc = locate(lat, lng);

      await fog.revealSinglePixel(lat: lat, lng: lng, layerId: lid);
      final after = await fog.mergedBlockBitmap(loc.dbX, loc.dbY, [lid]);
      expect(after, isNotNull);
      expect(FogEngine.isSet(after!, loc.px, loc.py), isTrue);
      expect(_popcount(after), 1, reason: 'recording must reveal ONE pixel');

      await fog.eraseSinglePixel(lat: lat, lng: lng, layerId: lid);
      final cleared = await fog.mergedBlockBitmap(loc.dbX, loc.dbY, [lid]);
      expect(cleared == null || _popcount(cleared) == 0, isTrue);
    });

    test('revealed area inside a bbox is one positive sub-pixel², zero after erase',
        () async {
      const lat = 39.9075, lng = 116.39124;
      final lid = await newLayer('A');
      await fog.revealSinglePixel(lat: lat, lng: lng, layerId: lid);

      final km2 = await fog.revealedAreaInBboxKm2(
        [lid],
        minLat: lat - 0.01,
        minLng: lng - 0.01,
        maxLat: lat + 0.01,
        maxLng: lng + 0.01,
      );
      // One ~7–10 m pixel ⇒ well under 0.001 km² but strictly positive.
      expect(km2, greaterThan(0));
      expect(km2, lessThan(0.001));

      await fog.eraseSinglePixel(lat: lat, lng: lng, layerId: lid);
      final after = await fog.revealedAreaInBboxKm2(
        [lid],
        minLat: lat - 0.01,
        minLng: lng - 0.01,
        maxLat: lat + 0.01,
        maxLng: lng + 0.01,
      );
      expect(after, 0);
    });

    test('importBlocks writes touched tiles and OR-merges bitmaps', () async {
      final lid = await newLayer('A');
      final bmp = Uint8List(FogEngine.bitmapBytes);
      FogEngine.setBit(bmp, 5, 6);

      final written = await fog.importBlocks(layerId: lid, blocks: [
        (tileX: 10, tileY: 20, blockX: 3, blockY: 4, bitmap: bmp),
      ]);
      expect(written, 1);

      final dbX = 10 * FogEngine.tileWidth + 3;
      final dbY = 20 * FogEngine.tileWidth + 4;
      final merged = await fog.mergedBlockBitmap(dbX, dbY, [lid]);
      expect(merged, isNotNull);
      expect(FogEngine.isSet(merged!, 5, 6), isTrue);
      expect(_popcount(merged), 1);
    });

    test('mergedBlockBitmap unions across multiple layers', () async {
      final l1 = await newLayer('A');
      final l2 = await newLayer('B');

      final b1 = Uint8List(FogEngine.bitmapBytes)..[0] = 0; // bit (1,1)
      FogEngine.setBit(b1, 1, 1);
      final b2 = Uint8List(FogEngine.bitmapBytes);
      FogEngine.setBit(b2, 2, 2);

      await fog.importBlocks(layerId: l1, blocks: [
        (tileX: 7, tileY: 8, blockX: 1, blockY: 2, bitmap: b1),
      ]);
      await fog.importBlocks(layerId: l2, blocks: [
        (tileX: 7, tileY: 8, blockX: 1, blockY: 2, bitmap: b2),
      ]);

      final dbX = 7 * FogEngine.tileWidth + 1;
      final dbY = 8 * FogEngine.tileWidth + 2;

      final only1 = await fog.mergedBlockBitmap(dbX, dbY, [l1]);
      expect(FogEngine.isSet(only1!, 1, 1), isTrue);
      expect(FogEngine.isSet(only1, 2, 2), isFalse);

      final union = await fog.mergedBlockBitmap(dbX, dbY, [l1, l2]);
      expect(FogEngine.isSet(union!, 1, 1), isTrue);
      expect(FogEngine.isSet(union, 2, 2), isTrue);
      expect(_popcount(union), 2);
    });

    test('importBlocks is empty-safe', () async {
      final lid = await newLayer('A');
      expect(await fog.importBlocks(layerId: lid, blocks: []), 0);
    });
  });
}
