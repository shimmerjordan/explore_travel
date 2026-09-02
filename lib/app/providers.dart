import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto_hash;
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';
import '../core/prefs.dart';
import '../models/models.dart' show GroupTransportX;
import '../data/db/database.dart';
import '../services/ai/ai_service.dart';
import '../services/ai/companion_controller.dart';
import '../services/ai/stt_service.dart';
import '../services/ai/tts_service.dart';
import '../services/fog/fog_engine.dart';
import '../services/group/group_service.dart';
import '../services/group/group_sync_controller.dart';
import '../services/location/location_service.dart';
import '../services/music/music_service.dart';
import '../services/p2p/crypto.dart';
import '../services/p2p/p2p_service.dart';
import '../services/webdav/webdav_service.dart';
import '../services/sync/sync_storage.dart';
import '../services/sync/onedrive_service.dart';
import '../services/sync/github_sync_storage.dart';
import '../services/sync/webdav_sync_storage.dart';
import '../services/vault/config_sync_controller.dart';
import '../services/imghost/upload_queue.dart';
import '../services/backup/backup_service.dart';
import '../services/geo/coord_converter.dart';
import '../services/geo/geocoding_service.dart';
import '../services/geo/learned_regions.dart';
import '../services/leaderboard/leaderboard_service.dart';
import '../services/leaderboard/leaderboard_sync.dart';
import '../services/visits/visit_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

final prefsStoreProvider = Provider((_) => PrefsStore());

/// Read-only "memory / 回忆" mode. ON for web (the web build is a viewer, not a
/// recorder), OFF for native. When on, recording / capture / P2P affordances
/// are hidden and the recording pipeline refuses to start at the source.
///
/// **Backdoor**: enabling debug mode disables read-only — so a developer can
/// unlock recording/editing on web by toggling debug mode (tap the version
/// label 10× on the menu screen). `&&` short-circuits on native, so this never
/// reads settings there (and stays test-safe).
final viewOnlyProvider =
    Provider<bool>((ref) => kIsWeb && !ref.watch(settingsProvider).debugMode);

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
    // Stamp AFTER the disk read so style consumers (fog veil, trail widths)
    // can hold rendering until real values are in — otherwise the first
    // frames flash the default veil colour / 14 m trail width.
    state = loaded.copyWith(loaded: true);
    CoordConverter.ovitalUsesGcj02 = state.ovitalGcj02;
  }

  Future<void> update(AppSettings Function(AppSettings) f) async {
    state = f(state);
    CoordConverter.ovitalUsesGcj02 = state.ovitalGcj02;
    await store.save(state);
  }

  /// Re-read settings from disk. A backup/sync import writes
  /// `app_settings_v1` directly to prefs behind this notifier's back — until
  /// reload the in-memory state (and everything watching it, like the
  /// OneDrive "connected" flag) kept showing pre-import values, and the next
  /// settings edit would even write the stale state back over the import.
  Future<void> reload() => _load();
}

final dbProvider = Provider<AppDb>((ref) {
  final db = AppDb();
  ref.onDispose(() => db.close());
  return db;
});

/// Startup maintenance run once from the app's post-frame callback (not from
/// [dbProvider], so the provider stays side-effect-free): self-heal a
/// layer-less-but-content-full DB — every render layer is layer-driven, so
/// content whose layers got wiped shows a blank map until this recreates
/// them — then log a one-line row-count probe. The probe splits "synced but
/// nothing shows" in one look: zeros → the data never landed (sync); non-zero
/// → data is here and RENDERING is what's off.
Future<void> runStartupDbMaintenance(AppDb db) async {
  try {
    final fixedIds = await db.backfillMissingUuids();
    if (fixedIds > 0) {
      debugPrint('[DB] backfilled $fixedIds missing uuid(s)');
    }
    final healed = await db.ensureLayersForContent();
    if (healed > 0) {
      debugPrint('[DB] recreated $healed orphaned layer(s) on startup');
    }
    Future<int> count(String t, [String where = '']) async =>
        (await db.customSelect('SELECT COUNT(*) c FROM $t $where').getSingle())
            .read<int>('c');
    debugPrint('[DB] rows — journal=${await count('journal_entries')} '
        'layers=${await count('track_layers')} '
        'points=${await count('track_points')} '
        'fog=${await count('fog_tiles')} '
        'chat=${await count('chat_messages')} '
        'favorites=${await count('song_favorites')}');
    // uuid coverage on the two identity-critical, low-volume tables — a
    // non-zero "no-uuid" count means sync identity is broken for those rows.
    debugPrint('[DB] no-uuid — '
        "journal=${await count('journal_entries', "WHERE uuid IS NULL OR uuid=''")} "
        "layers=${await count('track_layers', "WHERE uuid IS NULL OR uuid=''")}");
  } catch (e) {
    debugPrint('[DB] startup self-heal/probe failed: $e');
  }
}

