import 'dart:math' as math;
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

/// True if [name] could be a FOW tile filename (obfuscated, no extension).
/// A cheap pre-filter so callers can skip reading non-FOW files; the real
/// validation is [filenameToTile].
bool looksLikeFowTileName(String name) =>
    !name.contains('.') && name.length >= 6 && filenameToTile(name) != null;

/// A FOW block ready to feed [FogEngine.importBlocks]. A structural record so
/// fow_compat and fog_engine don't have to import each other's types.
typedef FowBlockImport = ({
  int tileX,
  int tileY,
  int blockX,
  int blockY,
  Uint8List bitmap,
});

/// Parse one FOW tile file — raw [bytes] keyed by its obfuscated [filename] —
/// into engine-ready blocks. Returns `[]` if it isn't a valid FOW tile.
///
/// This does NOT write to the DB. Callers collect blocks across many files and
/// hand them to a single batched [FogEngine.importBlocks] — a Fog of World
/// "Sync" folder is ~45k blocks, so per-block DB writes are unusably slow.
List<FowBlockImport> fowBlocksFromFile(String filename, Uint8List bytes) {
  if (!looksLikeFowTileName(filename)) return const [];
  final tile = parseFowTile(filename, bytes);
  return [
    for (final b in tile.blocks)
      (
        tileX: tile.tileX,
        tileY: tile.tileY,
        blockX: b.bx,
        blockY: b.by,
        bitmap: b.bitmap,
      ),
  ];
}

/// Build the FOW-format tile files (filename → bytes) for [layerIds].
/// Shared by both the directory and zip-archive exporters so the tile
/// grouping/merging logic lives in exactly one place.
Future<Map<String, Uint8List>> _buildFowFiles(
  FogEngine engine,
  List<int> layerIds,
) async {
  final db = engine.db;
  final allTiles = await db.fogTilesForLayers(layerIds, FogEngine.tileZoom);
  final out = <String, Uint8List>{};
  if (allTiles.isEmpty) return out;

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

  for (final entry in tileGroups.entries) {
    final (tileX, tileY) = entry.key;
    final tileId = tileY * 512 + tileX;
    out[tileIdToFilename(tileId)] = buildFowTile(tileX, tileY, entry.value);
  }
  return out;
}

/// Export fog data for [layerIds] as a Fog of World-compatible `Sync.zip`.
/// The layout mirrors a real FoW Sync.zip exactly — every tile is one
/// obfuscated-name file under a top-level `Sync/` folder — so the archive can
/// be dropped into Fog of World's cloud sync as-is, extracted into its "Sync"
/// folder, or re-imported here via [fowBlocksFromArchive]. Returns an empty
/// list when there's nothing explored to export.
Future<Uint8List> exportFowArchive({
  required FogEngine engine,
  required List<int> layerIds,
}) async {
  final files = await _buildFowFiles(engine, layerIds);
  if (files.isEmpty) return Uint8List(0);
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(
        ArchiveFile('Sync/${entry.key}', entry.value.length, entry.value));
  }
  final encoded = ZipEncoder().encode(archive);
  return encoded == null ? Uint8List(0) : Uint8List.fromList(encoded);
}

/// Parse every FOW tile inside a user-picked zip's [zipBytes] into engine-ready
/// blocks. Entries may sit at any path inside the zip — only the basename
/// matters, matching how Fog of World names its Sync files — so both our own
/// exports and a raw FoW "Sync" folder zipped up will import. Non-FOW/corrupt
/// entries are skipped.
List<FowBlockImport> fowBlocksFromArchive(Uint8List zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  final out = <FowBlockImport>[];
  for (final file in archive) {
    if (!file.isFile) continue;
    final name = file.name.split('/').last;
    if (!looksLikeFowTileName(name)) continue;
    try {
      out.addAll(
          fowBlocksFromFile(name, Uint8List.fromList(file.content as List<int>)));
    } catch (_) {
      // skip corrupt entries
    }
  }
  return out;
}

/// Parse a batch of picked inputs (each a `(name, bytes)`) into engine-ready
/// blocks, expanding any zip (detected by its PK magic bytes) into its tiles.
///
/// Pure and top-level so it can run in a background isolate via `compute` — a
/// full Fog of World "Sync" folder is ~45k blocks and parsing it on the UI
/// thread freezes the app for ~10 s.
List<FowBlockImport> parseFowInputs(
    List<({String name, Uint8List bytes})> inputs) {
  final out = <FowBlockImport>[];
  for (final inp in inputs) {
    final b = inp.bytes;
    final isZip = b.length >= 4 &&
        b[0] == 0x50 &&
        b[1] == 0x4B &&
        b[2] == 0x03 &&
        b[3] == 0x04;
    try {
      out.addAll(isZip ? fowBlocksFromArchive(b) : fowBlocksFromFile(inp.name, b));
    } catch (_) {
      // skip a corrupt input
    }
  }
  return out;
}

/// Parse FOW inputs AND expand every explored cell into a [penRadiusMeters]
/// disk, so imported fog matches NATIVELY-recorded corridors instead of FoW's
/// thin raw cells. Native recording reveals a penRadius disk per GPS fix
/// (FogEngine.revealPoint); a FoW tile only stores the bare explored cells, so
/// without this an import looks much thinner than data recorded in-app. Pure +
/// top-level so the whole thing runs in one `compute` isolate. A
/// [penRadiusMeters] <= 0 skips expansion (raw cells, the old behaviour).
List<FowBlockImport> parseAndExpandFowInputs(
    ({
      List<({String name, Uint8List bytes})> inputs,
      double penRadiusMeters
    }) arg) {
  final raw = parseFowInputs(arg.inputs);
  if (arg.penRadiusMeters <= 0 || raw.isEmpty) return raw;
  return _expandToCorridors(raw, arg.penRadiusMeters);
}

