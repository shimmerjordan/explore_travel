import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import '../services/backup/backup_service.dart' show kVaultSecretKeys;

class AppSettings {
  /// True once the persisted prefs have actually been read from disk.
  /// The provider starts from `const AppSettings()` and loads async — style
  /// consumers (fog veil, trail widths) should skip rendering until this
  /// flips, or the first frames flash default styles. Never persisted.
  final bool loaded;
  final MapProvider mapProvider;
  final MapStyle mapStyle;
  final RecordingMode recordingMode;
  final int fogColor; // ARGB
  final double fogOpacity; // 0..1
  final double fogPenRadius; // meters — manual erase/add brush radius
  final double trailWidth; // meters — visible recorded path/point size
  final bool allowMapRotation; // two-finger rotation gesture (default off)
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
  /// OneDrive (Microsoft Graph) OAuth. [oneDriveClientId] is your Azure app
  /// registration's Application (client) ID. [oneDriveRefreshToken] is the
  /// long-lived credential obtained after login (scrubbed from backups);
  /// [oneDriveAccount] is a human label (email/name) for the UI.
  final String? oneDriveClientId;
  final String? oneDriveRefreshToken;
  final String? oneDriveAccount;
  /// Which sync transport the incremental [SyncEngine] uses. One of
  /// [SyncBackend.all] ('onedrive' | 'github' | 'webdav' | 'nas'). Defaults to
  /// 'onedrive' so existing installs and mobile behave exactly as before.
  final String syncBackend;
  /// NAS web-display backend (zero-knowledge vault host). Non-secret config:
  /// the server base URL, the account email, and the b64 KDF salt returned by
  /// `GET /auth/salt` (cached so re-login can derive without a round trip).
  /// The session token is NOT here — it's bearer-equivalent and short-lived,
  /// kept in a dedicated clearable store ([NasTokenStore]).
  final String? nasServerUrl;
  final String? nasAccountEmail;
  final String? nasKdfSalt;
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

  // ── frp XTCP transport (GroupTransport.frp) ───────────────────────────
  /// frp server (frps) host/IP. The embedded frpc connects here to coordinate
  /// XTCP hole punching with other members. Empty disables the transport.
  final String? frpServerAddr;
  /// frps bind port (frpc `serverPort`). frp default is 7000.
  final int frpServerPort;
  /// frps auth token (frpc `auth.token`). Empty = no token.
  final String? frpToken;
  /// XTCP punch protocol once connected: 'quic' (default, robust) or 'kcp'.
  final String frpProtocol;
  /// frps dashboard API base URL (e.g. http://host:7500). Used purely to
  /// auto-discover the group roster: we list xtcp proxies whose name starts
  /// with the group prefix and open a visitor to each. Empty = no auto
  /// discovery (members must be added manually).
  final String? frpDashboardUrl;
  final String? frpDashboardUser;
  final String? frpDashboardPass;

  // ── 云中继 transport (GroupTransport.relay) ────────────────────────────
  /// Self-hosted backend base URL (backends/ in this repo), e.g.
  /// `https://ej.example.com` or `http://1.2.3.4:8080`. The client derives
  /// the WebSocket endpoint (`/group/v1/ws`) from it. Empty disables.
  final String? relayServerUrl;
  /// Optional access token — must equal the server's `GROUP_TOKEN`.
  final String? relayToken;

  // ── Image host (for journal photos) ───────────────────────────────────
  /// 'none' | 'github' | 'custom'
  final String imgHostKind;
  /// When true (default) queued journal photos upload to the image host
  /// automatically in the background. When false they stay `pending` until the
  /// user taps 上传 in the upload list — a data/roaming saver.
  final bool autoUploadImages;
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

  /// UI theme: 'dark' | 'light' | 'system'. Defaults to the light "轻快"
  /// scheme; 暗黑/跟随系统 via 设置 → 外观.
  final String themePref;

  /// When true, the map tile layer is rendered through an invert-style
  /// `ColorFilter` so light raster tiles look like a dark theme. None
  /// of the upstream providers (高德 / Google / OSM) expose a real
  /// dark-tile URL on terms we can ship; the filter is the next-best
  /// option and matches what other Flutter apps in the wild do.
  final bool darkMap;

  // ── Profile / avatar ──────────────────────────────────────────────────
  /// Base64-encoded JPEG (256×256, ~10–20 KB). Empty = no avatar; UI
  /// falls back to hue-from-peerId initials. Stored in prefs so it's
  /// covered by the settings backup module and travels with the user.
  final String avatarBase64;

