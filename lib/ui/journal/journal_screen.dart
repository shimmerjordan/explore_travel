import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../services/geo/coord_converter.dart';
import '../../services/imghost/upload_queue.dart' show UploadRecord;
import '../../services/imghost/private_image_loader.dart';
import '../../services/map/tile_providers.dart';
import '../../services/media/exif_service.dart';
import '../common/pixel.dart';
import '../map/native_file_image_io.dart';
import 'location_picker.dart';
import 'quill_editor_screen.dart';

class JournalScreen extends ConsumerStatefulWidget {
  const JournalScreen({super.key});
  @override
  ConsumerState<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends ConsumerState<JournalScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  int _refresh = 0;

  /// Multi-select state for bulk management. Holds entry ids.
  final Set<int> _selected = {};
  bool _selectMode = false;

  void _bumpRefresh() {
    setState(() => _refresh++);
    // Mirror the change to the map so its journal pins stay in sync — this
    // is the path that was missing for photo-imported entries (they showed
    // up in this list but never as pins).
    ref.read(journalRefreshProvider.notifier).state++;
  }

  void _exitSelect() => setState(() {
        _selectMode = false;
        _selected.clear();
      });

  void _toggleSelect(int id) => setState(() {
        if (!_selected.remove(id)) _selected.add(id);
        if (_selected.isEmpty) _selectMode = false;
      });

