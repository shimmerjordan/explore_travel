import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../services/map/tile_providers.dart';

/// 回放总结：以"一次有效记录（开始→停止，≥10 个点）"为单位的列表，
/// 顶部年/月筛选。点击进入单次回放。在回放里可叠加：
///   * 时间窗内的旅行手账（气泡，可隐藏）
///   * 组队成员同期轨迹（暂未实现持久化，需先在 group_service 里把
///     接收到的 location 落库才能回放历史）
class PlaybackScreen extends ConsumerStatefulWidget {
  const PlaybackScreen({super.key});
  @override
  ConsumerState<PlaybackScreen> createState() => _PlaybackScreenState();
}

/// One "session" — a contiguous run of GPS samples separated from
/// neighbours by [_kSessionGapMinutes] of silence. Built lazily from the
/// full TrackPoints table on screen-load.
class _Session {
  final List<TrackPoint> points;
  _Session(this.points);
  DateTime get start => points.first.time;
  DateTime get end => points.last.time;
  int get pointCount => points.length;
  double get distanceKm {
    double m = 0;
    for (int i = 1; i < points.length; i++) {
      m += _haversineMeters(points[i - 1].lat, points[i - 1].lng,
          points[i].lat, points[i].lng);
    }
    return m / 1000;
  }

  Duration get duration => end.difference(start);
}

const int _kSessionGapMinutes = 10;
const int _kMinPointsPerSession = 10;

class _PlaybackScreenState extends ConsumerState<PlaybackScreen> {
  List<_Session> _all = const [];
  bool _loading = true;
  int? _filterYear;
  int? _filterMonth; // null = whole year

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final db = ref.read(dbProvider);
    final all = await db.select(db.trackPoints).get();
    all.sort((a, b) => a.time.compareTo(b.time));
    final sessions = _splitIntoSessions(all);
    sessions.sort((a, b) => b.start.compareTo(a.start)); // newest first
    if (!mounted) return;
    setState(() {
      _all = sessions;
      _loading = false;
    });
  }

  static List<_Session> _splitIntoSessions(List<TrackPoint> all) {
    if (all.isEmpty) return const [];
    final out = <_Session>[];
    var bucket = <TrackPoint>[all.first];
    for (int i = 1; i < all.length; i++) {
      final gap = all[i].time.difference(all[i - 1].time).inMinutes;
      if (gap >= _kSessionGapMinutes) {
        if (bucket.length >= _kMinPointsPerSession) {
          out.add(_Session(List.of(bucket)));
        }
        bucket = <TrackPoint>[all[i]];
      } else {
        bucket.add(all[i]);
      }
    }
    if (bucket.length >= _kMinPointsPerSession) {
      out.add(_Session(List.of(bucket)));
    }
    return out;
  }

  List<_Session> get _filtered {
    return _all.where((s) {
      if (_filterYear != null && s.start.year != _filterYear) return false;
      if (_filterMonth != null && s.start.month != _filterMonth) return false;
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final years = <int>{
      for (final s in _all) s.start.year,
    }.toList()
      ..sort((a, b) => b.compareTo(a));
    final list = _filtered;

    return Scaffold(
      appBar: AppBar(
        title: const Text('回放 / 总结',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _reload,
          ),
        ],
      ),
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
                if (list.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text('一次性回放本筛选下的 ${list.length} 次记录'),
                        onPressed: () {
                          // Stitch all filtered sessions head-to-tail
                          // into one virtual session for combined playback.
                          // The player itself doesn't care that the points
                          // span multiple physical recordings — they're
                          // just a long ordered list of TrackPoints.
                          final pts = <TrackPoint>[
                            for (final s in list.reversed) ...s.points,
                          ]..sort((a, b) => a.time.compareTo(b.time));
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => _PlayerScreen(
                                session: _Session(pts),
                                stitchedCount: list.length,
                              ),
                            ),
                          );
                        },
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
                          itemBuilder: (_, i) =>
                              _SessionTile(session: list[i]),
                        ),
                ),
              ],
            ),
    );
  }
}

/// Single-line session row, tap to open the player.
class _SessionTile extends ConsumerWidget {
  final _Session session;
  const _SessionTile({required this.session});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.route_rounded, color: cs.primary),
      ),
      title: Text(DateFormat('yyyy-MM-dd HH:mm').format(session.start)),
      subtitle: Text(
        '${session.distanceKm.toStringAsFixed(2)} km · '
        '${session.duration.inMinutes} 分 · '
        '${session.pointCount} 点',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _PlayerScreen(session: session),
        ),
      ),
    );
  }
}

