/// providers.dart — Shared Riverpod providers across the Flutter WOIS app.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/warehouse_config.dart';
import '../models/sim_frame.dart';
import '../core/api_client.dart';
import '../core/auth/auth_provider.dart';
import 'manual_robot_controller.dart';

/// The currently active (or being-designed) warehouse layout.
/// Written by the creator screen on Save / Publish;
/// consumed read-only by the floor view, dashboard, and any future 3-D viewer.
final warehouseConfigProvider = StateProvider<WarehouseConfig?>((ref) => null);
// ── Operations state ─────────────────────────────────────────────────────────

/// True once the user presses "Start Operations" after publishing.
/// When false the floor view shows a blank/black screen (fog of war).
final operationsStartedProvider = StateProvider<bool>((ref) => false);

// ── Fog-of-war: explored cells ────────────────────────────────────────────────

/// Set of "row,col" strings representing cells explored by robots.
/// Populated by the simulation engine via WebSocket; in the absence of a live
/// sim the Flutter app seeds it from robot scout progress updates.
/// When operationsStarted is true and a cell is NOT in this set → rendered black.
class ExploredCellsNotifier extends StateNotifier<Set<String>> {
  ExploredCellsNotifier() : super(const {});

  void markExplored(int row, int col) {
    if (!state.contains('$row,$col')) {
      state = {...state, '$row,$col'};
    }
  }

  void markRegion(int row, int col, int radius) {
    final next = {...state};
    for (var dr = -radius; dr <= radius; dr++) {
      for (var dc = -radius; dc <= radius; dc++) {
        next.add('${row + dr},${col + dc}');
      }
    }
    state = next;
  }

  void reset() => state = const {};

  bool isExplored(int row, int col) => state.contains('$row,$col');
}

final exploredCellsProvider =
    StateNotifierProvider<ExploredCellsNotifier, Set<String>>(
  (_) => ExploredCellsNotifier(),
);

// ── Active cell events (blinking floor cells) ─────────────────────────────────

/// Map from "row,col" → event descriptor. Any entry here causes the
/// corresponding floor cell to blink until the event is resolved (entry removed).
///
/// event descriptor format: "TYPE|COLOR|SPEED"
/// e.g. "REPLENISHMENT_NEEDED|#F97316|slow"
/// e.g. "CELL_BLOCKED|#EF4444|fast"
/// e.g. "BATTERY_CRITICAL|#EF4444|fast"
class ActiveEventsNotifier extends StateNotifier<Map<String, String>> {
  ActiveEventsNotifier() : super(const {});

  void raise(int row, int col, String eventType,
      {String color = '#F97316', String speed = 'slow'}) {
    state = {...state, '$row,$col': '$eventType|$color|$speed'};
  }

  void resolve(int row, int col) {
    final next = Map<String, String>.from(state);
    next.remove('$row,$col');
    state = next;
  }

  void resolveAll() => state = const {};

  bool hasEvent(int row, int col) => state.containsKey('$row,$col');

  String? eventFor(int row, int col) => state['$row,$col'];

  /// Parse color from event descriptor string.
  static String colorOf(String descriptor) {
    final parts = descriptor.split('|');
    return parts.length > 1 ? parts[1] : '#F97316';
  }

  /// Parse speed from event descriptor string.
  static bool isFast(String descriptor) {
    final parts = descriptor.split('|');
    return parts.length > 2 && parts[2] == 'fast';
  }
}

final activeEventsProvider =
    StateNotifierProvider<ActiveEventsNotifier, Map<String, String>>(
  (_) => ActiveEventsNotifier(),
);

// ── Simulation mode ───────────────────────────────────────────────────────────
/// 'automated' = robots move on their own at configurable speed.
/// 'manual'    = each step is triggered by the user pressing "Step".
final simulationModeProvider = StateProvider<String>((ref) => 'automated');

// ── Selected chatbot persona ──────────────────────────────────────────────────
/// Tracks the active chatbot persona globally so the floor canvas can gate
/// sabotage context-menu items on 'Sabotager'.
final selectedPersonaProvider = StateProvider<String>((ref) => 'Manager');

