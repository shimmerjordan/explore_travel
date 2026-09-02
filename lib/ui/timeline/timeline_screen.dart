import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../services/location/point_filter.dart';
import '../../services/stats/footprint_stats.dart';
import '../common/pixel.dart';

/// 足迹时间轴 — one day as a list of stays and the legs between them, the
/// way 人生点点 / Arc / Dawarich's Timeline read a day. Stays come from the
/// detector (see VisitEngine); the user confirms, renames, merges or removes
/// them here. Journal entries of the day sit inline at their time.
class TimelineScreen extends ConsumerStatefulWidget {
  const TimelineScreen({super.key});
  @override
  ConsumerState<TimelineScreen> createState() => _TimelineScreenState();
}

class _DayData {
  final List<Visit> visits;
  final Map<int, Place> places;
  final List<TrackPoint> points;
  final List<JournalEntry> journals;
  const _DayData(this.visits, this.places, this.points, this.journals);
}

class _TimelineScreenState extends ConsumerState<TimelineScreen> {
  late DateTime _day = _midnight(DateTime.now());
  Future<_DayData>? _future;
  Set<String> _dataDays = {};
  int _seenRefresh = -1;

  static DateTime _midnight(DateTime d) => DateTime(d.year, d.month, d.day);
  static String _key(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  @override
  void initState() {
    super.initState();
    _reload();
    _jumpToLatestIfEmptyToday();
  }

  /// First open: if today has nothing yet, land on the last day that does.
  Future<void> _jumpToLatestIfEmptyToday() async {
    final db = ref.read(dbProvider);
    final today = _midnight(DateTime.now());
    final days = await db.daysWithPoints(
        today.subtract(const Duration(days: 365)),
        today.add(const Duration(days: 1)));
    if (!mounted || days.isEmpty || days.contains(_key(today))) return;
    final latest = days.reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
    setState(() {
      _day = DateTime.parse(latest);
      _reload();
    });
  }

  void _reload() {
    final db = ref.read(dbProvider);
    final from = _day, to = _day.add(const Duration(days: 1));
    _future = () async {
      final visits = await db.visitsBetween(from, to);
      final places = {for (final p in await db.allPlaces()) p.id: p};
      final layers = await db.allLayers();
      final pts = await db.cleanPoints(layers.map((l) => l.id).toList(),
          from: from, to: to);
      pts.sort((a, b) => a.time.compareTo(b.time));
      final journals = await db.journalBetween(from, to);
      // Strip weights for ±10 days around the selected one.
      _dataDays = await db.daysWithPoints(
          from.subtract(const Duration(days: 10)),
          to.add(const Duration(days: 10)));
      return _DayData(visits, places, pts, journals);
    }();
  }

  void _setDay(DateTime d) => setState(() {
        _day = _midnight(d);
        _reload();
      });

  @override
  Widget build(BuildContext context) {
    final refresh = ref.watch(visitsRefreshProvider);
    if (refresh != _seenRefresh) {
      _seenRefresh = refresh;
      _reload();
    }
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('足迹时间轴',
            style: PixelText.headline.copyWith(color: cs.onSurface)),
        actions: [
          IconButton(
            tooltip: '选择日期',
            icon: const Icon(Icons.calendar_month_rounded),
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _day,
                firstDate: DateTime(2000),
                lastDate: DateTime.now(),
              );
              if (picked != null) _setDay(picked);
            },
          ),
          IconButton(
            tooltip: '重新识别这一天的到访',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () async {
              await ref
                  .read(visitEngineProvider)
                  .detectRange(_day, _day.add(const Duration(days: 1)));
              ref.read(visitsRefreshProvider.notifier).state++;
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _DayStrip(
            day: _day,
            dataDays: _dataDays,
            onPick: _setDay,
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<_DayData>(
              future: _future,
              builder: (ctx, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                return _DayBody(
                  data: snap.data!,
                  day: _day,
                  onChanged: () {
                    ref.read(visitsRefreshProvider.notifier).state++;
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A week of day chips centred on the selected day; days with any recorded
/// point are heavier (人生点点's 字重日历 idea, one row of it).
class _DayStrip extends StatelessWidget {
  final DateTime day;
  final Set<String> dataDays;
  final ValueChanged<DateTime> onPick;
  const _DayStrip(
      {required this.day, required this.dataDays, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final today = DateTime.now();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: () => onPick(day.subtract(const Duration(days: 7))),
          ),
          Expanded(
            child: Row(
              children: [
                for (var i = -3; i <= 3; i++)
                  Expanded(child: _chip(context, day.add(Duration(days: i)),
                      cs, today)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: day.add(const Duration(days: 1)).isAfter(today)
                ? null
                : () => onPick(day.add(const Duration(days: 7))),
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, DateTime d, ColorScheme cs, DateTime today) {
    final selected = d.year == day.year && d.month == day.month && d.day == day.day;
    final future = d.isAfter(today);
    final has = dataDays.contains(DateFormat('yyyy-MM-dd').format(d));
    return GestureDetector(
      onTap: future ? null : () => onPick(d),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: selected ? cs.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(
              const ['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1],
              style: TextStyle(
                  fontSize: 11,
                  color: future ? cs.outlineVariant : cs.onSurfaceVariant),
            ),
            const SizedBox(height: 2),
            Text(
              '${d.day}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: has ? FontWeight.w800 : FontWeight.w300,
                color: future
                    ? cs.outlineVariant
                    : selected
                        ? cs.onPrimaryContainer
                        : cs.onSurface,
              ),
            ),
            SizedBox(
              height: 6,
              child: has
                  ? Container(
                      width: 4,
                      height: 4,
                      margin: const EdgeInsets.only(top: 2),
                      decoration: BoxDecoration(
                          color: cs.primary, shape: BoxShape.circle),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

sealed class _Item {
  DateTime get at;
}

class _VisitItem extends _Item {
  final Visit v;
  _VisitItem(this.v);
  @override
  DateTime get at => v.startedAt;
}

class _LegItem extends _Item {
  final DateTime from, to;
  final double meters;
  _LegItem(this.from, this.to, this.meters);
  @override
  DateTime get at => from;
  Duration get duration => to.difference(from);
  double get kmh => duration.inSeconds <= 0
      ? 0
      : meters / 1000 / (duration.inSeconds / 3600);
}

class _JournalItem extends _Item {
  final JournalEntry j;
  _JournalItem(this.j);
  @override
  DateTime get at => j.time;
}

class _DayBody extends ConsumerWidget {
  final _DayData data;
  final DateTime day;
  final VoidCallback onChanged;
  const _DayBody(
      {required this.data, required this.day, required this.onChanged});

  List<_Item> _build() {
    final shown = data.visits
        .where((v) => v.status != 2 && v.confidence >= 40)
        .toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final items = <_Item>[];
    // Legs: points strictly between consecutive shown visits (and before the
    // first / after the last), if they cover any real distance.
    DateTime cursor = day;
    final pts = data.points;
    void leg(DateTime a, DateTime b) {
      final seg = pts
          .where((p) => p.time.isAfter(a) && p.time.isBefore(b))
          .toList();
      if (seg.length < 2) return;
      final m = pathDistanceMeters(seg);
      if (m < 100) return;
      items.add(_LegItem(seg.first.time, seg.last.time, m));
    }
    for (final v in shown) {
      leg(cursor, v.startedAt);
      items.add(_VisitItem(v));
      cursor = v.endedAt;
    }
    leg(cursor, day.add(const Duration(days: 1)));
    for (final j in data.journals) {
      items.add(_JournalItem(j));
    }
    items.sort((a, b) => a.at.compareTo(b.at));
    return items;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final items = _build();
    final low = data.visits
        .where((v) => v.status != 2 && v.confidence < 40)
        .toList();
    final totalM = pathDistanceMeters(data.points);
    final visitCount = data.visits.where((v) => v.status != 2 && v.confidence >= 40).length;

    if (data.points.isEmpty && data.visits.isEmpty && data.journals.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('这一天没有记录',
              style: TextStyle(color: cs.onSurfaceVariant)),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Row(
          children: [
            _Stat(formatKm(totalM), '里程'),
            const SizedBox(width: 20),
            _Stat('$visitCount', '到访'),
            const SizedBox(width: 20),
            _Stat('${data.points.length}', '定位点'),
          ],
        ),
        const SizedBox(height: 12),
        for (final it in items)
          switch (it) {
            _VisitItem() => _VisitTile(
                v: it.v,
                place: it.v.placeId == null ? null : data.places[it.v.placeId!],
                places: data.places,
                onChanged: onChanged),
            _LegItem() => _LegTile(it),
            _JournalItem() => _JournalTile(it.j),
          },
        if (low.isNotEmpty)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('${low.length} 条低置信度到访',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              children: [
                for (final v in low)
                  _VisitTile(
                      v: v,
                      place: v.placeId == null ? null : data.places[v.placeId!],
                      places: data.places,
                      onChanged: onChanged),
              ],
            ),
          ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String value, label;
  const _Stat(this.value, this.label);
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: PixelText.headline.copyWith(color: cs.onSurface)),
        Text(label, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      ],
    );
  }
}

class _VisitTile extends ConsumerWidget {
  final Visit v;
  final Place? place;
  final Map<int, Place> places;
  final VoidCallback onChanged;
  const _VisitTile(
      {required this.v,
      required this.place,
      required this.places,
      required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final fmt = DateFormat('HH:mm');
    final confirmed = v.status == 1;
    final medium = !confirmed && v.confidence < 70;
    final name = place?.name ?? '未知地点';
    final sub = [
      formatDuration(v.endedAt.difference(v.startedAt)),
      if (place?.city != null && !(name.contains(place!.city!))) place!.city!,
      if (!confirmed) '建议 · 置信 ${v.confidence}',
    ].join(' · ');
    return Opacity(
      opacity: medium ? 0.65 : 1,
      child: InkWell(
        onTap: () => _showActions(context, ref),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 48,
                child: Column(
                  children: [
                    Text(fmt.format(v.startedAt),
                        style: TextStyle(fontSize: 12, color: cs.onSurface)),
                    Text(fmt.format(v.endedAt),
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(top: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: confirmed ? cs.primary : Colors.transparent,
                  border: Border.all(color: cs.primary, width: 2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            fontStyle:
                                confirmed ? FontStyle.normal : FontStyle.italic,
                            color: cs.onSurface)),
                    Text(sub,
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(Icons.more_horiz_rounded, color: cs.outline, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showActions(BuildContext context, WidgetRef ref) async {
    final engine = ref.read(visitEngineProvider);
    final action = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(place?.name ?? '未知地点',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                  '${DateFormat('MM-dd HH:mm').format(v.startedAt)} → '
                  '${DateFormat('HH:mm').format(v.endedAt)} · ${v.pointCount} 个定位点 · 半径 ${v.radius.round()} m'),
            ),
            if (v.status != 1)
              ListTile(
                leading: const Icon(Icons.check_circle_outline_rounded),
                title: const Text('确认到访'),
                onTap: () => Navigator.pop(context, 'confirm'),
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('重命名地点'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.merge_rounded),
              title: const Text('归入已有地点'),
              onTap: () => Navigator.pop(context, 'assign'),
            ),
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: const Text('在地图上查看'),
              onTap: () => Navigator.pop(context, 'map'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded,
                  color: Theme.of(context).colorScheme.error),
              title: Text('删除（不再建议）',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'confirm':
        await engine.confirm(v.id);
        onChanged();
      case 'delete':
        await engine.remove(v.id);
        onChanged();
      case 'map':
        ref.read(mapFocusProvider.notifier).state =
            (lat: v.lat, lng: v.lng, zoom: 16);
        if (context.mounted) context.go('/');
      case 'rename':
        final ctrl = TextEditingController(
            text: place == null || place!.name.endsWith('未命名地点')
                ? ''
                : place!.name);
        final name = await showDialog<String>(
          context: context,
          builder: (dctx) => AlertDialog(
            title: const Text('地点名称'),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(hintText: '家 / 公司 / 常去的咖啡馆…'),
              onSubmitted: (s) => Navigator.pop(dctx, s),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dctx),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(dctx, ctrl.text),
                  child: const Text('保存')),
            ],
          ),
        );
        if (name == null || name.trim().isEmpty) return;
        if (place != null) {
          await engine.renamePlace(place!.id, name);
          if (v.status != 1) await engine.confirm(v.id);
        } else {
          final db = ref.read(dbProvider);
          final id = await db.insertPlace(PlacesCompanion.insert(
            name: name.trim(),
            lat: v.lat,
            lng: v.lng,
            source: const Value(1),
            createdAt: DateTime.now(),
          ));
          await engine.assignPlace(v.id, id);
        }
        onChanged();
      case 'assign':
        final candidates = places.values
            .where((p) => p.id != v.placeId)
            .toList()
          ..sort((a, b) => PointFilter.haversineMeters(v.lat, v.lng, a.lat, a.lng)
              .compareTo(PointFilter.haversineMeters(v.lat, v.lng, b.lat, b.lng)));
        if (candidates.isEmpty) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('还没有其他地点')));
          }
          return;
        }
        final picked = await showModalBottomSheet<Place>(
          context: context,
          useRootNavigator: true,
          builder: (_) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in candidates.take(30))
                  ListTile(
                    leading: Icon(p.source == 1
                        ? Icons.place_rounded
                        : Icons.place_outlined),
                    title: Text(p.name),
                    subtitle: Text(
                        '${formatKm(PointFilter.haversineMeters(v.lat, v.lng, p.lat, p.lng))} 外'
                        '${p.city != null ? ' · ${p.city}' : ''}'),
                    onTap: () => Navigator.pop(context, p),
                  ),
              ],
            ),
          ),
        );
        if (picked == null) return;
        await engine.assignPlace(v.id, picked.id);
        onChanged();
    }
  }
}

class _LegTile extends StatelessWidget {
  final _LegItem leg;
  const _LegTile(this.leg);
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mode = travelModeLabel(leg.kmh);
    final icon = switch (mode) {
      '步行' => Icons.directions_walk_rounded,
      '骑行' => Icons.directions_bike_rounded,
      '驾车' => Icons.directions_car_rounded,
      _ => Icons.train_rounded,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 2, 0, 2),
      child: Row(
        children: [
          Container(
            width: 12,
            alignment: Alignment.center,
            child: Container(width: 2, height: 28, color: cs.outlineVariant),
          ),
          const SizedBox(width: 12),
          Icon(icon, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            '$mode ${formatKm(leg.meters)} · ${formatDuration(leg.duration)}',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _JournalTile extends StatelessWidget {
  final JournalEntry j;
  const _JournalTile(this.j);
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 4, 0, 4),
      child: Row(
        children: [
          Icon(Icons.auto_stories_rounded, size: 16, color: cs.tertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${DateFormat('HH:mm').format(j.time)}  ${j.title}',
              style: TextStyle(fontSize: 13, color: cs.onSurface),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
