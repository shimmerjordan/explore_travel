import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../services/export/track_export.dart';
import '../common/empty_state.dart';
import '../common/failure.dart';
import '../common/pixel.dart';
import '../import/track_import_flow.dart';

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
        error: (e, _) => EmptyState(
          title: failureMessage('读取图层', e),
          hint: '图层列表没能读出来。可以重试一次，或者退出这页再进来。',
          sprite: PixelSprites.map,
          actionLabel: '重试',
          onAction: () => ref.invalidate(layersProvider),
        ),
        data: (layers) {
          return StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                // Discoverability tip — edit lives in the ⋮ menu (and
                // long-press as a shortcut).
                const _Tip('点按切换当前图层 · 「⋮ → 编辑」或长按可改名称与路径颜色'),
                // 导入入口从图标弹出菜单拆成可见按钮 —— 这页足够简单，
                // 没必要把两个主要动作藏进一个不知名的图标里。
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              TrackImportFlow.fromFile(context, ref),
                          icon: const Icon(Icons.route_rounded, size: 18),
                          label: const Text('导入轨迹文件',
                              style: TextStyle(fontSize: 13)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              TrackImportFlow.fromPhotos(context, ref),
                          icon: const Icon(Icons.photo_library_rounded,
                              size: 18),
                          label: const Text('从照片点亮',
                              style: TextStyle(fontSize: 13)),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: layers.length,
                    itemBuilder: (_, i) {
                      final l = layers[i];
                      final isActive = l.id == activeId;
                      return ListTile(
                        // The active layer reads through the M3 selected
                        // state (tinted row) — no extra badge icon needed.
                        selected: isActive,
                        selectedTileColor: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.08),
                        leading: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: Color(l.colorValue),
                            shape: BoxShape.circle,
                          ),
                        ),
                        title: Text(l.name),
                        subtitle: (l.tag == null || l.tag!.isEmpty)
                            ? (isActive ? const Text('当前图层') : null)
                            : Text(isActive ? '${l.tag} · 当前图层' : l.tag!),
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
                                    value: 'edit',
                                    child: Text('编辑（名称 / 颜色）')),
                                PopupMenuDivider(),
                                PopupMenuItem(
                                    value: 'gpx', child: Text('导出 GPX')),
                                PopupMenuItem(
                                    value: 'kml', child: Text('导出 KML')),
                              ],
                            ),
                            IconButton(
                              tooltip: l.visible ? '隐藏图层' : '显示图层',
                              icon: Icon(l.visible
                                  ? Icons.visibility
                                  : Icons.visibility_off),
                              onPressed: () =>
                                  db.updateLayer(l.copyWith(visible: !l.visible)),
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
                if (selected.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('已选择 ${selected.length} 个图层'),
                        ),
                        // Batch delete — the primary ask. Confirms once, then
                        // removes every checked layer (and its points/fog).
                        TextButton.icon(
                          onPressed: () async {
                            final ids = selected.toList();
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (confirmCtx) => AlertDialog(
                                title: Text('删除 ${ids.length} 个图层？'),
                                content: const Text('所选图层及其轨迹、迷雾将从本机'
                                    '移除，此操作不可撤销（下次同步会传播到其他设备）。'),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(confirmCtx).pop(false),
                                    child: const Text('取消'),
                                  ),
                                  FilledButton(
                                    // 不可逆操作：白字压在 Colors.red 上只有
                                    // 3.68:1，改用 M3 保证成对的 error/onError。
                                    style: FilledButton.styleFrom(
                                      backgroundColor:
                                          Theme.of(confirmCtx).colorScheme.error,
                                      foregroundColor: Theme.of(confirmCtx)
                                          .colorScheme
                                          .onError,
                                    ),
                                    onPressed: () =>
                                        Navigator.of(confirmCtx).pop(true),
                                    child: const Text('删除'),
                                  ),
                                ],
                              ),
                            );
                            if (ok != true) return;
                            for (final id in ids) {
                              await db.deleteLayer(id);
                            }
                            setState(selected.clear);
                          },
                          style: TextButton.styleFrom(
                              foregroundColor:
                                  Theme.of(context).colorScheme.error),
                          icon: const Icon(Icons.delete_outline),
                          label: Text('删除所选 (${selected.length})'),
                        ),
                        const SizedBox(width: 8),
                        if (selected.length >= 2)
                          FilledButton.icon(
                            onPressed: () async {
                              final keep = selected.first;
                              final merge = selected
                                  .where((id) => id != keep)
                                  .toList();
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
    // Edit needs no track points — handle it before the points fetch/guard.
    if (action == 'edit') {
      _showEditDialog(context, db, l);
      return;
    }
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
      // Colour semantics: the corridor SHAPE is identical for every layer —
      // "透明" punches the fog to show the map, a colour paints the same
      // corridor in that colour. No second marking behind a coloured path.
      Text('路径颜色（透明 = 直接透出地图）',
          style: Theme.of(context).textTheme.labelLarge),
      Wrap(
        children: [
          // "无 / 透明" — plain revealed corridor.
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
      Text('颜色浓淡 ${opacity.toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 12)),
      Slider(
        value: opacity,
        min: 0.1,
        max: 1.0,
        divisions: 18,
        onChanged: (v) => setState(() => onOpacity(v)),
      ),
      // 路径粗细由记录笔刷（数据域）决定，渲染宽度所有图层一致 —— 不再有
      // 独立的"彩色线粗细"。pathWidth 字段保留在库里仅作兼容。
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
      builder: (dialogCtx) => AlertDialog(
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
              // Confirm — deleting a layer also drops its points/fog on the
              // map. Pop the DIALOG's own route (dialogCtx), not the caller's
              // screen route: using the screen context here popped the layers
              // PAGE off go_router's stack ("popped the last page…") and
              // cascaded into a locked navigator.
              final ok = await showDialog<bool>(
                context: dialogCtx,
                builder: (confirmCtx) => AlertDialog(
                  title: const Text('删除图层？'),
                  content: Text('“${l.name}”及其轨迹、迷雾将从本机移除，'
                      '此操作不可撤销（下次同步会传播到其他设备）。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(confirmCtx).pop(false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            Theme.of(confirmCtx).colorScheme.error,
                        foregroundColor:
                            Theme.of(confirmCtx).colorScheme.onError,
                      ),
                      onPressed: () => Navigator.of(confirmCtx).pop(true),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              );
              if (ok != true) return;
              await db.deleteLayer(l.id);
              if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
            },
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(dialogCtx).colorScheme.error),
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
              if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
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
