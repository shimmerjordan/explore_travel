import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';

class AppSettings {
  final MapProvider mapProvider;
  final MapStyle mapStyle;
  final RecordingMode recordingMode;
  final int fogColor; // ARGB
  final double fogOpacity; // 0..1
  final double fogPenRadius; // meters
  final String? amapApiKey;
  final String? googleMapKey;
  /// Optional override URL template for OSM/raster tiles, used when the
  /// default tile.openstreetmap.org server is unreachable (it often is
  /// from China). Supports {z}/{x}/{y} placeholders.
  final String? customOsmTileUrl;
  final String? aiBaseUrl;
  final String? aiApiKey;
  final String aiModel;
  final String musicApiBase;
  final String? webdavUrl;
  final String? webdavUser;
  final String? webdavPass;
  final bool autoBackup;
  final String? zerotierNetworkId;
  final String displayName;
  final String? p2pPassphrase;
  final String? groupId;
  final String? selfPeerId;
  final bool groupBroadcastMusic;
  final bool groupFollowMusic;
  final GroupTransport groupTransport;
  /// When true, the group service auto-starts on app launch (and persists
  /// across navigation — the chat screen does not own its lifecycle). Map
  /// screen keeps showing peer trails as long as this is on.
  final bool groupAutoConnect;
  /// Which local IP to base the active LAN scan on. Empty = all private
  /// interfaces (and we'll only walk a /24 around each). Pin this to your
  /// ZeroTier interface IP so the scan doesn't poke your Wi-Fi neighbours.
  final String? lanScanIp;
  /// Per-music-platform credentials. Stored opaquely (Cookie / token /
  /// username:password) — actual direct integration with each backend is
  /// future work; today the music screen still resolves everything through
  /// GD 音乐台. Kept here so when direct backends land we don't have to
  /// migrate user data.
  /// Shape: { 'netease': '...', 'spotify': 'Bearer ...', ... }
  final Map<String, String> musicCredentials;

  /// Per-peer display overrides keyed by peer id.
  /// Each value: { 'color': ARGB int?, 'visible': bool?, 'name': String? }
  /// Used by the members list + map trails to let the user rename / recolor
  /// / hide individual peers.
  final Map<String, Map<String, dynamic>> peerOverrides;
  /// CIDR prefix bits for the active scan. 24 (default, 254 hosts, ~5s),
  /// 22 (~1k, ~30s), 20 (~4k, ~2min), 16 (~65k, ~20min). Anything below 24
  /// is treated as a "big scan" — runs only when manually triggered.
  final int lanScanCidrBits;
  /// WebDAV subpath used as a "mailbox" for WebRTC signaling. Reuses the
  /// regular [webdavUrl] + credentials. Each peer drops SDP/ICE files under
  /// `<signalingPath>/<groupId>/<toPeerId>/` and polls its own subdir.
  final String webrtcSignalingPath;
  /// How often (seconds) to poll the WebDAV mailbox for new signaling
  /// messages. Lower = snappier connect, higher = friendlier to providers
  /// with strict rate limits (坚果云 etc).
  final int webrtcSignalingPollSec;
  /// Comma-separated STUN/TURN URLs. Public Google STUN is fine for casual
  /// use, but cross-NAT may need TURN.
  final String webrtcIceServers;

  // ── Image host (for journal photos) ───────────────────────────────────
  /// 'none' | 'github' | 'custom'
  final String imgHostKind;
  /// GitHub Personal Access Token with `contents:write` on the target repo.
  final String? githubPat;
  final String? githubOwner;
  final String? githubRepo;
  final String githubBranch;
  /// Path prefix within the repo — final upload path is
  ///   `<prefix>/<yyyy>/<mm>/<journalId>/<uuid>.<ext>`.
  final String githubPathPrefix;
  /// CDN URL template — supports {user} {repo} {branch} {path} placeholders.
  /// Default uses jsDelivr; users in China may switch to Statically or
  /// raw.githubusercontent.
  final String githubCdnTemplate;

  /// Custom image host. uploadUrl receives a multipart POST with the file in
  /// [customFileField]. The response JSON path [customResponseUrlPath] is
  /// extracted and substituted into [customDisplayUrlTemplate] (`{url}`).
  /// [customDeleteUrlTemplate] receives `{url}` and is DELETEd on entry
  /// removal — empty string disables remote delete.
  final String? customUploadUrl;
  final String customFileField;
  final String customResponseUrlPath;
  final String customDisplayUrlTemplate;
  final String customDeleteUrlTemplate;
  final String customAuthHeader;

