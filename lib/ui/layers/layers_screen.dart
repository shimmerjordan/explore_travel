import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../services/export/track_export.dart';

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
        error: (e, _) => Center(child: Text('错误：$e')),
        data: (layers) {
          return StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
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
                              onPressed: () => db.updateLayer(TrackLayer(
                                id: l.id,
                                uuid: l.uuid,
                                name: l.name,
                                colorValue: l.colorValue,
                                visible: !l.visible,
                                tag: l.tag,
                                createdAt: l.createdAt,
                              )),
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

  void _showCreateDialog(BuildContext context, AppDb db) {
    final nameCtrl = TextEditingController();
    final tagCtrl = TextEditingController();
    Color color = Colors.primaries[DateTime.now().millisecond %
        Colors.primaries.length];
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('新建图层'),
        content: StatefulBuilder(builder: (context, setState) {
          return Column(
            mainAxisSize: MainAxisSize.min,
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
              Wrap(
                children: Colors.primaries
                    .map((c) => GestureDetector(
                          onTap: () => setState(() => color = c),
                          child: Container(
                            margin: const EdgeInsets.all(4),
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: c == color
                                  ? Border.all(width: 3, color: Colors.black)
                                  : null,
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ],
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
                name: nameCtrl.text,
                colorValue: color.toARGB32(),
                tag: tagCtrl.text.isEmpty
                    ? const Value.absent()
                    : Value(tagCtrl.text),
                createdAt: DateTime.now(),
              ));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(BuildContext context, AppDb db, TrackLayer l) {
    final nameCtrl = TextEditingController(text: l.name);
    final tagCtrl = TextEditingController(text: l.tag ?? '');
    Color color = Color(l.colorValue);
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('编辑图层'),
        content: StatefulBuilder(builder: (context, setState) {
          return Column(
            mainAxisSize: MainAxisSize.min,
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
              Wrap(
                children: Colors.primaries
                    .map((c) => GestureDetector(
                          onTap: () => setState(() => color = c),
                          child: Container(
                            margin: const EdgeInsets.all(4),
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: c.toARGB32() == color.toARGB32()
                                  ? Border.all(width: 3, color: Colors.black)
                                  : null,
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ],
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
              await db.updateLayer(TrackLayer(
                id: l.id,
                uuid: l.uuid,
                name: nameCtrl.text,
                colorValue: color.toARGB32(),
                visible: l.visible,
                tag: tagCtrl.text.isEmpty ? null : tagCtrl.text,
                createdAt: l.createdAt,
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
