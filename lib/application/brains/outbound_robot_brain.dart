/// outbound_robot_brain.dart — pack & load (P4, step 7).
///
/// Claims a `packAndLoad` Job (only once the Order's truck has docked and
/// published its `shipBay`), takes the staged pallet, carries it to the docked
/// truck, and loads it. The load `completeJob(progressUnits: …)` is the SINGLE
/// point that advances the Order's counter (LCC-2); when it reaches the ordered
/// quantity the Order closes and the truck departs.
library;

import '../../models/warehouse_config.dart';
import '../../warehouse_engine/services/pathfinding.dart';
import '../job_board.dart';
import 'action_applier.dart';
import 'unit_brain.dart';

enum _OR { idle, toStage, picking, toTruck, loading }

class OutboundRobotBrain extends UnitBrain {
  OutboundRobotBrain({required super.id, required super.pos})
      : super(role: UnitRole.outboundRobot);

  static const int kPickTicks = 2;
  static const int kLoadTicks = 2;

  /// Give up a job whose drive can't finish within this many ticks — a truck that
  /// departed or an unreachable bay would otherwise strand the robot holding a
  /// pallet forever (the "stuck carrying SKU-x" wedge). Roomy so a legitimately
  /// long, congested haul is never cut short.
  static const int kGiveUpTicks = 350;

  _OR _state = _OR.idle;
  String? _jobId;
  String _sku = '';
  GridPos? _stage;
  GridPos? _shipBay;
  int _units = 0; // loose-equiv this load ships (from the packAndLoad Job)


  /// Blockers as of this tick, consulted by [_walkable]. Refreshed at the top of
  /// both phases: the PLANNER must agree with the executor that a blocked cell
  /// is impassable, or A* routes through it and tryStep livelocks forever.
  Set<(int, int)> _blockedNow = const {};

  List<GridPos> _path = const [];
  int _pathIdx = 0;
  int _ticksLeft = 0;

  @override
  void perceiveAndDecide(BrainContext ctx) {
    _blockedNow = blockedCellsFor(ctx.ref);
    if (_state != _OR.idle) return;
    final board = ctx.board;
    final orders = ctx.ref.read(jobBoardProvider).orders;
    for (final job in board.claimableFor(UnitRole.outboundRobot)) {
      final stage = job.src;
      final order = job.orderId == null ? null : orders[job.orderId];
      final shipBay = order?.shipBay;
      if (stage == null || shipBay == null) continue; // truck not docked yet
      if (!board.claim(job.id, id)) continue;

      final approach = _adjacentWalkable(
          ctx.config, stage.row, stage.col, occupiedByOthers(ctx.ref, id));
      final path = approach == null
          ? const <GridPos>[]
          : _findPath(ctx.config, pos, approach, occupiedByOthers(ctx.ref, id));
      if (path.isEmpty) {
        board.release(job.id);
        continue;
      }
      _jobId = job.id;
      currentJobId = job.id;
      _sku = job.skuId;
      _units = job.qtyUnits;
      _stage = stage;
      _shipBay = shipBay;
      _path = path;
      _pathIdx = 0;
      _state = _OR.toStage;
      lifecycle = UnitLifecycle.navigating;
      board.markActive(job.id);
      return;
    }
  }

