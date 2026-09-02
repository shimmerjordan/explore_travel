import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../services/geo/country_lookup.dart';
import '../../services/stats/footprint_stats.dart';
import '../../services/stats/footprint_summary.dart';
import '../common/pixel.dart';

/// 「足迹」— the numbers layer over the explore progress page: distance,
/// recorded days & streaks, an activity calendar, hour-of-day rhythm, the
/// countries / cities you actually stayed in, and your top places. All
/// derived from track points + detected visits; nothing here is a dashboard
/// of cards for their own sake (see PRODUCT.md) — a few figures with a face.
class FootprintTab extends ConsumerStatefulWidget {
  const FootprintTab({super.key});
  @override
  ConsumerState<FootprintTab> createState() => _FootprintTabState();
}

class _Data {
  final FootprintSummary summary;
  final Map<String, int> daysPerCountry;
  final List<Place> places;
  final List<Visit> visits;
  const _Data(this.summary, this.daysPerCountry, this.places, this.visits);
}

class _FootprintTabState extends ConsumerState<FootprintTab> {
  static const _snapKey = 'footprint_stats_v1';
  FootprintSummary? _summary; // restored snapshot renders instantly
  _Data? _data;
  int _seenRefresh = -1;

  @override
  void initState() {
    super.initState();
    _restore().then((_) => _load());
  }

