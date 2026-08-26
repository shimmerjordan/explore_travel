import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:explore_journal/services/map/fog_tile_provider.dart';

/// The fog compositor turns white corridor masks into the veil-with-holes in
/// ONE colour-filtered saveLayer (it used to be an opacity group + a dstOut
/// group). Pin the pixel semantics the map relies on:
///   * no mask → full veil (cover can never vanish);
///   * opaque mask → fully erased;
///   * half-alpha mask → half the veil;
///   * two overlapping masks → the same erase as one (idempotent under
///     flutter_map's cross-zoom tile overlap — the old "缩放黑色区块").
void main() {
  const veil = Color(0xC7101820); // alpha 199

  Future<ByteData> render(WidgetTester tester, Widget child) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 40,
              height: 40,
              child: fogCompositorForTest(veil: veil, child: child),
            ),
          ),
        ),
      ),
    );
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    // Rasterisation completes on real engine callbacks, which FakeAsync never
    // drives — without runAsync the future simply never resolves.
    final data = await tester.runAsync(() async {
      final img = await boundary.toImage();
      try {
        // rawRgba is PREMULTIPLIED (r·a/255); we assert on the veil's own
        // RGB, so read straight alpha.
        return await img.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba);
      } finally {
        img.dispose();
      }
    });
    return data!;
  }

  ({int r, int g, int b, int a}) px(ByteData d, int x, int y) {
    final o = (y * 40 + x) * 4;
    return (
      r: d.getUint8(o),
      g: d.getUint8(o + 1),
      b: d.getUint8(o + 2),
      a: d.getUint8(o + 3)
    );
  }

  testWidgets('no mask → full veil in the veil colour', (tester) async {
    final d = await render(tester, const SizedBox.expand());
    final p = px(d, 20, 20);
    expect(p.a, closeTo(199, 2));
    expect(p.r, closeTo(0x10, 2));
    expect(p.g, closeTo(0x18, 2));
    expect(p.b, closeTo(0x20, 2));
  });

  testWidgets('opaque mask erases the veil; outside stays covered',
      (tester) async {
    final d = await render(
      tester,
      const Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
            width: 20, height: 40, child: ColoredBox(color: Colors.white)),
      ),
    );
    expect(px(d, 5, 20).a, 0);
    expect(px(d, 35, 20).a, closeTo(199, 2));
  });

  testWidgets('half-alpha mask leaves half the veil', (tester) async {
    final d = await render(
        tester, const ColoredBox(color: Color(0x80FFFFFF))); // alpha 128
    expect(px(d, 20, 20).a, closeTo(199 * (1 - 128 / 255), 3));
  });

  testWidgets('two overlapping opaque masks erase exactly like one',
      (tester) async {
    final d = await render(
      tester,
      const Stack(children: [
        Positioned.fill(child: ColoredBox(color: Colors.white)),
        Positioned.fill(child: ColoredBox(color: Colors.white)),
      ]),
    );
    expect(px(d, 20, 20).a, 0);
  });
}
