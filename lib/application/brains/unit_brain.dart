/// unit_brain.dart — the base contract every autonomous unit implements.
///
/// Age-of-Empires model: each unit owns its brain (perceive → decide → act, one
/// step per tick), runs a claimed Job to completion, then recharges and idles
/// waiting for the next system-issued Job. Units NEVER reference each other —
/// all coordination is through the JobBoard and the reservation providers.
///
/// The scheduler (robot_scout_simulation.dart) is a clock, not a controller: it
/// calls [perceiveAndDecide] on every unit (Phase 1), lets the arbiter grant
/// contested moves (Phase 1.5), then calls [act] on every unit (Phase 2).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/warehouse_config.dart';
import '../../warehouse_engine/services/pathfinding.dart';
import '../bay_resource.dart';
import '../job_board.dart';
import '../providers.dart';
import 'action_applier.dart';

/// Cells occupied by OTHER units, as `(col, row)` for the A* `occupied` set.
/// Fed to pathfinding as a SOFT penalty so units prefer to route around each
/// other — congestion-aware routing (P6 soft layer; the hard collision arbiter
/// with move-intent + alternate-approach is a separate pass). Soft only, so it
/// never removes a path or deadlocks.
Set<(int, int)> occupiedByOthers(WidgetRef ref, String selfId) {
  final positions = ref.read(manualRobotPositionsProvider);
  final out = <(int, int)>{};
  for (final e in positions.entries) {
    if (e.key == selfId) continue;
    out.add((e.value.col, e.value.row));
  }
  return out;
}

/// Manually-placed blockers as `(col, row)` for the A* `walkable` predicate.
///
/// HARD, unlike [occupiedByOthers], which is a soft cost. The scheduler makes a
/// blocked cell impassable to `tryStep`, so the PLANNER must agree: if A* routes
/// through a blocker the executor refuses that step forever and the unit
/// livelocks, replanning the same blocked path (it cannot even fail out, because
/// attempts only increment via releaseOrFail, which movement never calls).
/// Every brain that paths must AND this into its walkable check.
Set<(int, int)> blockedCellsFor(WidgetRef ref) {
  final out = <(int, int)>{};
  for (final key in ref.read(blockedCellsProvider)) {
    final parts = key.split(','); // blockedCells keys are 'row,col'
    if (parts.length != 2) continue;
    final r = int.tryParse(parts[0]);
    final c = int.tryParse(parts[1]);
    if (r == null || c == null) continue;
    out.add((c, r)); // A* tuples are (col, row)
  }
  return out;
}

/// General lifecycle shared by all units. Role-specific sub-states (e.g. a
/// truck's `waitingAtBay`) are held privately by that brain.
enum UnitLifecycle {
  idle, // no Job; standing still, draining nothing, re-scanning the board
  navigating, // moving toward a claimed Job's next waypoint
  working, // performing a timed action (pick/drop/pack/charge-adjacent)
  seekingCharge, // battery low → pathing to a charger dock
  charging, // parked on a charger, battery rising
  offline, // battery 0 → a hard obstacle until a recovery tow arrives
}

/// Everything a brain needs each tick, without letting it see other brains.
class BrainContext {
  const BrainContext({
    required this.ref,
    required this.config,
    required this.tick,
  });

  /// Read/write providers (job board, positions, reservations, …). WidgetRef to
  /// match RobotScoutSimulation and the existing controllers.
  final WidgetRef ref;
  final WarehouseConfig config;

  /// Monotonic sim tick — the deterministic clock (never wall-clock).
  final int tick;

  JobBoardNotifier get board => ref.read(jobBoardProvider.notifier);
}

/// One autonomous unit. Concrete brains (scout, inbound robot, putaway robot,
/// trucks, …) extend this and fill in the two phase methods.
abstract class UnitBrain {
  UnitBrain({
    required this.id,
    required this.role,
    required this.pos,
    this.battery = 100.0,
  });

  final String id;
  final UnitRole role;

  /// Authoritative position (v2 §3.6): the brain owns its cell; the renderer
  /// mirrors it via manualRobotPositionsProvider. Scout `_bots` positions retired.
  GridPos pos;

  /// 0–100. Drained by moves/actions; only robots charge. Trucks ignore it.
  double battery;

  UnitLifecycle lifecycle = UnitLifecycle.idle;

  /// The single Job slot that cycles null → Job → null (the unit is immortal).
  String? currentJobId;

  /// Consecutive ticks this unit has been carrying cargo. The scheduler's global
  /// cargo-hold safety net uses it to force-drop a pallet from a robot wedged in
  /// ANY state (not just a drive, which the per-brain give-up covers), so a pallet
  /// can never be stranded on a robot forever. Reset the moment cargo clears.
  int cargoHeldTicks = 0;