  /// Separate config for private (level=private) journals. Only used when an
  /// entry is marked private — public entries always go through the public
  /// repo above. Private images can't be served by jsDelivr; the app fetches
  /// raw.githubusercontent.com with `Authorization: Bearer <privatePat>`.
  final String? githubPrivatePat;
  final String? githubPrivateOwner;
  final String? githubPrivateRepo;
  final String githubPrivateBranch;
  final String githubPrivatePathPrefix;

  /// When true, the map screen fires a low-rate reverse-geocode in the
  /// background for the screen center as the user pans, so the local cache
  /// gradually fills in without waiting for a journal save to trigger it.
  final bool geocodingPrewarm;
  /// Backup import: when on, each imported module clears the local table
  /// first; when off (default), imports merge by UUID. Persisted so users
  /// don't have to re-tick it every session.
  final bool importClearBeforeImport;
  /// Which backup modules were last selected. Persisted so the user
  /// doesn't have to re-tick every time. Empty = "all".
  final List<String> backupSelectedModules;
  /// Hidden debug mode — flipped by tapping the version label 10 times on
  /// the home screen. Unlocks the sim panel on release builds and a log
  /// viewer.
  final bool debugMode;

  const AppSettings({
    this.mapProvider = MapProvider.amap,
    this.mapStyle = MapStyle.standard,
    this.recordingMode = RecordingMode.balanced,
    this.fogColor = 0xFF101820,
    this.fogOpacity = 0.78,
    this.fogPenRadius = 50,
    this.amapApiKey,
    this.googleMapKey,
    this.customOsmTileUrl,
    this.aiBaseUrl = 'https://api.siliconflow.cn/v1',
    this.aiApiKey,
    this.aiModel = 'Qwen/Qwen2.5-7B-Instruct',
    this.musicApiBase = 'https://music-api.gdstudio.xyz/api.php',
    this.webdavUrl,
    this.webdavUser,
    this.webdavPass,
    this.autoBackup = false,
    this.zerotierNetworkId,
    this.displayName = '旅人',
    this.p2pPassphrase,
    this.groupId,
    this.selfPeerId,
    this.groupBroadcastMusic = false,
    this.groupFollowMusic = true,
    this.groupTransport = GroupTransport.lan,
    this.groupAutoConnect = true,
    this.lanScanIp,
    this.lanScanCidrBits = 24,
    this.peerOverrides = const {},
    this.musicCredentials = const {},
    this.webrtcSignalingPath = '/explore_journal/signaling',
    this.webrtcSignalingPollSec = 5,
    this.webrtcIceServers = 'stun:stun.l.google.com:19302',
    this.imgHostKind = 'none',
    this.githubPat,
    this.githubOwner,
    this.githubRepo,
    this.githubBranch = 'main',
    this.githubPathPrefix = 'media',
    this.githubCdnTemplate =
        'https://cdn.jsdelivr.net/gh/{user}/{repo}@{branch}/{path}',
    this.customUploadUrl,
    this.customFileField = 'file',
    this.customResponseUrlPath = 'data.url',
    this.customDisplayUrlTemplate = '{url}',
    this.customDeleteUrlTemplate = '',
    this.customAuthHeader = '',
    this.githubPrivatePat,
    this.githubPrivateOwner,
    this.githubPrivateRepo,
    this.githubPrivateBranch = 'main',
    this.githubPrivatePathPrefix = 'media',
    this.geocodingPrewarm = false,
    this.importClearBeforeImport = false,
    this.backupSelectedModules = const [],
    this.debugMode = false,
  });