  Future<void> _deleteSelected(AppDb db) async {
    final ids = _selected.toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除手账'),
        content: Text('确定删除所选的 ${ids.length} 条手账？此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final uploadQueue = ref.read(uploadQueueProvider);
    for (final id in ids) {
      await uploadQueue.deleteAllForJournal(id);
      // Tombstoning delete — the removal survives future sync merges.
      await db.deleteJournalById(id);
    }
    if (!mounted) return;
    _exitSelect();
    _bumpRefresh();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已删除 ${ids.length} 条手账')));
  }

  /// Batch-create one journal entry per picked photo. Default title is the
  /// capture time; location and time come from EXIF, falling back to a
  /// one-shot current fix (for time: the file's last-modified) when absent.
  Future<void> _importJournalsFromPhotos(AppDb db) async {
    final files = await ImagePicker().pickMultiImage();
    if (files.isEmpty || !mounted) return;
    await ExifService.ensureLocationMetadataAccess();

    // Lazily resolve a fallback location once for the whole batch — only
    // hit GPS if at least one photo lacks EXIF coordinates.
    ({double lat, double lng})? fallbackPos;
    var fallbackResolved = false;
    Future<({double lat, double lng})?> fallback() async {
      if (!fallbackResolved) {
        fallbackResolved = true;
        final p = await ref.read(locationServiceProvider).currentOnce();
        if (p != null) fallbackPos = (lat: p.latitude, lng: p.longitude);
      }
      return fallbackPos;
    }

    final layerId = ref.read(effectiveActiveLayerIdProvider);
    final uploadQueue = ref.read(uploadQueueProvider);
    final fmt = DateFormat('yyyy-MM-dd HH:mm');
    var created = 0;
    var skipped = 0;

    for (final f in files) {
      final gps = await ExifService.readGps(f.path);
      DateTime time = gps?.time ?? DateTime.now();
      if (gps?.time == null) {
        try {
          time = await File(f.path).lastModified();
        } catch (_) {}
      }
      double? lat = gps?.lat;
      double? lng = gps?.lng;
      if (lat == null || lng == null) {
        final fb = await fallback();
        if (fb == null) {
          skipped++; // no EXIF GPS and no current fix → can't place it
          continue;
        }
        lat = fb.lat;
        lng = fb.lng;
      }
      final id = await db.insertJournal(JournalEntriesCompanion.insert(
        time: time,
        lat: lat,
        lng: lng,
        title: fmt.format(time),
        mediaPaths: Value(f.path),
        layerId: layerId,
      ));
      await uploadQueue.enqueueForJournal(
        journalId: id,
        localPaths: [f.path],
        richContent: '',
      );
      created++;
    }

    if (!mounted) return;
    _bumpRefresh();
    final msg = StringBuffer('已从照片创建 $created 条手账');
    if (skipped > 0) msg.write('，$skipped 张无定位信息已跳过');
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg.toString())));
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(
        leading: _selectMode
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: _exitSelect,
              )
            : null,
        title: _selectMode
            ? Text('已选 ${_selected.length} 条',
                style: const TextStyle(fontWeight: FontWeight.w700))
            : Text('旅行手账',
                style: PixelText.headline
                    .copyWith(color: Theme.of(context).colorScheme.onSurface)),
        actions: _selectMode
            ? [
                IconButton(
                  tooltip: '删除所选',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed:
                      _selected.isEmpty ? null : () => _deleteSelected(db),
                ),
              ]
            : [
                IconButton(
                  tooltip: '图片上传队列',
                  icon: const Icon(Icons.cloud_upload_outlined),
                  onPressed: () => _showUploadQueue(context, ref),
                ),
                IconButton(
                  tooltip: '从照片批量导入手账',
                  icon: const Icon(Icons.photo_library_outlined),
                  onPressed: () => _importJournalsFromPhotos(db),
                ),
                IconButton(
                  tooltip: '多选管理',
                  icon: const Icon(Icons.checklist_rounded),
                  onPressed: () => setState(() => _selectMode = true),
                ),
                IconButton(
                  icon: const Icon(Icons.add_rounded),
                  onPressed: () async {
                    final changed =
                        await showJournalEditor(context, ref, entry: null);
                    if (changed && mounted) _bumpRefresh();
                  },
                ),
              ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                hintText: '搜索手账（标题/正文）',
                filled: true,
                fillColor: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHigh
                    .withValues(alpha: 0.5),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (v) => setState(() => _query = v),
            ),
          ),
        ),
      ),
      body: FutureBuilder<List<JournalEntry>>(
        key: ValueKey('journal-$_refresh-$_query'),
        future: _query.isEmpty ? db.recentJournal() : db.searchJournal(_query),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snap.data!;
          if (entries.isEmpty) {
            return const Center(child: Text('还没有动态。点 + 来记录第一条吧～'));
          }
          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (_, i) {
              final e = entries[i];
              final paths =
                  e.mediaPaths.split('\n').where((p) => p.isNotEmpty).toList();
              final preview = quillToPreview(e.richContent);
              final isSelected = _selected.contains(e.id);
              final cs = Theme.of(context).colorScheme;
              final tt = Theme.of(context).textTheme;
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                child: Material(
                  color: isSelected
                      ? cs.primaryContainer
                      : cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(6),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () async {
                      if (_selectMode) {
                        _toggleSelect(e.id);
                        return;
                      }
                      await openJournalDetail(context, ref, e);
                      if (mounted) _bumpRefresh();
                    },
                    onLongPress: () {
                      setState(() => _selectMode = true);
                      _toggleSelect(e.id);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_selectMode)
                            Padding(
                              padding:
                                  const EdgeInsets.only(right: 10, top: 26),
                              child: Icon(
                                isSelected
                                    ? Icons.check_circle_rounded
                                    : Icons.radio_button_unchecked_rounded,
                                color: isSelected
                                    ? cs.primary
                                    : cs.onSurface.withValues(alpha: 0.4),
                              ),
                            ),
                          // Leading photo (with +N badge) or a placeholder tile.
                          _JournalLeading(paths: paths),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Expanded(
                                    child: Text(
                                      e.title.isEmpty ? '(无标题)' : e.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: tt.titleMedium?.copyWith(
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(DateFormat('MM/dd').format(e.time),
                                      style: tt.bodySmall?.copyWith(
                                          color: cs.onSurfaceVariant)),
                                ]),
                                if (preview.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(preview,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: cs.onSurfaceVariant,
                                          height: 1.35)),
                                ],
                                const SizedBox(height: 8),
                                Row(children: [
                                  Icon(Icons.location_on_outlined,
                                      size: 13, color: cs.onSurfaceVariant),
                                  const SizedBox(width: 3),
                                  Flexible(
                                    child: Text(
                                      '${e.lat.toStringAsFixed(3)}, ${e.lng.toStringAsFixed(3)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: cs.onSurfaceVariant),
                                    ),
                                  ),
                                  const Spacer(),
                                  _ListUploadChip(entry: e),
                                  if (paths.isNotEmpty)
                                    _UploadStatusBadge(journalId: e.id),
                                ]),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ─── Reusable entry-points ──────────────────────────────────────────────
//
// Both functions return `true` when the database changed (insert / update /
// delete) so callers can refresh their views.

/// Editor dialog. Pass `entry` to edit, omit to create. Returns true if the
/// DB was changed.
Future<bool> showJournalEditor(
  BuildContext context,
  WidgetRef ref, {
  JournalEntry? entry,
}) async {
  final titleCtrl = TextEditingController(text: entry?.title ?? '');
  final mediaPaths = <String>[
    if (entry != null)
      ...entry.mediaPaths.split('\n').where((p) => p.isNotEmpty),
  ];
  String richContent = entry?.richContent ?? '';
  String level = entry?.level ?? 'public';
  String? ownerPeerId = entry?.ownerPeerId;
  final picker = ImagePicker();
  final activeLayer = ref.read(effectiveActiveLayerIdProvider);
  // For a new entry we anchor on the map's *displayed* pin (simulator-aware).
  // ⚠️ 弹窗必须**立即**出现：定位兜底与 peers 查询都在弹窗打开后异步补——
  // 老版本在这里同步 await currentOnce()，室内两级超时最长 ~13s，就是
  // 「点加号卡特别久」的根因。
  double? exifLat;
  double? exifLng;
  DateTime? exifTime;
  ({double lat, double lng})? pinPos;
  ({double lat, double lng})? pickedPos; // 用户在地图上手选的点，优先级最高
  var locating = false;
  if (entry == null) {
    pinPos = ref.read(currentDisplayPositionProvider);
    locating = pinPos == null; // 弹窗后异步补一次 GPS
  }
  DateTime resolvedTime() => entry?.time ?? exifTime ?? DateTime.now();
  double? resolvedLat() =>
      pickedPos?.lat ?? entry?.lat ?? exifLat ?? pinPos?.lat;
  double? resolvedLng() =>
      pickedPos?.lng ?? entry?.lng ?? exifLng ?? pinPos?.lng;
  // Peers ever seen — pulled from chat_messages so we include offline ones
  // too. Loaded async after the dialog opens.
  final db0 = ref.read(dbProvider);
  var knownPeers = <({String id, String name})>[];

  if (!context.mounted) return false;
  bool changed = false;
  // 弹窗关闭后异步回调不许再 setState（StatefulBuilder 的 element 已销毁）。
  var alive = true;
  var asyncStarted = false;
  // Inline validation message under the title field. The save used to just
  // `return` on an empty title, so the button looked broken ("保存不了没提示").
  String? titleError;
  String? posError;
  await showDialog<void>(
    context: context,
    builder: (_) => StatefulBuilder(builder: (dialogCtx, setState) {
      if (!asyncStarted) {
        asyncStarted = true;
        // Peers（毫秒级，但没理由挡弹窗）。
        () async {
          try {
            final rows = await db0
                .customSelect(
                  'SELECT DISTINCT peer_id, author FROM chat_messages ORDER BY peer_id',
                )
                .get();
            if (!alive) return;
            setState(() => knownPeers = [
                  for (final r in rows)
                    (
                      id: r.read<String>('peer_id'),
                      name: r.read<String>('author'),
                    ),
                ]);
          } catch (_) {}
        }();
        // 定位兜底：地图从没画过 pin 时才需要，一次性，慢也不挡 UI。
        if (locating) {
          () async {
            final pos =
                await ref.read(locationServiceProvider).currentOnce();
            if (!alive) return;
            setState(() {
              locating = false;
              if (pos != null) {
                pinPos = (lat: pos.latitude, lng: pos.longitude);
                posError = null;
              }
            });
          }();
        }
      }
      return AlertDialog(
        title: Text(entry == null ? '新增手账' : '编辑手账'),
        // Explicit width prevents AlertDialog from asking for intrinsic
        // dimensions on the descendant tree, which would crash on the
        // horizontal media-thumbs ListView (a Viewport can't return
        // intrinsics — that's by design, viewports are lazy).
        content: SizedBox(
          width: MediaQuery.of(dialogCtx).size.width * 0.9,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Default-visible location + time so the user knows what
                // will be saved before they even tap anything.
                _MetaLine(
                  icon: Icons.access_time,
                  text: DateFormat('yyyy-MM-dd HH:mm').format(resolvedTime()),
                ),
                const SizedBox(height: 4),
                Row(children: [
                  Icon(Icons.location_on_outlined,
                      size: 14, color: Theme.of(dialogCtx).hintColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      resolvedLat() == null
                          ? (locating ? '正在获取位置…' : '未获取到位置')
                          : '${resolvedLat()!.toStringAsFixed(5)}, ${resolvedLng()!.toStringAsFixed(5)}'
                              '${pickedPos != null ? '（手选）' : ''}',
                      style: TextStyle(
                          fontSize: 12,
                          color: posError != null
                              ? Theme.of(dialogCtx).colorScheme.error
                              : Theme.of(dialogCtx).hintColor),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8)),
                    icon: const Icon(Icons.map_outlined, size: 16),
                    label: const Text('地图选点', style: TextStyle(fontSize: 12)),
                    onPressed: () async {
                      final picked = await showLocationPicker(
                        dialogCtx,
                        initialLat: resolvedLat(),
                        initialLng: resolvedLng(),
                      );
                      if (picked != null && alive) {
                        setState(() {
                          pickedPos = picked;
                          posError = null;
                        });
                      }
                    },
                  ),
                ]),
                if (posError != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 20, bottom: 2),
                    child: Text(posError!,
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(dialogCtx).colorScheme.error)),
                  ),
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.person_outline, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: DropdownButton<String?>(
                      value: ownerPeerId,
                      isDense: true,
                      isExpanded: true,
                      hint: const Text('归属人：自己'),
                      items: [
                        const DropdownMenuItem<String?>(
                            value: null, child: Text('自己')),
                        ...knownPeers.map((p) => DropdownMenuItem<String?>(
                            value: p.id,
                            child: Text(
                                '${p.name}（${p.id.substring(0, p.id.length < 6 ? p.id.length : 6)}…）'))),
                      ],
                      onChanged: (v) => setState(() => ownerPeerId = v),
                    ),
                  ),
                ]),
                Row(children: [
                  const Icon(Icons.lock_outline, size: 14),
                  const SizedBox(width: 6),
                  const Text('级别：'),
                  Radio<String>(
                    value: 'public',
                    groupValue: level,
                    onChanged: (v) => setState(() => level = v ?? 'public'),
                  ),
                  const Text('公开'),
                  Radio<String>(
                    value: 'private',
                    groupValue: level,
                    onChanged: (v) => setState(() => level = v ?? 'public'),
                  ),
                  const Text('私有'),
                ]),
                TextField(
                  controller: titleCtrl,
                  decoration: InputDecoration(
                    labelText: '标题（必填）',
                    errorText: titleError,
                  ),
                  onChanged: (_) {
                    if (titleError != null) {
                      setState(() => titleError = null);
                    }
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.edit_note),
                  label: Text(richContent.isEmpty ? '撰写正文（富文本）' : '编辑正文'),
                  onPressed: () async {
                    final r = await Navigator.push<String>(
                      dialogCtx,
                      MaterialPageRoute(
                        builder: (_) => QuillEditorScreen(
                          initialJson: richContent,
                          title: titleCtrl.text.isEmpty ? '正文' : titleCtrl.text,
                        ),
                      ),
                    );
                    if (r != null) setState(() => richContent = r);
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final f =
                            await picker.pickImage(source: ImageSource.camera);
                        if (f != null) setState(() => mediaPaths.add(f.path));
                      },
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('拍照'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final f =
                            await picker.pickImage(source: ImageSource.gallery);
                        if (f != null) {
                          final gps = await ExifService.readGps(f.path);
                          setState(() {
                            mediaPaths.add(f.path);
                            if (gps != null && exifLat == null) {
                              exifLat = gps.lat;
                              exifLng = gps.lng;
                              exifTime = gps.time;
                            }
                          });
                        }
                      },
                      icon: const Icon(Icons.photo_library),
                      label: const Text('图库'),
                    ),
                  ],
                ),
                if (mediaPaths.isNotEmpty)
                  SizedBox(
                    height: 64,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: mediaPaths.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Stack(
                          children: [
                            JournalMediaThumb(path: mediaPaths[i], size: 60),
                            Positioned(
                              top: 0,
                              right: 0,
                              child: GestureDetector(
                                onTap: () =>
                                    setState(() => mediaPaths.removeAt(i)),
                                child: const CircleAvatar(
                                  radius: 9,
                                  backgroundColor: Colors.black54,
                                  child: Icon(Icons.close,
                                      size: 12, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          if (entry != null)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () async {
                final db = ref.read(dbProvider);
                // Best-effort remote cleanup BEFORE we drop the DB row,
                // since the upload queue keys delete-tokens by journal id.
                await ref
                    .read(uploadQueueProvider)
                    .deleteAllForJournal(entry.id);
                // Tombstoning delete — survives future sync merges.
                await db.deleteJournalById(entry.id);
                changed = true;
                if (dialogCtx.mounted) Navigator.pop(dialogCtx);
              },
              child: const Text('删除'),
            ),
          TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              // Was a silent no-op on empty title — now tell the user why.
              if (titleCtrl.text.trim().isEmpty) {
                setState(() => titleError = '标题不能为空');
                return;
              }
              final lat = resolvedLat();
              final lng = resolvedLng();
              if (entry == null && (lat == null || lng == null)) {
                // 不静默存 (0,0)（那会把手账钉到几内亚湾）。
                setState(() =>
                    posError = '还没有位置：等定位完成，或点「地图选点」手动指定');
                return;
              }
              final db = ref.read(dbProvider);
              int journalId;
              if (entry == null) {
                journalId =
                    await db.insertJournal(JournalEntriesCompanion.insert(
                  time: resolvedTime(),
                  lat: lat!,
                  lng: lng!,
                  title: titleCtrl.text,
                  richContent: Value(richContent),
                  mediaPaths: Value(mediaPaths.join('\n')),
                  layerId: activeLayer,
                  level: Value(level),
                  ownerPeerId: Value(ownerPeerId),
                ));
              } else {
                journalId = entry.id;
                await (db.update(db.journalEntries)
                      ..where((t) => t.id.equals(entry.id)))
                    .write(JournalEntriesCompanion(
                  title: Value(titleCtrl.text),
                  richContent: Value(richContent),
                  mediaPaths: Value(mediaPaths.join('\n')),
                  level: Value(level),
                  ownerPeerId: Value(ownerPeerId),
                  // 编辑时用户手选了新位置 → 一并写入（没选保持原坐标）。
                  lat: pickedPos != null
                      ? Value(pickedPos!.lat)
                      : const Value.absent(),
                  lng: pickedPos != null
                      ? Value(pickedPos!.lng)
                      : const Value.absent(),
                  // Stamp the edit so it beats older copies in sync merges.
                  updatedAt: Value(DateTime.now()),
                ));
                await db.customStatement(
                  'UPDATE journal_fts SET title=?, content=? WHERE rowid=?',
                  [titleCtrl.text, richContent, entry.id],
                );
              }
              // Local-first: the journal is already saved. Kick the queue
              // and let uploads finish in the background; the queue itself
              // rewrites richContent/mediaPaths with CDN URLs as each file
              // completes.
              await ref.read(uploadQueueProvider).enqueueForJournal(
                    journalId: journalId,
                    localPaths: mediaPaths,
                    richContent: richContent,
                  );
              changed = true;
              if (dialogCtx.mounted) Navigator.pop(dialogCtx);
            },
            child: const Text('保存'),
          ),
        ],
      );
    }),
  );
  alive = false;
  return changed;
}