  Future<void> _restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_snapKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (mounted) {
        setState(() => _summary = FootprintSummary.fromJson(j));
      }
    } catch (_) {}
  }

  Future<void> _load() async {
    final db = ref.read(dbProvider);
    final layers = await db.allLayers();
    final pts = await db.cleanPoints(layers.map((l) => l.id).toList());
    final n = pts.length;
    final lat = Float64List(n), lng = Float64List(n);
    final t = Int64List(n);
    final layer = Int32List(n);
    for (var i = 0; i < n; i++) {
      lat[i] = pts[i].lat;
      lng[i] = pts[i].lng;
      t[i] = pts[i].time.millisecondsSinceEpoch;
      layer[i] = pts[i].layerId;
    }
    final input = FootprintInput(
        lat, lng, t, layer, DateTime.now().timeZoneOffset.inMilliseconds);
    final summary = kIsWeb
        ? computeFootprint(input)
        : FootprintSummary.fromJson(
            (await compute(computeFootprintFromMap, input.toMap()))
                .map((k, v) => MapEntry(k, v)));

    // Days per country: one sample per (day, 2-hour slot) → offline bbox
    // lookup. A day counts for a country if any sample lands in it
    // (Dawarich: "≥1 point that day"), fixes over 500 km/h are already gone.
    final lookup = await CountryLookup.instance;
    final dayCountries = <String, Set<String>>{};
    String? lastSlot;
    for (final p in pts) {
      final slot =
          '${FootprintSummary.dayKey(p.time)}|${p.time.hour ~/ 2}|${p.layerId}';
      if (slot == lastSlot) continue;
      lastSlot = slot;
      final c = lookup.lookup(p.lat, p.lng).country;
      if (c == '未知') continue;
      (dayCountries[FootprintSummary.dayKey(p.time)] ??= {}).add(c);
    }
    final daysPerCountry = <String, int>{};
    for (final set in dayCountries.values) {
      for (final c in set) {
        daysPerCountry[c] = (daysPerCountry[c] ?? 0) + 1;
      }
    }

    final places = await db.allPlaces();
    final visits = await db.visitsBetween(
        DateTime(2000), DateTime.now().add(const Duration(days: 1)));
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _data = _Data(summary, daysPerCountry, places, visits);
    });
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_snapKey, jsonEncode(summary.toJson()));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final refresh = ref.watch(visitsRefreshProvider);
    if (refresh != _seenRefresh) {
      _seenRefresh = refresh;
      if (_data != null) _load();
    }
    final s = _summary;
    if (s == null) return const Center(child: CircularProgressIndicator());
    final cs = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final d = _data;

    // Visits → places → countries/cities with real dwell.
    final dwellByPlace = <int, int>{}; // seconds
    final countByPlace = <int, int>{};
    if (d != null) {
      for (final v in d.visits) {
        if (v.status == 2 || v.placeId == null) continue;
        dwellByPlace[v.placeId!] = (dwellByPlace[v.placeId!] ?? 0) +
            v.endedAt.difference(v.startedAt).inSeconds;
        countByPlace[v.placeId!] = (countByPlace[v.placeId!] ?? 0) + 1;
      }
    }
    final cityDwell = <String, int>{};
    for (final p in d?.places ?? const <Place>[]) {
      if (p.city == null) continue;
      cityDwell[p.city!] = (cityDwell[p.city!] ?? 0) + (dwellByPlace[p.id] ?? 0);
    }
    final cities = cityDwell.entries.where((e) => e.value >= 3600).length;
    final countries = <String>{
      ...d?.daysPerCountry.keys ?? const <String>[],
      for (final p in d?.places ?? const <Place>[])
        if (p.country != null && p.country!.isNotEmpty) p.country!,
    };
    final topPlaces = (d?.places ?? const <Place>[])
        .where((p) => (countByPlace[p.id] ?? 0) > 0)
        .toList()
      ..sort((a, b) => (countByPlace[b.id] ?? 0).compareTo(countByPlace[a.id] ?? 0));

    Widget label(String t) =>
        Text(t, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant));
    Widget section(String t) => Padding(
          padding: const EdgeInsets.only(top: 22, bottom: 8),
          child: Text(t,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant,
                  letterSpacing: 0.5)),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        // ── Hero: distance ──
        Text(formatKm(s.totalMeters),
            style: PixelText.display.copyWith(color: cs.onSurface)),
        label('走过的路 · 今年 ${formatKm(s.metersInYear(now.year))} · '
            '本月 ${formatKm(s.metersInMonth(now.year, now.month))}'
            '${s.longestDay != null ? ' · 最长一天 ${formatKm(s.longestDay!.value)}（${s.longestDay!.key}）' : ''}'),
        const SizedBox(height: 18),
        Row(
          children: [
            _Figure('${s.recordedDays}', '记录天数'),
            _Figure('${s.currentStreak(now)}', '当前连续'),
            _Figure('${s.longestStreak}', '最长连续'),
            _Figure(
                s.first == null
                    ? '—'
                    : '${now.difference(s.first!).inDays + 1}',
                '足迹天龄'),
          ],
        ),

        section('活动日历 · 近 6 个月'),
        _ActivityCalendar(daily: s.dailyMeters, months: 6, now: now),
        const SizedBox(height: 6),
        label('颜色越深走得越远：空 · <2 km · <10 km · <30 km · 更多'),

        section('一天里的节律'),
        SizedBox(height: 56, child: _HourBars(hourly: s.hourly)),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [label('0'), label('6'), label('12'), label('18'), label('24')],
        ),

        section('国家与城市'),
        if (d == null)
          label('统计中…')
        else ...[
          Row(
            children: [
              _Figure('${countries.length}', '国家 / 地区'),
              _Figure('$cities', '城市（停留 ≥1 小时）'),
              _Figure('${d.places.length}', '地点'),
            ],
          ),
          if (d.daysPerCountry.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in (d.daysPerCountry.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value)))
                    .take(12))
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('${e.key} ${e.value} 天',
                        style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ],
          if (d.visits.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: label('城市按到访停留时长统计——到「足迹时间轴」确认几处到访后这里会更准。'),
            ),
        ],

        if (topPlaces.isNotEmpty) ...[
          section('最常去的地方'),
          for (final p in topPlaces.take(5))
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                  p.source == 1 ? Icons.place_rounded : Icons.place_outlined,
                  color: cs.primary),
              title: Text(p.name),
              subtitle: Text(
                  '${countByPlace[p.id]} 次 · 累计 ${formatDuration(Duration(seconds: dwellByPlace[p.id] ?? 0))}'
                  '${p.city != null && !p.name.contains(p.city!) ? ' · ${p.city}' : ''}'),
              onTap: () {
                ref.read(mapFocusProvider.notifier).state =
                    (lat: p.lat, lng: p.lng, zoom: 16);
                context.go('/');
              },
            ),
        ],
        const SizedBox(height: 12),
        label('里程按相邻定位点累加；间隔超过 30 分钟或隐含速度超过 300 km/h 的段不计。'),
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  final String value, label;
  const _Figure(this.value, this.label);
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: PixelText.headline.copyWith(color: cs.onSurface)),
          Text(label,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// GitHub-style week columns × 7 rows, most recent week on the right. Cells
/// are crisp squares on the pixel grid; intensity by daily distance.
class _ActivityCalendar extends StatelessWidget {
  final Map<String, double> daily;
  final int months;
  final DateTime now;
  const _ActivityCalendar(
      {required this.daily, required this.months, required this.now});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (ctx, c) {
      final weeks = (months * 4.4).ceil();
      final cell = ((c.maxWidth - 24) / weeks).clamp(6.0, 14.0);
      return SizedBox(
        height: cell * 7 + 6 * 2 + 14,
        child: CustomPaint(
          painter: _CalendarPainter(
            daily: daily,
            weeks: weeks,
            cell: cell,
            now: now,
            on: cs.primary,
            off: cs.onSurface.withValues(alpha: 0.08),
            text: cs.onSurfaceVariant,
          ),
        ),
      );
    });
  }
}