/// Sticky header that aggregates "this filter slice" — total distance,
/// total duration, session count, point count.
class _PeriodSummary extends StatelessWidget {
  final List<_Session> sessions;
  const _PeriodSummary({required this.sessions});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final totalKm =
        sessions.fold<double>(0, (a, s) => a + s.distanceKm);
    final totalMin =
        sessions.fold<int>(0, (a, s) => a + s.duration.inMinutes);
    final totalPts =
        sessions.fold<int>(0, (a, s) => a + s.pointCount);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          _stat('${sessions.length}', '次记录'),
          const SizedBox(width: 8),
          _stat('${totalKm.toStringAsFixed(1)}', 'km'),
          const SizedBox(width: 8),
          _stat('${(totalMin / 60).toStringAsFixed(1)}', '小时'),
          const SizedBox(width: 8),
          _stat('$totalPts', '采样点'),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) => Expanded(
        child: Column(
          children: [
            Text(value,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700)),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      );
}

// ─── Single-session player ──────────────────────────────────────────────

class _PlayerScreen extends ConsumerStatefulWidget {
  final _Session session;
  /// >1 when this is a stitched virtual session (multiple recordings
  /// concatenated). Surfaced in the AppBar title so the user knows.
  final int stitchedCount;
  const _PlayerScreen({required this.session, this.stitchedCount = 1});
  @override
  ConsumerState<_PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<_PlayerScreen> {
  int _idx = 0;
  bool _playing = false;
  bool _showJournals = true;
  /// Playback speed multiplier. 1× = 25 ms per step (≈ 40 pts/sec, fast
  /// enough for hour-long sessions). Stored so the user can crank it up
  /// for very long stitched playbacks.
  double _speed = 4.0;
  bool _showPeers = true;
  List<JournalEntry> _journalsInWindow = const [];
  /// peerId → ordered (time, lat, lng) points within the session window.
  Map<String, List<PeerLocation>> _peerTrails = const {};

  @override
  void initState() {
    super.initState();
    _loadJournals();
    _loadPeerTrails();
  }

  Future<void> _loadJournals() async {
    final db = ref.read(dbProvider);
    final all = await db.select(db.journalEntries).get();
    final s = widget.session;
    // Pad ±30 min so journals written right before/after still show.
    final from = s.start.subtract(const Duration(minutes: 30));
    final to = s.end.add(const Duration(minutes: 30));
    if (!mounted) return;
    setState(() {
      _journalsInWindow = all
          .where((j) => !j.time.isBefore(from) && !j.time.isAfter(to))
          .toList();
    });
  }

  Future<void> _loadPeerTrails() async {
    final db = ref.read(dbProvider);
    final s = widget.session;
    final from = s.start.subtract(const Duration(minutes: 30));
    final to = s.end.add(const Duration(minutes: 30));
    // Use raw where-expression syntax because drift's generated table
    // doesn't expose isBetweenValues — that lives on Drift's column DSL.
    final all = await db.select(db.peerLocations).get();
    final rows = all
        .where((r) => !r.time.isBefore(from) && !r.time.isAfter(to))
        .toList()
      ..sort((a, b) => a.time.compareTo(b.time));
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

  @override
  Widget build(BuildContext context) {
    final pts = widget.session.points;
    final s = ref.watch(settingsProvider);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(
          widget.stitchedCount > 1
              ? '${widget.stitchedCount} 次记录拼接回放'
              : DateFormat('yyyy-MM-dd HH:mm').format(pts.first.time),
          style: const TextStyle(
              fontWeight: FontWeight.w700, fontSize: 16),
        ),
        actions: [
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
            onPressed: () =>
                setState(() => _showJournals = !_showJournals),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            options: MapOptions(
              initialCenter: LatLng(pts[_idx].lat, pts[_idx].lng),
              initialZoom: 14,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
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
              PolylineLayer(polylines: [
                Polyline(
                  points: pts
                      .take(_idx + 1)
                      .map((p) => LatLng(p.lat, p.lng))
                      .toList(),
                  color: const Color(0xFF26A69A),
                  strokeWidth: 4,
                ),
                // Peer trails — clipped to the current playback time so
                // they sweep alongside the user's own trail rather than
                // appearing all at once.
                if (_showPeers)
                  for (final entry in _peerTrails.entries)
                    Polyline(
                      points: entry.value
                          .where((p) => !p.time.isAfter(pts[_idx].time))
                          .map((p) => LatLng(p.lat, p.lng))
                          .toList(),
                      color: _peerColor(entry.key)
                          .withValues(alpha: 0.85),
                      strokeWidth: 3,
                    ),
              ]),
              // Peer "where they are now" markers — one per peer, at the
              // last location ≤ current playback time.
              if (_showPeers && _peerTrails.isNotEmpty)
                MarkerLayer(markers: [
                  for (final entry in _peerTrails.entries) ...[
                    () {
                      final upTo = entry.value
                          .where((p) => !p.time.isAfter(pts[_idx].time))
                          .toList();
                      if (upTo.isEmpty) return null;
                      final last = upTo.last;
                      final label = last.peerName.isNotEmpty
                          ? last.peerName
                          : entry.key.substring(
                              0, entry.key.length < 4 ? entry.key.length : 4);
                      return Marker(
                        point: LatLng(last.lat, last.lng),
                        width: 32,
                        height: 32,
                        child: Tooltip(
                          message: label,
                          child: Container(
                            decoration: BoxDecoration(
                              color: _peerColor(entry.key),
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: Colors.white, width: 2),
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
              if (_showJournals && _journalsInWindow.isNotEmpty)
                MarkerLayer(
                  markers: [
                    for (final j in _journalsInWindow)
                      Marker(
                        point: LatLng(j.lat, j.lng),
                        width: 36,
                        height: 36,
                        child: Tooltip(
                          message: j.title,
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF8A65),
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: Colors.white, width: 2),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black
                                      .withValues(alpha: 0.3),
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
              MarkerLayer(markers: [
                Marker(
                  point: LatLng(pts[_idx].lat, pts[_idx].lng),
                  width: 24,
                  height: 24,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF26A69A),
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
              ]),
            ],
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1A2733).withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(16),
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
                            _playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 22),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SliderTheme(
                      data: SliderThemeData(
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6),
                        overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 14),
                        activeTrackColor: const Color(0xFF26A69A),
                        inactiveTrackColor: Colors.white24,
                        thumbColor: Colors.white,
                        trackHeight: 3,
                      ),
                      child: Slider(
                        value: _idx.toDouble(),
                        min: 0,
                        max: (pts.length - 1).toDouble(),
                        onChanged: (v) =>
                            setState(() => _idx = v.toInt()),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                      DateFormat('HH:mm:ss')
                          .format(pts[_idx].time),
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 11)),
                  const SizedBox(width: 8),
                  // Speed picker — 1× / 2× / 4× / 8× / 16×.
                  PopupMenuButton<double>(
                    initialValue: _speed,
                    tooltip: '播放速度',
                    onSelected: (v) => setState(() => _speed = v),
                    color: const Color(0xFF223040),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 1.0, child: Text('1×',
                          style: TextStyle(color: Colors.white))),
                      PopupMenuItem(value: 2.0, child: Text('2×',
                          style: TextStyle(color: Colors.white))),
                      PopupMenuItem(value: 4.0, child: Text('4×',
                          style: TextStyle(color: Colors.white))),
                      PopupMenuItem(value: 8.0, child: Text('8×',
                          style: TextStyle(color: Colors.white))),
                      PopupMenuItem(value: 16.0, child: Text('16×',
                          style: TextStyle(color: Colors.white))),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('${_speed.toStringAsFixed(0)}×',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            top: MediaQuery.of(context).padding.top + 56,
            child: _PlayerSummary(session: widget.session),
          ),
        ],
      ),
    );
  }

  void _togglePlay() {
    setState(() => _playing = !_playing);
    if (_playing) _tick();
  }

  Future<void> _tick() async {
    while (_playing && mounted && _idx < widget.session.points.length - 1) {
      // 25 ms base / _speed → 1× is 40 fps, 8× = 320 pts/sec, fine for
      // stitched multi-hour playback.
      final ms = (25 / _speed).round().clamp(2, 200);
      await Future.delayed(Duration(milliseconds: ms));
      if (!mounted) return;
      setState(() => _idx++);
    }
    if (mounted) setState(() => _playing = false);
  }
}

class _PlayerSummary extends StatelessWidget {
  final _Session session;
  const _PlayerSummary({required this.session});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2733).withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '${session.distanceKm.toStringAsFixed(2)} km · '
        '${session.duration.inMinutes} 分钟 · '
        '${session.pointCount} 点',
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }
}

double _haversineMeters(double a, double b, double c, double d) {
  const r = 6371000.0;
  final dLat = (c - a) * math.pi / 180;
  final dLng = (d - b) * math.pi / 180;
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(a * math.pi / 180) *
          math.cos(c * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * r * math.atan2(math.sqrt(h), math.sqrt(1 - h));
}
