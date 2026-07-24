/// recovery_robot_brain.dart — the "clear the obstruction" unit.
///
/// The ACT half of the anomaly loop the JEPA work demonstrates. It claims a
/// `clearBlocker` Job raised by [BlockerMonitorBrain], drives to a cell ADJACENT
/// to the obstruction (it cannot enter the blocked cell — that is the whole
/// point), lifts the blocker, hauls it to a dump-yard cell, and drops it there.
///
/// Lifting is what actually unblocks the floor: the cell leaves
/// `blockedCellsProvider`, so the scheduler stops reserving it and every other
/// robot's path through that cell reopens.
///
/// Failure is safe in both directions: if the route to the dump is lost after
/// lifting, the blocker is put BACK where it was rather than vanishing, so a
/// blocker can never be silently deleted by a failed recovery.
library;

import '../../models/warehouse_config.dart';
import '../../warehouse_engine/services/pathfinding.dart';
import '../job_board.dart';
import '../providers.dart';
import 'action_applier.dart';
import 'unit_brain.dart';

enum _RC { idle, toBlocker, lifting, toDump, dumping }

class RecoveryRobotBrain extends UnitBrain {
  RecoveryRobotBrain({required super.id, required super.pos})
      : super(role: UnitRole.recovery);

  static const int kLiftTicks = 2;
  static const int kDropTicks = 2;

  _RC _state = _RC.idle;
  String? _jobId;
  GridPos? _blocker; // the cell being cleared
  GridPos? _dump;
  bool _carrying = false;