  AppSettings copyWith({
    MapProvider? mapProvider,
    MapStyle? mapStyle,
    RecordingMode? recordingMode,
    int? fogColor,
    double? fogOpacity,
    double? fogPenRadius,
    String? amapApiKey,
    String? googleMapKey,
    String? customOsmTileUrl,
    String? aiBaseUrl,
    String? aiApiKey,
    String? aiModel,
    String? musicApiBase,
    String? webdavUrl,
    String? webdavUser,
    String? webdavPass,
    bool? autoBackup,
    String? zerotierNetworkId,
    String? displayName,
    String? p2pPassphrase,
    String? groupId,
    String? selfPeerId,
    bool? groupBroadcastMusic,
    bool? groupFollowMusic,
    GroupTransport? groupTransport,
    bool? groupAutoConnect,
    String? lanScanIp,
    int? lanScanCidrBits,
    Map<String, Map<String, dynamic>>? peerOverrides,
    Map<String, String>? musicCredentials,
    String? webrtcSignalingPath,
    int? webrtcSignalingPollSec,
    String? webrtcIceServers,
    String? imgHostKind,
    String? githubPat,
    String? githubOwner,
    String? githubRepo,
    String? githubBranch,
    String? githubPathPrefix,
    String? githubCdnTemplate,
    String? customUploadUrl,
    String? customFileField,
    String? customResponseUrlPath,
    String? customDisplayUrlTemplate,
    String? customDeleteUrlTemplate,
    String? customAuthHeader,
    String? githubPrivatePat,
    String? githubPrivateOwner,
    String? githubPrivateRepo,
    String? githubPrivateBranch,
    String? githubPrivatePathPrefix,
    bool? geocodingPrewarm,
    bool? importClearBeforeImport,
    List<String>? backupSelectedModules,
    bool? debugMode,
  }) =>
      AppSettings(
        mapProvider: mapProvider ?? this.mapProvider,
        mapStyle: mapStyle ?? this.mapStyle,
        recordingMode: recordingMode ?? this.recordingMode,
        fogColor: fogColor ?? this.fogColor,
        fogOpacity: fogOpacity ?? this.fogOpacity,
        fogPenRadius: fogPenRadius ?? this.fogPenRadius,
        amapApiKey: amapApiKey ?? this.amapApiKey,
        googleMapKey: googleMapKey ?? this.googleMapKey,
        customOsmTileUrl: customOsmTileUrl ?? this.customOsmTileUrl,
        aiBaseUrl: aiBaseUrl ?? this.aiBaseUrl,
        aiApiKey: aiApiKey ?? this.aiApiKey,
        aiModel: aiModel ?? this.aiModel,
        musicApiBase: musicApiBase ?? this.musicApiBase,
        webdavUrl: webdavUrl ?? this.webdavUrl,
        webdavUser: webdavUser ?? this.webdavUser,
        webdavPass: webdavPass ?? this.webdavPass,
        autoBackup: autoBackup ?? this.autoBackup,
        zerotierNetworkId: zerotierNetworkId ?? this.zerotierNetworkId,
        displayName: displayName ?? this.displayName,
        p2pPassphrase: p2pPassphrase ?? this.p2pPassphrase,
        groupId: groupId ?? this.groupId,
        selfPeerId: selfPeerId ?? this.selfPeerId,
        groupBroadcastMusic: groupBroadcastMusic ?? this.groupBroadcastMusic,
        groupFollowMusic: groupFollowMusic ?? this.groupFollowMusic,
        groupTransport: groupTransport ?? this.groupTransport,
        groupAutoConnect: groupAutoConnect ?? this.groupAutoConnect,
        lanScanIp: lanScanIp ?? this.lanScanIp,
        lanScanCidrBits: lanScanCidrBits ?? this.lanScanCidrBits,
        peerOverrides: peerOverrides ?? this.peerOverrides,
        musicCredentials: musicCredentials ?? this.musicCredentials,
        webrtcSignalingPath: webrtcSignalingPath ?? this.webrtcSignalingPath,
        webrtcSignalingPollSec:
            webrtcSignalingPollSec ?? this.webrtcSignalingPollSec,
        webrtcIceServers: webrtcIceServers ?? this.webrtcIceServers,
        imgHostKind: imgHostKind ?? this.imgHostKind,
        githubPat: githubPat ?? this.githubPat,
        githubOwner: githubOwner ?? this.githubOwner,
        githubRepo: githubRepo ?? this.githubRepo,
        githubBranch: githubBranch ?? this.githubBranch,
        githubPathPrefix: githubPathPrefix ?? this.githubPathPrefix,
        githubCdnTemplate: githubCdnTemplate ?? this.githubCdnTemplate,
        customUploadUrl: customUploadUrl ?? this.customUploadUrl,
        customFileField: customFileField ?? this.customFileField,
        customResponseUrlPath:
            customResponseUrlPath ?? this.customResponseUrlPath,
        customDisplayUrlTemplate:
            customDisplayUrlTemplate ?? this.customDisplayUrlTemplate,
        customDeleteUrlTemplate:
            customDeleteUrlTemplate ?? this.customDeleteUrlTemplate,
        customAuthHeader: customAuthHeader ?? this.customAuthHeader,
        githubPrivatePat: githubPrivatePat ?? this.githubPrivatePat,
        githubPrivateOwner: githubPrivateOwner ?? this.githubPrivateOwner,
        githubPrivateRepo: githubPrivateRepo ?? this.githubPrivateRepo,
        githubPrivateBranch:
            githubPrivateBranch ?? this.githubPrivateBranch,
        githubPrivatePathPrefix:
            githubPrivatePathPrefix ?? this.githubPrivatePathPrefix,
        geocodingPrewarm: geocodingPrewarm ?? this.geocodingPrewarm,
        importClearBeforeImport:
            importClearBeforeImport ?? this.importClearBeforeImport,
        backupSelectedModules:
            backupSelectedModules ?? this.backupSelectedModules,
        debugMode: debugMode ?? this.debugMode,
      );

