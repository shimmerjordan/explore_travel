import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../services/export/track_export.dart';
import '../../services/export/track_import.dart';

class LayersScreen extends ConsumerWidget {
  const LayersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layersAsync = ref.watch(layersProvider);
    final activeId = ref.watch(activeLayerIdProvider);
    final db = ref.read(dbProvider);
    final selected = <int>{};

    return Scaffold(
      appBar: AppBar(
        title: const Text('图层与标签',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: '导入轨迹（GPX / KML / KMZ / GeoJSON）',
            onPressed: () => _importTracks(context, ref),
            icon: const Icon(Icons.file_download_rounded),
          ),
          FilledButton.tonalIcon(
            onPressed: () => _showCreateDialog(context, db),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('新建'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: layersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('错误：$e')),
        data: (layers) {
          return StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                // Discoverability tip — the style editor is behind a
                // long-press, which isn't obvious otherwise.
                const _Tip('点按切换当前图层 · 长按图层可编辑路径样式（颜色 / 粗细 / 浓淡）'),
                Expanded(
                  child: ListView.builder(
                    itemCount: layers.length,
                    itemBuilder: (_, i) {
                      final l = layers[i];
                      final isActive = l.id == activeId;
                      return ListTile(
                        leading: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: Color(l.colorValue),
                            shape: BoxShape.circle,
                          ),
                        ),
                        title: Text(l.name),
                        subtitle: Text(l.tag ?? '无标签'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Checkbox(
                              value: selected.contains(l.id),
                              onChanged: (v) {
                                setState(() {
                                  if (v == true) {
                                    selected.add(l.id);
                                  } else {
                                    selected.remove(l.id);
                                  }
                                });
                              },
                            ),
                            PopupMenuButton<String>(
                              icon: const Icon(Icons.more_vert),
                              onSelected: (action) =>
                                  _onAction(context, db, l, action),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                    value: 'gpx', child: Text('导出 GPX')),
                                PopupMenuItem(
                                    value: 'kml', child: Text('导出 KML')),
                              ],
                            ),
                            IconButton(
                              icon: Icon(l.visible
                                  ? Icons.visibility
                                  : Icons.visibility_off),
                              onPressed: () =>
                                  db.updateLayer(l.copyWith(visible: !l.visible)),
                            ),
                            if (isActive)
                              const Padding(
                                padding: EdgeInsets.only(left: 8),
                                child: Icon(Icons.check_circle,
                                    color: Colors.green),
                              ),
                          ],
                        ),
                        onTap: () => ref
                            .read(activeLayerIdProvider.notifier)
                            .state = l.id,
                        onLongPress: () =>
                            _showEditDialog(context, db, l),
                      );
                    },
                  ),
                ),
                if (selected.length >= 2)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('已选择 ${selected.length} 个图层'),
                        ),
                        FilledButton.icon(
                          onPressed: () async {
                            final keep = selected.first;
                            final merge =
                                selected.where((id) => id != keep).toList();
                            await db.mergeLayers(merge, keep);
                            setState(selected.clear);
                          },
                          icon: const Icon(Icons.merge),
                          label: const Text('合并到第一个'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _onAction(
      BuildContext context, AppDb db, TrackLayer l, String action) async {
    final pts = await db.pointsForLayer(l.id);
    if (pts.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('该图层暂无轨迹点')));
      }
      return;
    }
    final file = action == 'gpx'
        ? await TrackExport.exportGpx(name: l.name, points: pts)
        : await TrackExport.exportKml(
            name: l.name,
            points: pts,
            colorHex: l.colorValue.toRadixString(16).padLeft(8, '0'),
          );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已导出：${file.path}'),
        duration: const Duration(seconds: 6),
      ));
    }
  }

  /// Pick a track file (GPX / KML / KMZ / GeoJSON — including Fog of World,
  /// Strava, Garmin exports), let the user choose a target layer, then write
  /// the points and reveal the fog along them.
  Future<void> _importTracks(BuildContext context, WidgetRef ref) async {
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
      final color = Colors.primaries[
          DateTime.now().millisecond % Colors.primaries.length];
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
            : '已导入 $inserted 个轨迹点（${track.segments.length} 段）');
  }

  void _snack(BuildContext context, String msg) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));

  void _showCreateDialog(BuildContext context, AppDb db) {
    final nameCtrl = TextEditingController();
    final tagCtrl = TextEditingController();
    Color? color = Colors.primaries[DateTime.now().millisecond %
        Colors.primaries.length];
    double opacity = 0.6;
    double width = 14;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('新建图层'),
        content: StatefulBuilder(builder: (context, setState) {
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                TextField(
                  controller: tagCtrl,
                  decoration: const InputDecoration(labelText: '标签（可选）'),
                ),
                const SizedBox(height: 12),
                ..._styleControls(
                  context: context,
                  setState: setState,
                  color: color,
                  opacity: opacity,
                  width: width,
                  onColor: (c) => color = c,
                  onOpacity: (v) => opacity = v,
                  onWidth: (v) => width = v,
                ),
              ],
            ),
          );
        }),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (nameCtrl.text.isEmpty) return;
              await db.insertLayer(TrackLayersCompanion.insert(
                // Identity/chip colour — fall back to a neutral when the
                // user chose "无" (no coloured line).
                colorValue: (color ?? const Color(0xFF90A4AE)).toARGB32(),
                name: nameCtrl.text,
                tag: tagCtrl.text.isEmpty
                    ? const Value.absent()
                    : Value(tagCtrl.text),
                createdAt: DateTime.now(),
                // The chosen colour draws the in-fog line; null = no line.
                pathColor: Value(color?.toARGB32()),
                pathOpacity: Value(opacity),
                pathWidth: Value(width),
              ));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  /// Shared colour + opacity + width controls for the create/edit dialogs.
  /// The picked colour draws a translucent line along the revealed trail
  /// ("a line in the fog"); the first "无" swatch (color == null) means no
  /// coloured line — just the plain reveal. Takes effect on the map live.
  List<Widget> _styleControls({
    required BuildContext context,
    required StateSetter setState,
    required Color? color,
    required double opacity,
    required double width,
    required ValueChanged<Color?> onColor,
    required ValueChanged<double> onOpacity,
    required ValueChanged<double> onWidth,
  }) {
    final cs = Theme.of(context).colorScheme;
    Widget swatch(
            {required bool selected,
            required Widget child,
            required VoidCallback onTap}) =>
        GestureDetector(
          onTap: () => setState(onTap),
          child: Container(
            margin: const EdgeInsets.all(4),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border:
                  selected ? Border.all(width: 3, color: Colors.black) : null,
            ),
            child: child,
          ),
        );
    return [
      Text('路径颜色（在迷雾中画线）',
          style: Theme.of(context).textTheme.labelLarge),
      Wrap(
        children: [
          // "无 / 透明" — no coloured line, just the revealed corridor.
          swatch(
            selected: color == null,
            onTap: () => onColor(null),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cs.surfaceContainerHighest,
                border: Border.all(color: cs.outline),
              ),
              child: Icon(Icons.block, size: 16, color: cs.onSurfaceVariant),
            ),
          ),
          ...Colors.primaries.map((c) => swatch(
                selected: color?.toARGB32() == c.toARGB32(),
                onTap: () => onColor(c),
                child: Container(
                  decoration:
                      BoxDecoration(shape: BoxShape.circle, color: c),
                ),
              )),
        ],
      ),
      const SizedBox(height: 8),
      Text('路径不透明度 ${opacity.toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 12)),
      Slider(
        value: opacity,
        min: 0.1,
        max: 1.0,
        divisions: 18,
        onChanged: (v) => setState(() => onOpacity(v)),
      ),
      Text('路径粗细 ${width.toStringAsFixed(0)} m',
          style: const TextStyle(fontSize: 12)),
      Slider(
        value: width,
        min: 2,
        max: 60,
        divisions: 58,
        onChanged: (v) => setState(() => onWidth(v)),
      ),
    ];
  }

  void _showEditDialog(BuildContext context, AppDb db, TrackLayer l) {
    final nameCtrl = TextEditingController(text: l.name);
    final tagCtrl = TextEditingController(text: l.tag ?? '');
    // The line colour drawn in the fog. null (no pathColor) = no line.
    Color? color = l.pathColor == null ? null : Color(l.pathColor!);
    double opacity = l.pathOpacity ?? 0.6;
    double width = l.pathWidth ?? 14;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('编辑图层'),
        content: StatefulBuilder(builder: (context, setState) {
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                TextField(
                  controller: tagCtrl,
                  decoration: const InputDecoration(labelText: '标签'),
                ),
                const SizedBox(height: 12),
                ..._styleControls(
                  context: context,
                  setState: setState,
                  color: color,
                  opacity: opacity,
                  width: width,
                  onColor: (c) => color = c,
                  onOpacity: (v) => opacity = v,
                  onWidth: (v) => width = v,
                ),
              ],
            ),
          );
        }),
        actions: [
          TextButton(
            onPressed: () async {
              await db.deleteLayer(l.id);
              if (context.mounted) Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
          FilledButton(
            onPressed: () async {
              // Apply the chosen style to the whole layer (live, incl. past
              // data). copyWith preserves columns we don't set.
              await db.updateLayer(l.copyWith(
                name: nameCtrl.text,
                // Keep the chip colour in sync when a line colour is set;
                // preserve the existing chip colour for "无".
                colorValue: (color ?? Color(l.colorValue)).toARGB32(),
                tag: Value(tagCtrl.text.isEmpty ? null : tagCtrl.text),
                pathColor: Value(color?.toARGB32()),
                pathOpacity: Value(opacity),
                pathWidth: Value(width),
              ));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
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
  late int _selectedLayerId = widget.layers.any((l) => l.id == widget.activeLayerId)
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

/// Small inline hint banner — used to surface actions that are otherwise
/// hidden behind a long-press, so users can actually discover them.
class _Tip extends StatelessWidget {
  final String text;
  const _Tip(this.text);
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.lightbulb_outline_rounded,
              size: 16, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}
