import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:drift/drift.dart' show Value;

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../services/geo/coord_converter.dart';
import '../../services/map/tile_providers.dart';
import '../../services/playback/merged_trip_model.dart';
import '../../services/playback/quick_video_encoder_sink.dart';
import '../../services/playback/replay_model.dart';
import '../../services/playback/replay_video_exporter.dart';
import '../common/pixel.dart';

/// 回放总结：以"一次有效记录（开始→停止，≥10 个点，单图层）"为单位的列表，
/// 顶部年/月筛选。点击进入单次回放；勾选多条后可**合并回放**——各条轨迹
/// 各画各的线、共用一条去掉空档的时间轴（见 replay_model.dart），并可把
/// 回放导出为 mp4 视频保存到本地。
///
/// 世界迷雾（FOW）导入的图层只有位图、没有带时间的轨迹点，因此不会出现在
/// 这里（列表顶部会提示）。
class PlaybackScreen extends ConsumerStatefulWidget {
  const PlaybackScreen({super.key});
  @override
  ConsumerState<PlaybackScreen> createState() => _PlaybackScreenState();
}

/// Per-layer look used by the list and the player.
class _LayerStyle {
  final String name;
  final Color color;
  const _LayerStyle(this.name, this.color);
}

_LayerStyle _styleOf(Map<int, TrackLayer> layers, int layerId) {
  final l = layers[layerId];
  if (l == null) return _LayerStyle('图层 $layerId', const Color(0xFF26A69A));
  return _LayerStyle(l.name, Color(l.pathColor ?? l.colorValue));
}

class _PlaybackScreenState extends ConsumerState<PlaybackScreen> {
  List<ReplaySession> _all = const [];
  Map<int, TrackLayer> _layers = const {};
  List<MergedTrip> _trips = const [];
  int _layersWithoutTrack = 0;
  bool _loading = true;
  int? _filterYear;
  int? _filterMonth; // null = whole year
  final Set<ReplaySession> _selected = {};