  /// True when the lift also reverted a CellType.obstacle, so a put-back knows to
  /// restore it. Without this, an aborted haul would restore only half the
  /// blocker and leave the floor in a state the UI never created.
  bool _clearedType = false;


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
    if (_state != _RC.idle) return;
    final board = ctx.board;
    for (final job in board.claimableFor(UnitRole.recovery)) {
      final src = job.src;
      if (src == null) continue;
      // Decide the whole route BEFORE claiming: we must be able to reach the
      // blocker AND have somewhere to put it, or the Job just churns.
      final dump = _nearestDump(ctx);
      if (dump == null) continue;
      // Try EVERY side of the blocker, nearest first, until one is actually
      // reachable. Taking the first walkable neighbour (always the north one)
      // sent a unit standing south of the blocker on a route that had to pass
      // THROUGH it; with two adjacent blockers the chosen side was the other
      // blocker, and the unit parked one cell short forever.
      final path = _routeToAnySideOf(ctx, src);
      if (path.isEmpty) {
        board.releaseOrFail(job.id);
        continue;
      }
      if (!board.claim(job.id, id)) continue;
      _jobId = job.id;
      currentJobId = job.id;
      _blocker = src;
      _dump = dump;
      _path = path;
      _pathIdx = 0;
      _state = _RC.toBlocker;
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
      case _RC.idle:
        lifecycle = UnitLifecycle.idle;

      case _RC.toBlocker:
        if (_advance(applier)) {
          _state = _RC.lifting;
          _ticksLeft = kLiftTicks;
          lifecycle = UnitLifecycle.working;
        } else if (_givenUp) {
          _abort(ctx); // nothing lifted yet — the blocker stays where it is
        }

      case _RC.lifting:
        if (--_ticksLeft <= 0) {
          // Secure the route to the dump BEFORE lifting, so a failed haul can't
          // leave us holding a blocker with nowhere to put it.
          final approach = _adjacentWalkable(
              ctx.config, _dump!.row, _dump!.col, occupiedByOthers(ctx.ref, id));
          final path = approach == null
              ? const <GridPos>[]
              : _findPath(ctx.config, pos, approach, occupiedByOthers(ctx.ref, id));
          if (path.isEmpty) {
            _abort(ctx); // nothing lifted yet — the blocker stays put
            return;
          }
          // LIFT: the moment the floor reopens. A blocker placed through the UI
          // is a TWO-PART write — CellType.obstacle on the cell AND an entry in
          // blockedCells — so both halves must be reverted. Clearing only the
          // blocked set left the obstacle cell type behind, and the "cleared"
          // cell stayed impassable (obstacle is not walkable).
          ctx.ref
              .read(blockedCellsProvider.notifier)
              .removeLocal(_blocker!.row, _blocker!.col);
          final cfg = ctx.ref.read(warehouseConfigProvider);
          final cell = cfg?.cellAt(_blocker!.row, _blocker!.col);
          if (cfg != null && cell?.type == CellType.obstacle) {
            _clearedType = true; // remember, so a put-back can restore it
            ctx.ref.read(warehouseConfigProvider.notifier).state = cfg.setCell(
                WarehouseCell(
                    row: _blocker!.row,
                    col: _blocker!.col,
                    type: CellType.empty));
          }
          _carrying = true;
          _path = path;
          _pathIdx = 0;
          _state = _RC.toDump;
          lifecycle = UnitLifecycle.navigating;
        }

      case _RC.toDump:
        if (_advance(applier)) {
          _state = _RC.dumping;
          _ticksLeft = kDropTicks;
          lifecycle = UnitLifecycle.working;
        } else if (_givenUp) {
          // Carrying, but the dump became unreachable. This state previously had
          // NO failure exit at all, so the unit held the blocker forever. _abort
          // puts the obstruction BACK where it was, which is safe: the floor
          // returns to its true state and the monitor can raise a fresh Job.
          _abort(ctx);
        }

      case _RC.dumping:
        if (--_ticksLeft <= 0) {
          // Disposed of in the dump yard — the obstruction is gone for good.
          _carrying = false;
          ctx.board.completeJob(_jobId!);
          _reset();
          lifecycle = UnitLifecycle.idle;
        }
    }
  }

  /// True once the unit has been unable to progress for so long that the Job
  /// should be given up rather than churned forever. Every sibling brain has this
  /// escalation; this one lacked it, which is why a stuck recovery unit wedged
  /// terminally — it never returns to idle, so it could never claim another Job,
  /// and the live Job suppressed the monitor from re-raising one.
  static const int kGiveUpTicks = 24;

  int _blockedTicks = 0;
  int _stuckTicks = 0;
  bool _advance(ActionApplier applier) {
    if (_pathIdx < _path.length - 1) {
      if (applier.tryStep(this, _path[_pathIdx + 1])) {
        _pathIdx++;
        _blockedTicks = 0;
        _stuckTicks = 0;
        return false;
      }
      _blockedTicks++;
      _stuckTicks++;
      final reroute = recoverBlocked(
        applier: applier,
        blockedTicks: _blockedTicks,
        goal: _path.last,
        findPath: (f, t, occ, pen) => _findPath(applier.config, f, t, occ, pen),
        sideStep: (occ) =>
            _adjacentWalkable(applier.config, pos.row, pos.col, occ),
      );
      if (reroute != null) {
        _path = reroute;
        _pathIdx = 0;
      }
      if (_blockedTicks >= UnitBrain.kDetourAt) _blockedTicks = 0;
      return false;
    }
    return true;
  }

  /// Blocked for too long to keep trying. Callers abort so the Job's attempts
  /// counter advances and the seat frees for other work.
  bool get _givenUp => _stuckTicks > kGiveUpTicks;

  /// Put a lifted blocker BACK, both halves. A failed recovery must never make an
  /// obstruction silently disappear, and must never leave it half-restored.
  void _putBack(BrainContext ctx) {
    if (!_carrying || _blocker == null) return;
    ctx.ref
        .read(blockedCellsProvider.notifier)
        .addLocal(_blocker!.row, _blocker!.col);
    if (_clearedType) {
      final cfg = ctx.ref.read(warehouseConfigProvider);
      if (cfg != null) {
        ctx.ref.read(warehouseConfigProvider.notifier).state = cfg.setCell(
            WarehouseCell(
                row: _blocker!.row,
                col: _blocker!.col,
                type: CellType.obstacle));
      }
    }
  }

  void _abort(BrainContext ctx) {
    _putBack(ctx);
    final jid = _jobId;
    if (jid != null) ctx.board.releaseOrFail(jid);
    _reset();
    lifecycle = UnitLifecycle.idle;
  }

  @override
  void onReset(BrainContext ctx) {
    _putBack(ctx);
    _reset();
  }

  void _reset() {
    _state = _RC.idle;
    _jobId = null;
    currentJobId = null;
    _blocker = null;
    _dump = null;
    _carrying = false;
    _clearedType = false;
    _blockedTicks = 0;
    _stuckTicks = 0;
    _path = const [];
    _pathIdx = 0;
    _ticksLeft = 0;
  }

  /// A real route to SOME side of [target], trying the nearest side first.
  /// Returns an empty list when no side is reachable — which correctly surfaces
  /// the Job to releaseOrFail instead of committing to an unreachable approach.
  List<GridPos> _routeToAnySideOf(BrainContext ctx, GridPos target) {
    final occupied = occupiedByOthers(ctx.ref, id);
    final sides = <GridPos>[];
    for (final d in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
      final nr = target.row + d.$1;
      final nc = target.col + d.$2;
      if (!_walkable(ctx.config, nr, nc)) continue; // skips blocked cells too
      // Skip a side another robot is SITTING on. Occupancy is only a soft A*
      // cost, so without this the planner keeps returning a route to a side that
      // is physically unenterable — the unit then creeps to the last free cell
      // and never arrives, so the blocker is never even lifted.
      if (occupied.contains((nc, nr))) continue;
      sides.add((row: nr, col: nc));
    }
    sides.sort((a, b) {
      final da = (a.row - pos.row).abs() + (a.col - pos.col).abs();
      final db = (b.row - pos.row).abs() + (b.col - pos.col).abs();
      return da.compareTo(db);
    });
    for (final s in sides) {
      if (s.row == pos.row && s.col == pos.col) {
        return [pos]; // already standing beside it
      }
      final p = _findPath(ctx.config, pos, s, occupied);
      if (p.length > 1) return p;
    }
    return const [];
  }

  GridPos? _nearestDump(BrainContext ctx) {
    GridPos? best;
    var bestD = 1 << 30;
    for (final c in ctx.config.cells) {
      if (c.type != CellType.dump) continue;
      final d = (c.row - pos.row).abs() + (c.col - pos.col).abs();
      if (d < bestD) {
        bestD = d;
        best = (row: c.row, col: c.col);
      }
    }
    return best;
  }

  List<GridPos> _findPath(WarehouseConfig cfg, GridPos from, GridPos to,
      [Set<(int, int)>? occupied, int? penalty]) {
    final pf = AStarPathfinder(cols: cfg.cols, rows: cfg.rows);
    final raw = pf.findPath(
      (from.col, from.row),
      (to.col, to.row),
      occupied: occupied,
      penalty: penalty, // escalated when a robot is genuinely wedged
      walkable: (c) => _walkable(cfg, c.$2, c.$1),
    );
    return raw.map((p) => (row: p.$2, col: p.$1)).toList();
  }

  bool _walkable(WarehouseConfig cfg, int row, int col) {
    if (_blockedNow.contains((col, row))) return false;
    if (row < 0 || row >= cfg.rows || col < 0 || col >= cfg.cols) return false;
    final t = cfg.cellAt(row, col)?.type ?? CellType.empty;
    return t.isWalkable || t == CellType.empty || t == CellType.dump;
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
      return (row: nr, col: nc);
    }
    return fallback;
  }
}
