/// One freshly-recorded point, pushed by the recording pipeline. Consumers
/// (playback, future overlays) can APPEND instead of re-reading every
/// TrackPoint row per tick.
///
/// Historical note: this used to live in `fog_layer.dart` next to the
/// coloured-polyline trail overlay. That overlay is gone — coloured layers now
/// render inside the baked fog tiles with the SAME corridor geometry as the
/// transparent reveal (see `fog_tile_provider.dart`), so路径样式完全一致，
/// 只是透明色与自定义颜色的区别。
typedef LiveTrackPoint = ({
  double lat,
  double lng,
  DateTime time,
  int layerId,
  double? width,
  double? accuracy,
});