  bool get isIdle => currentJobId == null && lifecycle == UnitLifecycle.idle;

  /// Phase 1 — sense the world, (maybe) claim a Job, and register an intended
  /// move/action for this tick. Must NOT mutate shared world state that another
  /// unit's Phase 1 reads (claims via CAS are the exception — they're atomic).
  void perceiveAndDecide(BrainContext ctx);

  /// Phase 2 — execute the intent granted for this tick (advance one cell, or
  /// tick one unit of a timed action, or commit a pick/drop).
  void act(BrainContext ctx);

  // ── Charging (P5) ──────────────────────────────────────────────────────────
  // Battery drains on moves (ActionApplier). When a chargeable robot is IDLE and
  // below the seek threshold it drives to a free charger dock and tops up to a
  // HIGHER resume threshold — the hysteresis prevents the charge/work/charge
  // thrash (EC-1). The scheduler drives this so per-brain FSMs stay untouched.
  // Mid-job (carrier-critical) preemption + die-en-route bounds are refinements.

  static const double kSeekBattery = 20.0;
  static const double kResumeBattery = 60.0;
  static const double kChargePerTick = 0.8;

  bool _charging = false;
  bool _atCharger = false;
  GridPos? _charger;
  List<GridPos> _chargePath = const [];
  int _chargeIdx = 0;

  bool get isCharging => _charging;

  // Scouts are excluded: they run a standing order (never idle), so the idle
  // charge-gate never fires for them — the energy model doesn't cleanly apply
  // to continuous scouting (review CHG-1). Job-running robots charge between jobs.
  bool get isChargeable =>
      role == UnitRole.inboundRobot ||
      role == UnitRole.putawayRobot ||
      role == UnitRole.pickRobot ||
      role == UnitRole.outboundRobot;

  bool get _batteryLow => battery < kSeekBattery;

  /// Scheduler calls this before decide(): an idle, low-battery robot claims a
  /// charger and heads there. Returns true while (now or already) charging, so
  /// the scheduler skips this unit's work-claiming.
  bool startChargeIfNeeded(BrainContext ctx) {
    if (_charging) return true;
    if (!isChargeable || !_batteryLow || !isIdle) return false;
    final chargers = _chargerCells(ctx.config);
    if (chargers.isEmpty) return false; // no chargers → rules-only (EC-3 note)
    final arb = ctx.ref.read(chargerOccupancyProvider.notifier);
    final claimed = arb.claimFirstFree(chargers, id);
    if (claimed == null) return false; // all busy → retry next tick
    final path = _chargePathTo(ctx.config, claimed);
    if (path.isEmpty) {
      arb.release(claimed.row, claimed.col);
      return false;
    }
    _charging = true;
    _atCharger = false;
    _charger = claimed;
    _chargePath = path;
    _chargeIdx = 0;
    lifecycle = UnitLifecycle.seekingCharge;
    return true;
  }

  /// Scheduler calls this in place of act() while charging.
  void chargeStep(BrainContext ctx) {
    if (!_atCharger) {
      if (_chargeIdx < _chargePath.length - 1) {
        _chargeIdx++;
        ActionApplier(ctx.ref, ctx.config).moveTo(this, _chargePath[_chargeIdx]);
        lifecycle = UnitLifecycle.seekingCharge;
        return;
      }
      _atCharger = true; // arrived — charge this same tick (no dead dwell tick)
    }
    battery = (battery + kChargePerTick).clamp(0.0, 100.0);
    lifecycle = UnitLifecycle.charging;
    if (battery >= kResumeBattery) {
      ctx.ref
          .read(chargerOccupancyProvider.notifier)
          .release(_charger!.row, _charger!.col);
      _charging = false;
      _atCharger = false;
      _charger = null;
      _chargePath = const [];
      _chargeIdx = 0;
      lifecycle = UnitLifecycle.idle;
    }
  }

  List<GridPos> _chargerCells(WarehouseConfig cfg) => [
        for (final c in cfg.cells)
          if (c.type.isCharger) (row: c.row, col: c.col)
      ];

  List<GridPos> _chargePathTo(WarehouseConfig cfg, GridPos to) {
    final pf = AStarPathfinder(cols: cfg.cols, rows: cfg.rows);
    final raw = pf.findPath(
      (pos.col, pos.row),
      (to.col, to.row),
      walkable: (c) => _chargeWalkable(cfg, c.$2, c.$1),
    );
    return raw.map((p) => (row: p.$2, col: p.$1)).toList();
  }

