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

  List<GridPos> _path = const [];
  int _pathIdx = 0;
  int _ticksLeft = 0;

  @override
  void perceiveAndDecide(BrainContext ctx) {
    if (_state != _RC.idle) return;
    final board = ctx.board;
    for (final job in board.claimableFor(UnitRole.recovery)) {
      final src = job.src;
      if (src == null) continue;
      // Decide the whole route BEFORE claiming: we must be able to reach the
      // blocker AND have somewhere to put it, or the Job just churns.
      final dump = _nearestDump(ctx);
      if (dump == null) continue;
      final approach = _adjacentWalkable(
          ctx.config, src.row, src.col, occupiedByOthers(ctx.ref, id));
      final path = approach == null
          ? const <GridPos>[]
          : _findPath(ctx.config, pos, approach, occupiedByOthers(ctx.ref, id));
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
    final applier = ActionApplier(ctx.ref, ctx.config);
    switch (_state) {
      case _RC.idle:
        lifecycle = UnitLifecycle.idle;

      case _RC.toBlocker:
        if (_advance(applier)) {
          _state = _RC.lifting;
          _ticksLeft = kLiftTicks;
          lifecycle = UnitLifecycle.working;
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
          // LIFT: this is the moment the floor reopens. The cell leaves the
          // blocked set, so the scheduler stops reserving it next tick.
          ctx.ref
              .read(blockedCellsProvider.notifier)
              .removeLocal(_blocker!.row, _blocker!.col);
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

  int _blockedTicks = 0;
  bool _advance(ActionApplier applier) {
    if (_pathIdx < _path.length - 1) {
      if (applier.tryStep(this, _path[_pathIdx + 1])) {
        _pathIdx++;
        _blockedTicks = 0;
        return false;
      }
      _blockedTicks++;
      if (_blockedTicks >= 4) {
        final replan = _findPath(applier.config, pos, _path.last,
            occupiedByOthers(applier.ref, id));
        if (replan.length > 1) {
          _path = replan;
          _pathIdx = 0;
        }
        _blockedTicks = 0;
      }
      return false;
    }
    return true;
  }

  void _abort(BrainContext ctx) {
    // If we were already carrying, put the blocker BACK rather than deleting it —
    // a failed recovery must never silently make an obstruction disappear.
    if (_carrying && _blocker != null) {
      ctx.ref
          .read(blockedCellsProvider.notifier)
          .addLocal(_blocker!.row, _blocker!.col);
    }
    final jid = _jobId;
    if (jid != null) ctx.board.releaseOrFail(jid);
    _reset();
    lifecycle = UnitLifecycle.idle;
  }

  @override
  void onReset(BrainContext ctx) {
    if (_carrying && _blocker != null) {
      ctx.ref
          .read(blockedCellsProvider.notifier)
          .addLocal(_blocker!.row, _blocker!.col);
    }
    _reset();
  }

  void _reset() {
    _state = _RC.idle;
    _jobId = null;
    currentJobId = null;
    _blocker = null;
    _dump = null;
    _carrying = false;
    _path = const [];
    _pathIdx = 0;
    _ticksLeft = 0;
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
      [Set<(int, int)>? occupied]) {
    final pf = AStarPathfinder(cols: cfg.cols, rows: cfg.rows);
    final raw = pf.findPath(
      (from.col, from.row),
      (to.col, to.row),
      occupied: occupied,
      walkable: (c) => _walkable(cfg, c.$2, c.$1),
    );
    return raw.map((p) => (row: p.$2, col: p.$1)).toList();
  }

  bool _walkable(WarehouseConfig cfg, int row, int col) {
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
