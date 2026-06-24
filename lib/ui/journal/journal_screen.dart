import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../services/imghost/private_image_loader.dart';
import '../../services/media/exif_service.dart';
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
      await (db.delete(db.journalEntries)..where((t) => t.id.equals(id))).go();
      await db
          .customStatement('DELETE FROM journal_fts WHERE rowid=?', [id]);
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
        title: Text(_selectMode ? '已选 ${_selected.length} 条' : '旅行手账',
            style: const TextStyle(fontWeight: FontWeight.w700)),
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
                  borderRadius: BorderRadius.circular(28),
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
              return Card(
                margin:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                color: isSelected
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () async {
                    if (_selectMode) {
                      _toggleSelect(e.id);
                      return;
                    }
                    final changed =
                        await showJournalViewer(context, ref, e);
                    if (changed && mounted) _bumpRefresh();
                  },
                  onLongPress: () {
                    setState(() => _selectMode = true);
                    _toggleSelect(e.id);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (_selectMode)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Icon(
                                  isSelected
                                      ? Icons.check_circle_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  color: isSelected
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.4),
                                ),
                              ),
                            Expanded(
                              child: Text(e.title,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                          fontWeight: FontWeight.w600)),
                            ),
                            Text(
                                DateFormat('MM/dd HH:mm').format(e.time),
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.5))),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(preview,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.7),
                                height: 1.4)),
                        if (paths.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 72,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: paths.length,
                              itemBuilder: (_, i) => Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: JournalMediaThumb(
                                    path: paths[i], size: 72),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.location_on_outlined,
                                size: 14,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.4)),
                            const SizedBox(width: 4),
                            Text(
                                '${e.lat.toStringAsFixed(4)}, ${e.lng.toStringAsFixed(4)}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.4))),
                          ],
                        ),
                      ],
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

/// Read-only viewer. Shows title, time, lat/lng, rich-text body and media.
/// A trailing "编辑" button switches into [showJournalEditor].
Future<bool> showJournalViewer(
    BuildContext context, WidgetRef ref, JournalEntry entry) async {
  bool changed = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final paths = entry.mediaPaths
          .split('\n')
          .where((p) => p.isNotEmpty)
          .toList();
      return AlertDialog(
        title: Text(entry.title.isEmpty ? '(无标题)' : entry.title),
        content: SizedBox(
          width: MediaQuery.of(ctx).size.width * 0.9,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _MetaLine(
                  icon: Icons.access_time,
                  text: DateFormat('yyyy-MM-dd HH:mm').format(entry.time),
                ),
                const SizedBox(height: 4),
                _MetaLine(
                  icon: Icons.location_on_outlined,
                  text:
                      '${entry.lat.toStringAsFixed(5)}, ${entry.lng.toStringAsFixed(5)}',
                ),
                const Divider(height: 20),
                if (entry.richContent.isNotEmpty)
                  QuillReader(json: entry.richContent)
                else
                  Text('(无正文)',
                      style: TextStyle(color: Theme.of(ctx).hintColor)),
                if (paths.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 80,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: paths.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: GestureDetector(
                          onTap: () => Navigator.of(ctx).push(
                            MaterialPageRoute<void>(
                              fullscreenDialog: true,
                              builder: (_) => _FullscreenGallery(
                                  paths: paths, initialIndex: i),
                            ),
                          ),
                          child: JournalMediaThumb(path: paths[i], size: 80),
                        ),
                      ),
                    ),
                  ),
                ],
                _UploadStatusBar(entry: entry),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭')),
          FilledButton.icon(
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('编辑'),
            onPressed: () async {
              Navigator.pop(ctx);
              final edited =
                  await showJournalEditor(context, ref, entry: entry);
              if (edited) changed = true;
            },
          ),
        ],
      );
    },
  );
  return changed;
}

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
  // For a new entry we anchor on the map's *displayed* pin (simulator-aware)
  // instead of forcing a fresh GPS read. Falls back to a one-shot GPS read
  // only if no pin has been displayed yet (e.g. user opened the journal
  // page before the map screen was ever drawn).
  double? exifLat;
  double? exifLng;
  DateTime? exifTime;
  ({double lat, double lng})? pinPos;
  if (entry == null) {
    pinPos = ref.read(currentDisplayPositionProvider);
    if (pinPos == null) {
      final pos = await ref.read(locationServiceProvider).currentOnce();
      if (pos != null) pinPos = (lat: pos.latitude, lng: pos.longitude);
    }
  }
  DateTime resolvedTime() => entry?.time ?? exifTime ?? DateTime.now();
  double resolvedLat() =>
      entry?.lat ?? exifLat ?? pinPos?.lat ?? 0;
  double resolvedLng() =>
      entry?.lng ?? exifLng ?? pinPos?.lng ?? 0;
  // Peers ever seen — pulled from chat_messages so we include offline ones
  // too. "self" is always first.
  final db0 = ref.read(dbProvider);
  final peerRows = await db0.customSelect(
    'SELECT DISTINCT peer_id, author FROM chat_messages ORDER BY peer_id',
  ).get();
  final knownPeers = <({String id, String name})>[
    for (final r in peerRows)
      (
        id: r.read<String>('peer_id'),
        name: r.read<String>('author'),
      ),
  ];

  if (!context.mounted) return false;
  bool changed = false;
  await showDialog<void>(
    context: context,
    builder: (_) => StatefulBuilder(builder: (dialogCtx, setState) {
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
                _MetaLine(
                  icon: Icons.location_on_outlined,
                  text:
                      '${resolvedLat().toStringAsFixed(5)}, ${resolvedLng().toStringAsFixed(5)}',
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
                            child: Text('${p.name}（${p.id.substring(0, p.id.length < 6 ? p.id.length : 6)}…）'))),
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
                  decoration: const InputDecoration(labelText: '标题'),
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
                          title:
                              titleCtrl.text.isEmpty ? '正文' : titleCtrl.text,
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
                        final f = await picker.pickImage(
                            source: ImageSource.camera);
                        if (f != null) setState(() => mediaPaths.add(f.path));
                      },
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('拍照'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final f = await picker.pickImage(
                            source: ImageSource.gallery);
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
                await (db.delete(db.journalEntries)
                      ..where((t) => t.id.equals(entry.id)))
                    .go();
                await db.customStatement(
                    'DELETE FROM journal_fts WHERE rowid=?', [entry.id]);
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
              if (titleCtrl.text.isEmpty) return;
              final db = ref.read(dbProvider);
              int journalId;
              if (entry == null) {
                journalId =
                    await db.insertJournal(JournalEntriesCompanion.insert(
                  time: resolvedTime(),
                  lat: resolvedLat(),
                  lng: resolvedLng(),
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
          child: Text(text,
              style: TextStyle(fontSize: 12, color: c)),
        ),
      ],
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
      child = Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
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
  ConsumerState<_FullscreenGallery> createState() =>
      _FullscreenGalleryState();
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
    const broken =
        Icon(Icons.broken_image, color: Colors.white54, size: 48);
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
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => broken);
      }
      return Image.file(File(path),
          fit: BoxFit.contain, errorBuilder: (_, __, ___) => broken);
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
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('${_index + 1} / ${widget.paths.length}',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13)),
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
      messenger.showSnackBar(
          SnackBar(content: Text('已加入上传队列（$localCount 张）')));
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
          borderRadius: BorderRadius.circular(8),
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
                child: Text(
                    failed > 0 && localImages.isEmpty ? '重试' : '上传到图床'),
              ),
          ],
        ),
      ),
    );
  }
}