class _CalendarPainter extends CustomPainter {
  final Map<String, double> daily;
  final int weeks;
  final double cell;
  final DateTime now;
  final Color on, off, text;
  _CalendarPainter({
    required this.daily,
    required this.weeks,
    required this.cell,
    required this.now,
    required this.on,
    required this.off,
    required this.text,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 2.0;
    final today = DateTime(now.year, now.month, now.day);
    // Rightmost column = this week (Mon..Sun rows).
    final thisMonday = today.subtract(Duration(days: today.weekday - 1));
    final paint = Paint();
    final left = 24.0; // room for weekday labels
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (final (row, lbl) in const [(0, '一'), (3, '四'), (6, '日')]) {
      tp.text = TextSpan(text: lbl, style: TextStyle(fontSize: 9, color: text));
      tp.layout();
      tp.paint(canvas, Offset(0, 14 + row * (cell + gap) + (cell - tp.height) / 2));
    }
    String? lastMonth;
    for (var w = 0; w < weeks; w++) {
      final monday = thisMonday.subtract(Duration(days: 7 * (weeks - 1 - w)));
      final x = left + w * (cell + gap);
      final m = '${monday.month}月';
      if (m != lastMonth && monday.day <= 7) {
        tp.text = TextSpan(text: m, style: TextStyle(fontSize: 9, color: text));
        tp.layout();
        tp.paint(canvas, Offset(x, 0));
        lastMonth = m;
      }
      for (var r = 0; r < 7; r++) {
        final d = monday.add(Duration(days: r));
        if (d.isAfter(today)) continue;
        final meters = daily[FootprintSummary.dayKey(d)];
        final y = 14 + r * (cell + gap);
        if (meters == null) {
          paint.color = off;
        } else {
          final level = meters < 2000
              ? 0.3
              : meters < 10000
                  ? 0.55
                  : meters < 30000
                      ? 0.8
                      : 1.0;
          paint.color = on.withValues(alpha: level);
        }
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CalendarPainter old) =>
      old.daily != daily || old.weeks != weeks || old.cell != cell;
}

class _HourBars extends StatelessWidget {
  final List<int> hourly;
  const _HourBars({required this.hourly});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return CustomPaint(
      painter: _HourBarsPainter(hourly, cs.primary, cs.onSurface.withValues(alpha: 0.08)),
      child: const SizedBox.expand(),
    );
  }
}

class _HourBarsPainter extends CustomPainter {
  final List<int> hourly;
  final Color on, off;
  _HourBarsPainter(this.hourly, this.on, this.off);
  @override
  void paint(Canvas canvas, Size size) {
    if (hourly.length != 24) return;
    final mx = hourly.fold<int>(0, math.max);
    final w = size.width / 24;
    final p = Paint();
    for (var h = 0; h < 24; h++) {
      final frac = mx == 0 ? 0.0 : hourly[h] / mx;
      final bh = math.max(2.0, frac * size.height);
      p.color = frac == 0 ? off : on.withValues(alpha: 0.35 + 0.65 * frac);
      canvas.drawRect(
          Rect.fromLTWH(h * w + 1, size.height - bh, w - 2, bh), p);
    }
  }

  @override
  bool shouldRepaint(covariant _HourBarsPainter old) => old.hourly != hourly;
}