/// Dilate every set cell in [blocks] by a [penRadiusMeters] disk — the exact
/// shape [FogEngine.revealPoint] paints — so the result is indistinguishable
/// from native corridors. The disk radius in PIXELS is derived per source block
/// from its centre latitude (Web-Mercator metres-per-pixel shrinks toward the
/// poles), so the GROUND radius stays uniform, matching revealPoint. Dilation
/// that spills past a block/tile edge is routed to the correct neighbour via
/// the global block grid. Pure + isolate-safe.
List<FowBlockImport> _expandToCorridors(
    List<FowBlockImport> blocks, double penRadiusMeters) {
  const full = FogEngine.full; // 2^22 px per axis
  const bw = FogEngine.bitmapWidth; // 64
  const tw = FogEngine.tileWidth; // 128
  const earthCirc = 40075016.686;

  // Disk offsets are reused across blocks at the same latitude band.
  final offsetsByR = <int, List<(int, int)>>{};
  List<(int, int)> diskOffsets(int r) => offsetsByR.putIfAbsent(r, () {
        final o = <(int, int)>[];
        final r2 = r * r;
        for (int dy = -r; dy <= r; dy++) {
          for (int dx = -r; dx <= r; dx++) {
            if (dx * dx + dy * dy <= r2) o.add((dx, dy));
          }
        }
        return o;
      });

  // Output keyed by global block index: key = (dbY << 16) | dbX, each < 2^16
  // (full / bw = 2^16). Value is one 512-byte (64×64) block bitmap.
  final out = <int, Uint8List>{};

  for (final b in blocks) {
    final blockGx = (b.tileX * tw + b.blockX) * bw;
    final blockGy = (b.tileY * tw + b.blockY) * bw;
    final centreLat = FogEngine.globalYToLat(blockGy + bw ~/ 2);
    final mpp = earthCirc * math.cos(centreLat * math.pi / 180.0) / full;
    // Cap so a near-pole block can't queue an enormous disk.
    final rPx = (penRadiusMeters / mpp).ceil().clamp(1, 32);
    final offs = diskOffsets(rPx);
    final bm = b.bitmap;

    // Most disk samples for one source cell land in the same target block —
    // cache it so we hit the map only when the target block changes.
    int lastDbX = -1, lastDbY = -1;
    Uint8List? lastBm;
    for (int py = 0; py < bw; py++) {
      final rowBase = py * 8;
      for (int byteCol = 0; byteCol < 8; byteCol++) {
        final bval = bm[rowBase + byteCol];
        if (bval == 0) continue;
        for (int bit = 0; bit < 8; bit++) {
          if (((bval >> (7 - bit)) & 1) == 0) continue;
          final gx0 = blockGx + (byteCol << 3) + bit;
          final gy0 = blockGy + py;
          for (final (dx, dy) in offs) {
            final gx = gx0 + dx, gy = gy0 + dy;
            if (gx < 0 || gy < 0 || gx >= full || gy >= full) continue;
            final dbX = gx >> 6, dbY = gy >> 6;
            Uint8List tbm;
            if (dbX == lastDbX && dbY == lastDbY) {
              tbm = lastBm!;
            } else {
              tbm = out.putIfAbsent(
                  (dbY << 16) | dbX, () => Uint8List(_bitmapSize));
              lastDbX = dbX;
              lastDbY = dbY;
              lastBm = tbm;
            }
            final tpx = gx & 63, tpy = gy & 63;
            tbm[(tpx >> 3) + (tpy << 3)] |= 1 << (7 - (tpx & 7));
          }
        }
      }
    }
  }

  return [
    for (final e in out.entries)
      (
        tileX: (e.key & 0xFFFF) ~/ tw,
        tileY: (e.key >> 16) ~/ tw,
        blockX: (e.key & 0xFFFF) % tw,
        blockY: (e.key >> 16) % tw,
        bitmap: e.value,
      ),
  ];
}

/// Like [fowBlocksFromArchive], but reports progress as it decompresses/parses
/// each entry and yields to the event loop between batches so a progress bar
/// can repaint. Used for the single-`Sync.zip` import path (hundreds of entries
/// in one file). [onProgress] is called as (done, total) over FOW entries.
Future<List<FowBlockImport>> fowBlocksFromArchiveProgress(
  Uint8List zipBytes, {
  void Function(int done, int total)? onProgress,
}) async {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  final entries = [
    for (final f in archive)
      if (f.isFile && looksLikeFowTileName(f.name.split('/').last)) f,
  ];
  final out = <FowBlockImport>[];
  for (var i = 0; i < entries.length; i++) {
    final f = entries[i];
    try {
      out.addAll(fowBlocksFromFile(
          f.name.split('/').last, Uint8List.fromList(f.content as List<int>)));
    } catch (_) {
      // skip corrupt entries
    }
    if (onProgress != null && (i % 8 == 0 || i == entries.length - 1)) {
      onProgress(i + 1, entries.length);
      await Future<void>.delayed(Duration.zero); // let the UI repaint
    }
  }
  return out;
}
