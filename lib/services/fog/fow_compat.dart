import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'fog_engine.dart';

/// FOW file format constants.
const _mask1 = 'olhwjsktri';
const _mask2 = 'eizxdwknmo';
const _tileWidth = 128;
const _bitmapSize = 512;
const _blockSize = 515; // 512 bitmap + 3 extra bytes
const _headerLen = _tileWidth * _tileWidth; // 16384
const _headerSize = _headerLen * 2; // 32768 bytes

/// Encode a tile ID into the FOW filename format.
String tileIdToFilename(int id) {
  final s = id.toString();
  final md5hex = crypto.md5.convert(utf8.encode(s)).toString();
  final prefix = md5hex.substring(0, 4);
  final body = s.split('').map((d) => _mask1[int.parse(d)]).join();
  final suffix = s.split('').map((d) => _mask2[int.parse(d)]).join();
  return '$prefix$body${suffix.substring(suffix.length - 2)}';
}

/// Decode a FOW filename to tile ID and coordinates.
({int id, int x, int y})? filenameToTile(String name) {
  if (name.length < 6) return null;
  final middle = name.substring(4, name.length - 2);
  int id = 0;
  for (final ch in middle.split('')) {
    final d = _mask1.indexOf(ch);
    if (d < 0) return null;
    id = id * 10 + d;
  }
  if (id < 0 || id >= 512 * 512) return null;
  return (id: id, x: id % 512, y: id ~/ 512);
}

/// Parsed FOW block.
class FowBlock {
  final int bx, by;
  final Uint8List bitmap;
  final String region;
  FowBlock(this.bx, this.by, this.bitmap, this.region);
}

/// Parsed FOW tile.
class FowTile {
  final String filename;
  final int tileX, tileY;
  final List<FowBlock> blocks;
  FowTile(this.filename, this.tileX, this.tileY, this.blocks);
}

/// Parse a single FOW tile file (raw zlib-compressed bytes).
FowTile parseFowTile(String filename, Uint8List rawBytes) {
  final coords = filenameToTile(filename);
  if (coords == null) throw FormatException('Invalid FOW filename: $filename');

  Uint8List buf;
  try {
    final decoded = ZLibDecoder().decodeBytes(rawBytes);
    buf = decoded is Uint8List ? decoded : Uint8List.fromList(decoded);
  } catch (_) {
    buf = rawBytes;
  }

  if (buf.length < _headerSize) {
    throw FormatException('$filename: inflated size ${buf.length} < header $_headerSize');
  }

  final view = ByteData.sublistView(buf);
  final blocks = <FowBlock>[];

  for (int i = 0; i < _headerLen; i++) {
    final blockIdx = view.getUint16(i * 2, Endian.little);
    if (blockIdx == 0) continue;
    final start = _headerSize + (blockIdx - 1) * _blockSize;
    if (start + _bitmapSize > buf.length) continue;

    final bitmap = Uint8List.fromList(
        buf.sublist(start, start + _bitmapSize));

    String region = '??';
    if (start + _bitmapSize + 1 < buf.length) {
      final extra0 = buf[start + _bitmapSize];
      final extra1 = buf[start + _bitmapSize + 1];
      final c0 = String.fromCharCode((extra0 >> 3) + 63); // '?'
      final c1 = String.fromCharCode(
          (((extra0 & 0x7) << 2) | ((extra1 & 0xC0) >> 6)) + 63);
      region = '$c0$c1';
    }

    blocks.add(FowBlock(i % _tileWidth, i ~/ _tileWidth, bitmap, region));
  }

  return FowTile(filename, coords.x, coords.y, blocks);
}