  bool _chargeWalkable(WarehouseConfig cfg, int row, int col) {
    if (row < 0 || row >= cfg.rows || col < 0 || col >= cfg.cols) return false;
    final t = cfg.cellAt(row, col)?.type ?? CellType.empty;
    return t.isWalkable || t == CellType.empty || t.isCharger;
  }

  // ── Offline / battery-0 + recovery (P5 / review CHG-3) ──────────────────────

  bool get isOffline => lifecycle == UnitLifecycle.offline;

  /// The scheduler calls this when a robot's battery hits 0 mid-work: it drops
  /// its Job (so nothing is stuck), sheds cargo, resets its FSM (via [onReset]),
  /// and goes offline until a roadside recharge revives it — battery-0 now has a
  /// real consequence + a recovery path (review CHG-3).
  void goOffline(BrainContext ctx) {
    final jid = currentJobId;
    if (jid != null) ctx.board.releaseOrFail(jid);
    ActionApplier(ctx.ref, ctx.config).clearCargo(this);
    onReset(ctx); // brain releases any held reservations + clears its FSM
    currentJobId = null;
    lifecycle = UnitLifecycle.offline;
  }

  /// One tick of in-place roadside recovery; revives to idle at the resume level.
  void offlineRecoverStep() {
    battery = (battery + kChargePerTick * 0.5).clamp(0.0, 100.0);
    if (battery >= kResumeBattery) lifecycle = UnitLifecycle.idle;
  }

  /// Overridden by concrete brains to release any held reservations and reset
  /// their private FSM when forced idle (on going offline). Default: no-op.
  void onReset(BrainContext ctx) {}

  // ── Shared head-of-line recovery (used by every driving robot brain) ─────────
  // Robots move one cell/tick via ActionApplier.tryStep. When the next cell is
  // held by another unit this tick tryStep fails; the brain counts consecutive
  // blocked ticks and calls [recoverBlocked] to react. Kept in ONE place so all
  // robots behave identically (the per-brain copies had already drifted).
  //
  // Escalation, cheapest first (thresholds measured on the seeded sweep — an
  // earlier yield clears head-of-line jams AND ships more than the old 4/8, while
  // a forced long cross-aisle detour was tried and measured WORSE on both: it
  // burns the give-up budget on a wasteful trek, so it was dropped):
  //   • [kSoftReplanAt] — congestion-aware replan; takes a genuinely different
  //     route only when a SHORT one exists (a nearby cross-aisle), else holds.
  //   • [kDetourAt]     — re-check that replan (adopt it only if its FIRST step is
  //     free right now), and if the robot is still nose-to-nose, YIELD: step to a
  //     free side cell so the opposing unit can pass, then re-plan from there. In
  //     a 1-wide aisle the only free neighbour is backward, which still clears the
  //     lane for the other robot.
  // If nothing frees the robot, its per-brain give-up eventually aborts the job
  // and re-attempts, so a robot can never be permanently wedged.
  static const int kSoftReplanAt = 3;
  static const int kDetourAt = 6;

  /// One tick of blocked-recovery. Returns a new path (from the current [pos] to
  /// [goal]) to adopt, or null to hold. [findPath]/[sideStep] are the calling
  /// brain's own domain-typed helpers (each robot has a different walkable set).
  /// May physically step the unit aside (via [applier]) as a last resort.
  List<GridPos>? recoverBlocked({
    required ActionApplier applier,
    required int blockedTicks,
    required GridPos goal,
    required List<GridPos> Function(
            GridPos from, GridPos to, Set<(int, int)>? occ, int? penalty)
        findPath,
    required GridPos? Function(Set<(int, int)>? occ) sideStep,
  }) {
    final occ = occupiedByOthers(applier.ref, id);
    if (blockedTicks == kSoftReplanAt) {
      final replan = findPath(pos, goal, occ, null);
      if (replan.length > 1) return replan;
    } else if (blockedTicks >= kDetourAt) {
      // Re-check the congestion-aware replan; adopt only if its first step is
      // free right now (the blocker may have moved / another route opened).
      final replan = findPath(pos, goal, occ, null);
      if (replan.length > 1 &&
          !occ.contains((replan[1].col, replan[1].row))) {
        return replan;
      }
      // Still nose-to-nose — yield: step to a free side cell so it can pass.
      final side = sideStep(occ);
      if (side != null &&
          findPath(side, goal, null, null).length > 1 &&
          applier.tryStep(this, side)) {
        return findPath(pos, goal, occ, null);
      }
    }
    return null;
  }

