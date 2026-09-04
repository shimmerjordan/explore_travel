// 从 map_screen.dart 拆出（纯搬迁，无行为改动）。
// 队友与自己的身份呈现：头像缓存、队友标记/轨迹、个人卡与等级。
part of 'map_screen.dart';

// ════════════════════════════════════════════════════════════════════════
// Profile chip top-right + expanded stats sheet (FOW continent card style)
// ════════════════════════════════════════════════════════════════════════

class _ProfileCard extends ConsumerWidget {
  final VoidCallback onTap;
  const _ProfileCard({required this.onTap});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: [
              _SelfAvatar(
                radius: 16,
                b64: s.avatarBase64,
                seed: s.selfPeerId ?? s.displayName,
              ),
              const SizedBox(width: 8),
              Text(s.displayName,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
              const SizedBox(width: 8),
              const Icon(Icons.expand_more_rounded,
                  color: Colors.white70, size: 18),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String value;
  final String label;
  const _StatTile(this.value, this.label);
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        children: [
          // Stats are collection numbers — pixel display face.
          Text(value,
              style: PixelText.label
                  .copyWith(fontSize: 16, color: Colors.white)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(color: Colors.white60, fontSize: 11)),
        ],
      ),
    );
  }
}

/// 头像 base64 → 已解码 [MemoryImage] 的进程级缓存。
///
/// MemoryImage 的相等性按字节数组**实例**比较：每次 build 里 base64.decode
/// 出来的都是新数组 → ImageCache 必定 miss → 队友 marker 每重建一次就把
/// JPEG 完整重解一遍（组队时每来一条位置消息就重建一轮）。这里按「串长:哈希」
/// 取键复用同一个实例，让 ImageCache 命中。条目超过 64 就整个清掉——队友数
/// 远到不了这个量级，纯防泄漏。坏 base64 返回 null，调用方回退到彩色首字母。
final Map<String, MemoryImage> _avatarImageCache = {};
MemoryImage? _cachedAvatarImage(String b64) {
  if (b64.isEmpty) return null;
  final key = '${b64.length}:${b64.hashCode}';
  final hit = _avatarImageCache[key];
  if (hit != null) return hit;
  try {
    final img = MemoryImage(base64.decode(b64));
    if (_avatarImageCache.length >= 64) _avatarImageCache.clear();
    _avatarImageCache[key] = img;
    return img;
  } catch (_) {
    return null;
  }
}

class _PeerTrailsLayer extends ConsumerWidget {
  final LatLng Function(double, double) toDisplay;
  const _PeerTrailsLayer({required this.toDisplay});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peers = ref.watch(groupPeersProvider);
    final trails = ref.watch(groupTrailsProvider);
    // 只订阅队友覆盖项：整份 settings 里主题 / 地图源 / AI 配置随便动一项都会
    // notify，没必要为此把全部队友轨迹重画一遍。PeerOverrideX 的解析规则只
    // 依赖 peerOverrides，用一个只带该字段的壳复用它，免得在这儿再抄一份
    // visible / color / name 的解析。
    final overrides =
        ref.watch(settingsProvider.select((s) => s.peerOverrides));
    final s = AppSettings(peerOverrides: overrides);
    if (peers.isEmpty) return const SizedBox.shrink();
    // 「多久没联系」的判定基准一层算一次，不在每个 marker 里各取一次 now。
    final now = DateTime.now();
    // Look up the peer's avatar from the leaderboard — entries are signed
    // snapshots that travel on the same mesh as locations, so by the time a
    // peer is on the map their avatar (if they set one) is already in our
    // local store. Self peers won't be here but they're not rendered as
    // remote markers anyway.
    final lbEntries = ref.read(leaderboardServiceProvider).current;
    final lines = <Polyline>[];
    final markers = <Marker>[];
    for (final p in peers) {
      if (!s.peerVisible(p.id)) continue;
      final color = Color(s.peerColor(p.id) ?? p.colorValue);
      final name = s.peerName(p.id) ?? p.name;
      // 一个队友一条 3 px 折线（与回放页的队友轨迹同款）。以前是每个历史点
      // 一个带边框的 CircleMarker：≤200 点/人 = 每帧几百个圆 + 边框各画一遍，
      // 拖图时肉眼可见掉帧；一条折线只是一条 path。
      final hist = trails[p.id] ?? const [];
      if (hist.length >= 2) {
        lines.add(Polyline(
          points: [for (final c in hist) toDisplay(c[0], c[1])],
          color: color.withValues(alpha: 0.85),
          strokeWidth: 3,
        ));
      }
      if (p.lat != null && p.lng != null) {
        final entry = lbEntries.where((e) => e.peerId == p.id).firstOrNull;
        markers.add(Marker(
          point: toDisplay(p.lat!, p.lng!),
          width: 44,
          height: 44,
          child: _PeerMarker(
            peer: p,
            color: color,
            name: name,
            now: now,
            avatarB64: entry?.avatarBase64 ?? '',
          ),
        ));
      }
    }
    return Stack(
      children: [
        if (lines.isNotEmpty) PolylineLayer(polylines: lines),
        if (markers.isNotEmpty) MarkerLayer(markers: markers),
      ],
    );
  }
}

