import '../music_service.dart';

/// Per-platform music backend. Each platform (netease, kuwo, joox, ...)
/// has its own implementation. The aggregator [MusicService] picks one
/// based on the user's selected source and falls back to the GD studio
/// proxy when no direct backend is registered.
abstract class MusicBackend {
  /// Stable id matching the dropdown value: 'netease' | 'kuwo' | 'joox' | ...
  String get source;

  Future<List<MusicTrack>> search(String keyword, {int count = 20});

  /// Returns a streamable URL for the given track, or null if the backend
  /// refuses (geo / DRM / dead).
  Future<String?> streamUrl(MusicTrack t, {String br = '320'});

  /// Returns a cover image URL. Many backends embed it in the search
  /// result; if so, just return that. Returns null if unavailable.
  Future<String?> coverUrl(MusicTrack t, {int size = 300});
}