  // ── Idle patrol — keep the floor alive (the sim must always SIMULATE) ────────
  // A robot that claimed no Job this tick must NOT freeze: it takes one
  // scout-style step toward the nearest unrevealed cell (revealing fog), so a
  // warehouse with no pending work still visibly moves instead of looking dead —
  // the "absolutely no simulation" symptom. The instant a Job appears, Phase-1
  // perceiveAndDecide claims it and real warehouse work takes over. Only healthy
  // real robots patrol (gated by isChargeable + battery); trucks, generators and
  // the stock monitor never wander.

  final List<GridPos> _patrolHistory = [];
  static const int _patrolHistoryDepth = 6;
  // Bias: down, left, right, up — head toward the dark, like the retired scout.
  static const List<(int, int)> _patrolBias = [(1, 0), (0, -1), (0, 1), (-1, 0)];

  bool _patrolRecent(int r, int c) =>
      _patrolHistory.any((h) => h.row == r && h.col == c);

  /// One idle-patrol step. Called by the scheduler for a unit still idle after
  /// Phase 1 (i.e. it found no Job). Safe no-op for non-robots / low battery.
  void idleStep(BrainContext ctx) {
    if (!isChargeable || _batteryLow) return; // don't ground a robot on patrol
    final cfg = ctx.config;
    final explored = ctx.ref.read(exploredCellsProvider);

    (int, int)? best;
    // 1) Highest-bias walkable, non-recent neighbour that borders darkness.
    for (final d in _patrolBias) {
      final nr = pos.row + d.$1;
      final nc = pos.col + d.$2;
      if (!_patrolWalkable(cfg, nr, nc) || _patrolRecent(nr, nc)) continue;
      if (_patrolBordersDark(cfg, explored, nr, nc)) {
        best = (nr, nc);
        break;
      }
    }
    // 2) Fallback: any walkable, non-recent neighbour (keep moving).
    if (best == null) {
      for (final d in _patrolBias) {
        final nr = pos.row + d.$1;
        final nc = pos.col + d.$2;
        if (!_patrolWalkable(cfg, nr, nc) || _patrolRecent(nr, nc)) continue;
        best = (nr, nc);
        break;
      }
    }
    if (best == null) {
      _patrolHistory.clear(); // boxed in → forget history so we can retrace
      return;
    }

    final next = (row: best.$1, col: best.$2);
    // tryStep honours the per-tick cell reservation (P6 collision arbiter): if
    // the cell is taken this tick the robot simply holds and retries next tick.
    // NOTE: lifecycle stays `idle` on purpose — flipping it to navigating would
    // make isIdle false, stopping both the next patrol step and the low-battery
    // charge-seek gate. An idle-patrolling robot is still logically idle.
    if (ActionApplier(ctx.ref, cfg).tryStep(this, next, drainBattery: false)) {
      _patrolHistory.add((row: pos.row, col: pos.col));
      if (_patrolHistory.length > _patrolHistoryDepth) _patrolHistory.removeAt(0);
    }
  }

  bool _patrolWalkable(WarehouseConfig cfg, int r, int c) {
    if (r < 0 || r >= cfg.rows || c < 0 || c >= cfg.cols) return false;
    final t = cfg.cellAt(r, c)?.type ?? CellType.empty;
    if (t.isRack ||
        t == CellType.obstacle ||
        t == CellType.tree ||
        t == CellType.packStation) {
      return false;
    }
    return t.isWalkable || t == CellType.empty;
  }

  bool _patrolBordersDark(
      WarehouseConfig cfg, Set<String> explored, int tr, int tc) {
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        if (dr == 0 && dc == 0) continue;
        final nr = tr + dr;
        final nc = tc + dc;
        if (nr < 0 || nr >= cfg.rows || nc < 0 || nc >= cfg.cols) continue;
        if (!explored.contains('$nr,$nc')) return true;
      }
    }
    return false;
  }
}

/// Registry of every live unit. `all()` iterates in a deterministic order
/// (insertion, then id) so the scheduler and arbiter are reproducible.
class UnitRegistryNotifier extends StateNotifier<Map<String, UnitBrain>> {
  UnitRegistryNotifier() : super(const {});

  void register(UnitBrain brain) {
    state = {...state, brain.id: brain};
  }

  void remove(String id) {
    if (!state.containsKey(id)) return;
    state = {...state}..remove(id);
  }

  void clear() => state = const {};

  /// Deterministic iteration: id-sorted.
  List<UnitBrain> all() {
    final list = state.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return list;
  }

  Iterable<UnitBrain> withRole(UnitRole role) =>
      all().where((b) => b.role == role);
}

final unitRegistryProvider =
    StateNotifierProvider<UnitRegistryNotifier, Map<String, UnitBrain>>(
  (_) => UnitRegistryNotifier(),
);