  // ── Leaderboard (decentralised, append-only LWW) ──────────────────────
  /// Ed25519 keypair generated once per device. Each leaderboard entry the
  /// user contributes is signed with [leaderboardPrivateKey]; peers verify
  /// with [leaderboardPublicKey]. Both base64 (raw bytes).
  final String leaderboardPrivateKey;
  final String leaderboardPublicKey;
  /// Optional: target repo for "贡献到社区榜单" PR flow. Owner/repo, branch,
  /// PAT with `pull_requests:write` + `contents:write` on a fork.
  final String? leaderboardRepoOwner;
  final String? leaderboardRepoName;
  final String leaderboardRepoBranch;
  final String? leaderboardRepoPat;
  /// Optional: centralised leaderboard server (REST). See
  /// docs/leaderboard-server-api.md for the contract. Empty = disabled.
  final String? leaderboardServerUrl;
  final String? leaderboardServerToken;
  /// Auto-sync to/from the configured server every N minutes (0 = manual).
  final int leaderboardServerSyncMin;

  const AppSettings({
    this.loaded = false,
    this.mapProvider = MapProvider.amap,
    this.mapStyle = MapStyle.standard,
    this.recordingMode = RecordingMode.balanced,
    this.fogColor = 0xFF101820,
    this.fogOpacity = 0.78,
    this.fogPenRadius = 50,
    this.trailWidth = 14,
    this.allowMapRotation = false,
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
    this.oneDriveClientId,
    this.oneDriveRefreshToken,
    this.oneDriveAccount,
    this.syncBackend = 'onedrive',
    this.nasServerUrl,
    this.nasAccountEmail,
    this.nasKdfSalt,
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
    this.frpServerAddr,
    this.frpServerPort = 7000,
    this.frpToken,
    this.frpProtocol = 'quic',
    this.frpDashboardUrl,
    this.frpDashboardUser,
    this.frpDashboardPass,
    this.relayServerUrl,
    this.relayToken,
    this.imgHostKind = 'none',
    this.autoUploadImages = true,
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
    this.themePref = 'light',
    this.darkMap = false,
    this.avatarBase64 = '',
    this.leaderboardPrivateKey = '',
    this.leaderboardPublicKey = '',
    this.leaderboardRepoOwner,
    this.leaderboardRepoName,
    this.leaderboardRepoBranch = 'main',
    this.leaderboardRepoPat,
    this.leaderboardServerUrl,
    this.leaderboardServerToken,
    this.leaderboardServerSyncMin = 0,
  });

