/// inbound_robot_brain.dart — the unload unit (P2).
///
/// Claims an `unloadTruck` Job, drives to the docked truck, picks a pallet,
/// drives to a free staging slot, drops it — then MINTS the `putaway` Job that
/// the P1 cart consumes. That mint is the truck→staging→rack handoff: producers
/// and consumers never reference each other, only the JobBoard.
library;

import '../../models/warehouse_config.dart';
import '../../warehouse_engine/services/pathfinding.dart';
import '../job_board.dart';
import '../providers.dart';
import 'action_applier.dart';
import 'unit_brain.dart';

enum _IR { idle, toDock, picking, toStaging, dropping }

class InboundRobotBrain extends UnitBrain {
  InboundRobotBrain({required super.id, required super.pos})
      : super(role: UnitRole.inboundRobot);

  static const int kPickTicks = 3;
  static const int kDropTicks = 2;

  _IR _state = _IR.idle;
  String? _jobId;
  String? _orderId;
  String _sku = '';
  GridPos? _staging;


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
    if (_state != _IR.idle) return;
    final board = ctx.board;
    for (final job in board.claimableFor(UnitRole.inboundRobot)) {
      final dock = job.src;
      if (dock == null) continue;
      if (!board.claim(job.id, id)) continue;

      final approach = _adjacentWalkable(
          ctx.config, dock.row, dock.col, occupiedByOthers(ctx.ref, id));
      final path = approach == null
          ? const <GridPos>[]
          : _findPath(ctx.config, pos, approach, occupiedByOthers(ctx.ref, id));
      if (path.isEmpty) {
        board.release(job.id);
        continue;
      }
      _jobId = job.id;
      currentJobId = job.id;
      _orderId = job.orderId;
      _sku = job.skuId;
      _path = path;
      _pathIdx = 0;
      _state = _IR.toDock;
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
      case _IR.idle:
        lifecycle = UnitLifecycle.idle;

      case _IR.toDock:
        if (_advance(applier)) {
          _state = _IR.picking;
          _ticksLeft = kPickTicks;
          lifecycle = UnitLifecycle.working;
        }

      case _IR.picking:
        if (--_ticksLeft <= 0) {
          applier.pickFromTruck(this, _sku);
          final dest =
              _findStaging(ctx.config, _sku, ctx.ref.read(stagingPalletsProvider));
          final approach = dest == null
              ? null
              : _adjacentWalkable(
                  ctx.config, dest.$1, dest.$2, occupiedByOthers(ctx.ref, id));
          final path = approach == null
              ? const <GridPos>[]
              : _findPath(ctx.config, pos, approach, occupiedByOthers(ctx.ref, id));
          if (dest == null || path.isEmpty) {
            _abort(ctx);
            return;
          }
          _staging = (row: dest.$1, col: dest.$2);
          _path = path;
          _pathIdx = 0;
          _state = _IR.toStaging;
          lifecycle = UnitLifecycle.navigating;
        }

      case _IR.toStaging:
        if (_advance(applier)) {
          _state = _IR.dropping;
          _ticksLeft = kDropTicks;
          lifecycle = UnitLifecycle.working;
        }

      case _IR.dropping:
        if (--_ticksLeft <= 0) {
          applier.dropAtStaging(this, _staging!, _sku);
          // Handoff: the staged pallet now needs putting away → mint the Job a
          // PutawayRobotBrain will pull-claim. No brain references another brain.
          ctx.board.mintJobOf(
            kind: JobKind.putaway,
            requiredRole: UnitRole.putawayRobot,
            skuId: _sku,
            src: _staging,
            orderId: _orderId, // so putaway advances the inbound Order (AC-2)
            qtyUnits: kLoosePerPallet,
          );
          ctx.board.completeJob(_jobId!);
          _reset();
          lifecycle = UnitLifecycle.idle;
        }
    }
  }

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
    ActionApplier(ctx.ref, ctx.config).clearCargo(this); // roll back any pick
    final id = _jobId;
    if (id != null) ctx.board.releaseOrFail(id);
    _reset();
    lifecycle = UnitLifecycle.idle;
  }

  @override
  void onReset(BrainContext ctx) => _reset(); // forced idle (offline)

  void _reset() {
    _state = _IR.idle;
    _jobId = null;
    currentJobId = null;
    _orderId = null;
    _sku = '';
    _staging = null;
    _path = const [];
    _pathIdx = 0;
    _ticksLeft = 0;
  }

  /// First staging cell that can actually hold this SKU: empty, or same-SKU with
  /// room (< kMaxStagingPallets). Returns null when all are full/mismatched, so
  /// staging capacity is real backpressure, not a pile-up on one cell (DL-1).
  (int, int)? _findStaging(
      WarehouseConfig cfg, String sku, Map<String, StagingSlot> staging) {
    for (final c in cfg.cells) {
      if (c.type != CellType.palletStaging) continue;
      final slot = staging['${c.row}_${c.col}'];
      if (slot == null ||
          (slot.skuId == sku && slot.count < kMaxStagingPallets)) {
        return (c.row, c.col);
      }
    }
    return null;
  }

  // ── Navigation (shared shape with PutawayRobotBrain) ───────────────────────

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
    return t.isWalkable || t == CellType.empty || t == CellType.inbound;
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