final fogEngineProvider =
    Provider<FogEngine>((ref) => FogEngine(ref.watch(dbProvider)));

final locationServiceProvider = Provider((ref) => LocationService());

final aiServiceProvider = Provider((ref) => AiService());

final sttServiceProvider = Provider((ref) => SttService());
final ttsServiceProvider = Provider((ref) => TtsService());

/// 地图页 AI 旅伴。挂全局：卡片最小化 / 切页面时通话与流式回复继续跑。
final companionProvider =
    ChangeNotifierProvider<CompanionController>((ref) {
  final c = CompanionController(
    ai: ref.read(aiServiceProvider),
    stt: ref.read(sttServiceProvider),
    tts: ref.read(ttsServiceProvider),
    settingsOf: () => ref.read(settingsProvider),
    geocodingOf: () => ref.read(geocodingServiceProvider),
  );
  // NOTE: no ref.onDispose(c.dispose) here — ChangeNotifierProvider already
  // disposes its notifier on teardown; doing it again threw
  // "used after being disposed" whenever the container shut down.
  return c;
});

final musicServiceProvider = Provider((ref) {
  final s = ref.watch(settingsProvider);
  final svc = MusicService(s.musicApiBase);
  svc.setCredentials(s.musicCredentials);
  return svc;
});

final learnedRegionsProvider =
    Provider<LearnedRegionsStore>((_) => LearnedRegionsStore());

/// Stay detection → visits/places. Long-lived; geocodes new places through
/// the shared [GeocodingService] (network only if the user allowed prewarm
/// geocoding — detection must never spend the data plan on its own).
final visitEngineProvider = Provider<VisitEngine>((ref) {
  final engine = VisitEngine(
    ref.read(dbProvider),
    geocoder: (lat, lng) => ref.read(geocodingServiceProvider).resolve(lat, lng,
        allowNetwork: ref.read(settingsProvider).geocodingPrewarm),
  );
  final sub = engine.changes
      .listen((_) => ref.read(visitsRefreshProvider.notifier).state++);
  ref.onDispose(() {
    sub.cancel();
    engine.dispose();
  });
  return engine;
});

/// Bumped whenever visits/places change (detection run, user edit) so the
/// timeline and stats pages refresh.
final visitsRefreshProvider = StateProvider<int>((ref) => 0);

/// One-shot: the first launch after the visits feature lands walks the whole
/// history (month by month, off the UI isolate). Subsequent launches do
/// nothing — recording stops and imports keep the table current.
Future<void> runInitialVisitDetection(VisitEngine engine) async {
  const key = 'visits_initial_v1';
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(key) == true) return;
    final n = await engine.detectAll();
    await prefs.setBool(key, true);
    debugPrint('[VISITS] initial full-history detection: $n visits');
  } catch (e) {
    debugPrint('[VISITS] initial detection failed: $e');
  }
}

/// Where the map should fly next (a visit, a place). Consumed once by the
/// map screen, like [fogImportFocusProvider] but with a caller-chosen zoom.
final mapFocusProvider =
    StateProvider<({double lat, double lng, double zoom})?>((ref) => null);

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

final backupServiceProvider = Provider<BackupService>((ref) => BackupService(
      ref.read(dbProvider),
      leaderboard: ref.read(leaderboardServiceProvider),
    ));

final webdavServiceProvider = Provider<WebDavService>((ref) {
  final s = ref.watch(settingsProvider);
  final svc = WebDavService();
  svc.configure(s);
  return svc;
});

/// The active sync transport for [SyncEngine], chosen by
/// [AppSettings.syncBackend]. OneDrive is the default so existing installs and
/// mobile are unchanged.
///
/// On web the credential (e.g. a GitHub PAT) lives only in memory — it comes
/// from the config the console hands out at login and is NEVER persisted (see
/// [PrefsStore] web hygiene). So GitHub is a valid web transport (its API sends
/// CORS headers). Direct WebDAV from a browser is usually CORS-blocked and will
/// fail at call time (the login flow treats sync failures as non-fatal,
/// local-first); routing it through the console's proxy is future work.
///
/// `default` is not decoration: [AppSettings.syncBackend] is a free-form string
/// read straight out of persisted JSON, so an install left holding a value this
/// build no longer knows lands here and syncs against OneDrive instead of
/// throwing.
final syncStorageProvider = Provider<SyncStorage>((ref) {
  final s = ref.watch(settingsProvider);
  switch (s.syncBackend) {
    case SyncBackend.github:
      return GithubSyncStorage.fromSettings(s);
    case SyncBackend.webdav:
      return WebdavSyncStorage(ref.watch(webdavServiceProvider));
    case SyncBackend.onedrive:
    default:
      return ref.watch(oneDriveServiceProvider);
  }
});