  AppSettings copyWith({
    bool? loaded,
    MapProvider? mapProvider,
    MapStyle? mapStyle,
    RecordingMode? recordingMode,
    int? fogColor,
    double? fogOpacity,
    double? fogPenRadius,
    double? trailWidth,
    bool? allowMapRotation,
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
    String? oneDriveClientId,
    String? oneDriveRefreshToken,
    String? oneDriveAccount,
    String? syncBackend,
    String? nasServerUrl,
    String? nasAccountEmail,
    String? nasKdfSalt,
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
    String? frpServerAddr,
    int? frpServerPort,
    String? frpToken,
    String? frpProtocol,
    String? frpDashboardUrl,
    String? frpDashboardUser,
    String? frpDashboardPass,
    String? relayServerUrl,
    String? relayToken,
    String? imgHostKind,
    bool? autoUploadImages,
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
    String? themePref,
    bool? darkMap,
    String? avatarBase64,
    String? leaderboardPrivateKey,
    String? leaderboardPublicKey,
    String? leaderboardRepoOwner,
    String? leaderboardRepoName,
    String? leaderboardRepoBranch,
    String? leaderboardRepoPat,
    String? leaderboardServerUrl,
    String? leaderboardServerToken,
    int? leaderboardServerSyncMin,
  }) =>
      AppSettings(
        loaded: loaded ?? this.loaded,
        mapProvider: mapProvider ?? this.mapProvider,
        mapStyle: mapStyle ?? this.mapStyle,
        recordingMode: recordingMode ?? this.recordingMode,
        fogColor: fogColor ?? this.fogColor,
        fogOpacity: fogOpacity ?? this.fogOpacity,
        fogPenRadius: fogPenRadius ?? this.fogPenRadius,
        trailWidth: trailWidth ?? this.trailWidth,
        allowMapRotation: allowMapRotation ?? this.allowMapRotation,
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
        oneDriveClientId: oneDriveClientId ?? this.oneDriveClientId,
        oneDriveRefreshToken: oneDriveRefreshToken ?? this.oneDriveRefreshToken,
        oneDriveAccount: oneDriveAccount ?? this.oneDriveAccount,
        syncBackend: syncBackend ?? this.syncBackend,
        nasServerUrl: nasServerUrl ?? this.nasServerUrl,
        nasAccountEmail: nasAccountEmail ?? this.nasAccountEmail,
        nasKdfSalt: nasKdfSalt ?? this.nasKdfSalt,
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
        frpServerAddr: frpServerAddr ?? this.frpServerAddr,
        frpServerPort: frpServerPort ?? this.frpServerPort,
        frpToken: frpToken ?? this.frpToken,
        frpProtocol: frpProtocol ?? this.frpProtocol,
        frpDashboardUrl: frpDashboardUrl ?? this.frpDashboardUrl,
        frpDashboardUser: frpDashboardUser ?? this.frpDashboardUser,
        frpDashboardPass: frpDashboardPass ?? this.frpDashboardPass,
        relayServerUrl: relayServerUrl ?? this.relayServerUrl,
        relayToken: relayToken ?? this.relayToken,
        imgHostKind: imgHostKind ?? this.imgHostKind,
        autoUploadImages: autoUploadImages ?? this.autoUploadImages,
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
        themePref: themePref ?? this.themePref,
        darkMap: darkMap ?? this.darkMap,
        avatarBase64: avatarBase64 ?? this.avatarBase64,
        leaderboardPrivateKey:
            leaderboardPrivateKey ?? this.leaderboardPrivateKey,
        leaderboardPublicKey:
            leaderboardPublicKey ?? this.leaderboardPublicKey,
        leaderboardRepoOwner:
            leaderboardRepoOwner ?? this.leaderboardRepoOwner,
        leaderboardRepoName: leaderboardRepoName ?? this.leaderboardRepoName,
        leaderboardRepoBranch:
            leaderboardRepoBranch ?? this.leaderboardRepoBranch,
        leaderboardRepoPat: leaderboardRepoPat ?? this.leaderboardRepoPat,
        leaderboardServerUrl:
            leaderboardServerUrl ?? this.leaderboardServerUrl,
        leaderboardServerToken:
            leaderboardServerToken ?? this.leaderboardServerToken,
        leaderboardServerSyncMin:
            leaderboardServerSyncMin ?? this.leaderboardServerSyncMin,
      );