  Map<int, String> get _layerUuidById =>
      {for (final l in _layers.values) l.id: l.uuid};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final db = ref.read(dbProvider);
    final points = await db.select(db.trackPoints).get();
    final layers = await db.select(db.trackLayers).get();
    final trips = await db.allMergedTrips();
    final sessions = splitIntoSessions(points);
    final withTrack = sessions.map((s) => s.layerId).toSet();
    if (!mounted) return;
    setState(() {
      _all = sessions;
      _layers = {for (final l in layers) l.id: l};
      _trips = trips;
      _layersWithoutTrack =
          layers.where((l) => !withTrack.contains(l.id)).length;
      _selected.removeWhere((s) => !sessions.contains(s));
      _loading = false;
    });
  }

  List<ReplaySession> _sessionsOfTrip(MergedTrip t) => resolveTripSessions(
      decodeTripSegments(t.segmentsJson), _all, _layerUuidById)
    ..sort((a, b) => a.start.compareTo(b.start));

  /// 把选中的段存成一个可命名的「合并记录」。只存引用（图层 uuid + 时间窗），
  /// 原始轨迹点一个都不动 —— 图层、迷雾、同步全都不受影响。
  Future<void> _saveSelectionAsTrip() async {
    final picked = _all.where(_selected.contains).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final segs = segmentsForSessions(picked, _layerUuidById);
    if (segs.isEmpty) return;
    final defaultName =
        '${DateFormat('M月d日').format(picked.first.start)}的旅程';
    final ctrl = TextEditingController(text: defaultName);
    final name = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('合并为一条记录（${picked.length} 段）'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '记录名称'),
          onSubmitted: (s) => Navigator.pop(dctx, s),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, ctrl.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await ref.read(dbProvider).insertMergedTrip(MergedTripsCompanion.insert(
          name: name.trim(),
          segmentsJson: encodeTripSegments(segs),
          createdAt: DateTime.now(),
          updatedAt: Value(DateTime.now()),
        ));
    if (!mounted) return;
    setState(_selected.clear);
    await _reload();
  }

  Future<void> _renameTrip(MergedTrip t) async {
    final ctrl = TextEditingController(text: t.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('重命名合并记录'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          onSubmitted: (s) => Navigator.pop(dctx, s),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, ctrl.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || name.trim() == t.name) return;
    await ref.read(dbProvider).renameMergedTrip(t.id, name.trim());
    await _reload();
  }

  Future<void> _dissolveTrip(MergedTrip t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text('解散「${t.name}」？'),
        content: const Text('只删除这条合并记录本身，原始轨迹段不受影响。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('解散')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(dbProvider).deleteMergedTrip(t.id);
    await _reload();
  }

  List<ReplaySession> get _filtered {
    return _all.where((s) {
      if (_filterYear != null && s.start.year != _filterYear) return false;
      if (_filterMonth != null && s.start.month != _filterMonth) return false;
      return true;
    }).toList();
  }

  void _openPlayer(List<ReplaySession> sessions) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _PlayerScreen(sessions: sessions, layers: _layers),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final years = <int>{
      for (final s in _all) s.start.year,
    }.toList()
      ..sort((a, b) => b.compareTo(a));
    final list = _filtered;
    final selecting = _selected.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(
            selecting ? '已选 ${_selected.length} 段' : '回放 / 总结',
            style: PixelText.headline
                .copyWith(color: Theme.of(context).colorScheme.onSurface)),
        leading: selecting
            ? IconButton(
                tooltip: '取消选择',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => setState(_selected.clear),
              )
            : null,
        actions: [
          if (selecting)
            TextButton(
              onPressed: () => setState(() => _selected.addAll(list)),
              child: const Text('全选'),
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _reload,
          ),
        ],
      ),
      bottomNavigationBar: selecting
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.bookmark_add_outlined),
                        label: const Text('存为合并记录'),
                        onPressed: _saveSelectionAsTrip,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.merge_rounded),
                        label: Text('合并回放 ${_selected.length} 段'),
                        onPressed: () {
                          final picked =
                              _all.where(_selected.contains).toList();
                          _openPlayer(picked);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // ── Filters ─────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      DropdownButton<int?>(
                        value: _filterYear,
                        hint: const Text('全部年份'),
                        items: [
                          const DropdownMenuItem<int?>(
                              value: null, child: Text('全部年份')),
                          for (final y in years)
                            DropdownMenuItem<int?>(
                                value: y, child: Text('$y 年')),
                        ],
                        onChanged: (v) => setState(() {
                          _filterYear = v;
                          if (v == null) _filterMonth = null;
                        }),
                      ),
                      if (_filterYear != null)
                        DropdownButton<int?>(
                          value: _filterMonth,
                          hint: const Text('全年'),
                          items: [
                            const DropdownMenuItem<int?>(
                                value: null, child: Text('全年')),
                            for (int m = 1; m <= 12; m++)
                              DropdownMenuItem<int?>(
                                  value: m, child: Text('$m 月')),
                          ],
                          onChanged: (v) => setState(() => _filterMonth = v),
                        ),
                    ],
                  ),
                ),
                // ── Aggregate header for the filtered set ─────────────
                _PeriodSummary(sessions: list),
                // ── 合并记录：用户存下来的多段捆绑，一条即可整体回放 ──
                if (_trips.isNotEmpty && !selecting)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 216),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final t in _trips)
                          Builder(builder: (_) {
                            final sess = _sessionsOfTrip(t);
                            final km = sess.fold<double>(
                                0, (a, s) => a + s.distanceKm);
                            final range = sess.isEmpty
                                ? '所引用的记录段已不存在'
                                : '${DateFormat('yyyy-MM-dd').format(sess.first.start)}'
                                    '${sess.length > 1 ? ' → ${DateFormat('MM-dd').format(sess.last.start)}' : ''}'
                                    ' · ${sess.length} 段 · ${km.toStringAsFixed(1)} km';
                            return ListTile(
                              dense: true,
                              leading: Icon(Icons.bookmark_rounded,
                                  color: cs.primary),
                              title: Text(t.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text(range,
                                  style: const TextStyle(fontSize: 11)),
                              onTap: sess.isEmpty
                                  ? null
                                  : () => _openPlayer(sess),
                              trailing: PopupMenuButton<String>(
                                onSelected: (v) => switch (v) {
                                  'rename' => _renameTrip(t),
                                  'dissolve' => _dissolveTrip(t),
                                  _ => null,
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                      value: 'rename', child: Text('重命名')),
                                  PopupMenuItem(
                                      value: 'dissolve',
                                      child: Text('解散（不动原始记录）')),
                                ],
                              ),
                            );
                          }),
                      ],
                    ),
                  ),
                if (_layersWithoutTrack > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                    child: Text(
                      '$_layersWithoutTrack 个图层只有迷雾数据（如世界迷雾导入），'
                      '没有带时间的轨迹点，无法回放',
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                    ),
                  ),
                if (list.isNotEmpty && !selecting)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text('合并回放本筛选下的 ${list.length} 段记录'),
                        onPressed: () => _openPlayer(list),
                      ),
                    ),
                  ),
                const Divider(height: 1),
                Expanded(
                  child: list.isEmpty
                      ? Center(
                          child: Text(
                            _all.isEmpty
                                ? '还没有记录 — 在地图上按下中央按钮开始'
                                : '所选时间段没有记录',
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                        )
                      : ListView.separated(
                          itemCount: list.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final s = list[i];
                            return _SessionTile(
                              session: s,
                              style: _styleOf(_layers, s.layerId),
                              selected: _selected.contains(s),
                              selecting: selecting,
                              onToggle: () => setState(() {
                                if (!_selected.remove(s)) _selected.add(s);
                              }),
                              onOpen: () => _openPlayer([s]),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

/// Single-line session row. Tap opens the player (or toggles selection while
/// selecting); long-press / the checkbox toggles selection.
class _SessionTile extends StatelessWidget {
  final ReplaySession session;
  final _LayerStyle style;
  final bool selected;
  final bool selecting;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  const _SessionTile({
    required this.session,
    required this.style,
    required this.selected,
    required this.selecting,
    required this.onToggle,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      selected: selected,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: style.color.withValues(alpha: 0.18),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.route_rounded, color: style.color),
      ),
      title: Text(DateFormat('yyyy-MM-dd HH:mm').format(session.start)),
      subtitle: Text(
        '${style.name} · '
        '${session.distanceKm.toStringAsFixed(2)} km · '
        '${session.duration.inMinutes} 分 · '
        '${session.pointCount} 点',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
      trailing: Checkbox(value: selected, onChanged: (_) => onToggle()),
      onTap: selecting ? onToggle : onOpen,
      onLongPress: onToggle,
    );
  }
}

/// Sticky header that aggregates "this filter slice" — total distance,
/// total duration, session count, point count.
class _PeriodSummary extends StatelessWidget {
  final List<ReplaySession> sessions;
  const _PeriodSummary({required this.sessions});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final totalKm = sessions.fold<double>(0, (a, s) => a + s.distanceKm);
    final totalMin = sessions.fold<int>(0, (a, s) => a + s.duration.inMinutes);
    final totalPts = sessions.fold<int>(0, (a, s) => a + s.pointCount);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          _stat('${sessions.length}', '次记录'),
          const SizedBox(width: 8),
          _stat(totalKm.toStringAsFixed(1), 'km'),
          const SizedBox(width: 8),
          _stat((totalMin / 60).toStringAsFixed(1), '小时'),
          const SizedBox(width: 8),
          _stat('$totalPts', '采样点'),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) => Expanded(
        child: Column(
          children: [
            Text(value, style: PixelText.label.copyWith(fontSize: 16)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      );
}

// ─── Player (one or many sessions on a shared timeline) ─────────────────

class _PlayerScreen extends ConsumerStatefulWidget {
  final List<ReplaySession> sessions;
  final Map<int, TrackLayer> layers;
  const _PlayerScreen({required this.sessions, required this.layers});
  @override
  ConsumerState<_PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<_PlayerScreen>
    with SingleTickerProviderStateMixin {
  late final MergedTimeline _tl = MergedTimeline(widget.sessions);
  final MapController _mapCtrl = MapController();
  final GlobalKey _captureKey = GlobalKey();

  /// Position on the virtual (gap-free) timeline. 放在 ValueNotifier 里而不是
  /// 普通字段：播放时它每帧都变，只让真正跟着动的几块（轨迹 / 头部图层、进度条
  /// 与时间标签）经 ValueListenableBuilder 重建，整页 Scaffold 不再 setState。
  final ValueNotifier<Duration> _cursor = ValueNotifier(Duration.zero);

  /// 轨迹层专用的低频光标：只在 [_cursor] 跨过 125 ms 档时才跟进（≈8 Hz）。
  /// 头部圆点与进度条仍吃 30 Hz 的 [_cursor]，肉眼看到的是它们在动；线本身
  /// 每次一变，PolylineLayer 就要把全部点重新投影 + 抽稀，合并回放里两千多点
  /// 30 次/秒重投影是回放期间 UI isolate 上最重的一笔——线每秒长 8 次和 30 次
  /// 看不出区别，CPU 却差近 4 倍。
  final ValueNotifier<Duration> _trailCursor = ValueNotifier(Duration.zero);
  static const _trailStepMs = 125;
  bool _playing = false;

  /// 推进虚拟时钟的 Ticker。用 createTicker 而不是 Future.delayed 循环：跟 vsync
  /// 对齐，且路由被盖住 / 不可见时 TickerMode 会自动静音，不会在后台空转。
  /// 在 initState 里建（不懒建），免得从没播过就 dispose 时才首次创建它。
  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  /// 最多每 30 ms 发布一次光标（≈ 原来 Future.delayed 循环的 30 次/秒）。跟满
  /// vsync 没有意义：polylines 一换，PolylineLayer 就把全部点重新投影 + 抽稀
  /// （flutter_map 的缓存在 didUpdateWidget 里整个作废），长途合并回放上这是
  /// 回放期间最重的一笔，别把它翻倍到 60/120 Hz。
  static const _minPublishInterval = Duration(milliseconds: 30);

  /// 单次最多按这么多墙钟时间推进。更长的间隔不是卡顿就是被盖住 / 切后台又回来
  /// （静音期间 Ticker 的 elapsed 照样累计），别让轨迹一下蹿出去。
  static const _maxFrameGap = Duration(milliseconds: 100);

  /// Real-time multiplier: virtual seconds advanced per wall-clock second.
  double _speed = 128;
  static const _speeds = [16.0, 32.0, 64.0, 128.0, 256.0, 512.0];

  /// Camera follows the moving head until the user pans.
  bool _follow = true;
  bool _showJournals = true;
  bool _showPeers = true;
  List<JournalEntry> _journalsInWindow = const [];
  Map<String, List<PeerLocation>> _peerTrails = const {};

  // ── video export ──
  bool _exporting = false;
  bool _exportCancel = false;
  double _exportProgress = 0;

  bool get _multiDay =>
      _tl.realStart.year != _tl.realEnd.year ||
      _tl.realStart.month != _tl.realEnd.month ||
      _tl.realStart.day != _tl.realEnd.day;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _cursor.addListener(_syncTrailCursor);
    _loadJournals();
    _loadPeerTrails();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _cursor.removeListener(_syncTrailCursor);
    _cursor.dispose();
    _trailCursor.dispose();
    _mapCtrl.dispose();
    super.dispose();
  }

  /// Journals / peers "belong" to the replay when they fall inside one of
  /// the timeline's active stretches (±30 min) — not in the days between
  /// two merged trips.
  bool _inWindow(DateTime t) {
    const pad = Duration(minutes: 30);
    for (final seg in _tl.segments) {
      if (!t.isBefore(seg.start.subtract(pad)) &&
          !t.isAfter(seg.end.add(pad))) {
        return true;
      }
    }
    return false;
  }

  Future<void> _loadJournals() async {
    final db = ref.read(dbProvider);
    final all = await db.select(db.journalEntries).get();
    if (!mounted) return;
    setState(() {
      _journalsInWindow = all.where((j) => _inWindow(j.time)).toList();
    });
  }

  Future<void> _loadPeerTrails() async {
    final db = ref.read(dbProvider);
    if (_tl.segments.isEmpty) return;
    // 只读时间窗内的行（表里是每个队友每秒一条、无限累积），窄口径的空档再在
    // 内存里按段过滤。
    const pad = Duration(minutes: 30);
    final from = _tl.segments
        .map((s) => s.start)
        .reduce((a, b) => a.isBefore(b) ? a : b)
        .subtract(pad);
    final to = _tl.segments
        .map((s) => s.end)
        .reduce((a, b) => a.isAfter(b) ? a : b)
        .add(pad);
    final all = await db.peerLocationsBetween(from, to);
    final rows = all.where((r) => _inWindow(r.time)).toList();
    final grouped = <String, List<PeerLocation>>{};
    for (final r in rows) {
      (grouped[r.peerId] ??= []).add(r);
    }
    if (!mounted) return;
    setState(() => _peerTrails = grouped);
  }

  /// Stable color per peer id — hash-based so the same peer is the same
  /// color across screen rebuilds.
  Color _peerColor(String peerId) {
    final h = peerId.hashCode;
    final hue = (h.abs() % 360).toDouble();
    return HSLColor.fromAHSL(1, hue, 0.6, 0.55).toColor();
  }

  /// Stored WGS-84 → the base map's datum (GCJ-02 shift for amap/google/
  /// ovital). The old player skipped this and drew trails 100–700 m off on
  /// Chinese base maps.
  LatLng _toDisplay(LatLng wgs) {
    if (!CoordConverter.needsGcj02(ref.read(settingsProvider).mapProvider)) {
      return wgs;
    }
    final g = CoordConverter.wgs84ToGcj02(wgs.latitude, wgs.longitude);
    return LatLng(g.lat, g.lng);
  }

  LatLngBounds get _allBounds =>
      LatLngBounds.fromPoints(_tl.allPoints().map(_toDisplay).toList());

  /// The head the camera follows: the active session whose trail is
  /// currently moving; with several active, the first selected one.
  LatLng? _leadHead(DateTime real) {
    for (final s in widget.sessions) {
      if (s.isActiveAt(real)) {
        final pos = s.positionAt(real);
        if (pos != null) return _toDisplay(pos);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final title = widget.sessions.length > 1
        ? '${widget.sessions.length} 段合并回放'
        : DateFormat('yyyy-MM-dd HH:mm').format(_tl.realStart);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        // The player draws no fog veil, so the bare map underneath is bright
        // — white-on-white left the back arrow and these actions (including
        // 导出视频) practically invisible on a daytime base map. A top scrim
        // keeps them legible without hiding the map.
        flexibleSpace: const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xB3000000), Color(0x00000000)],
              ),
            ),
            child: SizedBox.expand(),
          ),
        ),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        actions: [
          IconButton(
            tooltip: _follow ? '停止跟随' : '跟随轨迹',
            icon: Icon(_follow
                ? Icons.center_focus_strong_rounded
                : Icons.center_focus_weak_rounded),
            onPressed: () => setState(() => _follow = !_follow),
          ),
          IconButton(
            tooltip: _showPeers ? '隐藏队友轨迹' : '显示队友轨迹',
            icon: Icon(
              _showPeers ? Icons.group : Icons.group_outlined,
              color: _peerTrails.isEmpty ? Colors.white38 : null,
            ),
            onPressed: _peerTrails.isEmpty
                ? null
                : () => setState(() => _showPeers = !_showPeers),
          ),
          IconButton(
            tooltip: _showJournals ? '隐藏手账气泡' : '显示手账气泡',
            icon: Icon(_showJournals
                ? Icons.bubble_chart
                : Icons.bubble_chart_outlined),
            onPressed: () => setState(() => _showJournals = !_showJournals),
          ),
          IconButton(
            tooltip: '导出视频',
            icon: const Icon(Icons.movie_creation_outlined),
            onPressed: _exporting ? null : _exportVideo,
          ),
        ],
      ),
      body: Stack(
        children: [
          // Only the map is inside the capture boundary — the transport bar,
          // summary and export overlay never end up in the video.
          RepaintBoundary(
            key: _captureKey,
            child: FlutterMap(
              mapController: _mapCtrl,
              options: MapOptions(
                initialCameraFit: CameraFit.bounds(
                  bounds: _allBounds,
                  padding: const EdgeInsets.all(48),
                  maxZoom: 16,
                ),
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
                onPositionChanged: (_, hasGesture) {
                  if (hasGesture && _follow && !_exporting) {
                    setState(() => _follow = false);
                  }
                },
              ),
              children: [
                buildTileLayer(
                  provider: s.mapProvider,
                  style: s.mapStyle,
                  amapKey: s.amapApiKey,
                  googleKey: s.googleMapKey,
                  customOsmUrl: s.customOsmTileUrl,
                  ovitalUrl: s.ovitalTileUrl,
                ),
                // 随播放头移动的图层单独听 _cursor 重建；底图和手账气泡不动。
                // 分两个 builder 夹着手账层，是为了保住原来的叠放顺序（头部圆点
                // 压在气泡之上）。
                ValueListenableBuilder<Duration>(
                  valueListenable: _trailCursor,
                  builder: (_, cursor, __) => _trailLayers(_tl.realAt(cursor)),
                ),
                if (_showJournals && _journalsInWindow.isNotEmpty)
                  MarkerLayer(
                    markers: [
                      for (final j in _journalsInWindow)
                        Marker(
                          point: _toDisplay(LatLng(j.lat, j.lng)),
                          width: 36,
                          height: 36,
                          child: Tooltip(
                            message: j.title,
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFFFF8A65),
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: Colors.white, width: 2),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.3),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                              child: const Icon(Icons.menu_book_rounded,
                                  color: Colors.white, size: 18),
                            ),
                          ),
                        ),
                    ],
                  ),
                ValueListenableBuilder<Duration>(
                  valueListenable: _cursor,
                  builder: (_, cursor, __) => _headLayer(_tl.realAt(cursor)),
                ),
              ],
            ),
          ),
          if (!_exporting) _transportBar(),
          Positioned(
            left: 16,
            right: 16,
            top: MediaQuery.of(context).padding.top + 56,
            child: _PlayerSummary(
                sessions: widget.sessions, layers: widget.layers),
          ),
          if (_exporting) _exportOverlay(),
        ],
      ),
    );
  }

  /// 画到 [real] 为止的轨迹：本人各段的线、队友的线，以及队友「现在在哪」的点。
  /// 这几层每帧都要重建，所以从 build() 里拆出来只听 _cursor。
  Widget _trailLayers(DateTime real) {
    // 不裁剪：只是把两层打包成一个 child 放进 FlutterMap 的 Stack，裁剪交给
    // 地图本身，和原先直接平铺在 children 里时一样。
    return Stack(clipBehavior: Clip.none, children: [
      PolylineLayer(polylines: [
        for (final sess in widget.sessions)
          Polyline(
            points: sess.pathUntil(real).map(_toDisplay).toList(),
            color: _styleOf(widget.layers, sess.layerId).color,
            strokeWidth: 4,
          ),
        // Peer trails — clipped to the current playback time so
        // they sweep alongside the user's own trail rather than
        // appearing all at once.
        if (_showPeers)
          for (final entry in _peerTrails.entries)
            Polyline(
              points: entry.value
                  .where((p) => !p.time.isAfter(real))
                  .map((p) => _toDisplay(LatLng(p.lat, p.lng)))
                  .toList(),
              color: _peerColor(entry.key).withValues(alpha: 0.85),
              strokeWidth: 3,
            ),
      ]),
      // Peer "where they are now" markers — one per peer, at the
      // last location ≤ current playback time.
      if (_showPeers && _peerTrails.isNotEmpty)
        MarkerLayer(markers: [
          for (final entry in _peerTrails.entries) ...[
            () {
              final upTo =
                  entry.value.where((p) => !p.time.isAfter(real)).toList();
              if (upTo.isEmpty) return null;
              final last = upTo.last;
              final label = last.peerName.isNotEmpty
                  ? last.peerName
                  : entry.key.substring(0, math.min(4, entry.key.length));
              return Marker(
                point: _toDisplay(LatLng(last.lat, last.lng)),
                width: 32,
                height: 32,
                child: Tooltip(
                  message: label,
                  child: Container(
                    decoration: BoxDecoration(
                      color: _peerColor(entry.key),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      label.characters.first,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              );
            }(),
          ].whereType<Marker>(),
        ]),
    ]);
  }

  /// One head dot per trail that has started, in its layer colour; trails
  /// still to come have no dot yet.
  Widget _headLayer(DateTime real) {
    return MarkerLayer(markers: [
      for (final sess in widget.sessions)
        if (sess.positionAt(real) case final pos?)
          Marker(
            point: _toDisplay(pos),
            width: 24,
            height: 24,
            child: Container(
              decoration: BoxDecoration(
                color: _styleOf(widget.layers, sess.layerId).color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
          ),
    ]);
  }

  Widget _transportBar() {
    final totalMs = math.max(1, _tl.total.inMilliseconds);
    return Positioned(
      left: 16,
      right: 16,
      bottom: 24,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1A2733).withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _togglePlay,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(
                    color: Color(0xFF26A69A),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                      _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 22),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 进度条 + 时间标签是这一栏里唯二随播放头动的东西，只有它们听 _cursor。
            Expanded(
              child: ValueListenableBuilder<Duration>(
                valueListenable: _cursor,
                builder: (_, cursor, __) => Row(children: [
                  Expanded(
                    child: SliderTheme(
                      data: SliderThemeData(
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 6),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 14),
                        activeTrackColor: const Color(0xFF26A69A),
                        inactiveTrackColor: Colors.white24,
                        thumbColor: Colors.white,
                        trackHeight: 3,
                      ),
                      child: Slider(
                        value:
                            cursor.inMilliseconds.clamp(0, totalMs).toDouble(),
                        min: 0,
                        max: totalMs.toDouble(),
                        onChanged: (v) =>
                            _cursor.value = Duration(milliseconds: v.round()),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                      DateFormat(_multiDay ? 'MM-dd HH:mm' : 'HH:mm:ss')
                          .format(_tl.realAt(cursor)),
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 11)),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<double>(
              initialValue: _speed,
              tooltip: '播放速度（真实时间倍率）',
              onSelected: (v) => setState(() => _speed = v),
              color: const Color(0xFF223040),
              itemBuilder: (_) => [
                for (final v in _speeds)
                  PopupMenuItem(
                      value: v,
                      child: Text('${v.toInt()}×',
                          style: const TextStyle(color: Colors.white))),
              ],
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text('${_speed.toInt()}×',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _exportOverlay() => Positioned.fill(
        child: Container(
          color: Colors.black54,
          alignment: Alignment.center,
          child: Container(
            width: 260,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1A2733),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('正在导出视频…',
                    style: TextStyle(color: Colors.white, fontSize: 14)),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: _exportProgress),
                const SizedBox(height: 6),
                Text('${(_exportProgress * 100).toStringAsFixed(0)}%',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 11)),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () => setState(() => _exportCancel = true),
                  child: const Text('取消'),
                ),
              ],
            ),
          ),
        ),
      );

  void _togglePlay() {
    if (_tl.total <= Duration.zero) return;
    if (!_playing && _cursor.value >= _tl.total) _cursor.value = Duration.zero;
    _setPlaying(!_playing);
  }

  /// 轨迹光标按 125 ms 档跟进 [_cursor]；停播、拖动、到末尾这些"落点"必须立刻
  /// 对齐，否则线会停在上一档、差最多 125 ms 的虚拟时长。
  void _syncTrailCursor({bool force = false}) {
    final c = _cursor.value;
    if (force ||
        !_playing ||
        c.inMilliseconds ~/ _trailStepMs !=
            _trailCursor.value.inMilliseconds ~/ _trailStepMs) {
      _trailCursor.value = c;
    }
  }

  /// 播放态与 Ticker 同进同退：_playing 为真 ⇔ Ticker 在跑。setState 只为了换
  /// 播放 / 暂停按钮的图标。
  void _setPlaying(bool v) {
    if (v == _playing) return;
    if (v) {
      // Ticker 的 elapsed 从 start() 起算，差分基准跟着归零。
      _lastElapsed = Duration.zero;
      _ticker.start();
    } else {
      _ticker.stop();
    }
    setState(() => _playing = v);
    if (!v) _syncTrailCursor(force: true);
  }

  /// 每个 vsync 被叫一次：虚拟时钟按墙钟 × 倍率推进，写进 _cursor 让动的图层自己
  /// 重建。不足 _minPublishInterval 的帧先跳过，墙钟差分留到下一帧一起算。
  void _onTick(Duration elapsed) {
    if (_exporting) return; // 导出时帧由 _captureFrame 逐帧摆，不许抢
    var dt = elapsed - _lastElapsed;
    if (dt < _minPublishInterval) return;
    _lastElapsed = elapsed;
    if (dt > _maxFrameGap) dt = _maxFrameGap;
    var next = _cursor.value + dt * _speed;
    final done = next >= _tl.total;
    if (done) next = _tl.total;
    _cursor.value = next;
    if (done) _setPlaying(false);
    if (_follow) {
      final head = _leadHead(_tl.realAt(next));
      if (head != null) _mapCtrl.move(head, _mapCtrl.camera.zoom);
    }
  }

  // ── video export ──────────────────────────────────────────────────────

  Future<void> _exportVideo() async {
    if (!QuickVideoEncoderSink.supported) {
      _toast('当前平台不支持视频导出（Android / iOS / macOS 可用）');
      return;
    }
    if (_tl.total <= Duration.zero) {
      _toast('这段记录没有可回放的时长');
      return;
    }
    final plan = await showDialog<ExportPlan>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('导出为视频'),
        children: [
          for (final secs in const [15, 30, 60])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(
                  ctx, ExportPlan(fps: 30, videoDuration: Duration(seconds: secs))),
              child: Text('$secs 秒 · 30 fps'),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 4),
            child: Text('整段回放会被压进所选时长；导出期间请保持在本页。',
                style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
    if (plan == null || !mounted) return;

    _setPlaying(false); // 停掉 Ticker，导出期间帧全由 _captureFrame 摆
    setState(() {
      _exporting = true;
      _exportCancel = false;
      _exportProgress = 0;
      _follow = false;
    });
    // A fixed frame showing the whole route reads far better in a clip than
    // a camera chasing the head; give the base tiles a moment to land.
    _mapCtrl.fitCamera(CameraFit.bounds(
        bounds: _allBounds, padding: const EdgeInsets.all(40), maxZoom: 16));
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;

    final boundary = _captureKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) {
      setState(() => _exporting = false);
      return;
    }
    // Longest side ≈ 1080 px regardless of the device's density.
    final longest = math.max(boundary.size.width, boundary.size.height);
    final pixelRatio = (1080 / longest).clamp(1.0, 3.0);

    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final outPath = p.join(dir.path, 'exports', 'replay_$stamp.mp4');
    final savedCursor = _cursor.value;

    ExportResult? result;
    Object? error;
    try {
      result = await ReplayVideoExporter().run(
        timelineTotal: _tl.total,
        plan: plan,
        capture: (t) => _captureFrame(t, pixelRatio),
        sink: QuickVideoEncoderSink(),
        outputPath: outPath,
        onProgress: (v) {
          if (mounted) setState(() => _exportProgress = v);
        },
        isCancelled: () => _exportCancel || !mounted,
      );
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    _cursor.value = savedCursor;
    setState(() => _exporting = false);
    if (error != null) {
      _toast('导出失败：$error');
      return;
    }
    if (result == null || result.cancelled) {
      try {
        await File(outPath).delete();
      } catch (_) {}
      _toast('已取消导出');
      return;
    }
    await _offerExportedFile(File(outPath), result);
  }

  /// Show frame [t], wait for it to be painted, read the pixels back.
  Future<RawFrame?> _captureFrame(Duration t, double pixelRatio) async {
    if (!mounted) return null;
    // 只动 _cursor：听它的图层会自己标脏并排一帧；endOfFrame 在空闲时也会
    // 主动排一帧，所以 t 没变时同样能等到一次绘制。
    _cursor.value = t;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return null;
    final boundary = _captureKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return null;
    // If layout dirtied the boundary again (rare), let one more frame paint.
    if (boundary.debugNeedsPaint) await WidgetsBinding.instance.endOfFrame;
    final img = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) return null;
      return RawFrame(img.width, img.height,
          bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes));
    } finally {
      img.dispose();
    }
  }

  Future<void> _offerExportedFile(File file, ExportResult res) async {
    final bytes = await file.length();
    final mb = (bytes / (1024 * 1024)).toStringAsFixed(1);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.movie_rounded),
              title: Text('视频已生成 · $mb MB'),
              subtitle: Text(
                  '${res.width}×${res.height} · ${res.framesWritten} 帧\n${file.path}',
                  style: const TextStyle(fontSize: 11)),
              isThreeLine: true,
            ),
            ListTile(
              leading: const Icon(Icons.save_alt_rounded),
              title: const Text('保存到本地'),
              subtitle: const Text('选择保存位置（Android 默认 Download）'),
              onTap: () async {
                Navigator.pop(ctx);
                await _saveLocally(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_rounded),
              title: const Text('分享'),
              onTap: () async {
                Navigator.pop(ctx);
                await Share.shareXFiles([XFile(file.path)],
                    subject: 'Explore Journal 路径回放');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Same SAF pattern as the FOW export: saveFile writes the bytes itself on
  /// mobile; desktop pickers only return a path.
  Future<void> _saveLocally(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '保存回放视频',
        fileName: p.basename(file.path),
        type: FileType.custom,
        allowedExtensions: ['mp4'],
        bytes: bytes,
      );
      if (path == null) return;
      if (!kIsWeb &&
          (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
        await File(path).writeAsBytes(bytes);
      }
      _toast('已保存：$path');
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _PlayerSummary extends StatelessWidget {
  final List<ReplaySession> sessions;
  final Map<int, TrackLayer> layers;
  const _PlayerSummary({required this.sessions, required this.layers});
  @override
  Widget build(BuildContext context) {
    final km = sessions.fold<double>(0, (a, s) => a + s.distanceKm);
    final minutes = sessions.fold<int>(0, (a, s) => a + s.duration.inMinutes);
    final pts = sessions.fold<int>(0, (a, s) => a + s.pointCount);
    final layerIds = sessions.map((s) => s.layerId).toSet();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2733).withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${km.toStringAsFixed(2)} km · $minutes 分钟 · $pts 点'
            '${sessions.length > 1 ? ' · ${sessions.length} 段' : ''}',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          if (layerIds.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final id in layerIds)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: _styleOf(layers, id).color,
                              shape: BoxShape.circle)),
                      const SizedBox(width: 4),
                      Text(_styleOf(layers, id).name,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11)),
                    ]),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
