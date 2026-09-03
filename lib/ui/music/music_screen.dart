import 'dart:async';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart' show PlayerState;
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../services/music/music_service.dart';
import '../common/pixel.dart';

/// Music screen: search → play → favorite, plus an AI-driven "make me a
/// travel playlist" tab that derives keywords from current location and mood.
class MusicScreen extends ConsumerStatefulWidget {
  const MusicScreen({super.key});
  @override
  ConsumerState<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends ConsumerState<MusicScreen>
    with SingleTickerProviderStateMixin {
  final _searchCtrl = TextEditingController();
  final _moodCtrl = TextEditingController(text: '惬意的下午，公路旅行');
  String _source = 'gd';
  List<MusicTrack> _results = [];
  MusicTrack? _now;
  bool _loading = false;
  bool _aiLoading = false;
  String _aiStatus = '';
  int _aiPlaylistCount = 10;
  StreamSubscription<PlayerState>? _playerSub;

  static const _favoritesTab = 2;
  late final TabController _tabs;
  int _lastTab = 0;

  /// 收藏列表查询只在这里持有。本页随播放器状态事件频繁 setState，以前在
  /// build() 里每次 new Future，FutureBuilder 每次都退回转圈并重查一遍。
  /// 只在收藏增删、重新切到收藏页时刷新；首次打开收藏页时懒建。
  Future<List<SongFavorite>>? _favsFuture;

  /// 已划掉、但列表还没重查回来的收藏 id。Dismissible 要求 onDismissed 一返回这
  /// 行就不在树里（否则 debug 断言），删库是异步的，先在本地藏起来。id 是自增主
  /// 键、删除走墓碑，不会再出现，所以不必清理。
  final Set<int> _dismissedFavIds = {};
  // Five user-facing sources. "gd" is the GD音乐台 aggregator (no auth, just
  // works); the other four are the platforms that gdstudio proxies behind
  // the scenes. They appear as first-class options in the dropdown so the
  // dropdown matches the user's mental model. Direct (non-GD) API
  // integrations are not implemented yet — see [MusicSourcesScreen] for
  // honest status and per-platform credential storage. Searches with any
  // value other than 'gd' still hit gdstudio with `?source=<value>` until
  // a direct backend lands.
  static const _sources = ['gd', 'netease', 'kuwo', 'joox'];
  static const _sourceLabels = {
    'gd': 'GD 音乐台',
    'netease': '网易云',
    'kuwo': '酷我',
    'joox': 'JOOX',
  };
  MusicService? _svc;
  Timer? _syncTimer;
  // 组内广播用的直链缓存：同一首歌只 resolve 一次（见 _syncTimer）。
  String? _syncedSongKey;
  String? _syncedUrl;

  @override
  void initState() {
    super.initState();
    _svc = ref.read(musicServiceProvider);
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(_onTabChanged);
    // Auto-clear the "正在解析 N 首" status as soon as the player actually
    // starts playing — used to be sticky which was confusing.
    _playerSub = _svc?.player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (s.playing &&
          (_aiStatus.startsWith('解析') || _aiStatus.startsWith('已入队'))) {
        setState(() => _aiStatus = '');
      }
    });
    _syncTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted) return;
      final s = ref.read(settingsProvider);
      if (!s.groupBroadcastMusic || (s.groupId ?? '').isEmpty) return;
      final now = _now;
      if (now == null) return;
      final pos = _svc?.player.position.inMilliseconds ?? 0;
      try {
        // 每 5s 重新 resolveStreamUrl 是一次真实网络请求（流量 + 电量）；
        // 同一首歌的直链在播放期内不变，按歌缓存即可。
        if (_syncedSongKey != '${now.source}:${now.id}') {
          _syncedUrl = await _svc!.resolveStreamUrl(now);
          _syncedSongKey = '${now.source}:${now.id}';
        }
        final url = _syncedUrl;
        if (url == null) return;
        await ref.read(groupServiceProvider).sendMusicPlay(
              url: url,
              title: now.name,
              artist: now.artist,
              positionMs: pos,
            );
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _playerSub?.cancel();
    _tabs.dispose();
    _svc?.stop();
    super.dispose();
  }

  /// 重新切回收藏页时刷一次：收藏可能在别处变了（收藏地图、同步合并进来的）。
  /// TabController 一次切换会通知两回（起手 / 落定），用 _lastTab 折成一次。
  void _onTabChanged() {
    final i = _tabs.index;
    if (i == _favoritesTab && _lastTab != _favoritesTab && _favsFuture != null) {
      _reloadFavorites();
    }
    _lastTab = i;
  }

  Future<List<SongFavorite>> _queryFavorites() {
    final db = ref.read(dbProvider);
    return db.select(db.songFavorites).get();
  }

  void _reloadFavorites() {
    if (!mounted) return;
    setState(() => _favsFuture = _queryFavorites());
  }

  Future<void> _doSearch(String keyword) async {
    if (keyword.trim().isEmpty) return;
    final svc = ref.read(musicServiceProvider);
    setState(() {
      _loading = true;
      _results = [];
    });
    try {
      final r = await svc.search(keyword.trim(), source: _source);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('搜索失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _aiPlaylist() async {
    final settings = ref.read(settingsProvider);
    final ai = ref.read(aiServiceProvider);
    final loc = ref.read(locationServiceProvider);
    if (settings.aiApiKey == null || settings.aiApiKey!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先到「设置」配置 AI API Key')));
      return;
    }
    setState(() {
      _aiLoading = true;
      _aiStatus = '正在请求 AI 推荐...';
    });
    try {
      final pos = await loc.currentOnce();
      final place = pos == null
          ? '未知位置'
          : '纬度 ${pos.latitude.toStringAsFixed(2)}, 经度 ${pos.longitude.toStringAsFixed(2)}';
      final keywords = await ai.suggestSongKeywords(
        settings: settings,
        placeDescription: place,
        moodHint: _moodCtrl.text,
        count: _aiPlaylistCount,
      );
      setState(() => _aiStatus = '搜索 ${keywords.length} 个关键词…');
      final svc = ref.read(musicServiceProvider);
      final all = <MusicTrack>[];
      // 2 hits per keyword × 10 keywords = ≤20 requests, well under
      // gdstudio's 50-per-5-min budget.
      for (final k in keywords) {
        try {
          final r = await svc.search(k, source: _source, count: 2);
          all.addAll(r);
        } catch (_) {}
      }
      final seen = <String>{};
      final uniq = <MusicTrack>[];
      for (final t in all) {
        final key = '${t.source}:${t.id}';
        if (seen.add(key)) uniq.add(t);
      }
      setState(() {
        _results = uniq;
        _aiStatus = '已生成 ${uniq.length} 首旅行歌单 — 点单首播放，或点上方"播放整张"';
      });
    } catch (e) {
      setState(() => _aiStatus = '失败：$e');
    } finally {
      if (mounted) setState(() => _aiLoading = false);
    }
  }

  /// Resolve every result's URL and queue them into the player so the user
  /// gets a hands-off playlist experience.
  Future<void> _playAllResults() async {
    if (_results.isEmpty) return;
    final svc = ref.read(musicServiceProvider);
    setState(() => _aiStatus = '解析 ${_results.length} 首的播放地址…');
    try {
      final queued = await svc.playAll(_results);
      if (mounted) {
        setState(() => _aiStatus =
            '已入队 $queued 首 — 自动顺序播放，跳过下一首/上一首用系统通知');
      }
    } catch (e) {
      if (mounted) setState(() => _aiStatus = '入队失败：$e');
    }
  }

  Future<void> _favorite(MusicTrack t) async {
    final db = ref.read(dbProvider);
    final pos = await ref.read(locationServiceProvider).currentOnce();
    await db.into(db.songFavorites).insert(SongFavoritesCompanion.insert(
          songId: t.id,
          title: t.name,
          artist: t.artist,
          source: t.source,
          coverUrl: const Value.absent(),
          addedAt: DateTime.now(),
          lat: Value(pos?.latitude),
          lng: Value(pos?.longitude),
        ));
    if (mounted) {
      // 收藏页已经建过列表才重查；还没打开过就等它首次打开时懒建。
      if (_favsFuture != null) _reloadFavorites();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('收藏：${t.name}')));
    }
  }

  Future<void> _play(MusicTrack t) async {
    setState(() => _now = t);
    final svc = ref.read(musicServiceProvider);
    try {
      await svc.play(t);
      // If group broadcast is on, share the song with the group.
      final s = ref.read(settingsProvider);
      if (s.groupBroadcastMusic &&
          (s.groupId ?? '').isNotEmpty) {
        try {
          final url = await svc.resolveStreamUrl(t);
          if (url != null) {
            final pos = svc.player.position.inMilliseconds;
            await ref.read(groupServiceProvider).sendMusicPlay(
                  url: url,
                  title: t.name,
                  artist: t.artist,
                  positionMs: pos,
                );
          }
        } catch (_) {}
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('播放失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 显式 TabController（而不是 DefaultTabController）：要听「切到收藏页」。
    return Scaffold(
      appBar: AppBar(
        title: Text('旅行歌单',
            style: PixelText.headline
                .copyWith(color: Theme.of(context).colorScheme.onSurface)),
        actions: [
          Consumer(builder: (context, ref, _) {
            final s = ref.watch(settingsProvider);
            final inGroup = (s.groupId ?? '').isNotEmpty;
            return IconButton(
              icon: Icon(
                s.groupBroadcastMusic && inGroup
                    ? Icons.cast_connected
                    : Icons.cast,
                color: s.groupBroadcastMusic && inGroup
                    ? Colors.greenAccent
                    : null,
              ),
              tooltip: inGroup
                  ? (s.groupBroadcastMusic ? '正在与群组同步播放' : '广播到群组')
                  : '需先加入群组',
              onPressed: inGroup
                  ? () => ref
                      .read(settingsProvider.notifier)
                      .update((p) => p.copyWith(
                          groupBroadcastMusic: !s.groupBroadcastMusic))
                  : null,
            );
          }),
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: '收藏地图',
            onPressed: () => context.push('/music/map'),
          ),
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: '音乐平台配置',
            onPressed: () => context.push('/music/sources'),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '搜索'),
            Tab(text: 'AI 歌单'),
            Tab(text: '我的收藏'),
          ],
        ),
      ),
      body: Column(
        children: [
          // Source-aware banner. Only shown when the user has picked GD;
          // for direct backends the source is shown via the dropdown
          // label and platform config page already.
          if (_source == 'gd')
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 4),
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHigh,
              child: Row(
                children: [
                  const Icon(Icons.library_music_outlined, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '数据来源：GD 音乐台 (music.gdstudio.xyz)',
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).hintColor),
                    ),
                  ),
                  Text('频率 ≤50 次/5 分钟',
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).hintColor)),
                ],
              ),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _buildSearchTab(),
                _buildAiTab(),
                _buildFavoritesTab(),
              ],
            ),
          ),
          if (_now != null) _buildPlayerBar(),
        ],
      ),
    );
  }

  Widget _buildSearchTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    hintText: '搜索歌名 / 歌手',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: _doSearch,
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _source,
                items: _sources
                    .map((s) =>
                        DropdownMenuItem(value: s, child: Text(_sourceLabels[s] ?? s)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _source = v);
                },
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(),
        Expanded(
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (_, i) {
              final t = _results[i];
              return ListTile(
                leading: const Icon(Icons.music_note),
                title: Text(t.name),
                subtitle: Text('${t.artist} · ${t.album}'),
                onTap: () => _play(t),
                onLongPress: () => _favorite(t),
                trailing: IconButton(
                  icon: const Icon(Icons.favorite_border),
                  onPressed: () => _favorite(t),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAiTab() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          TextField(
            controller: _moodCtrl,
            decoration: const InputDecoration(
              labelText: '现在的心情 / 路况 / 风景',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 8),
          // Wrap (not Row) so narrow screens reflow instead of overflowing.
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('源：'),
                  DropdownButton<String>(
                    value: _source,
                    isDense: true,
                    items: _sources
                        .map((s) => DropdownMenuItem(
                            value: s,
                            child: Text(_sourceLabels[s] ?? s)))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _source = v);
                    },
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('歌单：'),
                  DropdownButton<int>(
                    value: _aiPlaylistCount,
                    isDense: true,
                    items: const [5, 10, 15, 20, 25, 30]
                        .map((n) => DropdownMenuItem(
                            value: n, child: Text('$n 首')))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _aiPlaylistCount = v);
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          FilledButton.icon(
            icon: const Icon(Icons.auto_awesome),
            onPressed: _aiLoading ? null : _aiPlaylist,
            label: const Text('根据当前位置 + 心情生成歌单'),
          ),
          const SizedBox(height: 8),
          if (_results.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      icon: const Icon(Icons.playlist_play_rounded),
                      onPressed: _aiLoading ? null : _playAllResults,
                      label: Text('播放整张 (${_results.length} 首)'),
                    ),
                  ),
                ],
              ),
            ),
          if (_aiLoading) const LinearProgressIndicator(),
          if (_aiStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(4),
              child: Text(_aiStatus,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (_, i) {
                final t = _results[i];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.queue_music),
                  title: Text(t.name),
                  subtitle: Text(t.artist),
                  onTap: () => _play(t),
                  onLongPress: () => _favorite(t),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFavoritesTab() {
    final db = ref.watch(dbProvider);
    // TabBarView 只在滑到 / 切到这页时才 build 它，所以首次查询在这里懒建；
    // 之后 build 再跑多少次都复用同一个 future。
    return FutureBuilder<List<SongFavorite>>(
      future: _favsFuture ??= _queryFavorites(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final favs = snap.data!
            .where((f) => !_dismissedFavIds.contains(f.id))
            .toList();
        if (favs.isEmpty) {
          final cs = Theme.of(context).colorScheme;
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              PixelSprite(
                  rows: PixelSprites.note, color: cs.primary, cell: 5),
              const SizedBox(height: 12),
              const Text('还没有收藏，长按一首歌试试'),
            ]),
          );
        }
        return ListView.builder(
          itemCount: favs.length,
          itemBuilder: (_, i) {
            final f = favs[i];
            return Dismissible(
              key: ValueKey('fav-${f.id}'),
              direction: DismissDirection.endToStart,
              background: Container(color: Colors.red),
              onDismissed: (_) async {
                // 先把这行从列表里藏掉（Dismissible 要求回调一返回它就不在树里），
                // 再落库、重查。
                setState(() => _dismissedFavIds.add(f.id));
                // Tombstoning delete — survives future sync merges.
                await db.deleteSongFavoriteById(f.id);
                _reloadFavorites();
              },
              child: ListTile(
                leading: const Icon(Icons.favorite, color: Colors.red),
                title: Text(f.title),
                subtitle: Text(
                    '${f.artist} · ${f.source}${f.lat != null ? '  📍${f.lat!.toStringAsFixed(2)},${f.lng!.toStringAsFixed(2)}' : ''}'),
                onTap: () => _play(MusicTrack(
                  id: f.songId,
                  name: f.title,
                  artist: f.artist,
                  album: '',
                  source: f.source,
                )),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPlayerBar() {
    final svc = ref.read(musicServiceProvider);
    return SafeArea(
      top: false,
      child: Container(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.music_note),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_now!.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(_now!.artist,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            StreamBuilder<bool>(
              stream: svc.player.playingStream,
              builder: (_, snap) {
                final playing = snap.data ?? false;
                return IconButton(
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  onPressed: () async {
                    if (playing) {
                      await svc.pause();
                    } else {
                      await svc.resume();
                    }
                    setState(() {});
                  },
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.stop),
              onPressed: () async {
                await svc.stop();
                final s = ref.read(settingsProvider);
                if (s.groupBroadcastMusic && (s.groupId ?? '').isNotEmpty) {
                  try {
                    await ref.read(groupServiceProvider).sendMusicStop();
                  } catch (_) {}
                }
                if (mounted) setState(() => _now = null);
              },
            ),
            IconButton(
              icon: const Icon(Icons.favorite_border),
              onPressed: () => _favorite(_now!),
            ),
          ],
        ),
      ),
    );
  }
}
