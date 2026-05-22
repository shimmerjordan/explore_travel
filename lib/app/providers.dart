import 'dart:async';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/prefs.dart';
import '../models/models.dart' show GroupTransportX;
import '../data/db/database.dart';
import '../services/ai/ai_service.dart';
import '../services/fog/fog_engine.dart';
import '../services/group/group_service.dart';
import '../services/group/group_sync_controller.dart';
import '../services/location/location_service.dart';
import '../services/music/music_service.dart';
import '../services/p2p/crypto.dart';
import '../services/p2p/p2p_service.dart';
import '../services/webdav/webdav_service.dart';
import '../services/imghost/upload_queue.dart';
import '../services/backup/backup_service.dart';
import '../services/geo/geocoding_service.dart';
import '../services/geo/learned_regions.dart';

final prefsStoreProvider = Provider((_) => PrefsStore());

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  return SettingsNotifier(ref.read(prefsStoreProvider));
});

class SettingsNotifier extends StateNotifier<AppSettings> {
  final PrefsStore store;
  SettingsNotifier(this.store) : super(const AppSettings()) {
    _load();
  }
  Future<void> _load() async {
    var loaded = await store.load();
    // Ensure each device has a stable peer id used by GroupService.
    if (loaded.selfPeerId == null || loaded.selfPeerId!.isEmpty) {
      loaded = loaded.copyWith(selfPeerId: const Uuid().v4());
      await store.save(loaded);
    }
    state = loaded;
  }

  Future<void> update(AppSettings Function(AppSettings) f) async {
    state = f(state);
    await store.save(state);
  }
}

final dbProvider = Provider<AppDb>((ref) {
  final db = AppDb();
  ref.onDispose(() => db.close());
  return db;
});

final fogEngineProvider =
    Provider<FogEngine>((ref) => FogEngine(ref.watch(dbProvider)));

final locationServiceProvider = Provider((ref) => LocationService());

final aiServiceProvider = Provider((ref) => AiService());

final musicServiceProvider = Provider((ref) {
  final s = ref.watch(settingsProvider);
  final svc = MusicService(s.musicApiBase);
  svc.setCredentials(s.musicCredentials);
  return svc;
});

final learnedRegionsProvider =
    Provider<LearnedRegionsStore>((_) => LearnedRegionsStore());

/// Long-lived. Same shape as [uploadQueueProvider] — settings updates are
/// pushed in instead of rebuilding (cache lives on the instance).
final geocodingServiceProvider = Provider<GeocodingService>((ref) {
  final svc = GeocodingService(
      ref.read(settingsProvider), ref.read(learnedRegionsProvider));
  ref.listen<AppSettings>(settingsProvider, (_, next) => svc.updateSettings(next));
  return svc;
});

/// Long-lived. Settings updates are pushed into the queue via `updateSettings`
/// so we don't recreate it (and lose in-flight uploads) on every prefs tick.
final uploadQueueProvider = Provider<UploadQueue>((ref) {
  final q = UploadQueue(
    ref.read(dbProvider),
    ref.read(settingsProvider),
    geocoding: ref.read(geocodingServiceProvider),
  );
  ref.listen<AppSettings>(settingsProvider, (_, next) => q.updateSettings(next));
  return q;
});

final backupServiceProvider =
    Provider<BackupService>((ref) => BackupService(ref.read(dbProvider)));

final webdavServiceProvider = Provider<WebDavService>((ref) {
  final s = ref.watch(settingsProvider);
  final svc = WebDavService();
  svc.configure(s);
  return svc;
});

final p2pServiceProvider = Provider<P2PService>((ref) {
  final s = ref.watch(settingsProvider);
  final crypto = (s.p2pPassphrase == null || s.p2pPassphrase!.isEmpty)
      ? null
      : P2PCrypto.fromPassphrase(s.p2pPassphrase!);
  return P2PService(s.displayName, crypto: crypto);
});

/// Live state shared with map screen for rendering peer trails.
final groupPeersProvider =
    StateProvider<List<GroupPeer>>((ref) => const []);

/// History of points per peer id, for trail rendering. Pruned to last 200.
final groupTrailsProvider =
    StateProvider<Map<String, List<List<double>>>>((ref) => {});

/// Owns the group service lifecycle, *creates* the service, fans messages
/// into the global streams. Lives at app scope — independent of any screen.
/// Auto-starts when settings have a groupId and [AppSettings.groupAutoConnect]
/// is on.
///
/// Service ownership is here on purpose: an earlier design had a separate
/// `groupServiceProvider` that watched the whole [settingsProvider], which
/// rebuilt the service on every unrelated setting change (e.g. fog color),
/// disposing the running one while the UI still believed it was online.
final groupLifecycleProvider = Provider<GroupLifecycle>((ref) {
  final ctrl = GroupLifecycle(ref);
  ref.onDispose(ctrl.dispose);
  return ctrl;
});

