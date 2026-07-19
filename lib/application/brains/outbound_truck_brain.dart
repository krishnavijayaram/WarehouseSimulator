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

/// One outbound truck holds 10 pallets (loose-equivalent). Many orders share a
/// truck; it departs when everything aboard is loaded (or it has dwelled too
/// long), which is what stops a 1:1 truck-per-order from swamping the bays.
const int kOutboundTruckCapacityUnits = 10 * kLoosePerPallet; // 480

class OutboundTruckBrain extends UnitBrain {
  OutboundTruckBrain({
    required super.id,
    required super.pos,
    required String orderId,
    this.capacityUnits = kOutboundTruckCapacityUnits,
    GridPos? exit,
  })  : _orders = [orderId],
        _exit = exit,
        super(role: UnitRole.outboundTruck);

  /// Every Order aboard. One truck serves MANY orders — with one truck per order
  /// and a single bay, most trucks never docked before kMaxSeekTicks and aborted
  /// their Order (an ~87% order failure rate in the E2E probe).
  final List<String> _orders;
  final int capacityUnits;
  final GridPos? _exit;

  List<String> get orders => List.unmodifiable(_orders);

  static const int kMaxSeekTicks = 120;

  /// Never hold a bay forever: if the floor stops delivering, leave with what we
  /// have so the next truck can dock. 500 measured best — shortening it to 120
  /// made trucks leave before their orders were picked and ships FELL (6 -> 2),
  /// so this is a deliberate value, not a default.
  static const int kMaxDwellTicks = 500;

  _OT _state = _OT.seekingBay;
  GridPos? _bay;
  int _seekTicks = 0;
  int _dwellTicks = 0;
  List<GridPos> _path = const [];
  int _pathIdx = 0;

  /// Loose-equivalent already promised to this truck.
  int committedUnits(BrainContext ctx) {
    final board = ctx.ref.read(jobBoardProvider).orders;
    var total = 0;
    for (final oid in _orders) {
      total += board[oid]?.orderedUnits ?? 0;
    }
    return total;
  }

  /// Still loading and has room for [units] more.
  bool canAccept(BrainContext ctx, int units) =>
      _state != _OT.departing &&
      committedUnits(ctx) + units <= capacityUnits;

  /// Put another Order aboard, publishing the bay if we are already docked.
  void addOrder(BrainContext ctx, String orderId) {
    if (_orders.contains(orderId)) return;
    _orders.add(orderId);
    if (_state == _OT.docked && _bay != null) {
      ctx.board.setShipBay(orderId, _bay);
    }
  }

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
          // Couldn't get a bay in time → abort what we carry so the generator's
          // WIP slots free instead of the outbound loop wedging (review HT-2).
          for (final oid in _orders) {
            ctx.board.closeOrder(oid, aborted: true);
          }
          ctx.ref.read(unitRegistryProvider.notifier).remove(id);
        }

      case _OT.driving:
        if (_advance(applier)) {
          _state = _OT.docked;
          lifecycle = UnitLifecycle.working;
          // Publish the bay (through the notifier, HT-6) so pack/load can find us
          // — for EVERY order aboard, not just the first.
          for (final oid in _orders) {
            ctx.board.setShipBay(oid, _bay);
          }
        }

      case _OT.docked:
        _dwellTicks++;
        final boardOrders = ctx.ref.read(jobBoardProvider).orders;
        // Anything aboard still waiting to be loaded?
        final stillLoading = _orders.any((oid) {
          final o = boardOrders[oid];
          return o != null &&
              !o.isSatisfied &&
              o.status != OrderStatus.aborted;
        });
        // Depart when everything aboard is loaded (or gone), or we have dwelled
        // too long — the timeout is what stops a half-full truck holding the bay
        // forever and starving every following order.
        if (!stillLoading || _dwellTicks > kMaxDwellTicks) {
          for (final oid in _orders) {
            ctx.board.setShipBay(oid, null); // clear the handoff (HT-5/HT-6)
          }
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
