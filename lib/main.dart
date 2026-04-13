/// main.dart — App entry point, router setup, and deep-link handling.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:app_links/app_links.dart';
import 'package:google_fonts/google_fonts.dart';

import 'core/auth/auth_provider.dart';
import 'core/sim_ws.dart';
import 'core/api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'application/robot_scout_simulation.dart';
import 'screens/login_screen.dart';
import 'screens/floor_screen.dart';
import 'screens/game_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/warehouse_creator_screen.dart';
import 'models/warehouse_config.dart';
import 'application/providers.dart';
import 'widgets/adaptive_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: WoisApp()));
}

// (Browser right-click suppression is handled in web/index.html via JS).

// ── Router ────────────────────────────────────────────────────────────────────

final _router = GoRouter(
  initialLocation: '/login',
  redirect: (context, state) {
    // Redirect is driven by auth state — handled in ShellRoute below.
    return null;
  },
  routes: [
    GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
    GoRoute(path: '/dashboard', builder: (_, __) => const AdaptiveShell()),
    GoRoute(path: '/floor', builder: (_, __) => const FloorScreen()),
    GoRoute(path: '/game', builder: (_, __) => const GameScreen()),
    GoRoute(path: '/chat', builder: (_, __) => const ChatScreen()),
    GoRoute(
        path: '/warehouse', builder: (_, __) => const WarehouseCreatorScreen()),
  ],
);

// ── App ───────────────────────────────────────────────────────────────────────

class WoisApp extends ConsumerStatefulWidget {
  const WoisApp({super.key});
  @override
  ConsumerState<WoisApp> createState() => _WoisAppState();
}

class _WoisAppState extends ConsumerState<WoisApp> {
  StreamSubscription<Uri?>? _linkSub;

  @override
  void initState() {
    super.initState();
    _listenDeepLinks();
    _checkWebOAuthCallback();
    if (!kIsWeb) _restoreConfigNative();
  }