/// Read-side accessor for the current service. Returns whatever the
/// lifecycle is holding right now — a no-op if nothing is running. Always
/// safe to call.
///
/// Watches [groupRunningProvider] so it rebuilds every time the lifecycle
/// flips state (start / stop / restart on identity change). Without this
/// the Provider would memoize and callers would keep seeing the stale
/// `_noop` instance from app launch even after `start()` produced a real
/// service.
final groupServiceProvider = Provider<GroupService>((ref) {
  ref.watch(groupRunningProvider);
  return ref.read(groupLifecycleProvider).service;
});

/// Public chat log (broadcast messages). Per-peer private chat lives in its
/// own provider below.
final groupChatLogProvider =
    StateProvider<List<GroupMessage>>((ref) => const []);

/// Private chat logs keyed by the *other* peer id. So if two peers talk
/// privately, both sides look it up under each other's peerId.
final privateChatLogProvider =
    StateProvider<Map<String, List<GroupMessage>>>((ref) => const {});

/// Whether the group service is currently running (drives the chat-page
/// connect/disconnect indicator and the setup-screen banner).
final groupRunningProvider = StateProvider<bool>((ref) => false);

class GroupLifecycle {
  final Ref ref;
  GroupService? _svc;
  bool _started = false;

  /// Fallback returned by [service] when nothing is running. Re-used so the
  /// reference stays stable across calls.
  static final GroupService _noop = GroupService.create(
    transport: 0,
    selfId: 'noop',
    selfName: '',
    groupId: '',
    selfColor: 0,
  );

  /// The active service, or a no-op if not running. Always non-null; callers
  /// never have to null-check. Methods on the no-op are safe to call (they
  /// just do nothing and return empty streams).
  GroupService get service => _svc ?? _noop;

  GroupLifecycle(this.ref) {
    ref.listen<AppSettings>(settingsProvider, (prev, next) {
      _react(prev, next);
    });
    Future.microtask(() => _react(null, ref.read(settingsProvider)));
  }

  Future<void> _react(AppSettings? prev, AppSettings next) async {
    final wantRun =
        next.groupAutoConnect && (next.groupId ?? '').isNotEmpty;
    // Any of these fields means the wire identity changes, so we need a
    // fresh service instance.
    final identityChanged = prev != null &&
        (prev.groupTransport != next.groupTransport ||
            prev.groupId != next.groupId ||
            prev.p2pPassphrase != next.p2pPassphrase ||
            prev.selfPeerId != next.selfPeerId ||
            prev.displayName != next.displayName ||
            prev.webdavUrl != next.webdavUrl ||
            prev.webdavUser != next.webdavUser ||
            prev.webdavPass != next.webdavPass ||
            prev.webrtcSignalingPath != next.webrtcSignalingPath ||
            prev.webrtcSignalingPollSec != next.webrtcSignalingPollSec ||
            prev.webrtcIceServers != next.webrtcIceServers ||
            prev.lanScanIp != next.lanScanIp ||
            prev.lanScanCidrBits != next.lanScanCidrBits);
    if (identityChanged && _started) {
      await stop();
    }
    if (wantRun && !_started) {
      await start();
    } else if (!wantRun && _started) {
      await stop();
    }
  }

  /// Build a fresh service from the current settings snapshot.
  GroupService _build() {
    final s = ref.read(settingsProvider);
    final crypto = (s.p2pPassphrase == null || s.p2pPassphrase!.isEmpty)
        ? null
        : P2PCrypto.fromPassphrase(s.p2pPassphrase!);
    return GroupService.create(
      transport: s.groupTransport.canonical.index,
      selfId: s.selfPeerId ?? 'pending',
      selfName: s.displayName,
      groupId: s.groupId ?? '',
      selfColor: groupPalette[0],
      crypto: crypto,
      lanScanIp: s.lanScanIp,
      lanScanCidrBits: s.lanScanCidrBits,
      webdavUrl: s.webdavUrl,
      webdavUser: s.webdavUser,
      webdavPass: s.webdavPass,
      signalingPath: s.webrtcSignalingPath,
      pollSec: s.webrtcSignalingPollSec,
      iceServers: s.webrtcIceServers,
    );
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    final svc = _build();
    _svc = svc;
    try {
      await svc.start();
    } catch (e) {
      _started = false;
      _svc = null;
      ref.read(groupRunningProvider.notifier).state = false;
      return;
    }
    ref.read(groupRunningProvider.notifier).state = true;
    svc.peers.listen((peers) {
      ref.read(groupPeersProvider.notifier).state = peers;
    });
    svc.messages.listen(_onMessage);
    try {
      ref.read(groupSyncControllerProvider).attach(svc.messages);
    } catch (_) {}
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    ref.read(groupRunningProvider.notifier).state = false;
    try {
      await _svc?.stop();
    } catch (_) {}
    _svc = null;
    ref.read(groupPeersProvider.notifier).state = const [];
  }

