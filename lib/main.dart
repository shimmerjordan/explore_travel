import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'ui/home/home_screen.dart';
import 'ui/map/map_screen.dart';
import 'ui/globe/globe_screen.dart';
import 'ui/layers/layers_screen.dart';
import 'ui/settings/settings_screen.dart';
import 'ui/settings/ai_settings_screen.dart';
import 'ui/settings/storage_screen.dart';
import 'ui/journal/journal_screen.dart';
import 'ui/playback/playback_screen.dart';
import 'ui/explore/explore_screen.dart';
import 'ui/timeline/timeline_screen.dart';
import 'ui/ai_planner/ai_planner_screen.dart';
import 'ui/chat/chat_screen.dart';
import 'ui/music/music_screen.dart';
import 'ui/music/favorites_map_screen.dart';
import 'ui/music/music_sources_screen.dart';
import 'ui/backup/backup_screen.dart';
import 'ui/imghost/imghost_settings_screen.dart';
import 'ui/group_setup/group_setup_screen.dart';
import 'ui/group_setup/group_diagnostics_screen.dart';
import 'ui/leaderboard/leaderboard_screen.dart';
import 'ui/about/about_screen.dart';
import 'ui/permissions/permissions_screen.dart';
import 'app/startup_maintenance.dart' show runStartupDbMaintenance;
import 'app/providers.dart'
    show groupLifecycleProvider, dbProvider,
        runInitialVisitDetection, visitEngineProvider, visitsRefreshProvider,
        settingsProvider;
import 'services/vault/auth_controller.dart';
import 'ui/auth/login_screen.dart';
import 'services/debug/log_buffer.dart';
import 'ui/debug/debug_screen.dart';
import 'main_native.dart' if (dart.library.js_interop) 'main_web.dart'
    as platform;
import 'ui/common/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Two tile pyramids (base map + baked fog) live in the image cache at
  // once; the 100 MB default thrashes during pinch-zoom and every eviction
  // is a re-decode flash. Modern phones can afford a bigger working set.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 256 << 20;
  // The ENTRY cap (default 1000) is the one that actually bit: base map +
  // fog mask + fog tint pyramids plus pin thumbnails evicted each other by
  // count long before the byte budget, and every eviction is a re-bake.
  PaintingBinding.instance.imageCache.maximumSize = 4000;
  // Capture every debugPrint into an in-memory ring so the debug log viewer
  // can show them. Debug builds always; release builds only while the hidden
  // debug mode is on (toggled below, once settings have loaded).
  if (kDebugMode) LogBuffer.install();

  // Catch every unhandled error with full stack trace — without this, Flutter
  // collapses repeated exceptions into "Another exception was thrown" with
  // no detail.
  FlutterError.onError = (details) {
    final lib = details.library ?? '';
    final ex = details.exceptionAsString();
    // Image-decode failures (a broken/unsupported image, common on web for
    // missing or cross-origin sources) are non-fatal — each Image handles them
    // via errorBuilder. Don't dump a full stack per occurrence; it floods the
    // console without telling us anything actionable.
    if (lib.contains('image resource') ||
        ex.contains('EncodingError') ||
        ex.contains('cannot be decoded')) {
      debugPrint('[image] decode failed (non-fatal): $ex');
      return;
    }
    FlutterError.dumpErrorToConsole(details);
    debugPrint('=== FLUTTER ERROR ===');
    debugPrint('library: ${details.library}');
    debugPrint('context: ${details.context}');
    debugPrint('exception: ${details.exceptionAsString()}');
    debugPrint('stack:\n${details.stack}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('=== UNCAUGHT ERROR ===\n$error\n$stack');
    return true;
  };
  // Replace the default grey-on-grey ErrorWidget with one that shows the
  // exception text inline — both in debug and release builds. Anything that
  // throws during build (e.g. a misbehaving Quill embed) now leaves a
  // breadcrumb on screen and a copy in the console instead of a blank red
  // rectangle that says only "Assertion failed".
  ErrorWidget.builder = (FlutterErrorDetails details) {
    debugPrint('=== ErrorWidget triggered ===');
    debugPrint(details.exceptionAsString());
    debugPrint('${details.stack}');
    return Material(
      color: const Color(0x33FF0000),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: Text(
          '⚠️ 组件渲染出错：\n${details.exceptionAsString()}\n\n'
          '${details.stack ?? ''}',
          style: const TextStyle(
              color: Color(0xFFFFEB3B),
              fontSize: 11,
              fontFamily: 'monospace'),
        ),
      ),
    );
  };

  platform.initPlatform();
  runApp(const ProviderScope(child: ExploreJournalApp()));
}

class ExploreJournalApp extends ConsumerStatefulWidget {
  const ExploreJournalApp({super.key});

  @override
  ConsumerState<ExploreJournalApp> createState() => _ExploreJournalAppState();
}

class _ExploreJournalAppState extends ConsumerState<ExploreJournalApp> {
  // Built ONCE (late final) so router rebuilds never drop the navigation stack.
  late final GoRouter _router = _makeRouter();

