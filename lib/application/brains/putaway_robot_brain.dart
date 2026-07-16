/// putaway_robot_brain.dart — the "cart" (P1).
///
/// The first fully autonomous ops unit: it pull-claims a `putaway` Job, drives
/// to the staged pallet, picks it, runs the 5.1–5.4 rule to choose a pallet /
/// case / loose destination, drives there, drops (unwrapping via UOM
/// conversion), and closes the Job — then idles waiting for the next.
///
/// This is where `assignPutaway`'s logic finally *fires* under automation: the
/// original "no cart moves" bug is dead the moment one of these claims a Job.
///
/// P1 arbiter is pass-through, so the whole FSM step runs in [act]; contested-
/// cell resolution (the two-phase move/grant split) lands with the arbiter in P6.
library;

import '../../models/warehouse_config.dart';
import '../../warehouse_engine/services/pathfinding.dart';
import '../bay_resource.dart';
import '../job_board.dart';
import 'action_applier.dart';
import 'unit_brain.dart';

enum _PR { idle, toStaging, picking, toRack, dropping }

class PutawayRobotBrain extends UnitBrain {
  PutawayRobotBrain({required super.id, required super.pos})
      : super(role: UnitRole.putawayRobot);

  static const int kPickTicks = 3;
  static const int kDropTicks = 2;
  static const double kReplenishThreshold = 0.5;

  _PR _state = _PR.idle;
  String? _jobId;
  String _sku = '';
  GridPos? _staging;
  GridPos? _rack;
  int _dropAmount = 0; // in the destination rack's native unit

  List<GridPos> _path = const [];
  int _pathIdx = 0;
  int _ticksLeft = 0;

  // ── Phase 1: claim work when idle ──────────────────────────────────────────

  @override
  void perceiveAndDecide(BrainContext ctx) {
    if (_state != _PR.idle) return;
    final board = ctx.board;
    for (final job in board.claimableFor(UnitRole.putawayRobot)) {
      final src = job.src;
      if (src == null) continue;
      // Decide the destination BEFORE claiming/draining staging (review DL-2,
      // F1-fsm): a capacity-aware 5.1–5.4 that won't over-fill. If no legal rack
      // exists, leave the pallet staged and the job unclaimed for a later retry.
      final dest = _decideDestination(ctx.config, job.skuId);
      if (dest == null) continue;
      if (!board.claim(job.id, id)) continue;
      // Reserve the destination face so two carts can't fill the same cell
      // (F2-fsm): if it's already reserved, drop the claim and retry later.
      final destCell = (row: dest.row, col: dest.col);
      final rackRes = ctx.ref.read(rackReservationProvider.notifier);
      if (rackRes.claimFirstFree([destCell], id) == null) {
        board.release(job.id);
        continue;
      }

      final approach =
          _adjacentWalkable(ctx.config, src.row, src.col, occupiedByOthers(ctx.ref, id));
      final path =
          approach == null ? const <GridPos>[] : _findPath(ctx.config, pos, approach, occupiedByOthers(ctx.ref, id));
      if (path.isEmpty) {
        board.release(job.id); // couldn't reach the pallet — let someone else try
        rackRes.release(destCell.row, destCell.col);
        continue;
      }
      _jobId = job.id;
      currentJobId = job.id;
      _sku = job.skuId;
      _staging = src;
      _rack = destCell;
      _dropAmount = dest.amount;
      _path = path;
      _pathIdx = 0;
      _state = _PR.toStaging;
      lifecycle = UnitLifecycle.navigating;
      board.markActive(job.id);
      return;
    }
  }

  // ── Phase 2: run the FSM one step ──────────────────────────────────────────