/// App-scoped controller for the console's settings config (login / push /
/// pull). Long-lived so its session token + debounce survive navigation.
final configSyncControllerProvider = Provider<ConfigSyncController>((ref) {
  final c = ConfigSyncController(ref);
  ref.onDispose(c.dispose);
  return c;
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
            prev.lanScanCidrBits != next.lanScanCidrBits ||
            prev.relayServerUrl != next.relayServerUrl ||
            prev.relayToken != next.relayToken);
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
      frpServerAddr: s.frpServerAddr ?? '',
      frpServerPort: s.frpServerPort,
      frpToken: s.frpToken,
      frpProtocol: s.frpProtocol,
      // XTCP `sk` gates who may hole-punch into a member's proxy. Derive it
      // from the shared passphrase + group id so only members can punch in;
      // both sides compute the same value with no extra config.
      frpSecretKey: _frpSecretKey(s.p2pPassphrase, s.groupId ?? ''),
      frpDashboardUrl: s.frpDashboardUrl,
      frpDashboardUser: s.frpDashboardUser,
      frpDashboardPass: s.frpDashboardPass,
      relayServerUrl: s.relayServerUrl ?? '',
      relayToken: s.relayToken,
    );
  }

  static String _frpSecretKey(String? passphrase, String groupId) {
    final seed = '${passphrase ?? ''}|$groupId|ej-xtcp';
    return crypto_hash.sha256
        .convert(utf8.encode(seed))
        .toString()
        .substring(0, 32);
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
    // Wire leaderboard auto-merge over the same transport. Ed25519 keys
    // and the local entry are bootstrapped on settings load via
    // [leaderboardServiceProvider] — by the time the group is up, the
    // service is already populated.
    try {
      ref.read(leaderboardSyncProvider).attach(svc);
    } catch (_) {}
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    ref.read(groupRunningProvider.notifier).state = false;
    try {
      ref.read(leaderboardSyncProvider).detach();
    } catch (_) {}
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

/// Counter that bumps whenever journal entries are created, imported, edited
/// or deleted. The map listens to this to refresh its journal pins — without
/// it, entries added from another screen (the journal list's photo import, a
/// backup restore) land in the DB but the map's cached pin list goes stale
/// and they silently never appear as pins.
final journalRefreshProvider = StateProvider<int>((ref) => 0);

/// When a FOW import finishes, the centre (WGS-84) of the imported fog. The
/// map watches this and flies there so the freshly-revealed region is on
/// screen. FoW Sync data carries ONLY the fog bitmap (no GPS tracks), so the
/// only visible effect of an import is cleared fog — which is otherwise easy
/// to miss when it's far from the user's current location. Reset to null
/// after the map has moved.
final fogImportFocusProvider = StateProvider<LatLng?>((ref) => null);

/// Last position rendered as the user's "current location pin" on the map.
/// Updated by [MapScreen]'s location-stream listener (and by the debug
/// simulator). Other screens — notably the journal editor — read this so
/// "create at my current location" picks the simulated/walked position
/// instead of forcing a fresh GPS read.
final currentDisplayPositionProvider =
    StateProvider<({double lat, double lng})?>((ref) => null);

/// Singleton — loaded once on first read; subsequent reads share the same
/// in-memory map of entries.
final leaderboardServiceProvider = Provider<LeaderboardService>((ref) {
  final svc = LeaderboardService();
  // Fire load; UI listens via [leaderboardEntriesProvider].
  unawaited(svc.load());
  // Ensure the local device has a keypair. Generated lazily on first run
  // so a fresh install gets one without needing user interaction.
  Future.microtask(() async {
    final s = ref.read(settingsProvider);
    if (s.leaderboardPrivateKey.isEmpty || s.leaderboardPublicKey.isEmpty) {
      final kp = await svc.generateKeyPair();
      ref.read(settingsProvider.notifier).update((p) => p.copyWith(
            leaderboardPrivateKey: kp.privateKey,
            leaderboardPublicKey: kp.publicKey,
          ));
    }
  });
  return svc;
});

/// Bridges the LeaderboardService onto the active GroupService.
final leaderboardSyncProvider = Provider<LeaderboardSync>((ref) {
  final svc = ref.watch(leaderboardServiceProvider);
  final sync = LeaderboardSync(svc);
  ref.onDispose(sync.detach);
  return sync;
});

/// Watchable stream of the merged leaderboard, for UI.
final leaderboardEntriesProvider = StreamProvider((ref) {
  final svc = ref.watch(leaderboardServiceProvider);
  return svc.watch;
});