  void _onMessage(GroupMessage m) {
    // Trail history for location pings.
    if (m.type == 'location') {
      final lat = (m.data['lat'] as num?)?.toDouble();
      final lng = (m.data['lng'] as num?)?.toDouble();
      if (lat != null && lng != null) {
        // 1) live in-memory trail (rendered on the map immediately)
        final trails = {...ref.read(groupTrailsProvider)};
        final list = <List<double>>[...(trails[m.fromId] ?? const [])];
        list.add(<double>[lat, lng]);
        if (list.length > 200) list.removeRange(0, list.length - 200);
        trails[m.fromId] = list;
        ref.read(groupTrailsProvider.notifier).state = trails;
        // 2) persisted history (used by playback to rewind peer trails
        //    long after the session ended). Best-effort — failure here
        //    must not break the live render path.
        final db = ref.read(dbProvider);
        final peerName = (m.data['name'] as String?) ?? '';
        unawaited(db.into(db.peerLocations).insert(
              PeerLocationsCompanion.insert(
                peerId: m.fromId,
                peerName: Value(peerName),
                lat: lat,
                lng: lng,
                time: DateTime.now(),
              ),
            ));
      }
      return;
    }
    // Only true user messages get logged. hello/voice/voice_end/music_*
    // are wire-level signalling; they have no place in the chat history.
    if (m.type != 'chat') return;
    // Chat. Private messages go into [privateChatLogProvider] under the
    // other peer's id; public ones into [groupChatLogProvider].
    final to = m.data['to'];
    final isPrivate = to is String && to.isNotEmpty;
    if (isPrivate) {
      final logs = {...ref.read(privateChatLogProvider)};
      final list = <GroupMessage>[...(logs[m.fromId] ?? const [])];
      list.add(m);
      if (list.length > 500) list.removeRange(0, list.length - 500);
      logs[m.fromId] = list;
      ref.read(privateChatLogProvider.notifier).state = logs;
    } else {
      final log = <GroupMessage>[...ref.read(groupChatLogProvider)];
      log.add(m);
      if (log.length > 500) log.removeRange(0, log.length - 500);
      ref.read(groupChatLogProvider.notifier).state = log;
    }
  }

  void dispose() {
    stop();
  }
}

final layersProvider = StreamProvider((ref) => ref.watch(dbProvider).watchLayers());

/// Raw stored value — defaults to 1 (id of the auto-created default layer
/// on a fresh DB). Callers should normally read [effectiveActiveLayerId]
/// instead, which auto-corrects when the stored value points at a
/// nonexistent / hidden layer.
final activeLayerIdProvider = StateProvider<int>((ref) => 1);

/// The "real" active layer id used by recording + manual reveal. If the
/// stored [activeLayerIdProvider] points at a layer that:
///   * doesn't exist (e.g. user deleted it, or had a stale default from
///     before they created their own layer), OR
///   * exists but is currently invisible (so its fog wouldn't render),
/// this provider falls back to the first **visible** layer's id. This
/// fixes a long-standing bug where recording was silently writing to
/// layer id=1 while only layer id=10 was actually visible — the fog
/// existed in DB but never appeared.
final effectiveActiveLayerIdProvider = Provider<int>((ref) {
  final raw = ref.watch(activeLayerIdProvider);
  final layersAsync = ref.watch(layersProvider);
  // Explicit type — otherwise the orElse callback's return type is `dynamic`,
  // which makes `layers.firstWhere(... orElse: () => layers.first)` blow up
  // at runtime with "() => dynamic is not a subtype of (() => TrackLayer)?".
  final List<TrackLayer> layers = layersAsync.maybeWhen(
    data: (rows) => rows,
    orElse: () => const <TrackLayer>[],
  );
  if (layers.isEmpty) return raw;
  if (layers.any((l) => l.id == raw && l.visible)) return raw;
  // Prefer first visible; if none visible, first existing.
  final firstVisible =
      layers.firstWhere((l) => l.visible, orElse: () => layers.first);
  return firstVisible.id;
});

/// Counter that bumps whenever fog tiles are written; used to invalidate cache.
final fogRefreshProvider = StateProvider<int>((ref) => 0);

/// Last position rendered as the user's "current location pin" on the map.
/// Updated by [MapScreen]'s location-stream listener (and by the debug
/// simulator). Other screens — notably the journal editor — read this so
/// "create at my current location" picks the simulated/walked position
/// instead of forcing a fresh GPS read.
final currentDisplayPositionProvider =
    StateProvider<({double lat, double lng})?>((ref) => null);