  @override
  void act(BrainContext ctx) {
    final applier = ActionApplier(ctx.ref, ctx.config);
    switch (_state) {
      case _PR.idle:
        lifecycle = UnitLifecycle.idle;

      case _PR.toStaging:
        if (_advance(applier)) {
          _state = _PR.picking;
          _ticksLeft = kPickTicks;
          lifecycle = UnitLifecycle.working;
        }

      case _PR.picking:
        if (--_ticksLeft <= 0) {
          // Secure the path to the (pre-decided) rack BEFORE draining staging,
          // so an abort never leaves the staged pallet destroyed (review DL-2).
          final approach = _adjacentWalkable(
              ctx.config, _rack!.row, _rack!.col, occupiedByOthers(ctx.ref, id));
          final path = approach == null
              ? const <GridPos>[]
              : _findPath(ctx.config, pos, approach, occupiedByOthers(ctx.ref, id));
          if (path.isEmpty) {
            _abort(ctx); // rack now unreachable — staging still intact
            return;
          }
          applier.pickFromStaging(this, _staging!, _sku);
          _path = path;
          _pathIdx = 0;
          _state = _PR.toRack;
          lifecycle = UnitLifecycle.navigating;
        }

      case _PR.toRack:
        if (_advance(applier)) {
          _state = _PR.dropping;
          _ticksLeft = kDropTicks;
          lifecycle = UnitLifecycle.working;
        }

      case _PR.dropping:
        if (--_ticksLeft <= 0) {
          // Credit the Order by what the rack ACTUALLY absorbed, not a fixed
          // amount — no phantom over-credit if the cell clamped (review F2-fsm).
          final absorbed = applier.dropToRack(this, _rack!, _sku, _dropAmount);
          ctx.ref
              .read(rackReservationProvider.notifier)
              .release(_rack!.row, _rack!.col); // dest filled → free the reservation
          // absorbed is in the rack's native unit; convert to loose-equiv
          // (loose→×1, case→×4, pallet→×48) via kLoosePerPallet / _dropAmount.
          ctx.board.completeJob(_jobId!,
              progressUnits: absorbed * (kLoosePerPallet ~/ _dropAmount));
          _reset();
          lifecycle = UnitLifecycle.idle;
        }
    }
  }

  /// Advance one cell along the current path; returns true once at the end.
  int _blockedTicks = 0;
  bool _advance(ActionApplier applier) {
    if (_pathIdx < _path.length - 1) {
      if (applier.tryStep(this, _path[_pathIdx + 1])) {
        _pathIdx++;
        _blockedTicks = 0;
        return false;
      }
      _blockedTicks++;
      final goal = _path.last;
      if (_blockedTicks == 4) {
        final replan =
            _findPath(applier.config, pos, goal, occupiedByOthers(applier.ref, id));
        if (replan.length > 1) {
          _path = replan;
          _pathIdx = 0;
        }
      } else if (_blockedTicks >= 8) {
        final side = _adjacentWalkable(
            applier.config, pos.row, pos.col, occupiedByOthers(applier.ref, id));
        if (side != null &&
            _findPath(applier.config, side, goal).length > 1 &&
            applier.tryStep(this, side)) {
          _path =
              _findPath(applier.config, pos, goal, occupiedByOthers(applier.ref, id));
          _pathIdx = 0;
        }
        _blockedTicks = 0;
      }
      return false;
    }
    return true;
  }

  void _abort(BrainContext ctx) {
    if (_rack != null) {
      ctx.ref
          .read(rackReservationProvider.notifier)
          .release(_rack!.row, _rack!.col);
    }
    final id = _jobId;
    if (id != null) ctx.board.releaseOrFail(id);
    _reset();
    lifecycle = UnitLifecycle.idle;
  }

  @override
  void onReset(BrainContext ctx) {
    // Release the held dest reservation so a revived cart isn't blocked by its
    // own reservation (offline).
    if (_rack != null) {
      ctx.ref
          .read(rackReservationProvider.notifier)
          .release(_rack!.row, _rack!.col);
    }
    _reset();
  }

  void _reset() {
    _state = _PR.idle;
    _jobId = null;
    currentJobId = null;
    _sku = '';
    _staging = null;
    _rack = null;
    _dropAmount = 0;
    _path = const [];
    _pathIdx = 0;
    _ticksLeft = 0;
  }