// ── Navigate-to-tab signal ────────────────────────────────────────────────────
/// Set to a tab index to signal the shell to switch to that tab.
/// Shell watches this and resets it to null after switching.
/// Index mapping (both mobile + desktop): 0=Dashboard 1=Floor 2=Craft 3=About…
final navigateToTabProvider = StateProvider<int?>((ref) => null);

// ── WMS commit paused flag ────────────────────────────────────────────────────
/// True while the simulation is flushing its 30-second cache to the backend.
/// When true, the floor shows a "Syncing WMS…" banner and motion is paused.
final wmsCommitInProgressProvider = StateProvider<bool>((ref) => false);

// ── Manual robot control ──────────────────────────────────────────────────────

/// ID of the robot currently selected for D-pad control.
/// Null = no robot selected (D-pad hidden).
final selectedRobotIdProvider = StateProvider<String?>((ref) => null);

/// Live positions of each robot while in manual mode.
/// Key = robot_id, Value = (row, col).
/// Updated on every D-pad move; drives the floor painter.
class ManualRobotPositionsNotifier
    extends StateNotifier<Map<String, ({int row, int col})>> {
  ManualRobotPositionsNotifier() : super(const {});

  void update(String robotId, int row, int col) {
    state = {...state, robotId: (row: row, col: col)};
  }

  void remove(String robotId) {
    final next = Map<String, ({int row, int col})>.from(state)
      ..remove(robotId);
    state = next;
  }

  void clear() => state = const {};
}

final manualRobotPositionsProvider = StateNotifierProvider<
    ManualRobotPositionsNotifier, Map<String, ({int row, int col})>>(
  (_) => ManualRobotPositionsNotifier(),
);

// ── ManualRobotController (Notifier-backed for stable Ref lifetime) ───────────

/// StateNotifier that owns [ManualRobotController] and gives it a [Ref]
/// that lives as long as the Riverpod container — never stale.
///
/// Usage from widgets:
///   ref.read(manualRobotControllerProvider.notifier).initialize(config)
///   ref.watch(manualRobotControllerProvider) // → ManualRobotController?
class ManualRobotNotifier extends StateNotifier<ManualRobotController?> {
  ManualRobotNotifier(this._ref) : super(null);

  // _ref is StateNotifierProviderRef — lives for the provider's lifetime.
  final Ref<ManualRobotController?> _ref;

  /// Create a fresh controller for [config].
  /// Clears all fog-of-war positions and selected robot first.
  void initialize(WarehouseConfig config) {
    state?.dispose();
    _ref.read(manualRobotPositionsProvider.notifier).clear();
    _ref.read(selectedRobotIdProvider.notifier).state = null;

    final auth = _ref.read(authProvider);
    final token = auth is AuthLoggedIn ? auth.token : null;

    state = ManualRobotController(
      config: config,
      token: token,
      onPositionUpdate: _ref.read(manualRobotPositionsProvider.notifier).update,
      onRemovePosition: _ref.read(manualRobotPositionsProvider.notifier).remove,
      onMarkExplored: _ref.read(exploredCellsProvider.notifier).markExplored,
      onEventRaise: (r, c, type, color, speed) => _ref
          .read(activeEventsProvider.notifier)
          .raise(r, c, type, color: color, speed: speed),
      readSelectedId: () => _ref.read(selectedRobotIdProvider),
      writeSelectedId: (id) =>
          _ref.read(selectedRobotIdProvider.notifier).state = id,
    );
  }

  void reset() {
    state?.dispose();
    state = null;
  }
}

final manualRobotControllerProvider =
    StateNotifierProvider<ManualRobotNotifier, ManualRobotController?>(
  (ref) => ManualRobotNotifier(ref),
);

// ── Live robot positions (polls /api/v1/robot/positions every 3 s) ────────────

