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
import 'ui/journal/journal_screen.dart';
import 'ui/playback/playback_screen.dart';
import 'ui/explore/explore_screen.dart';
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
import 'app/providers.dart' show groupLifecycleProvider;
import 'services/vault/auth_controller.dart';
import 'ui/auth/login_screen.dart';
import 'services/debug/log_buffer.dart';
import 'ui/debug/debug_screen.dart';
import 'main_native.dart' if (dart.library.js_interop) 'main_web.dart'
    as platform;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Capture every debugPrint into an in-memory ring so the debug log
  // viewer can show them.
  LogBuffer.install();

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(authControllerProvider).restore();
    });
  }

  GoRouter _makeRouter() => GoRouter(
    // Re-evaluate the redirect whenever auth state flips (login / logout).
    refreshListenable: ref.read(authControllerProvider),
    redirect: (context, state) {
      if (!kIsWeb) return null; // native is never gated
      final s = ref.read(authStateProvider);
      if (s.status == AuthStatus.unknown) return null; // still resolving
      final atLogin = state.matchedLocation == '/login';
      if (s.status == AuthStatus.loggedOut && !atLogin) return '/login';
      if (s.status == AuthStatus.loggedIn && atLogin) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/', builder: (_, __) => const MapScreen()),
      GoRoute(path: '/globe', builder: (_, __) => const GlobeScreen()),
      GoRoute(path: '/menu', builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/layers', builder: (_, __) => const LayersScreen()),
      GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
      GoRoute(path: '/journal', builder: (_, __) => const JournalScreen()),
      GoRoute(path: '/playback', builder: (_, __) => const PlaybackScreen()),
      GoRoute(path: '/explore', builder: (_, __) => const ExploreScreen()),
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

  @override
  Widget build(BuildContext context) {
    // Eagerly instantiate so it begins reacting to settings on launch.
    ref.read(groupLifecycleProvider);
    return kIsWeb
        ? MaterialApp.router(
            title: 'Explore Journal',
            theme: _lightTheme,
            darkTheme: _darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: _router,
            localizationsDelegates: _localizationsDelegates,
            supportedLocales: _supportedLocales,
          )
        : _buildWithForegroundTask(context);
  }

  Widget _buildWithForegroundTask(BuildContext context) {
    return platform.wrapWithForegroundTask(
      child: MaterialApp.router(
        title: 'Explore Journal',
        theme: _lightTheme,
        darkTheme: _darkTheme,
        themeMode: ThemeMode.dark,
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

  static final _lightTheme = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF26A69A),
      brightness: Brightness.light,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 1,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
    listTileTheme: const ListTileThemeData(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12))),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10)),
      side: BorderSide.none,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12))),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12))),
      ),
    ),
  );

  static final _darkTheme = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF26A69A),
      brightness: Brightness.dark,
    ),
    scaffoldBackgroundColor: const Color(0xFF0F1923),
    cardTheme: CardThemeData(
      elevation: 0,
      color: const Color(0xFF1A2733),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Color(0xFF0F1923),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
    listTileTheme: const ListTileThemeData(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12))),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10)),
      side: BorderSide.none,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12))),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12))),
      ),
    ),
  );
}
