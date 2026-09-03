import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../services/map/tile_providers.dart';
import '../../services/music/music_service.dart';

class FavoritesMapScreen extends ConsumerStatefulWidget {
  const FavoritesMapScreen({super.key});

  @override
  ConsumerState<FavoritesMapScreen> createState() =>
      _FavoritesMapScreenState();
}

class _FavoritesMapScreenState extends ConsumerState<FavoritesMapScreen> {
  /// 查询只发一次，握在 state 里。以前在 build() 里每次 new Future，设置变动
  /// （底图切换等）一重建就转圈、重查。本页只读，不需要刷新。
  late final Future<List<SongFavorite>> _favsFuture;

  @override
  void initState() {
    super.initState();
    final db = ref.read(dbProvider);
    _favsFuture = db.select(db.songFavorites).get();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('收藏歌曲地图'),
      ),
      body: FutureBuilder<List<SongFavorite>>(
        future: _favsFuture,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final all = snap.data!
              .where((f) => f.lat != null && f.lng != null)
              .toList();
          if (all.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.music_off_rounded,
                      size: 64,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.3)),
                  const SizedBox(height: 16),
                  Text('暂无带有位置的收藏',
                      style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.5))),
                ],
              ),
            );
          }
          final center = LatLng(all.first.lat!, all.first.lng!);
          return FlutterMap(
            options: MapOptions(
              initialCenter: center,
              initialZoom: 10,
              initialRotation: 0,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              () {
                final s = ref.watch(settingsProvider);
                return buildTileLayer(
                  provider: s.mapProvider,
                  style: s.mapStyle,
                  amapKey: s.amapApiKey,
                  googleKey: s.googleMapKey,
                  customOsmUrl: s.customOsmTileUrl,
                  ovitalUrl: s.ovitalTileUrl,
                );
              }(),
              MarkerLayer(
                markers: all
                    .map((f) => Marker(
                          point: LatLng(f.lat!, f.lng!),
                          width: 40,
                          height: 40,
                          child: GestureDetector(
                            onTap: () => _playAt(context, ref, f),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.deepPurple,
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: Colors.white, width: 2),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black
                                        .withValues(alpha: 0.3),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                              child: const Icon(Icons.music_note_rounded,
                                  color: Colors.white, size: 20),
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _playAt(
      BuildContext context, WidgetRef ref, SongFavorite f) async {
    final svc = ref.read(musicServiceProvider);
    final track = MusicTrack(
      id: f.songId,
      name: f.title,
      artist: f.artist,
      album: '',
      source: f.source,
    );
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.deepPurple.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(Icons.music_note_rounded,
                    color: Colors.deepPurple),
              ),
              title: Text(f.title,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('${f.artist} · ${f.source}'),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('播放'),
                onPressed: () async {
                  Navigator.pop(context);
                  try {
                    await svc.play(track);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('播放失败：$e')));
                    }
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