  /// On native (Android/iOS), restore the last saved warehouse config from
  /// SharedPreferences on app restart. On web this is handled inside
  /// _checkWebOAuthCallback() after OAuth processing.
  void _restoreConfigNative() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (ref.read(warehouseConfigProvider) != null) return;
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString('warehouse_config') ??
          prefs.getString('warehouse_autosave');
      if (code == null) return;
      final cfg = WarehouseConfig.fromShareCode(code);
      if (cfg != null && mounted) {
        ref.read(warehouseConfigProvider.notifier).state = cfg;
        // If auth already completed before the first frame rendered (fast
        // localhost/emulator), the authProvider listener already fired but found
        // cfg == null and returned early.  Re-trigger restoration now.
        final auth = ref.read(authProvider);
        if (auth is AuthLoggedIn) {
          _restoreExplorationState();
        }
      }
    });
  }

  /// On web, after OAuth the page reloads at:
  /// Also handles ?wh=<base64> warehouse share links.
  void _checkWebOAuthCallback() {
    if (!kIsWeb) return;
    final uri = Uri.base;
    if (uri.queryParameters.containsKey('wois_token') ||
        uri.queryParameters.containsKey('auth_error')) {
      // Use a microtask so handleOAuthCallback fires before any async work in
      // _restore() can set AuthLoggedOut and navigate away.
      Future.microtask(() {
        ref.read(authProvider.notifier).handleOAuthCallback(uri);
      });
      // Still need to restore any warehouse the user previously published.
      // The OAuth redirect URL doesn't carry config data — it lives in prefs.
      _scheduleWebConfigRestore();
      return;
    }
    // Import shared warehouse config if present in URL.
    // Always assign a fresh ID so the importing user gets their own copy
    // in the DB rather than overwriting the original author's warehouse.
    final whCode = uri.queryParameters['wh'];
    if (whCode != null && whCode.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final cfg = WarehouseConfig.fromShareCode(whCode);
        if (cfg != null) {
          ref.read(warehouseConfigProvider.notifier).state = cfg.copyWith(
            id: 'wh-${DateTime.now().millisecondsSinceEpoch}',
            ownerId: '', // will be stamped at publish time
          );
        }
      });
    } else {
      // Plain refresh — restore last saved config from SharedPreferences.
      _scheduleWebConfigRestore();
    }
  }

  /// Schedules a post-frame restore of [warehouseConfigProvider] from
  /// SharedPreferences.  Safe to call multiple times — the guard inside
  /// prevents double-assignment.
  void _scheduleWebConfigRestore() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (ref.read(warehouseConfigProvider) != null) return;
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString('warehouse_config') ??
          prefs.getString('warehouse_autosave');
      if (code == null) return;
      final cfg = WarehouseConfig.fromShareCode(code);
      if (cfg != null && mounted) {
        ref.read(warehouseConfigProvider.notifier).state = cfg;
        // If auth already completed before this postFrameCallback set the
        // config (fast network / localhost), the authProvider listener fired
        // and found cfg==null, so we must re-trigger restoration here.
        // Otherwise, the authProvider listener below handles it once
        // the token is confirmed.
        final auth = ref.read(authProvider);
        if (auth is AuthLoggedIn) {
          _restoreExplorationState();
        }
      }
    });
  }

  /// Handle the OAuth deep-link callback: wois://auth-callback?wois_token=...
  void _listenDeepLinks() {
    final appLinks = AppLinks();
    // Handle app-already-open deep link
    _linkSub = appLinks.uriLinkStream.listen((Uri uri) {
      if (uri.host == 'auth-callback') {
        ref.read(authProvider.notifier).handleOAuthCallback(uri);
      }
    });
    // Handle app-launched-via-deep-link
    appLinks.getInitialLink().then((Uri? uri) {
      if (uri != null && uri.host == 'auth-callback') {
        ref.read(authProvider.notifier).handleOAuthCallback(uri);
      }
    });
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch auth — redirect when state changes
    ref.listen<AuthState>(authProvider, (prev, next) {
      if (next is AuthLoggedIn) {
        // Start WebSocket when signed in
        ref.read(simFrameProvider.notifier).connect();
        _router.go('/dashboard');
        // Restore exploration state on initial app load (AuthLoading) AND on
        // re-login after a session expiry (AuthLoggedOut → AuthLoggedIn).
        // Skip only if we were already logged in (e.g. token silently refreshed).
        if (prev is! AuthLoggedIn) {
          _restoreExplorationState();
        }
      } else if (next is AuthLoggedOut || next is AuthError) {
        ref.read(simFrameProvider.notifier).disconnect();
        _router.go('/login');
      }
    });

    return MaterialApp.router(
      title: 'WOIS — Warehouse AI Sim',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      routerConfig: _router,
    );
  }

  /// Called after auth is confirmed (token set) to restore the fog-of-war and
  /// ops state from the backend if the warehouse was already being explored.
  Future<void> _restoreExplorationState() async {
    if (!mounted) return;
    // Wait for warehouseConfigProvider to be populated by _restoreConfigNative.
    // On fast networks (emulator/localhost) auth validates before the first frame
    // renders, so we poll briefly rather than relying on a single microtask.
    WarehouseConfig? cfg;
    for (int i = 0; i < 20; i++) {
      cfg = ref.read(warehouseConfigProvider);
      if (cfg != null) break;
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
    }
    if (cfg == null) return;
    if (ref.read(operationsStartedProvider)) return; // already running

    // ── 1. Ensure warehouse row exists in DB ───────────────────────────────
    // If the very first publish failed (e.g. a previous FK bug) the warehouse
    // is in SharedPreferences but not in the DB. Robots have no reality data
    // and the dashboard stays empty forever. Fix by silently re-publishing
    // whenever the warehouse ID is missing from the DB.
    try {
      final status = await ApiClient.instance.getWarehouseStatus(cfg.id);
      if (status == null && mounted) {
        final auth = ref.read(authProvider);
        final userId = auth is AuthLoggedIn ? auth.user.id : 'local';
        await ApiClient.instance.publishWarehouse(
          warehouseId: cfg.id,
          name: cfg.name,
          configJson: cfg.toShareCode(),
          ownerId: userId,
        );
        debugPrint('🔄 Auto-republished missing warehouse ${cfg.id}');
      }
    } catch (_) {
      // Backend offline — skip re-publish, will retry on next start.
    }

    // ── 2. Restore fog-of-war / ops state ─────────────────────────────────
    try {
      final cells = await ApiClient.instance.getExploredCells(cfg.id);
      if (cells.isNotEmpty && mounted) {
        final exploredN = ref.read(exploredCellsProvider.notifier);
        for (final cell in cells) {
          exploredN.markExplored(cell[0], cell[1]);
        }
        ref.read(simulationModeProvider.notifier).state = 'manual';
        ref.read(operationsStartedProvider.notifier).state = true;
        ref.read(manualRobotControllerProvider.notifier).initialize(cfg);
        _restartScoutSim(cfg);
        unawaited(_restoreRobotCargo());
      } else {
        // Backend online but no cells recorded yet — check local ops flag.
        await _restoreFromLocalPrefs(cfg);
      }
    } catch (_) {
      // Backend offline — fall back to locally persisted state.
      await _restoreFromLocalPrefs(cfg);
    }
  }

  /// Restores ops state from SharedPreferences when the backend is unavailable.
  Future<void> _restoreFromLocalPrefs(WarehouseConfig cfg) async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final wasStarted = prefs.getBool('ops_started') ?? false;
    final opsWhId = prefs.getString('ops_warehouse_id');
    if (!wasStarted || opsWhId != cfg.id) return;
    if (!mounted) return;

    // Restore explored cells saved by the last 30-second flush.
    final localJson = prefs.getString('explored_cells_${cfg.id}');
    if (localJson != null) {
      try {
        final keys = (jsonDecode(localJson) as List).cast<String>();
        final exploredN = ref.read(exploredCellsProvider.notifier);
        for (final key in keys) {
          final parts = key.split(',');
          if (parts.length == 2) {
            final r = int.tryParse(parts[0]);
            final c = int.tryParse(parts[1]);
            if (r != null && c != null) exploredN.markExplored(r, c);
          }
        }
      } catch (_) {
        // Corrupt cache — start fresh.
      }
    }

    ref.read(simulationModeProvider.notifier).state = 'manual';
    ref.read(operationsStartedProvider.notifier).state = true;
    ref.read(manualRobotControllerProvider.notifier).initialize(cfg);
    _restartScoutSim(cfg);
    unawaited(_restoreRobotCargo());
  }

  /// Fetches all active robot holdings from the backend and seeds
  /// [robotCargoProvider] so cargo is not lost after a page refresh.
  Future<void> _restoreRobotCargo() async {
    try {
      final holdings = await ApiClient.instance.getActiveHoldings();
      if (!mounted) return;
      final cargoNotifier = ref.read(robotCargoProvider.notifier);
      for (final h in holdings) {
        final robotId = h['robot_id'] as String?;
        final skuId = h['sku_id'] as String?;
        final truckId = h['picked_from_id'] as String? ?? '';
        if (robotId != null && skuId != null) {
          cargoNotifier.loadPallet(
              robotId, PalletData(skuId: skuId, truckId: truckId));
        }
      }
    } catch (_) {
      // Non-fatal — cargo starts empty; robot re-pick will reload it.
    }
  }

  /// Creates a fresh RobotScoutSimulation for [cfg] in manual mode (paused).
  /// The 30-second flush timer still runs so any STEP-driven discoveries
  /// reach the backend, but robots don't auto-move.
  void _restartScoutSim(WarehouseConfig cfg) {
    final prev = ref.read(scoutSimulationProvider);
    prev?.dispose();
    final scout = RobotScoutSimulation(
      config: cfg,
      ref: ref,
      isSaboteur: false,
    );
    ref.read(scoutSimulationProvider.notifier).state = scout;
    // Manual mode: never create the step timer — robots only move via STEP.
    scout.startManual();
  }

  ThemeData _buildTheme() {
    final mono = GoogleFonts.shareTechMono();
    final monoFamily = mono.fontFamily!;
    return ThemeData(
      colorScheme: const ColorScheme.dark(
        surface: Color(0xFF0D1117),
        primary: Color(0xFF00D4FF),
        secondary: Color(0xFF00FF88),
        error: Color(0xFFFF4444),
      ),
      scaffoldBackgroundColor: const Color(0xFF0D1117),
      fontFamily: monoFamily,
      textTheme: GoogleFonts.shareTechMonoTextTheme(
        ThemeData.dark().textTheme.apply(
              bodyColor: const Color(0xFFE6EDF3),
              displayColor: const Color(0xFF00D4FF),
            ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xFF0D1117),
        foregroundColor: const Color(0xFF00D4FF),
        elevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: monoFamily,
          fontSize: 15,
          color: const Color(0xFF00D4FF),
          letterSpacing: 1.5,
        ),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xFF30363D), width: 1),
        ),
        elevation: 0,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF00D4FF),
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: TextStyle(fontFamily: monoFamily, fontSize: 13),
        ),
      ),
    );
  }
}
