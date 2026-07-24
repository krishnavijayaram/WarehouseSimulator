/// inbound_truck_brain.dart — the carrier (P3).
///
/// A truck is an agent too: it arrives on the yard needing a bay, CAS-claims a
/// free inbound bay, drives to it, docks, and posts one `unloadTruck` Job per
/// pallet (tagged with its own id via subjectUnitId). It waits until every one
/// of those Jobs has completed (been claimed by an InboundRobotBrain and swept),
/// then releases the bay and drives off — despawning at the exit.
///
/// Trucks never drain battery (ActionApplier skips truck roles) and travel a
/// permissive road/empty/inbound domain.
library;

import '../../models/warehouse_config.dart';
import '../../warehouse_engine/services/pathfinding.dart';
import '../bay_resource.dart';
import '../job_board.dart';
import 'action_applier.dart';
import 'unit_brain.dart';

enum _IT { seekingBay, driving, docked, departing }

class InboundTruckBrain extends UnitBrain {
  InboundTruckBrain({
    required super.id,
    required super.pos,
    required this.skuId,
    this.manifest = 1,
    this.orderId,
    GridPos? exit,
  })  : _exit = exit,
        super(role: UnitRole.inboundTruck);

  /// SKU carried, and how many pallets are aboard.
  final String skuId;
  final int manifest;

  /// The inbound replenish Order this delivery satisfies (threaded to putaway
  /// so the Order's progress counter actually advances — review AC-2).
  final String? orderId;

  /// Where the truck drives off to when empty (defaults to the left road edge).
  final GridPos? _exit;

  _IT _state = _IT.seekingBay;
  GridPos? _bay;
  bool _minted = false;
  List<GridPos> _path = const [];
  int _pathIdx = 0;

  /// A truck that can never reach a bay must remove itself, or orphaned trucks
  /// pile up in the registry (which is iterated in full every phase every tick)
  /// and a long run creeps toward stall. Mirrors OutboundTruckBrain's kMaxSeekTicks.
  static const int kMaxSeekTicks = 120;
  int _seekTicks = 0;

  @override
  void perceiveAndDecide(BrainContext ctx) {
    if (_state != _IT.seekingBay) return;
    final bays = _bayCells(ctx.config);
    if (bays.isEmpty) return;
    final bayN = ctx.ref.read(bayOccupancyProvider.notifier);
    final claimed = bayN.claimFirstFree(bays, id);
    if (claimed == null) return; // all bays busy → keep waiting on the yard

    final approach = _adjacentDriveable(ctx.config, claimed.row, claimed.col);
    final path = approach == null
        ? const <GridPos>[]
        : _findPath(ctx.config, pos, approach);
    if (path.isEmpty) {
      bayN.release(claimed.row, claimed.col); // can't reach it → give it back
      return;
    }
    _bay = claimed;
    _path = path;
    _pathIdx = 0;
    _state = _IT.driving;
    lifecycle = UnitLifecycle.navigating;
  }

  @override
  void act(BrainContext ctx) {
    final applier = ActionApplier(ctx.ref, ctx.config);
    switch (_state) {
      case _IT.seekingBay:
        lifecycle = UnitLifecycle.idle;
        if (++_seekTicks > kMaxSeekTicks) {
          // Never found a reachable free bay — remove self so orphaned trucks
          // can't accumulate, and abort the replenish Order so StockMonitor's
          // inFlight slot frees for a fresh attempt.
          if (orderId != null) ctx.board.closeOrder(orderId!, aborted: true);
          applier.despawn(this);
        }

      case _IT.driving:
        if (_advance(applier)) {
          _state = _IT.docked;
          lifecycle = UnitLifecycle.working;
        }

      case _IT.docked:
        if (!_minted) {
          _minted = true;
          for (var i = 0; i < manifest; i++) {
            ctx.board.mintJobOf(
              kind: JobKind.unloadTruck,
              requiredRole: UnitRole.inboundRobot,
              skuId: skuId,
              src: _bay,
              subjectUnitId: id,
              orderId: orderId,
            );
          }
        } else if (!_hasOutstandingUnloads(ctx)) {
          // Manifest fully unloaded → free the bay and drive off.
          ctx.ref.read(bayOccupancyProvider.notifier).release(_bay!.row, _bay!.col);
          // Leave up the LEFT road (col 0) and off the top — a truck departs the
          // way it came, never across the floor.
          final exit = _exit ?? (row: 0, col: 0);
          final approach =
              _adjacentDriveable(ctx.config, exit.row, exit.col) ?? exit;
          _path = _findPath(ctx.config, pos, approach);
          _pathIdx = 0;
          _state = _IT.departing;
          lifecycle = UnitLifecycle.navigating;
        }

      case _IT.departing:
        if (_advance(applier)) {
          // Gone: remove from the registry so it stops being scheduled.
          applier.despawn(this);
        }
    }
  }

  bool _hasOutstandingUnloads(BrainContext ctx) => ctx.ref
      .read(jobBoardProvider)
      .jobs
      .values
      .any((j) => j.kind == JobKind.unloadTruck && j.subjectUnitId == id);

  bool _advance(ActionApplier applier) {
    if (_pathIdx < _path.length - 1) {
      _pathIdx++;
      applier.moveTo(this, _path[_pathIdx]);
      return false;
    }
    return true;
  }

  /// The inbound bays a truck may claim (dock / inbound cells).
  List<GridPos> _bayCells(WarehouseConfig cfg) {
    final out = <GridPos>[];
    for (final c in cfg.cells) {
      if (c.type == CellType.dock || c.type == CellType.inbound) {
        out.add((row: c.row, col: c.col));
      }
    }
    out.sort((a, b) => a.row != b.row ? a.row - b.row : a.col - b.col);
    return out;
  }

  // ── Truck navigation (permissive road/empty domain) ────────────────────────

  List<GridPos> _findPath(WarehouseConfig cfg, GridPos from, GridPos to) {
    final pf = AStarPathfinder(cols: cfg.cols, rows: cfg.rows);
    final raw = pf.findPath(
      (from.col, from.row),
      (to.col, to.row),
      walkable: (c) => _driveable(cfg, c.$2, c.$1),
    );
    return raw.map((p) => (row: p.$2, col: p.$1)).toList();
  }

  // A truck drives the ROAD network, its own bay column, and open yard floor —
  // but NEVER the working storage interior: aisles, cross-aisles, robot paths,
  // staging or pack cells are excluded. That confinement keeps a truck on the
  // perimeter road and docked in the inbound column instead of cutting straight
  // across the warehouse (the "truck crosses beyond the staging area" fault) and
  // out of the aisles where it used to sit on cells the pick robots needed,
  // jamming them into a line. `empty` stays driveable so a road-less yard (the
  // acceptance layouts, a minimal custom build) can still route a truck to a bay.
  bool _driveable(WarehouseConfig cfg, int row, int col) {
    if (row < 0 || row >= cfg.rows || col < 0 || col >= cfg.cols) return false;
    final t = cfg.cellAt(row, col)?.type ?? CellType.empty;
    return t.isRoad ||
        t == CellType.dock ||
        t == CellType.inbound ||
        t == CellType.empty;
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