class _MetaLine extends StatelessWidget {
  final IconData icon;
  final String text;
  const _MetaLine({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hintColor;
    return Row(
      children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12, color: c)),
        ),
      ],
    );
  }
}

/// Leading tile for a journal list row: the first photo with a "+N" badge when
/// there are more, or a branded placeholder when there are none.
class _JournalLeading extends StatelessWidget {
  final List<String> paths;
  const _JournalLeading({required this.paths});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const s = 76.0;
    if (paths.isEmpty) {
      return Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Center(
          child: PixelSprite(
            rows: PixelSprites.book,
            color: cs.onPrimaryContainer,
            cell: 4,
          ),
        ),
      );
    }
    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        children: [
          JournalMediaThumb(path: paths.first, size: s),
          if (paths.length > 1)
            Positioned(
              right: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.photo_library_rounded,
                      size: 11, color: Colors.white),
                  const SizedBox(width: 3),
                  Text('${paths.length}',
                      style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                          fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

class JournalMediaThumb extends ConsumerWidget {
  final String path;
  final double size;
  const JournalMediaThumb({super.key, required this.path, this.size = 80});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    Widget child;
    if (path.startsWith('gh-private://')) {
      child = PrivateAwareImage(
        url: path,
        settings: s,
        fit: BoxFit.cover,
        width: size,
        height: size,
        errorBuilder: (_) => const Icon(Icons.broken_image),
      );
    } else if (path.startsWith('http://') || path.startsWith('https://')) {
      child = Image.network(
        path,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
      );
    } else {
      // Local file path. NativeFileImage is conditionally compiled: real
      // Image.file on native, a broken-image placeholder on web (no dart:io at
      // runtime) — so a view-only web build doesn't throw on local-only photos.
      child = NativeFileImage(path: path);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: size,
        height: size,
        color: Colors.grey.shade300,
        child: child,
      ),
    );
  }
}