/// Maps a REST robot payload + warehouse config → Flutter [Robot].
/// The payload is now enriched by the backend with [name] and [functional_type]
/// so downstream identity checks (e.g. inbound-only menus) work reliably.
Robot _mapApiRobot(Map<String, dynamic> r, WarehouseConfig config) {
  final id   = r['robot_id']       as String? ?? '';
  final name = r['name']           as String? ?? id;
  final type = r['robot_type']     as String? ?? 'AMR';
  final ft   = r['functional_type'] as String? ?? '';
  // Derive WS-compatible domain so robot.isInbound works correctly.
  final domain = ft == 'inbound_pick' ? 'INBOUND' : 'ANY';
  return Robot(
    id:      id,
    name:    name,
    type:    type,
    x:       (r['col'] as num? ?? 0).toDouble(),
    y:       (r['row'] as num? ?? 0).toDouble(),
    state:   (r['status'] as String? ?? 'IDLE').toUpperCase(),
    battery: ((r['battery_level'] as num? ?? 100.0) / 100.0).clamp(0.0, 1.0),
    domain:  domain,
  );
}

/// Polls live robot positions every 3 s.
/// Rebuilds automatically when [warehouseConfigProvider] changes.
final liveRobotsProvider =
    StreamProvider.autoDispose<List<Robot>>((ref) async* {
  final config = ref.watch(warehouseConfigProvider);
  if (config == null) {
    yield const [];
    return;
  }
  while (true) {
    try {
      final data = await ApiClient.instance.getRobotPositions(config.id);
      final robots = (data['robots'] as List? ?? [])
          .cast<Map<String, dynamic>>()
          .map((r) => _mapApiRobot(r, config))
          .toList();
      yield robots;
    } catch (_) {
      yield const [];
    }
    await Future.delayed(const Duration(seconds: 3));
  }
});

// ── Edit-access / view-mode ───────────────────────────────────────────────────

/// Result of the last heartbeat call for the current warehouse.
///
/// "EDITOR"  — this session holds the edit lock; bots run, WMS writes allowed.
/// "VIEWER"  — another session holds the lock; read-only / view-only mode.
/// ""        — heartbeat not yet called (before Start Operations).
///
/// The floor screen updates this on every heartbeat (every 45 s) so the UI
/// reacts if the previous editor closes their tab and this viewer becomes editor.
final editAccessProvider = StateProvider<String>((ref) => '');

/// Name of whoever holds the edit lock (shown in the viewer-mode banner).
final lockHolderNameProvider = StateProvider<String>((ref) => '');

// ── Blocked cells overlay ─────────────────────────────────────────────────────

/// Set of "row,col" strings for cells that have an active physical obstruction
/// (is_blocked=True in RealityCell). Used by FloorPainter to draw a red overlay.
/// Refreshed on demand (after placing/removing an obstacle) or periodically.
class BlockedCellsNotifier extends StateNotifier<Set<String>> {
  BlockedCellsNotifier() : super(const {});

  Future<void> refresh(String warehouseId) async {
    try {
      final cells = await ApiClient.instance.getBlockedCells(warehouseId);
      state = cells.map((c) => '${c['row']},${c['col']}').toSet();
    } catch (_) {
      // Keep previous state on network error — don't clear valid data.
    }
  }

  void addLocal(int row, int col) {
    state = {...state, '$row,$col'};
  }

  void removeLocal(int row, int col) {
    final next = Set<String>.from(state)..remove('$row,$col');
    state = next;
  }

  void reset() => state = const {};
}

final blockedCellsProvider =
    StateNotifierProvider<BlockedCellsNotifier, Set<String>>(
  (_) => BlockedCellsNotifier(),
);

// ── Inbound robot pallet cargo ────────────────────────────────────────────────

/// One pallet that an inbound robot is currently carrying.
class PalletData {
  const PalletData({required this.skuId, required this.truckId});
  final String skuId;
  final String truckId;
}

class RobotCargoNotifier extends StateNotifier<Map<String, PalletData>> {
  RobotCargoNotifier() : super(const {});

