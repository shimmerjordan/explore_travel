import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:explore_journal/core/prefs.dart';
import 'package:explore_journal/services/geo/geocoding_service.dart';
import 'package:explore_journal/services/geo/learned_regions.dart';

/// 格缓存的 prefs 键与格式是对外契约（备份导出 / 导入直接读写它），测试也钉住。
const kKey = 'geocode_cell_cache_v1';

/// 0.01° 格：成都 (30.5735, 104.0665) → floor(3057.35), floor(10406.65)。
const kChengduA = (lat: 30.5735, lng: 104.0665);
const kChengduB = (lat: 30.5738, lng: 104.0669); // 同一格的另一个点
const kChengduKey = '3057,10406';

/// 上海 (31.2304, 121.4737) → 另一格。
const kShanghai = (lat: 31.2304, lng: 121.4737);
const kShanghaiKey = '3123,12147';

const kChengdu = GeocodeResult(
    country: '中国', province: '四川省', city: '成都市', source: 'amap');
const kShanghaiRes = GeocodeResult(
    country: '中国', province: '上海市', city: '上海市', source: 'amap');

/// 不走网络的替身：数 prefs 解码次数，在线反查按坐标返回预设结果。
class _FakeGeocoder extends GeocodingService {
  _FakeGeocoder({this.online = const {}})
      : super(const AppSettings(), LearnedRegionsStore());

  /// 格键 → 在线反查结果；没配的格视为在线也查不到。
  final Map<String, GeocodeResult> online;
  int decodes = 0;
  int onlineCalls = 0;

  @override
  Map<String, GeocodeResult> decodeCellCache(String raw) {
    decodes++;
    return super.decodeCellCache(raw);
  }

  @override
  Future<GeocodeResult?> lookupOnline(double lat, double lng) async {
    onlineCalls++;
    final k = '${(lat / 0.01).floor()},${(lng / 0.01).floor()}';
    return online[k];
  }
}

Map<String, dynamic> _blob(Map<String, GeocodeResult> cells) =>
    cells.map((k, v) => MapEntry(k, v.toJson()));

void main() {
  // 用 testWidgets 是为了拿到 fake async：pump(Duration) 能精确推进防抖定时器，
  // 不必真等 2 秒。

  testWidgets('同一格两次 resolve 只解码一次 prefs，第二次不再上网', (tester) async {
    SharedPreferences.setMockInitialValues({
      kKey: jsonEncode(_blob({kChengduKey: kChengdu})),
    });
    final svc = _FakeGeocoder();

    final a = await svc.resolve(kChengduA.lat, kChengduA.lng);
    final b =
        await svc.resolve(kChengduB.lat, kChengduB.lng, allowNetwork: false);

    expect(a.city, '成都市');
    expect(a.source, 'cache');
    expect(b.source, 'cache');
    expect(svc.onlineCalls, 0);
    expect(svc.decodes, 1, reason: '内存副本已备好，不该再解一次');

    // cachedCellCount 同样读内存，不重解。
    expect(await svc.cachedCellCount(), 1);
    expect(svc.decodes, 1);
  });

  testWidgets('别处直接改了 prefs（备份恢复）→ 以 prefs 为准重解，不用内存旧表',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      kKey: jsonEncode(_blob({kChengduKey: kChengdu})),
    });
    final svc = _FakeGeocoder();
    await svc.resolve(kChengduA.lat, kChengduA.lng);
    expect(svc.decodes, 1);

    // 模拟备份导入：整包覆盖成另一份（丢了成都、多了上海）。
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kKey, jsonEncode(_blob({kShanghaiKey: kShanghaiRes})));

    final sh = await svc.resolve(kShanghai.lat, kShanghai.lng);
    expect(sh.city, '上海市');
    expect(sh.source, 'cache');
    expect(svc.decodes, 2, reason: '原文变了才重解，且只重解一次');
    expect(await svc.cachedCellCount(), 1);
    expect(svc.decodes, 2);
  });

  testWidgets('在线结果先进内存，防抖 2 s 后才整包写回 prefs', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final svc = _FakeGeocoder(online: {
      kChengduKey: kChengdu,
      kShanghaiKey: kShanghaiRes,
    });
    final prefs = await SharedPreferences.getInstance();

    final got = await svc.resolve(kChengduA.lat, kChengduA.lng);
    expect(got.source, 'amap');
    expect(prefs.getString(kKey), isNull, reason: '还在防抖窗口内');

    // 同格再查：命中内存，不上网、不解码。
    final again = await svc.resolve(kChengduB.lat, kChengduB.lng);
    expect(again.source, 'cache');
    expect(again.city, '成都市');
    expect(svc.onlineCalls, 1);

    // 窗口内再来一格：并进同一次写。
    await tester.pump(const Duration(seconds: 1));
    await svc.resolve(kShanghai.lat, kShanghai.lng);
    expect(prefs.getString(kKey), isNull);

    await tester.pump(const Duration(seconds: 1, milliseconds: 100));
    expect(
      jsonDecode(prefs.getString(kKey)!),
      _blob({kChengduKey: kChengdu, kShanghaiKey: kShanghaiRes}),
    );
    expect(svc.decodes, 0, reason: '空 prefs 起步，从头到尾没有东西可解');
    expect(await svc.cachedCellCount(), 2);
  });

  testWidgets('flush() 立刻落盘，不等定时器', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final svc = _FakeGeocoder(online: {kChengduKey: kChengdu});
    final prefs = await SharedPreferences.getInstance();

    await svc.resolve(kChengduA.lat, kChengduA.lng);
    expect(prefs.getString(kKey), isNull);

    await svc.flush();
    expect(jsonDecode(prefs.getString(kKey)!), _blob({kChengduKey: kChengdu}));

    // 写完再读：认得出是自己写的，不重解。
    await svc.resolve(kChengduB.lat, kChengduB.lng);
    expect(svc.decodes, 0);
  });

  testWidgets('落盘前别处覆盖了 prefs → 写回时把待写的格叠在新原文上，两边都不丢',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final svc = _FakeGeocoder(online: {kChengduKey: kChengdu});
    final prefs = await SharedPreferences.getInstance();

    await svc.resolve(kChengduA.lat, kChengduA.lng); // 成都待写
    await prefs.setString(kKey, jsonEncode(_blob({kShanghaiKey: kShanghaiRes})));

    await svc.flush();
    expect(
      jsonDecode(prefs.getString(kKey)!),
      _blob({kShanghaiKey: kShanghaiRes, kChengduKey: kChengdu}),
    );
  });

  testWidgets('clearCache() 同时清 prefs 和内存副本，并作废待写', (tester) async {
    SharedPreferences.setMockInitialValues({
      kKey: jsonEncode(_blob({kShanghaiKey: kShanghaiRes})),
    });
    final svc = _FakeGeocoder(online: {kChengduKey: kChengdu});
    final prefs = await SharedPreferences.getInstance();

    await svc.resolve(kChengduA.lat, kChengduA.lng); // 成都待写
    await svc.clearCache();

    expect(prefs.getString(kKey), isNull);
    expect(await svc.cachedCellCount(), 0);
    // 定时器已取消：再等也不会把旧的待写格写出来。
    await tester.pump(const Duration(seconds: 3));
    expect(prefs.getString(kKey), isNull);
  });
}