  @override
  void initState() {
    super.initState();
    // Resolve the initial auth state (web gate) AFTER the first frame —
    // restore() flips the AuthController (a refreshListenable), and notifying
    // a listenable during the initial build would dirty the tree mid-build.
    // Release builds: the in-memory log ring follows the hidden debug switch.
    ref.listenManual<bool>(
      settingsProvider.select((s) => s.debugMode),
      (_, on) {
        if (kDebugMode) return;
        on ? LogBuffer.install() : LogBuffer.uninstall();
      },
      fireImmediately: true,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(authControllerProvider).restore();
      // Self-heal a layer-less DB + log the row-count probe (see
      // runStartupDbMaintenance). Recreating an orphaned layer flips the
      // watchLayers() stream, so the map/trail/journal re-render on their own.
      runStartupDbMaintenance(ref.read(dbProvider),
          probe: kDebugMode || ref.read(settingsProvider).debugMode);
      // First-launch stay detection over the whole history — after the map
      // has had a few seconds to settle, and never on the read-only web view.
      // A cancellable Timer (not Future.delayed) so tearing the app down —
      // widget tests do — leaves nothing pending.
      if (!kIsWeb) {
        _visitKick = Timer(const Duration(seconds: 8), () {
          if (!mounted) return;
          runInitialVisitDetection(ref.read(visitEngineProvider))
              .then((_) => ref.read(visitsRefreshProvider.notifier).state++);
        });
      }
    });
  }

  Timer? _visitKick;

  @override
  void dispose() {
    _visitKick?.cancel();
    super.dispose();
  }

  GoRouter _makeRouter() => GoRouter(
    // Re-evaluate the redirect whenever auth state flips (login / logout).
    refreshListenable: ref.read(authControllerProvider),
    // 地图页靠它感知「有整页路由压在自己上面」，好把 GPS 流停掉（MapScreen
    // 是常驻首页，push 出去时并不会 dispose）。
    observers: [mapRouteObserver],
    redirect: (context, state) {
      if (!kIsWeb) return null; // native is never gated
      // The whole policy lives in webAuthRedirect (unit-tested there): deny
      // while resolving, and carry the intercepted location through login.
      return webAuthRedirect(
          status: ref.read(authStateProvider).status, uri: state.uri);
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      // Where `unknown` parks: nothing to query, nothing to render, nothing to
      // flash. It is unreachable once auth resolves.
      GoRoute(path: '/splash', builder: (_, __) => const _AuthSplash()),
      GoRoute(path: '/', builder: (_, __) => const MapScreen()),
      GoRoute(path: '/globe', builder: (_, __) => const GlobeScreen()),
      GoRoute(path: '/menu', builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/layers', builder: (_, __) => const LayersScreen()),
      GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
      GoRoute(
          path: '/settings/ai',
          builder: (_, __) => const AiSettingsScreen()),
      GoRoute(
          path: '/settings/storage',
          builder: (_, __) => const StorageScreen()),
      GoRoute(path: '/journal', builder: (_, __) => const JournalScreen()),
      GoRoute(path: '/playback', builder: (_, __) => const PlaybackScreen()),
      GoRoute(path: '/explore', builder: (_, __) => const ExploreScreen()),
      GoRoute(path: '/timeline', builder: (_, __) => const TimelineScreen()),
      GoRoute(path: '/ai', builder: (_, __) => const AiPlannerScreen()),
      GoRoute(path: '/group', builder: (_, __) => const ChatScreen()),
      GoRoute(path: '/music', builder: (_, __) => const MusicScreen()),
      GoRoute(
          path: '/music/map',
          builder: (_, __) => const FavoritesMapScreen()),
      GoRoute(
          path: '/music/sources',
          builder: (_, __) => const MusicSourcesScreen()),
      GoRoute(path: '/backup', builder: (_, __) => const BackupScreen()),
      GoRoute(
          path: '/imghost',
          builder: (_, __) => const ImgHostSettingsScreen()),
      GoRoute(path: '/debug', builder: (_, __) => const DebugScreen()),
      GoRoute(
          path: '/group/setup',
          builder: (_, __) => const GroupSetupScreen()),
      GoRoute(
          path: '/group/diag',
          builder: (_, __) => const GroupDiagnosticsScreen()),
      GoRoute(
          path: '/leaderboard',
          builder: (_, __) => const LeaderboardScreen()),
      GoRoute(path: '/about', builder: (_, __) => const AboutScreen()),
      GoRoute(
          path: '/permissions',
          builder: (_, __) => const PermissionsScreen()),
    ],
  );

  ThemeMode get _themeMode => switch (ref.watch(settingsProvider).themePref) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };

  @override
  Widget build(BuildContext context) {
    // Eagerly instantiate so it begins reacting to settings on launch.
    ref.read(groupLifecycleProvider);
    return kIsWeb
        ? MaterialApp.router(
            title: 'Explore Journal',
            theme: lightAppTheme,
            darkTheme: darkAppTheme,
            themeMode: _themeMode,
            routerConfig: _router,
            localizationsDelegates: _localizationsDelegates,
            supportedLocales: _supportedLocales,
            builder: (_, child) => _withSecurityNotices(child),
          )
        : _buildWithForegroundTask(context);
  }

  /// Standing security notices above every route.
  ///
  ///  * A console still on `admin/admin` is one open port away from being
  ///    someone else's, and changing the password is what makes that one go
  ///    away — so it can't be dismissed.
  ///  * A logout the server never confirmed leaves a live session (and a live
  ///    `ej_session` cookie) behind; on a shared browser the user needs to
  ///    know that "back at the login page" wasn't the whole story.
  ///
  /// Both ride the router's `builder:`, not the login screen — the router
  /// leaves that the instant login succeeds, so anything drawn there would
  /// flash past unread. See [defaultPasswordWarningProvider] for why this is
  /// wired on web only today.
  Widget _withSecurityNotices(Widget? child) {
    final body = child ?? const SizedBox.shrink();
    final bars = <Widget>[
      if (ref.watch(defaultPasswordWarningProvider))
        _noticeBar('仍在使用默认密码 admin/admin，请尽快修改'),
      if (ref.watch(logoutNoticeProvider) case final t?) _noticeBar(t),
    ];
    if (bars.isEmpty) return body;
    return Column(
      children: [
        // ONE SafeArea for the whole stack — each bar adding its own would
        // inset the status bar height per bar.
        SafeArea(bottom: false, child: Column(children: bars)),
        // The bars eat real height and real top inset. Without rewriting the
        // MediaQuery, everything below is told it has the FULL window height
        // (~37px more than it got) and still has an unconsumed status-bar
        // inset — which is how the companion card, sized as
        // `size.height - padding.top - 56 - 136`, ran off the bottom of a
        // narrow window.
        Expanded(child: ShrunkMediaQuery(child: body)),
      ],
    );
  }

  Widget _noticeBar(String text) => Material(
        color: const Color(0xFF8C1D18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      );

  // NOTE (deliberate gap): the native shell has NO `builder:`, so
  // `_withSecurityNotices` never runs on a phone — `defaultPasswordWarningProvider`
  // and `logoutNoticeProvider` are set by AuthController there and silently not
  // rendered. That is only acceptable while the native login screen is
  // unreachable (no entry point exists yet). When that entry point lands, add
  // `builder: (_, child) => _withSecurityNotices(child)` to the
  // MaterialApp.router below — that one line is the whole fix.
  Widget _buildWithForegroundTask(BuildContext context) {
    return platform.wrapWithForegroundTask(
      child: MaterialApp.router(
        title: 'Explore Journal',
        theme: lightAppTheme,
        darkTheme: darkAppTheme,
        themeMode: _themeMode,
        routerConfig: _router,
        localizationsDelegates: _localizationsDelegates,
        supportedLocales: _supportedLocales,
      ),
    );
  }

  // flutter_quill 11.x crashes its toolbar buttons when its Localizations
  // delegate isn't registered. Bundle quill's delegate alongside the
  // standard Material / widget / Cupertino ones, plus Chinese as the
  // primary supported locale.
  static const _localizationsDelegates = <LocalizationsDelegate<Object>>[
    quill.FlutterQuillLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];
  static const _supportedLocales = <Locale>[
    Locale('zh', 'CN'),
    Locale('zh'),
    Locale('en'),
  ];

}

