import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../services/export/track_import.dart';
import '../../services/media/exif_service.dart';

/// Shared entry points for importing track points + revealing fog, reused by
/// both the layers screen and the home/map screen so the flow (pick → choose
/// target layer → ingest with progress) lives in exactly one place.
class TrackImportFlow {
  const TrackImportFlow._();

  /// Pick a track file (GPX / KML / KMZ / GeoJSON — including Fog of World,
  /// Strava, Garmin exports) and import it into a chosen layer.
  static Future<void> fromFile(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['gpx', 'kml', 'kmz', 'geojson', 'json'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;

    ImportedTrack track;
    try {
      track = await TrackImport.parseFile(File(path));
    } catch (e) {
      if (context.mounted) _snack(context, '解析失败：$e');
      return;
    }
    if (track.isEmpty) {
      if (context.mounted) _snack(context, '文件中没有可导入的轨迹点');
      return;
    }
    if (!context.mounted) return;
    await _chooseTargetAndIngest(context, ref, track);
  }

  /// Pick multiple local photos and light up the trail at each photo's EXIF
  /// GPS location. Each photo becomes a discrete revealed point (no line
  /// connecting them — photos aren't a walked path). Photos without GPS are
  /// skipped.
  static Future<void> fromPhotos(BuildContext context, WidgetRef ref) async {
    final files = await ImagePicker().pickMultiImage();
    if (files.isEmpty || !context.mounted) return;
    await ExifService.ensureLocationMetadataAccess();

    final pts = <ImportedPoint>[];
    var noGps = 0;
    for (final f in files) {
      final gps = await ExifService.readGps(f.path);
      if (gps == null) {
        noGps++;
        continue;
      }
      pts.add(ImportedPoint(gps.lat, gps.lng, time: gps.time));
    }
    if (pts.isEmpty) {
      if (context.mounted) {
        _snack(context, '选中的 ${files.length} 张照片都没有 GPS 定位信息');
      }
      return;
    }
    // Order by capture time when available, then make each photo its own
    // single-point segment so ingest reveals a point per photo (no lines).
    pts.sort((a, b) => (a.time ?? DateTime(0)).compareTo(b.time ?? DateTime(0)));
    final track = ImportedTrack('照片定位', [for (final p in pts) [p]]);
    if (!context.mounted) return;
    await _chooseTargetAndIngest(context, ref, track,
        extraNote: noGps > 0 ? '（$noGps 张无定位已跳过）' : null);
  }

  /// Shared tail of both import paths: ask for a target layer, then write
  /// points + reveal fog with a progress dialog.
  static Future<void> _chooseTargetAndIngest(
      BuildContext context, WidgetRef ref, ImportedTrack track,
      {String? extraNote}) async {
    final db = ref.read(dbProvider);
    final layers = await db.allLayers();
    if (!context.mounted) return;

    final target = await showDialog<_ImportTarget>(
      context: context,
      builder: (_) => _ImportTargetDialog(
        suggestedName: track.name,
        pointCount: track.pointCount,
        layers: layers,
        activeLayerId: ref.read(activeLayerIdProvider),
      ),
    );
    if (target == null || !context.mounted) return;

    // Resolve the destination layer.
    int layerId;
    if (target.existingLayerId != null) {
      layerId = target.existingLayerId!;
    } else {
      final color = Colors
          .primaries[DateTime.now().millisecond % Colors.primaries.length];
      layerId = await db.insertLayer(TrackLayersCompanion.insert(
        name: target.newName.isEmpty ? track.name : target.newName,
        colorValue: color.toARGB32(),
        createdAt: DateTime.now(),
        pathColor: Value(color.toARGB32()),
        pathOpacity: const Value(0.6),
      ));
    }

    final settings = ref.read(settingsProvider);
    final fog = ref.read(fogEngineProvider);
    double? destWidth;
    for (final l in await db.allLayers()) {
      if (l.id == layerId) {
        destWidth = l.pathWidth;
        break;
      }
    }
    final pointWidth = destWidth ?? settings.trailWidth;

    // Progress dialog (fog reveal on a long track can take a few seconds).
    final progress = ValueNotifier<double>(0);
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, v, __) => Row(
            children: [
              const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5)),
              const SizedBox(width: 16),
              Text('正在导入… ${(v * 100).toStringAsFixed(0)}%'),
            ],
          ),
        ),
      ),
    );

    int inserted = 0;
    String? error;
    try {
      inserted = await TrackImport.ingest(
        track: track,
        layerId: layerId,
        db: db,
        fog: fog,
        pointWidth: pointWidth,
        penRadius: settings.fogPenRadius,
        onProgress: (p) => progress.value = p,
      );
    } catch (e) {
      error = '$e';
    }
    progress.dispose();
    ref.read(fogRefreshProvider.notifier).state++;

    if (!context.mounted) return;
    Navigator.of(context).pop(); // dismiss progress dialog
    _snack(
        context,
        error != null
            ? '导入失败：$error'
            : '已点亮 $inserted 个轨迹点${extraNote ?? ''}');
  }

  static void _snack(BuildContext context, String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// Where an imported track should land. Exactly one of [existingLayerId] /
/// [newName] is meaningful: null id → create a layer named [newName].
class _ImportTarget {
  final int? existingLayerId;
  final String newName;
  const _ImportTarget.existing(int id)
      : existingLayerId = id,
        newName = '';
  const _ImportTarget.create(this.newName) : existingLayerId = null;
}

/// Asks the user whether to import into a brand-new layer (default, named
/// after the file) or merge into an existing one.
class _ImportTargetDialog extends StatefulWidget {
  final String suggestedName;
  final int pointCount;
  final List<TrackLayer> layers;
  final int activeLayerId;
  const _ImportTargetDialog({
    required this.suggestedName,
    required this.pointCount,
    required this.layers,
    required this.activeLayerId,
  });

  @override
  State<_ImportTargetDialog> createState() => _ImportTargetDialogState();
}

class _ImportTargetDialogState extends State<_ImportTargetDialog> {
  bool _createNew = true;
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.suggestedName);
  late int _selectedLayerId =
      widget.layers.any((l) => l.id == widget.activeLayerId)
          ? widget.activeLayerId
          : (widget.layers.isNotEmpty ? widget.layers.first.id : 0);

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入轨迹'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('解析到 ${widget.pointCount} 个轨迹点',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            RadioListTile<bool>(
              value: true,
              groupValue: _createNew,
              onChanged: (v) => setState(() => _createNew = v!),
              contentPadding: EdgeInsets.zero,
              title: const Text('新建图层'),
            ),
            if (_createNew)
              Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 8),
                child: TextField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(labelText: '图层名称'),
                ),
              ),
            RadioListTile<bool>(
              value: false,
              groupValue: _createNew,
              onChanged: widget.layers.isEmpty
                  ? null
                  : (v) => setState(() => _createNew = v!),
              contentPadding: EdgeInsets.zero,
              title: const Text('导入到已有图层'),
            ),
            if (!_createNew)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: _selectedLayerId,
                  items: [
                    for (final l in widget.layers)
                      DropdownMenuItem(value: l.id, child: Text(l.name)),
                  ],
                  onChanged: (v) =>
                      setState(() => _selectedLayerId = v ?? _selectedLayerId),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
          onPressed: () {
            Navigator.pop(
              context,
              _createNew
                  ? _ImportTarget.create(_nameCtrl.text.trim())
                  : _ImportTarget.existing(_selectedLayerId),
            );
          },
          child: const Text('导入'),
        ),
      ],
    );
  }
}