  // ── 5.1–5.4 destination rule (ported from PalletPutawayController) ──────────

  ({int row, int col, int amount})? _decideDestination(
      WarehouseConfig cfg, String sku) {
    // 5.2 loose pick area below threshold → unwrap pallet to loose units.
    final loose = _belowThreshold(cfg, CellType.rackLoose, sku, kLoosePerPallet);
    if (loose != null) {
      return (row: loose.$1, col: loose.$2, amount: kLoosePerPallet);
    }
    // 5.3 case pick area below threshold → unwrap pallet to cases.
    final cse = _belowThreshold(cfg, CellType.rackCase, sku, kCasesPerPallet);
    if (cse != null) {
      return (row: cse.$1, col: cse.$2, amount: kCasesPerPallet);
    }
    // 5.4 default → store whole pallet in a pallet rack.
    final pal = _availablePalletRack(cfg, sku);
    if (pal != null) return (row: pal.$1, col: pal.$2, amount: 1);
    return null;
  }

  // Only returns a cell that can hold the full [need] (native units), so a whole
  // pallet is never dropped into a cell too small for it — no silent over-fill /
  // inventory annihilation (review AC-1). With small loose/case capacities this
  // simply falls through to 5.4 (whole pallet to a pallet rack).
  (int, int)? _belowThreshold(
      WarehouseConfig cfg, CellType type, String sku, int need) {
    for (final c in cfg.cells) {
      if (c.type != type) continue;
      final room = c.maxQuantity - c.quantity;
      if (c.skuId == sku && c.fillFraction < kReplenishThreshold && room >= need) {
        return (c.row, c.col);
      }
      if ((c.skuId == null || c.skuId!.isEmpty) &&
          c.quantity == 0 &&
          c.maxQuantity >= need) {
        return (c.row, c.col);
      }
    }
    return null;
  }

  (int, int)? _availablePalletRack(WarehouseConfig cfg, String sku) {
    for (final c in cfg.cells) {
      if (c.type == CellType.rackPallet && c.skuId == sku && !c.isFull) {
        return (c.row, c.col);
      }
    }
    for (final c in cfg.cells) {
      if (c.type == CellType.rackPallet &&
          c.quantity == 0 &&
          (c.skuId == null || c.skuId!.isEmpty)) {
        return (c.row, c.col);
      }
    }
    return null;
  }

  // ── Navigation helpers ─────────────────────────────────────────────────────

  List<GridPos> _findPath(WarehouseConfig cfg, GridPos from, GridPos to,
      [Set<(int, int)>? occupied]) {
    final pf = AStarPathfinder(cols: cfg.cols, rows: cfg.rows);
    // Pathfinder tuples are (col, row); walkable predicate receives (col, row).
    final raw = pf.findPath(
      (from.col, from.row),
      (to.col, to.row),
      occupied: occupied, // soft congestion penalty (P6)
      walkable: (c) => _walkable(cfg, c.$2, c.$1),
    );
    return raw.map((p) => (row: p.$2, col: p.$1)).toList();
  }

  bool _walkable(WarehouseConfig cfg, int row, int col) {
    if (row < 0 || row >= cfg.rows || col < 0 || col >= cfg.cols) return false;
    final t = cfg.cellAt(row, col)?.type ?? CellType.empty;
    return t.isWalkable || t == CellType.empty;
  }

  GridPos? _adjacentWalkable(WarehouseConfig cfg, int row, int col,
      [Set<(int, int)>? occupied]) {
    const dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)];
    GridPos? fallback; // an occupied-but-walkable side, used only if none free
    for (final d in dirs) {
      final nr = row + d.$1;
      final nc = col + d.$2;
      if (!_walkable(cfg, nr, nc)) continue;
      if (occupied != null && occupied.contains((nc, nr))) {
        fallback ??= (row: nr, col: nc);
        continue;
      }
      return (row: nr, col: nc); // prefer a FREE side (P6 deadlock avoidance)
    }
    return fallback;
  }
}
