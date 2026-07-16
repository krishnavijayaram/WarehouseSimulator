/// outbound_truck_brain.dart — the shipping carrier (P4, step 8).
///
/// Claims an outbound bay, drives to it, docks, and publishes its bay on the
/// Order (`shipBay`) so the pack/load robot knows where to bring pallets. It
/// waits until the Order is fully loaded (its single progress counter reaches
/// the ordered quantity — the load is the one increment, LCC-2), then releases
/// the bay and drives off. Departure closing the order = shipped == loaded.
library;

import '../../models/warehouse_config.dart';
import '../../warehouse_engine/services/pathfinding.dart';
import '../bay_resource.dart';
import '../job_board.dart';
import 'action_applier.dart';
import 'unit_brain.dart';

enum _OT { seekingBay, driving, docked, departing }

class OutboundTruckBrain extends UnitBrain {
  OutboundTruckBrain({
    required super.id,
    required super.pos,
    required this.orderId,
    GridPos? exit,
  })  : _exit = exit,
        super(role: UnitRole.outboundTruck);

  final String orderId;
  final GridPos? _exit;

  static const int kMaxSeekTicks = 120;

  _OT _state = _OT.seekingBay;
  GridPos? _bay;
  int _seekTicks = 0;
  List<GridPos> _path = const [];
  int _pathIdx = 0;

  @override
  void perceiveAndDecide(BrainContext ctx) {
    if (_state != _OT.seekingBay) return;
    final bays = _bayCells(ctx.config);
    if (bays.isEmpty) return;
    final bayN = ctx.ref.read(bayOccupancyProvider.notifier);
    final claimed = bayN.claimFirstFree(bays, id);
    if (claimed == null) return;

    final approach = _adjacentDriveable(ctx.config, claimed.row, claimed.col);
    final path = approach == null
        ? const <GridPos>[]
        : _findPath(ctx.config, pos, approach);
    if (path.isEmpty) {
      bayN.release(claimed.row, claimed.col);
      return;
    }
    _bay = claimed;
    _path = path;
    _pathIdx = 0;
    _state = _OT.driving;
    lifecycle = UnitLifecycle.navigating;
  }

  @override
  void act(BrainContext ctx) {
    final applier = ActionApplier(ctx.ref, ctx.config);
    switch (_state) {
      case _OT.seekingBay:
        lifecycle = UnitLifecycle.idle;
        if (++_seekTicks > kMaxSeekTicks) {
          // Couldn't get a bay in time → abort the Order so the generator's WIP
          // slot frees instead of the whole outbound loop wedging (review HT-2).
          ctx.board.closeOrder(orderId, aborted: true);
          ctx.ref.read(unitRegistryProvider.notifier).remove(id);
        }

      case _OT.driving:
        if (_advance(applier)) {
          _state = _OT.docked;
          lifecycle = UnitLifecycle.working;
          // Publish the bay (through the notifier, HT-6) so pack/load can find us.
          ctx.board.setShipBay(orderId, _bay);
        }

      case _OT.docked:
        final order = ctx.ref.read(jobBoardProvider).orders[orderId];
        // Order gone (closed + swept), fully loaded, or ABORTED (its pick failed
        // out — review DL-3) → ship out so the bay is never leaked.
        if (order == null ||
            order.isSatisfied ||
            order.status == OrderStatus.aborted) {
          ctx.board.setShipBay(orderId, null); // clear the handoff (HT-5/HT-6)
          ctx.ref
              .read(bayOccupancyProvider.notifier)
              .release(_bay!.row, _bay!.col);
          final exit = _exit ?? (row: pos.row, col: 0);
          final approach =
              _adjacentDriveable(ctx.config, exit.row, exit.col) ?? exit;
          _path = _findPath(ctx.config, pos, approach);
          _pathIdx = 0;
          _state = _OT.departing;
          lifecycle = UnitLifecycle.navigating;
        }

      case _OT.departing:
        if (_advance(applier)) {
          ctx.ref.read(unitRegistryProvider.notifier).remove(id);
        }
    }
  }

  bool _advance(ActionApplier applier) {
    if (_pathIdx < _path.length - 1) {
      _pathIdx++;
      applier.moveTo(this, _path[_pathIdx]);
      return false;
    }
    return true;
  }

  List<GridPos> _bayCells(WarehouseConfig cfg) {
    final out = <GridPos>[];
    for (final c in cfg.cells) {
      if (c.type == CellType.outbound) out.add((row: c.row, col: c.col));
    }
    out.sort((a, b) => a.row != b.row ? a.row - b.row : a.col - b.col);
    return out;
  }

  List<GridPos> _findPath(WarehouseConfig cfg, GridPos from, GridPos to) {
    final pf = AStarPathfinder(cols: cfg.cols, rows: cfg.rows);
    final raw = pf.findPath(
      (from.col, from.row),
      (to.col, to.row),
      walkable: (c) => _driveable(cfg, c.$2, c.$1),
    );
    return raw.map((p) => (row: p.$2, col: p.$1)).toList();
  }

  bool _driveable(WarehouseConfig cfg, int row, int col) {
    if (row < 0 || row >= cfg.rows || col < 0 || col >= cfg.cols) return false;
    final t = cfg.cellAt(row, col)?.type ?? CellType.empty;
    return t == CellType.empty || t.isRoad || t.isWalkable;
  }

  GridPos? _adjacentDriveable(WarehouseConfig cfg, int row, int col) {
    const dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)];
    for (final d in dirs) {
      final nr = row + d.$1;
      final nc = col + d.$2;
      if (_driveable(cfg, nr, nc)) return (row: nr, col: nc);
    }
    return null;
  }
}