  @override
  void act(BrainContext ctx) {
    _blockedNow = blockedCellsFor(ctx.ref);
    final applier = ActionApplier(ctx.ref, ctx.config);
    switch (_state) {
      case _OR.idle:
        lifecycle = UnitLifecycle.idle;

      case _OR.toStage:
        if (_driveTicks > kGiveUpTicks) return _abort(ctx);
        if (_advance(applier)) {
          _state = _OR.picking;
          _ticksLeft = kPickTicks;
          lifecycle = UnitLifecycle.working;
        }

      case _OR.picking:
        if (--_ticksLeft <= 0) {
          // Secure the path to the truck BEFORE taking the pallet off the stage,
          // so an abort never orphans the pallet in cargo (review HT-1).
          final approach =
              _adjacentWalkable(ctx.config, _shipBay!.row, _shipBay!.col,
                  occupiedByOthers(ctx.ref, id));
          final path = approach == null
              ? const <GridPos>[]
              : _findPath(ctx.config, pos, approach, occupiedByOthers(ctx.ref, id));
          if (path.isEmpty) {
            _abort(ctx); // stage not yet taken
            return;
          }
          // Phantom guard: if the stage cell is already empty (a racing/duplicate
          // claim took it), take nothing and abort rather than loading air.
          if (!applier.takeFromStage(this, _stage!, _sku)) {
            _abort(ctx);
            return;
          }
          _path = path;
          _pathIdx = 0;
          _state = _OR.toTruck;
          lifecycle = UnitLifecycle.navigating;
        }

      case _OR.toTruck:
        if (_driveTicks > kGiveUpTicks) return _abort(ctx);
        if (_advance(applier)) {
          _state = _OR.loading;
          _ticksLeft = kLoadTicks;
          lifecycle = UnitLifecycle.working;
        }

      case _OR.loading:
        if (--_ticksLeft <= 0) {
          applier.loadOntoTruck(this);
          // The one increment on the Order (LCC-2): credit the actual loose-equiv
          // shipped, from the Job — not a hardcoded pallet (review AC-5).
          ctx.board.completeJob(_jobId!, progressUnits: _units);
          _reset();
          lifecycle = UnitLifecycle.idle;
        }
    }
  }

  int _blockedTicks = 0;
  int _driveTicks = 0; // ticks spent driving the current job (give-up guard)
  bool _advance(ActionApplier applier) {
    _driveTicks++;
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
        // Head-on: back out to a free side cell IF the goal stays reachable from
        // there, so the opposing unit can pass (P6 back-out). A per-tick head-on
        // yield was tried (deterministic id tie-break) but made robots hold cells
        // longer, slowing blocker recovery below the e2e budget — reverted; the
        // ghost-truck despawn fix removes the visible "stuck" robots on its own.
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
    ActionApplier(ctx.ref, ctx.config).clearCargo(this); // roll back any take
    final id = _jobId;
    if (id != null) ctx.board.releaseOrFail(id);
    _reset();
    lifecycle = UnitLifecycle.idle;
  }

  @override
  void onReset(BrainContext ctx) => _reset(); // forced idle (offline)

  void _reset() {
    _state = _OR.idle;
    _jobId = null;
    currentJobId = null;
    _sku = '';
    _units = 0;
    _stage = null;
    _shipBay = null;
    _path = const [];
    _pathIdx = 0;
    _ticksLeft = 0;
    _driveTicks = 0;
  }

  List<GridPos> _findPath(WarehouseConfig cfg, GridPos from, GridPos to,
      [Set<(int, int)>? occupied]) {
    final pf = AStarPathfinder(cols: cfg.cols, rows: cfg.rows);
    final raw = pf.findPath(
      (from.col, from.row),
      (to.col, to.row),
      occupied: occupied, // soft congestion penalty (P6)
      walkable: (c) => _walkable(cfg, c.$2, c.$1),
    );
    return raw.map((p) => (row: p.$2, col: p.$1)).toList();
  }

  bool _walkable(WarehouseConfig cfg, int row, int col) {
    if (_blockedNow.contains((col, row))) return false;
    if (row < 0 || row >= cfg.rows || col < 0 || col >= cfg.cols) return false;
    final t = cfg.cellAt(row, col)?.type ?? CellType.empty;
    return t.isWalkable || t == CellType.empty;
  }

  GridPos? _adjacentWalkable(WarehouseConfig cfg, int row, int col,
      [Set<(int, int)>? occupied]) {
    const dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)];
    GridPos? fallback;
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