  /// Re-hydrate from backend RobotHolding table. Called on startup and after
  /// any operation that might lose in-memory state (e.g. page refresh).
  /// This makes cargo tracking transactional — the backend is the source of
  /// truth; the in-memory map is just a view over it.
  Future<void> hydrateFromBackend() async {
    try {
      final holdings = await ApiClient.instance.getActiveHoldings();
      final next = <String, PalletData>{};
      for (final h in holdings) {
        final robotId = h['robot_id'] as String?;
        final skuId   = h['sku_id']   as String?;
        final truckId = h['picked_from_id'] as String?;
        if (robotId != null && skuId != null && skuId.isNotEmpty) {
          next[robotId] = PalletData(
            skuId:   skuId,
            truckId: truckId ?? 'UNKNOWN',
          );
        }
      }
      state = next;
    } catch (_) {
      // Network unavailable — keep whatever is in memory; don't clear valid state.
    }
  }

  void loadPallet(String robotId, PalletData pallet) {
    state = {...state, robotId: pallet};
  }

  void clearCargo(String robotId) {
    final m = Map<String, PalletData>.from(state);
    m.remove(robotId);
    state = m;
  }
}

final robotCargoProvider =
    StateNotifierProvider<RobotCargoNotifier, Map<String, PalletData>>(
  (_) => RobotCargoNotifier(),
);

// ── Pallet staging SKU slots ──────────────────────────────────────────────────

const int kMaxStagingPallets = 5;

/// Pallets stored in one staging cell (enforces single-SKU, max-5 rule).
class StagingSlot {
  const StagingSlot({required this.skuId, required this.count});
  final String skuId;
  final int count;
}

class StagingNotifier extends StateNotifier<Map<String, StagingSlot>> {
  StagingNotifier() : super(const {});

  String _key(int row, int col) => '${row}_$col';

  /// Returns null if the drop is permitted, or an error message if not.
  String? canDrop(int row, int col, String skuId) {
    final slot = state[_key(row, col)];
    if (slot == null || slot.count == 0) return null; // empty — any SKU ok
    if (slot.skuId != skuId) {
      return 'SKU cannot be mixed — slot holds ${slot.skuId}';
    }
    if (slot.count >= kMaxStagingPallets) {
      return 'Staging slot is full (max $kMaxStagingPallets pallets)';
    }
    return null;
  }

  void drop(int row, int col, String skuId) {
    final k = _key(row, col);
    final existing = state[k];
    state = {
      ...state,
      k: StagingSlot(skuId: skuId, count: (existing?.count ?? 0) + 1),
    };
  }

  StagingSlot? slotAt(int row, int col) => state[_key(row, col)];
}

final stagingPalletsProvider =
    StateNotifierProvider<StagingNotifier, Map<String, StagingSlot>>(
  (_) => StagingNotifier(),
);

// ── Pending truck selection (set by Orders screen → consumed by Floor screen) ─
/// When the user taps "TRUCK ON ROAD" in the Orders screen we store the truck ID
/// here.  The Floor screen listens, selects that truck, and clears this to null.
final pendingTruckSelectionProvider = StateProvider<String?>((ref) => null);

// ── Live inbound trucks (polls every 5 s) ─────────────────────────────────────
/// Returns the latest inbound trucks + a shipments-by-truck map.
/// Consumed by both the Dashboard Fleet section and the Floor screen.
typedef InboundTruckData = ({
  List<Map<String, dynamic>> trucks,
  Map<String, List<Map<String, dynamic>>> shipmentsByTruck,
});

final inboundTrucksProvider =
    StreamProvider.autoDispose<InboundTruckData>((ref) async* {
  final config = ref.watch(warehouseConfigProvider);
  if (config == null) {
    yield (trucks: const [], shipmentsByTruck: const {});
    return;
  }
  while (true) {
    try {
      final trucks = await ApiClient.instance.getInboundTrucks(config.id);
      final shipments =
          await ApiClient.instance.getInboundShipments(config.id);
      final byTruck = <String, List<Map<String, dynamic>>>{};
      for (final s in shipments) {
        final tid = s['truck_id'] as String? ?? '';
        byTruck.putIfAbsent(tid, () => []).add(s);
      }
      yield (
        trucks: trucks,
        shipmentsByTruck: Map.unmodifiable(byTruck),
      );
    } catch (_) {
      yield (trucks: const [], shipmentsByTruck: const {});
    }
    await Future.delayed(const Duration(seconds: 5));
  }
});