/// Full-screen, swipeable, pinch-to-zoom image viewer. Opened by tapping a
/// thumbnail in the journal detail popup. Handles all three media kinds the
/// app stores: local files, plain http(s) URLs, and gh-private:// (decrypted
/// on the fly by [PrivateAwareImage]).
class _FullscreenGallery extends ConsumerStatefulWidget {
  final List<String> paths;
  final int initialIndex;
  const _FullscreenGallery({required this.paths, required this.initialIndex});
  @override
  ConsumerState<_FullscreenGallery> createState() => _FullscreenGalleryState();
}

class _FullscreenGalleryState extends ConsumerState<_FullscreenGallery> {
  late final PageController _pc =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    const broken = Icon(Icons.broken_image, color: Colors.white54, size: 48);
    Widget fullImage(String path) {
      if (path.startsWith('gh-private://')) {
        return PrivateAwareImage(
            url: path,
            settings: s,
            fit: BoxFit.contain,
            errorBuilder: (_) => broken);
      }
      if (path.startsWith('http://') || path.startsWith('https://')) {
        return Image.network(path,
            fit: BoxFit.contain, errorBuilder: (_, __, ___) => broken);
      }
      // Local file — web-safe via the conditional NativeFileImage.
      return NativeFileImage(path: path, fit: BoxFit.contain);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pc,
            itemCount: widget.paths.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Center(child: fullImage(widget.paths[i])),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close_rounded,
                  color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          if (widget.paths.length > 1)
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 16,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('${_index + 1} / ${widget.paths.length}',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 13)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Compact upload-status row shown in the viewer.
///
/// Shows the queue's done/pending/failed counts AND — crucially for entries
/// created BEFORE the image host was turned on — how many of the entry's
/// images are still local files, with a manual "上传到图床" button. Once an
/// image uploads, the queue rewrites the entry to the remote URL, so anything
/// still non-http here is genuinely un-hosted. Polls every 2s (a cheap
/// SharedPreferences read).
class _UploadStatusBar extends ConsumerStatefulWidget {
  final JournalEntry entry;
  const _UploadStatusBar({required this.entry});
  @override
  ConsumerState<_UploadStatusBar> createState() => _UploadStatusBarState();
}

class _UploadStatusBarState extends ConsumerState<_UploadStatusBar> {
  List<dynamic> _records = const [];
  // Avoid importing dart:async here; use a periodic via post-frame chain.
  bool _disposed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _tick();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _tick() async {
    if (_disposed) return;
    final q = ref.read(uploadQueueProvider);
    final list = await q.recordsForJournal(widget.entry.id);
    if (!mounted) return;
    setState(() => _records = list);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted && !_disposed) _tick();
  }

  static bool _isRemote(String s) =>
      s.startsWith('http://') || s.startsWith('https://');

  /// Image refs in the entry that are still local files (not yet hosted) —
  /// from both mediaPaths and the Quill rich body.
  List<String> _localImages() {
    final e = widget.entry;
    final out = <String>{};
    for (final raw in e.mediaPaths.split('\n')) {
      final s = raw.trim();
      if (s.isEmpty || _isRemote(s)) continue;
      out.add(s);
    }
    if (e.richContent.isNotEmpty) {
      try {
        final delta = jsonDecode(e.richContent);
        if (delta is List) {
          for (final op in delta) {
            if (op is Map &&
                op['insert'] is Map &&
                (op['insert'] as Map)['image'] is String) {
              final s = (op['insert'] as Map)['image'] as String;
              if (!_isRemote(s)) out.add(s);
            }
          }
        }
      } catch (_) {/* non-Quill body — ignore */}
    }
    return out.toList();
  }

  Future<void> _uploadNow(int localCount) async {
    final messenger = ScaffoldMessenger.of(context);
    final enabled = ref.read(settingsProvider).imgHostKind != 'none';
    if (!enabled) {
      messenger.showSnackBar(const SnackBar(
        content: Text('图床未开启：请到「设置 → 图床」选择 GitHub 或自定义后再上传'),
      ));
      return;
    }
    setState(() => _busy = true);
    try {
      final q = ref.read(uploadQueueProvider);
      await q.enqueueForJournal(
        journalId: widget.entry.id,
        localPaths: widget.entry.mediaPaths
            .split('\n')
            .where((p) => p.isNotEmpty)
            .toList(),
        richContent: widget.entry.richContent,
      );
      // Also flip any lingering failed/pending records back to pending.
      if (_records.any((r) => r.status == 'failed' || r.status == 'pending')) {
        await q.retryAllForJournal(widget.entry.id);
      }
      messenger.showSnackBar(SnackBar(content: Text('已加入上传队列（$localCount 张）')));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _tick();
    }
  }

  @override
  Widget build(BuildContext context) {
    final localImages = _localImages();
    final pending = _records.where((r) => r.status == 'pending').length;
    final failed = _records.where((r) => r.status == 'failed').length;
    final done = _records.where((r) => r.status == 'done').length;
    final hasRecords = _records.isNotEmpty;

    // Nothing to show: no queue history and no local images to offer.
    if (!hasRecords && localImages.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final enabled = ref.watch(settingsProvider).imgHostKind != 'none';

    final parts = <String>[];
    if (hasRecords) parts.add('$done 已传 / $pending 待传 / $failed 失败');
    if (localImages.isNotEmpty) parts.add('${localImages.length} 张本地图未上传');
    final showUpload = localImages.isNotEmpty || failed > 0;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Icon(
              failed > 0
                  ? Icons.error_outline
                  : (localImages.isNotEmpty || pending > 0
                      ? Icons.cloud_upload_outlined
                      : Icons.cloud_done_outlined),
              size: 16,
              color: failed > 0
                  ? Colors.redAccent
                  : (localImages.isNotEmpty || pending > 0
                      ? cs.primary
                      : Colors.green),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '图床：${parts.join(' · ')}${enabled ? '' : '（未开启）'}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (showUpload)
              TextButton(
                onPressed: () => _uploadNow(localImages.length),
                child: Text(failed > 0 && localImages.isEmpty ? '重试' : '上传到图床'),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Image-host upload status (item 4) ──────────────────────────────────────

/// Aggregate of a journal's upload records → the pill shown in the list.
({IconData icon, Color color, String label})? _statusOf(
    List<UploadRecord> recs, BuildContext context) {
  if (recs.isEmpty) return null;
  final failed = recs.where((r) => r.status == 'failed').length;
  final pending = recs.where((r) => r.status == 'pending').length;
  final done = recs.where((r) => r.status == 'done').length;
  if (failed > 0) {
    return (
      icon: Icons.cloud_off_rounded,
      color: Colors.red,
      label: '$failed 失败'
    );
  }
  if (pending > 0) {
    return (
      icon: Icons.cloud_sync_rounded,
      color: Colors.orange,
      label: '$pending 待传'
    );
  }
  return (
    icon: Icons.cloud_done_rounded,
    color: Colors.green,
    label: done > 1 ? '已传 $done' : '已传'
  );
}

/// A live status pill for one journal's photo uploads. Rebuilds on every queue
/// write via the queue's [revision] notifier. Tapping opens the upload queue.
class _UploadStatusBadge extends ConsumerWidget {
  final int journalId;
  const _UploadStatusBadge({required this.journalId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(uploadQueueProvider);
    return ValueListenableBuilder<int>(
      valueListenable: queue.revision,
      builder: (context, _, __) {
        return FutureBuilder<List<UploadRecord>>(
          future: queue.recordsForJournal(journalId),
          builder: (context, snap) {
            final st = snap.hasData ? _statusOf(snap.data!, context) : null;
            if (st == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                onTap: () => _showUploadQueue(context, ref),
                borderRadius: BorderRadius.circular(4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(st.icon, size: 15, color: st.color),
                  const SizedBox(width: 3),
                  Text(st.label,
                      style: TextStyle(fontSize: 11, color: st.color)),
                ]),
              ),
            );
          },
        );
      },
    );
  }
}

/// Local (not-yet-hosted) image refs in an entry — from both mediaPaths and
/// the Quill rich body. Mirrors [_UploadStatusBarState._localImages] so list
/// and detail agree on what still needs uploading.
List<String> _entryLocalImages(JournalEntry e) {
  bool isRemote(String s) =>
      s.startsWith('http://') || s.startsWith('https://');
  final out = <String>{};
  for (final raw in e.mediaPaths.split('\n')) {
    final s = raw.trim();
    if (s.isEmpty || isRemote(s)) continue;
    out.add(s);
  }
  if (e.richContent.isNotEmpty) {
    try {
      final delta = jsonDecode(e.richContent);
      if (delta is List) {
        for (final op in delta) {
          if (op is Map &&
              op['insert'] is Map &&
              (op['insert'] as Map)['image'] is String) {
            final s = (op['insert'] as Map)['image'] as String;
            if (!isRemote(s)) out.add(s);
          }
        }
      }
    } catch (_) {/* non-Quill body — ignore */}
  }
  return out.toList();
}

/// Compact "上传到图床" action shown on a journal list row while it still has
/// local images — push a journal's photos straight from the list, no need to
/// open it first.
class _ListUploadChip extends ConsumerStatefulWidget {
  final JournalEntry entry;
  const _ListUploadChip({required this.entry});
  @override
  ConsumerState<_ListUploadChip> createState() => _ListUploadChipState();
}

class _ListUploadChipState extends ConsumerState<_ListUploadChip> {
  bool _busy = false;

  Future<void> _upload(int count) async {
    final messenger = ScaffoldMessenger.of(context);
    final queue = ref.read(uploadQueueProvider);
    setState(() => _busy = true);
    try {
      await queue.enqueueForJournal(
        journalId: widget.entry.id,
        localPaths: widget.entry.mediaPaths
            .split('\n')
            .where((p) => p.isNotEmpty)
            .toList(),
        richContent: widget.entry.richContent,
      );
      await queue.drainNow();
      messenger.showSnackBar(SnackBar(content: Text('已开始上传（$count 张）')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(settingsProvider).imgHostKind != 'none';
    if (!enabled) return const SizedBox.shrink();
    final local = _entryLocalImages(widget.entry);
    if (local.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: _busy ? null : () => _upload(local.length),
        borderRadius: BorderRadius.circular(4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (_busy)
            const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(Icons.cloud_upload_outlined, size: 15, color: cs.primary),
          const SizedBox(width: 3),
          Text('上传 ${local.length}',
              style: TextStyle(fontSize: 11, color: cs.primary)),
        ]),
      ),
    );
  }
}

/// The upload queue sheet: every image's upload state, a manual 上传 button
/// (for when auto-upload is off), and per-item retry. Reactive via the queue
/// revision notifier so states flip live as uploads complete.
Future<void> _showUploadQueue(BuildContext context, WidgetRef ref) async {
  final queue = ref.read(uploadQueueProvider);
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetCtx) => Consumer(
      builder: (ctx, ref2, _) {
        final s = ref2.watch(settingsProvider);
        return ValueListenableBuilder<int>(
          valueListenable: queue.revision,
          builder: (ctx, _, __) => FutureBuilder<List<UploadRecord>>(
            future: queue.allRecords(),
            builder: (ctx, snap) {
              final recs = snap.data ?? const <UploadRecord>[];
              final pending = recs.where((r) => r.status != 'done').length;
              return DraggableScrollableSheet(
                expand: false,
                initialChildSize: 0.6,
                maxChildSize: 0.9,
                builder: (ctx, scrollCtrl) => Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
                      child: Row(children: [
                        const Text('图片上传队列',
                            style: TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 16)),
                        const Spacer(),
                        if (s.imgHostKind == 'none')
                          const Text('未启用图床',
                              style: TextStyle(color: Colors.grey))
                        else if (pending > 0)
                          FilledButton.icon(
                            onPressed: () => queue.drainNow(),
                            icon: const Icon(Icons.upload_rounded, size: 18),
                            label: Text('上传 $pending 项'),
                          ),
                      ]),
                    ),
                    if (!s.autoUploadImages && s.imgHostKind != 'none')
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text('自动上传已关闭 · 上传需手动触发',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.orange)),
                        ),
                      ),
                    const Divider(height: 16),
                    Expanded(
                      child: recs.isEmpty
                          ? const Center(child: Text('暂无上传记录'))
                          : ListView.builder(
                              controller: scrollCtrl,
                              itemCount: recs.length,
                              itemBuilder: (_, i) {
                                final r = recs[i];
                                final st = _statusOf([r], ctx)!;
                                return ListTile(
                                  dense: true,
                                  leading: Icon(st.icon, color: st.color),
                                  title: Text(
                                    r.localPath.split('/').last,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  subtitle: Text(
                                    r.status == 'failed'
                                        ? (r.error ?? '上传失败')
                                        : (r.status == 'done'
                                            ? (r.remoteUrl ?? '已上传')
                                            : '等待上传'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: r.status == 'failed'
                                      ? IconButton(
                                          tooltip: '重试',
                                          icon: const Icon(Icons.refresh),
                                          onPressed: () =>
                                              queue.retry(r.localPath),
                                        )
                                      : null,
                                );
                              },
                            ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    ),
  );
}

// ─── Full-screen journal detail (view ⇄ in-place edit) ──────────────────────
//
// Replaces the old showJournalViewer→showJournalEditor dialog stack for
// EXISTING entries: tapping a journal opens a near-fullscreen read-only page
// (with an embedded location map), and a single "编辑" toggle flips the SAME
// page into edit mode — title, level, owner, media and rich body all edited in
// place, no nested dialog. New-entry creation still uses [showJournalEditor].

/// Opens [JournalDetailScreen] for [entry]. Returns true if the entry changed
/// (edited or deleted) — though callers can also just refresh unconditionally,
/// since saves/deletes bump [journalRefreshProvider].
Future<bool> openJournalDetail(
  BuildContext context,
  WidgetRef ref,
  JournalEntry entry, {
  bool startInEdit = false,
}) async {
  final changed = await Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute(
      builder: (_) =>
          JournalDetailScreen(entry: entry, startInEdit: startInEdit),
    ),
  );
  return changed ?? false;
}

class JournalDetailScreen extends ConsumerStatefulWidget {
  final JournalEntry entry;
  final bool startInEdit;
  const JournalDetailScreen({
    super.key,
    required this.entry,
    this.startInEdit = false,
  });
  @override
  ConsumerState<JournalDetailScreen> createState() =>
      _JournalDetailScreenState();
}

class _JournalDetailScreenState extends ConsumerState<JournalDetailScreen> {
  late JournalEntry _entry = widget.entry;
  late bool _editing = widget.startInEdit;
  bool _changed = false;

  // Edit buffers.
  final _titleCtrl = TextEditingController();
  q.QuillController? _bodyCtrl; // live rich-text surface while editing
  List<String> _media = [];
  String _rich = '';
  String _level = 'public';
  String? _owner;
  String? _titleError;

  final _picker = ImagePicker();
  List<({String id, String name})> _peers = const [];

  @override
  void initState() {
    super.initState();
    _seedBuffers();
    if (_editing) _loadPeers();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl?.dispose();
    super.dispose();
  }

  void _seedBuffers() {
    _titleCtrl.text = _entry.title;
    _media = _entry.mediaPaths.split('\n').where((p) => p.isNotEmpty).toList();
    _rich = _entry.richContent;
    _level = _entry.level;
    _owner = _entry.ownerPeerId;
    _titleError = null;
    _bodyCtrl?.dispose();
    _bodyCtrl = _makeBodyController(_rich);
  }

  q.QuillController _makeBodyController(String json) {
    if (json.isNotEmpty) {
      try {
        return q.QuillController(
          document: q.Document.fromJson(jsonDecode(json) as List),
          selection: const TextSelection.collapsed(offset: 0),
        );
      } catch (_) {/* not a Quill doc — fall through to a blank one */}
    }
    return q.QuillController.basic();
  }

  Future<void> _loadPeers() async {
    final db = ref.read(dbProvider);
    final rows = await db
        .customSelect(
          'SELECT DISTINCT peer_id, author FROM chat_messages ORDER BY peer_id',
        )
        .get();
    if (!mounted) return;
    setState(() => _peers = [
          for (final r in rows)
            (id: r.read<String>('peer_id'), name: r.read<String>('author')),
        ]);
  }

  void _enterEdit() {
    _seedBuffers();
    setState(() => _editing = true);
    _loadPeers();
  }

  List<String> get _mediaPaths =>
      _entry.mediaPaths.split('\n').where((p) => p.isNotEmpty).toList();

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty) {
      setState(() => _titleError = '标题不能为空');
      return;
    }
    // Serialize the live rich-text surface (text + inline image embeds).
    if (_bodyCtrl != null) {
      _rich = jsonEncode(_bodyCtrl!.document.toDelta().toJson());
    }
    final db = ref.read(dbProvider);
    final id = _entry.id;
    await (db.update(db.journalEntries)..where((t) => t.id.equals(id)))
        .write(JournalEntriesCompanion(
      title: Value(_titleCtrl.text),
      richContent: Value(_rich),
      mediaPaths: Value(_media.join('\n')),
      level: Value(_level),
      ownerPeerId: Value(_owner),
      updatedAt: Value(DateTime.now()),
    ));
    await db.customStatement(
      'UPDATE journal_fts SET title=?, content=? WHERE rowid=?',
      [_titleCtrl.text, _rich, id],
    );
    await ref.read(uploadQueueProvider).enqueueForJournal(
          journalId: id,
          localPaths: _media,
          richContent: _rich,
        );
    final updated = await (db.select(db.journalEntries)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    _changed = true;
    ref.read(journalRefreshProvider.notifier).state++;
    if (!mounted) return;
    setState(() {
      if (updated != null) _entry = updated;
      _editing = false;
    });
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('删除手账'),
        content: Text('确定删除「${_entry.title}」？此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final db = ref.read(dbProvider);
    await ref.read(uploadQueueProvider).deleteAllForJournal(_entry.id);
    await db.deleteJournalById(_entry.id);
    ref.read(journalRefreshProvider.notifier).state++;
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _addImage(ImageSource source) async {
    final f = await _picker.pickImage(source: source);
    if (f == null || !mounted) return;
    setState(() => _media.add(f.path));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        // Carry the changed flag back even on system-back / swipe.
        if (didPop && result == null && _changed) {
          // Result already gone; refresh is also covered by the provider bump.
        }
      },
      child: _editing ? _buildEdit(context) : _buildView(context),
    );
  }

  // ── View ──────────────────────────────────────────────────────────────
  Widget _buildView(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final paths = _mediaPaths;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            leading:
                BackButton(onPressed: () => Navigator.pop(context, _changed)),
            title: Text(
              _entry.title.isEmpty ? '(无标题)' : _entry.title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            actions: [
              IconButton(
                tooltip: '编辑',
                icon: const Icon(Icons.edit_outlined),
                onPressed: _enterEdit,
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'delete') _delete();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline, color: Colors.red),
                      title: Text('删除', style: TextStyle(color: Colors.red)),
                    ),
                  ),
                ],
              ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            sliver: SliverList.list(children: [
              // Meta.
              Wrap(spacing: 16, runSpacing: 6, children: [
                _meta(Icons.access_time_rounded,
                    DateFormat('yyyy-MM-dd HH:mm').format(_entry.time)),
                if ((_entry.ownerPeerId ?? '').isNotEmpty)
                  _meta(Icons.person_outline, _peerName(_entry.ownerPeerId!)),
                _meta(
                    _entry.level == 'private'
                        ? Icons.lock_outline
                        : Icons.public,
                    _entry.level == 'private' ? '私有' : '公开'),
              ]),
              const SizedBox(height: 14),
              // Location map strip.
              _LocationMapStrip(lat: _entry.lat, lng: _entry.lng),
              const SizedBox(height: 18),
              // Rich body.
              if (_entry.richContent.isNotEmpty)
                QuillReader(json: _entry.richContent)
              else
                Text('（无正文）', style: TextStyle(color: cs.onSurfaceVariant)),
              // Media.
              if (paths.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text('照片 · ${paths.length}',
                    style:
                        tt.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 96,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: paths.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) => GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          fullscreenDialog: true,
                          builder: (_) =>
                              _FullscreenGallery(paths: paths, initialIndex: i),
                        ),
                      ),
                      child: JournalMediaThumb(path: paths[i], size: 96),
                    ),
                  ),
                ),
              ],
              _UploadStatusBar(entry: _entry),
            ]),
          ),
        ],
      ),
    );
  }

  // ── Edit (in place) ─────────────────────────────────────────────────────
  Widget _buildEdit(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: '取消',
          onPressed: () => setState(() => _editing = false),
        ),
        title:
            const Text('编辑手账', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _save,
              child: const Text('保存'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          // Location + time (read-only context).
          _LocationMapStrip(lat: _entry.lat, lng: _entry.lng),
          const SizedBox(height: 8),
          _meta(Icons.access_time_rounded,
              DateFormat('yyyy-MM-dd HH:mm').format(_entry.time)),
          const SizedBox(height: 16),
          TextField(
            controller: _titleCtrl,
            decoration: InputDecoration(
              labelText: '标题（必填）',
              errorText: _titleError,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_titleError != null) setState(() => _titleError = null);
            },
          ),
          const SizedBox(height: 16),
          // Level segmented.
          Row(children: [
            Icon(Icons.lock_outline, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'public',
                      label: Text('公开'),
                      icon: Icon(Icons.public, size: 16)),
                  ButtonSegment(
                      value: 'private',
                      label: Text('私有'),
                      icon: Icon(Icons.lock_outline, size: 16)),
                ],
                selected: {_level},
                onSelectionChanged: (s) => setState(() => _level = s.first),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          // Owner.
          Row(children: [
            Icon(Icons.person_outline, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String?>(
                value: _owner,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '归属人',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('自己')),
                  ..._peers.map((p) => DropdownMenuItem<String?>(
                        value: p.id,
                        child: Text(
                            '${p.name}（${p.id.substring(0, p.id.length < 6 ? p.id.length : 6)}…）'),
                      )),
                ],
                onChanged: (v) => setState(() => _owner = v),
              ),
            ),
          ]),
          const SizedBox(height: 18),
          // Rich body — edited inline. Text and images interleave right here;
          // no secondary editor screen, no "编辑正文" hop.
          Row(children: [
            Icon(Icons.notes_rounded, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Text('正文', style: Theme.of(context).textTheme.labelLarge),
            const Spacer(),
            Text('文字与图片可穿插',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ]),
          const SizedBox(height: 8),
          if (_bodyCtrl != null) QuillBodyField(controller: _bodyCtrl!),
          const SizedBox(height: 18),
          // Cover / album photos (optional) — feed the list thumbnail and the
          // view-mode gallery; inline body images upload the same way.
          Text('封面照片 · 相册（可选）',
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            OutlinedButton.icon(
              onPressed: () => _addImage(ImageSource.camera),
              icon: const Icon(Icons.camera_alt_outlined, size: 18),
              label: const Text('拍照'),
            ),
            OutlinedButton.icon(
              onPressed: () => _addImage(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined, size: 18),
              label: const Text('图库'),
            ),
          ]),
          if (_media.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 76,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _media.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, i) => Stack(
                  children: [
                    JournalMediaThumb(path: _media[i], size: 72),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: GestureDetector(
                        onTap: () => setState(() => _media.removeAt(i)),
                        child: const CircleAvatar(
                          radius: 10,
                          backgroundColor: Colors.black54,
                          child:
                              Icon(Icons.close, size: 13, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 28),
          Center(
            child: TextButton.icon(
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('删除这条手账'),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  String _peerName(String id) {
    for (final p in _peers) {
      if (p.id == id) return p.name;
    }
    return id.length <= 6 ? id : '${id.substring(0, 6)}…';
  }

  Widget _meta(IconData icon, String text) {
    final c = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 15, color: c),
      const SizedBox(width: 5),
      Text(text, style: TextStyle(fontSize: 13, color: c)),
    ]);
  }
}

/// A compact, lightly-interactive map showing one journal's location. Uses the
/// app's configured tile provider + the same GCJ-02 conversion as the main map
/// so the pin lands where it should.
class _LocationMapStrip extends ConsumerWidget {
  final double lat, lng; // WGS84
  const _LocationMapStrip({required this.lat, required this.lng});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final LatLng disp;
    if (CoordConverter.needsGcj02(s.mapProvider)) {
      final g = CoordConverter.wgs84ToGcj02(lat, lng);
      disp = LatLng(g.lat, g.lng);
    } else {
      disp = LatLng(lat, lng);
    }
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 168,
        child: Stack(
          children: [
            FlutterMap(
              options: MapOptions(
                initialCenter: disp,
                initialZoom: 14,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
                ),
              ),
              children: [
                buildTileLayer(
                  provider: s.mapProvider,
                  style: s.mapStyle,
                  amapKey: s.amapApiKey,
                  googleKey: s.googleMapKey,
                  customOsmUrl: s.customOsmTileUrl,
                ),
                MarkerLayer(markers: [
                  Marker(
                    point: disp,
                    width: 44,
                    height: 50,
                    alignment: Alignment.bottomCenter,
                    child: const _LocationPin(),
                  ),
                ]),
              ],
            ),
            // Coordinate chip.
            Positioned(
              left: 10,
              bottom: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: cs.surface.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: cs.onSurface),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationPin extends StatelessWidget {
  const _LocationPin();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: cs.primary,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 6,
                  offset: const Offset(0, 2)),
            ],
          ),
          child: Icon(Icons.place_rounded, color: cs.onPrimary, size: 20),
        ),
      ],
    );
  }
}