  Map<String, dynamic> toJson() => {
        'mapProvider': mapProvider.index,
        'mapStyle': mapStyle.index,
        'recordingMode': recordingMode.index,
        'fogColor': fogColor,
        'fogOpacity': fogOpacity,
        'fogPenRadius': fogPenRadius,
        'amapApiKey': amapApiKey,
        'googleMapKey': googleMapKey,
        'customOsmTileUrl': customOsmTileUrl,
        'aiBaseUrl': aiBaseUrl,
        'aiApiKey': aiApiKey,
        'aiModel': aiModel,
        'musicApiBase': musicApiBase,
        'webdavUrl': webdavUrl,
        'webdavUser': webdavUser,
        'webdavPass': webdavPass,
        'autoBackup': autoBackup,
        'zerotierNetworkId': zerotierNetworkId,
        'displayName': displayName,
        'p2pPassphrase': p2pPassphrase,
        'groupId': groupId,
        'selfPeerId': selfPeerId,
        'groupBroadcastMusic': groupBroadcastMusic,
        'groupFollowMusic': groupFollowMusic,
        'groupTransport': groupTransport.index,
        'groupAutoConnect': groupAutoConnect,
        'lanScanIp': lanScanIp,
        'lanScanCidrBits': lanScanCidrBits,
        'peerOverrides': peerOverrides,
        'musicCredentials': musicCredentials,
        'webrtcSignalingPath': webrtcSignalingPath,
        'webrtcSignalingPollSec': webrtcSignalingPollSec,
        'webrtcIceServers': webrtcIceServers,
        'imgHostKind': imgHostKind,
        'githubPat': githubPat,
        'githubOwner': githubOwner,
        'githubRepo': githubRepo,
        'githubBranch': githubBranch,
        'githubPathPrefix': githubPathPrefix,
        'githubCdnTemplate': githubCdnTemplate,
        'customUploadUrl': customUploadUrl,
        'customFileField': customFileField,
        'customResponseUrlPath': customResponseUrlPath,
        'customDisplayUrlTemplate': customDisplayUrlTemplate,
        'customDeleteUrlTemplate': customDeleteUrlTemplate,
        'customAuthHeader': customAuthHeader,
        'githubPrivatePat': githubPrivatePat,
        'githubPrivateOwner': githubPrivateOwner,
        'githubPrivateRepo': githubPrivateRepo,
        'githubPrivateBranch': githubPrivateBranch,
        'githubPrivatePathPrefix': githubPrivatePathPrefix,
        'geocodingPrewarm': geocodingPrewarm,
        'importClearBeforeImport': importClearBeforeImport,
        'backupSelectedModules': backupSelectedModules,
        'debugMode': debugMode,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        mapProvider: MapProvider.values[j['mapProvider'] ?? 0],
        mapStyle: MapStyle.values[j['mapStyle'] ?? 0],
        recordingMode: RecordingMode.values[j['recordingMode'] ?? 1],
        fogColor: j['fogColor'] ?? 0xFF101820,
        fogOpacity: (j['fogOpacity'] ?? 0.78).toDouble(),
        fogPenRadius: (j['fogPenRadius'] ?? 80).toDouble(),
        amapApiKey: j['amapApiKey'],
        googleMapKey: j['googleMapKey'],
        customOsmTileUrl: j['customOsmTileUrl'],
        aiBaseUrl: j['aiBaseUrl'] ?? 'https://api.siliconflow.cn/v1',
        aiApiKey: j['aiApiKey'],
        aiModel: j['aiModel'] ?? 'Qwen/Qwen2.5-7B-Instruct',
        musicApiBase:
            j['musicApiBase'] ?? 'https://music-api.gdstudio.xyz/api.php',
        webdavUrl: j['webdavUrl'],
        webdavUser: j['webdavUser'],
        webdavPass: j['webdavPass'],
        autoBackup: j['autoBackup'] ?? false,
        zerotierNetworkId: j['zerotierNetworkId'],
        displayName: j['displayName'] ?? '旅人',
        p2pPassphrase: j['p2pPassphrase'],
        groupId: j['groupId'],
        selfPeerId: j['selfPeerId'],
        groupBroadcastMusic: j['groupBroadcastMusic'] ?? false,
        groupFollowMusic: j['groupFollowMusic'] ?? true,
        groupTransport: GroupTransport
            .values[(j['groupTransport'] as int?) ?? 0],
        groupAutoConnect: j['groupAutoConnect'] ?? true,
        lanScanIp: j['lanScanIp'],
        lanScanCidrBits: (j['lanScanCidrBits'] as num?)?.toInt() ?? 24,
        peerOverrides: (j['peerOverrides'] as Map?)
                ?.map((k, v) => MapEntry(
                    k as String, (v as Map).cast<String, dynamic>())) ??
            const {},
        musicCredentials: (j['musicCredentials'] as Map?)
                ?.map((k, v) => MapEntry(k as String, v.toString())) ??
            const {},
        webrtcSignalingPath:
            j['webrtcSignalingPath'] ?? '/explore_journal/signaling',
        webrtcSignalingPollSec:
            (j['webrtcSignalingPollSec'] as num?)?.toInt() ?? 5,
        webrtcIceServers:
            j['webrtcIceServers'] ?? 'stun:stun.l.google.com:19302',
        imgHostKind: j['imgHostKind'] ?? 'none',
        githubPat: j['githubPat'],
        githubOwner: j['githubOwner'],
        githubRepo: j['githubRepo'],
        githubBranch: j['githubBranch'] ?? 'main',
        githubPathPrefix: j['githubPathPrefix'] ?? 'media',
        githubCdnTemplate: j['githubCdnTemplate'] ??
            'https://cdn.jsdelivr.net/gh/{user}/{repo}@{branch}/{path}',
        customUploadUrl: j['customUploadUrl'],
        customFileField: j['customFileField'] ?? 'file',
        customResponseUrlPath: j['customResponseUrlPath'] ?? 'data.url',
        customDisplayUrlTemplate: j['customDisplayUrlTemplate'] ?? '{url}',
        customDeleteUrlTemplate: j['customDeleteUrlTemplate'] ?? '',
        customAuthHeader: j['customAuthHeader'] ?? '',
        githubPrivatePat: j['githubPrivatePat'],
        githubPrivateOwner: j['githubPrivateOwner'],
        githubPrivateRepo: j['githubPrivateRepo'],
        githubPrivateBranch: j['githubPrivateBranch'] ?? 'main',
        githubPrivatePathPrefix: j['githubPrivatePathPrefix'] ?? 'media',
        geocodingPrewarm: j['geocodingPrewarm'] ?? false,
        importClearBeforeImport: j['importClearBeforeImport'] ?? false,
        backupSelectedModules:
            (j['backupSelectedModules'] as List?)?.cast<String>() ??
                const [],
        debugMode: j['debugMode'] ?? false,
      );
}

extension PeerOverrideX on AppSettings {
  /// True unless the user has explicitly hidden this peer.
  bool peerVisible(String peerId) {
    final v = peerOverrides[peerId]?['visible'];
    return v is bool ? v : true;
  }

  /// Override color (ARGB) or null to fall back to the auto-assigned palette
  /// color reported by the peer itself.
  int? peerColor(String peerId) {
    final c = peerOverrides[peerId]?['color'];
    return c is int ? c : null;
  }

  /// Override display name (e.g. "老王") or null to use what the peer
  /// reported.
  String? peerName(String peerId) {
    final n = peerOverrides[peerId]?['name'];
    return n is String && n.isNotEmpty ? n : null;
  }
}

class PrefsStore {
  static const _key = 'app_settings_v1';

  Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return const AppSettings();
    return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(AppSettings s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(s.toJson()));
  }
}