class _PeerMarker extends StatelessWidget {
  final GroupPeer peer;
  final Color color;
  final String name;
  /// 由所在图层统一传入（见 _PeerTrailsLayer），而不是每个 marker 各自取。
  final DateTime now;
  final String avatarB64;
  const _PeerMarker(
      {required this.peer,
      required this.color,
      required this.name,
      required this.now,
      this.avatarB64 = ''});
  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : name.characters.first;
    final age = now.difference(peer.lastSeen);
    final stale = age > const Duration(seconds: 30);
    final base = color;
    final shown = stale ? base.withValues(alpha: 0.45) : base;
    // 解码走进程级缓存（见 _cachedAvatarImage）；坏 base64 静默回退到彩色
    // 首字母气泡，一条畸形的队友记录不能把地图渲染路径打崩。
    final avatar = _cachedAvatarImage(avatarB64);
    final avatarImg = avatar == null
        ? null
        : DecorationImage(image: avatar, fit: BoxFit.cover);
    return Tooltip(
      message: stale ? '$name · ${age.inSeconds}s 未联系' : name,
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          Container(
            decoration: BoxDecoration(
              color: avatarImg == null ? shown : null,
              image: avatarImg,
              shape: BoxShape.circle,
              border: Border.all(color: stale ? Colors.grey : shown, width: 3),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4), blurRadius: 6),
              ],
            ),
            alignment: Alignment.center,
            child: avatarImg != null
                ? null
                : Text(initial,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
          ),
          if (!stale)
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: const Color(0xFF4CAF50),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}

/// Circular avatar used in the map's profile sheet. Same fallback logic
/// the leaderboard + peer markers use, so the user looks identical
/// everywhere.
class _SelfAvatar extends StatelessWidget {
  final double radius;
  final String b64;
  final String seed;
  const _SelfAvatar(
      {required this.radius, required this.b64, required this.seed});
  @override
  Widget build(BuildContext context) {
    // 与队友头像共用解码缓存：_ProfileCard 订阅整份 settings，随便一项变动
    // 都会重建到这里，不缓存就是每次重解一遍 JPEG。
    final avatar = _cachedAvatarImage(b64);
    if (avatar != null) {
      return CircleAvatar(radius: radius, backgroundImage: avatar);
    }
    final hue = (seed.hashCode % 360).abs().toDouble();
    return CircleAvatar(
      radius: radius,
      backgroundColor: HSLColor.fromAHSL(1, hue, 0.55, 0.55).toColor(),
      child: Text(
        seed.isEmpty ? '?' : seed.characters.first.toUpperCase(),
        style: TextStyle(
            color: Colors.white,
            fontSize: radius * 0.8,
            fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Exploration level derived from the total explored *path area* (km²).
/// Thresholds grow triangularly — reaching level L needs
/// `base · L·(L−1)/2` km² — so early levels come from a walk or two and
/// later ones take real exploring.
const double _kLevelBaseKm2 = 0.5; // km² for the first level-up

class _LevelInfo {
  final int level;
  final double progress; // 0..1 within the current level
  final double remaining; // km² still needed for the next level
  const _LevelInfo(this.level, this.progress, this.remaining);
}

_LevelInfo _levelForArea(double km2) {
  final a = km2 < 0 ? 0.0 : km2;
  double reqToReach(int l) => _kLevelBaseKm2 * l * (l - 1) / 2;
  var level = ((1 + math.sqrt(1 + 8 * a / _kLevelBaseKm2)) / 2).floor();
  if (level < 1) level = 1;
  final reqCur = reqToReach(level);
  final reqNext = reqToReach(level + 1);
  final span = reqNext - reqCur;
  final progress = span <= 0 ? 0.0 : ((a - reqCur) / span).clamp(0.0, 1.0);
  final remaining = (reqNext - a).clamp(0.0, reqNext);
  return _LevelInfo(level, progress.toDouble(), remaining.toDouble());
}

/// Format a km² area for display, dropping to m² when it's tiny so a short
/// trip doesn't read as "0.00 km²".
String _fmtArea(double km2) {
  if (km2 < 0.1) return '${(km2 * 1e6).toStringAsFixed(0)} m²';
  if (km2 < 100) return '${km2.toStringAsFixed(2)} km²';
  return '${km2.toStringAsFixed(0)} km²';
}