/// Re-states the `MediaQuery` to match the box the child was actually given.
///
/// `MaterialApp.builder` can shrink the Navigator (we put notice bars above it)
/// but it cannot shrink `MediaQuery`: the child keeps reading the full window
/// height and the full `padding.top`, even though the bar above already ate
/// both. Anything doing its own arithmetic off `size.height` / `padding.top` —
/// e.g. the map's companion card — then overflows by exactly the bar's height.
///
/// Public so a widget test can pin the rewrite without pumping the whole app.
class ShrunkMediaQuery extends StatelessWidget {
  final Widget child;
  const ShrunkMediaQuery({super.key, required this.child});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (ctx, c) {
          final mq = MediaQuery.of(ctx);
          if (!c.hasBoundedHeight) return child;
          // What the bars above consumed, top padding included (they wrap
          // themselves in the SafeArea, so the child needs none of it left).
          final eaten = math.max(0.0, mq.size.height - c.maxHeight);
          if (eaten == 0) return child;
          double inset(double v) => math.max(0.0, v - eaten);
          return MediaQuery(
            data: mq.copyWith(
              size: Size(mq.size.width, c.maxHeight),
              padding: mq.padding.copyWith(top: inset(mq.padding.top)),
              viewPadding:
                  mq.viewPadding.copyWith(top: inset(mq.viewPadding.top)),
            ),
            child: child,
          );
        },
      );
}

/// Shown while the web gate is still deciding. Deliberately inert — no DB
/// reads, no tiles, nothing that would have to be thrown away when the answer
/// turns out to be `/login`.
class _AuthSplash extends StatelessWidget {
  const _AuthSplash();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
}