/// Build a FOW tile file (zlib-compressed bytes) from blocks.
Uint8List buildFowTile(int tileX, int tileY, Map<(int, int), Uint8List> blocks) {
  final header = Uint8List(_headerSize);
  final headerView = ByteData.sublistView(header);

  final bodyParts = <Uint8List>[];
  int blockCounter = 1;

  for (int by = 0; by < _tileWidth; by++) {
    for (int bx = 0; bx < _tileWidth; bx++) {
      final bitmap = blocks[(bx, by)];
      if (bitmap == null) continue;

      bool hasData = false;
      for (int i = 0; i < bitmap.length; i++) {
        if (bitmap[i] != 0) {
          hasData = true;
          break;
        }
      }
      if (!hasData) continue;

      final idx = by * _tileWidth + bx;
      headerView.setUint16(idx * 2, blockCounter, Endian.little);
      blockCounter++;

      final blockData = Uint8List(_blockSize);
      blockData.setRange(0, _bitmapSize, bitmap);
      bodyParts.add(blockData);
    }
  }

  final totalLen = _headerSize + bodyParts.fold<int>(0, (s, b) => s + b.length);
  final raw = Uint8List(totalLen);
  raw.setRange(0, _headerSize, header);
  int offset = _headerSize;
  for (final part in bodyParts) {
    raw.setRange(offset, offset + part.length, part);
    offset += part.length;
  }

  final compressed = ZLibEncoder().encode(raw);
  return compressed is Uint8List ? compressed : Uint8List.fromList(compressed);
}

/// Import all FOW tile files from a directory into the engine.
Future<int> importFowDirectory({
  required String dirPath,
  required FogEngine engine,
  required int layerId,
}) async {
  final dir = Directory(dirPath);
  if (!await dir.exists()) return 0;
  int imported = 0;

  await for (final entity in dir.list()) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    if (name.contains('.') || name.length < 6) continue;
    final coords = filenameToTile(name);
    if (coords == null) continue;

    try {
      final bytes = await entity.readAsBytes();
      final tile = parseFowTile(name, Uint8List.fromList(bytes));
      for (final block in tile.blocks) {
        await engine.importBlock(
          tileX: tile.tileX,
          tileY: tile.tileY,
          blockX: block.bx,
          blockY: block.by,
          bitmap: block.bitmap,
          layerId: layerId,
        );
        imported++;
      }
    } catch (_) {
      // skip corrupt files
    }
  }
  return imported;
}

/// Export fog data to FOW tile files in a directory.
Future<int> exportFowDirectory({
  required String dirPath,
  required FogEngine engine,
  required List<int> layerIds,
}) async {
  final dir = Directory(dirPath);
  if (!await dir.exists()) await dir.create(recursive: true);

  final db = engine.db;
  final allTiles = await db.fogTilesForLayers(layerIds, FogEngine.tileZoom);
  if (allTiles.isEmpty) return 0;

  final tileGroups = <(int, int), Map<(int, int), Uint8List>>{};

  for (final t in allTiles) {
    final blockGlobalX = t.tileX;
    final blockGlobalY = t.tileY;
    final fowTileX = blockGlobalX ~/ FogEngine.tileWidth;
    final fowTileY = blockGlobalY ~/ FogEngine.tileWidth;
    final blockX = blockGlobalX % FogEngine.tileWidth;
    final blockY = blockGlobalY % FogEngine.tileWidth;

    final tileKey = (fowTileX, fowTileY);
    final blocks = tileGroups.putIfAbsent(tileKey, () => {});

    final bitmapKey = (blockX, blockY);
    final existing = blocks[bitmapKey];
    if (existing == null) {
      blocks[bitmapKey] = Uint8List.fromList(t.bitmap);
    } else {
      for (int i = 0; i < existing.length; i++) {
        existing[i] |= t.bitmap[i];
      }
    }
  }

  int exported = 0;
  for (final entry in tileGroups.entries) {
    final (tileX, tileY) = entry.key;
    final blocks = entry.value;
    final tileId = tileY * 512 + tileX;
    final filename = tileIdToFilename(tileId);
    final data = buildFowTile(tileX, tileY, blocks);
    await File('$dirPath/$filename').writeAsBytes(data);
    exported++;
  }
  return exported;
}