  Map<String, dynamic> toJson() => {
        'mapProvider': mapProvider.index,
        'mapStyle': mapStyle.index,
        'recordingMode': recordingMode.index,
        'fogColor': fogColor,
        'fogOpacity': fogOpacity,
        'fogPenRadius': fogPenRadius,
        'trailWidth': trailWidth,
        'allowMapRotation': allowMapRotation,
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
        'oneDriveClientId': oneDriveClientId,
        'oneDriveRefreshToken': oneDriveRefreshToken,
        'oneDriveAccount': oneDriveAccount,
        'syncBackend': syncBackend,
        'nasServerUrl': nasServerUrl,
        'nasAccountEmail': nasAccountEmail,
        'nasKdfSalt': nasKdfSalt,
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
        'frpServerAddr': frpServerAddr,
        'frpServerPort': frpServerPort,
        'frpToken': frpToken,
        'frpProtocol': frpProtocol,
        'frpDashboardUrl': frpDashboardUrl,
        'frpDashboardUser': frpDashboardUser,
        'frpDashboardPass': frpDashboardPass,
        'relayServerUrl': relayServerUrl,
        'relayToken': relayToken,
        'imgHostKind': imgHostKind,
        'autoUploadImages': autoUploadImages,
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
        'themePref': themePref,
        'darkMap': darkMap,
        'avatarBase64': avatarBase64,
        'leaderboardPrivateKey': leaderboardPrivateKey,
        'leaderboardPublicKey': leaderboardPublicKey,
        'leaderboardRepoOwner': leaderboardRepoOwner,
        'leaderboardRepoName': leaderboardRepoName,
        'leaderboardRepoBranch': leaderboardRepoBranch,
        'leaderboardRepoPat': leaderboardRepoPat,
        'leaderboardServerUrl': leaderboardServerUrl,
        'leaderboardServerToken': leaderboardServerToken,
        'leaderboardServerSyncMin': leaderboardServerSyncMin,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        mapProvider: MapProvider.values[j['mapProvider'] ?? 0],
        mapStyle: MapStyle.values[j['mapStyle'] ?? 0],
        recordingMode: RecordingMode.values[j['recordingMode'] ?? 1],
        fogColor: j['fogColor'] ?? 0xFF101820,
        fogOpacity: (j['fogOpacity'] ?? 0.78).toDouble(),
        fogPenRadius: (j['fogPenRadius'] ?? 50).toDouble(),
        trailWidth: (j['trailWidth'] ?? 14).toDouble(),
        allowMapRotation: (j['allowMapRotation'] ?? false) as bool,
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
        oneDriveClientId: j['oneDriveClientId'],
        oneDriveRefreshToken: j['oneDriveRefreshToken'],
        oneDriveAccount: j['oneDriveAccount'],
        syncBackend: j['syncBackend']?.toString() ?? 'onedrive',
        nasServerUrl: j['nasServerUrl']?.toString(),
        nasAccountEmail: j['nasAccountEmail']?.toString(),
        nasKdfSalt: j['nasKdfSalt']?.toString(),
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
        frpServerAddr: j['frpServerAddr'],
        frpServerPort: (j['frpServerPort'] as num?)?.toInt() ?? 7000,
        frpToken: j['frpToken'],
        frpProtocol: j['frpProtocol'] ?? 'quic',
        frpDashboardUrl: j['frpDashboardUrl'],
        frpDashboardUser: j['frpDashboardUser'],
        frpDashboardPass: j['frpDashboardPass'],
        relayServerUrl: j['relayServerUrl'],
        relayToken: j['relayToken'],
        imgHostKind: j['imgHostKind'] ?? 'none',
        autoUploadImages: j['autoUploadImages'] as bool? ?? true,
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
        themePref: j['themePref']?.toString() ?? 'light',
        darkMap: j['darkMap'] ?? false,
        avatarBase64: j['avatarBase64']?.toString() ?? '',
        leaderboardPrivateKey:
            j['leaderboardPrivateKey']?.toString() ?? '',
        leaderboardPublicKey:
            j['leaderboardPublicKey']?.toString() ?? '',
        leaderboardRepoOwner: j['leaderboardRepoOwner']?.toString(),
        leaderboardRepoName: j['leaderboardRepoName']?.toString(),
        leaderboardRepoBranch:
            j['leaderboardRepoBranch']?.toString() ?? 'main',
        leaderboardRepoPat: j['leaderboardRepoPat']?.toString(),
        leaderboardServerUrl: j['leaderboardServerUrl']?.toString(),
        leaderboardServerToken: j['leaderboardServerToken']?.toString(),
        leaderboardServerSyncMin:
            (j['leaderboardServerSyncMin'] as num?)?.toInt() ?? 0,
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
    // WEB SECRET HYGIENE: the web build is a stateless read-only viewer whose
    // settings (incl. credentials) come from the zero-knowledge vault each
    // session and live only in memory. Never read/write them to localStorage
    // (which shared_preferences uses on web) — so a shared browser can't leak
    // a previous user's PAT/WebDAV password. Native persists normally.
    if (kIsWeb) return const AppSettings();
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return const AppSettings();
    return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(AppSettings s) async {
    if (kIsWeb) return; // see load(): web settings are in-memory only
    final p = await SharedPreferences.getInstance();
    final raw = jsonEncode(s.toJson());
    await p.setString(_key, raw);
    // LWW stamp for settings sync — but only when a NON-secret field really
    // changed. Volatile credential rotations (OneDrive refresh token, music
    // cookies) also flow through save(); letting them bump the stamp would
    // make local settings permanently look freshly-edited and block every
    // cloud settings merge. Secrets never sync anyway (export scrubs them).
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      for (final k in kVaultSecretKeys) {
        if (j.containsKey(k)) j[k] = null;
      }
      final scrubbed = jsonEncode(j);
      if (p.getString('settings_scrub_snapshot') != scrubbed) {
        await p.setString('settings_scrub_snapshot', scrubbed);
        await p.setString(
            'settings_updated_at', DateTime.now().toIso8601String());
      }
    } catch (_) {}
  }
}
