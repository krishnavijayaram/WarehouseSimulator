/// pick_robot_brain.dart — outbound retrieval (P4, step 6).
///
/// Claims a UOM-matched `pickToStage` Job, drives to a rack holding that SKU,
/// pulls one unit (idem-guarded rack decrement, closing LCC-4 on a re-claim),
/// carries it to a free outbound stage cell, and drops it there for the pack/
/// load unit to ship. The Order's authoritative counter is NOT touched here —
/// it advances only at depart (single decrement point, LCC-2).
///
/// GATE for scaling to many pickers: a per-face reserved-units check (SBI-2) so
/// two pickers can't over-draw one rack face. One picker per SKU is race-free.
library;

import '../../models/warehouse_config.dart';
import '../../warehouse_engine/services/pathfinding.dart';
import '../bay_resource.dart';
import '../job_board.dart';
import '../outbound_stage.dart';
import 'action_applier.dart';
import 'unit_brain.dart';

enum _PK { idle, toRack, picking, toStage, staging }

class PickRobotBrain extends UnitBrain {
  PickRobotBrain({
    required super.id,
    required super.pos,
    this.handledUom = UomKind.pallet,
  }) : super(role: UnitRole.pickRobot);

  /// The UOM this picker handles (matched against the Job's requiredUom, SC-9).
  final UomKind handledUom;

  static const int kPickTicks = 3;
  static const int kDropTicks = 2;

  /// Give up a job whose drive can't finish within this many ticks so a picker
  /// can never strand itself holding stock it cannot deliver (the "stuck carrying
  /// SKU-x" wedge). Roomy so a legitimately long, congested haul is never cut.
  static const int kGiveUpTicks = 350;

  _PK _state = _PK.idle;
  String? _jobId;
  String? _idemKey;
  String? _orderId;

  /// The Order LINE this pick serves, so the load credits the right line of a
  /// multi-line (pallet+case+loose) order rather than a shared counter.
  String? _lineId;

  /// The claimed Job's demand in loose-equiv. One trip moves at most ONE native
  /// unit (a robot carries one pallet/case/handful), so a line larger than that
  /// is minted as several Jobs — never silently under-delivered by one trip.
  int _jobQty = 0;

  /// Loose-equiv this trip legitimately carries: one native unit, capped by what
  /// the Job actually asked for (so a 1-loose Job never credits a whole pallet).
  int get _tripUnits {
    final oneUnit = handledUom.looseUnits;
    if (_jobQty <= 0) return oneUnit; // Job carried no qty → assume one unit
    return _jobQty < oneUnit ? _jobQty : oneUnit;
  }
  String _sku = '';
  GridPos? _rack;
  GridPos? _stage;


  /// Blockers as of this tick, consulted by [_walkable]. Refreshed at the top of
  /// both phases: the PLANNER must agree with the executor that a blocked cell
  /// is impassable, or A* routes through it and tryStep livelocks forever.
  Set<(int, int)> _blockedNow = const {};

  List<GridPos> _path = const [];
  int _pathIdx = 0;
  int _ticksLeft = 0;

  CellType get _sourceType => switch (handledUom) {
        UomKind.pallet => CellType.rackPallet,
        UomKind.caseUom => CellType.rackCase,
        UomKind.loose => CellType.rackLoose,
      };

  @override
  void perceiveAndDecide(BrainContext ctx) {
    _blockedNow = blockedCellsFor(ctx.ref);
    if (_state != _PK.idle) return;
    final board = ctx.board;
    // NOTE (measured, do not "fix" naively): gating picks on a docked truck
    // (order.shipBay != null) raises pick->load conversion from 37% to 71% but
    // COLLAPSES throughput (ships 6 -> 3), because picking then only happens
    // inside the truck's short dwell window. Shortening the dwell made it worse
    // still (ships -> 2). The real fix is the grouping/close-at-departure design
    // — pick while the truck approaches, and let it wait for its group — not a
    // claim-time gate or a dwell knob.
    for (final job in board.claimableFor(UnitRole.pickRobot, uom: handledUom)) {
      if (!board.claim(job.id, id)) continue;
      final src = _findSource(
          ctx.config, job.skuId, ctx.ref.read(rackReservationProvider));
      final approach =
          src == null
              ? null
              : _adjacentWalkable(
                  ctx.config, src.row, src.col, occupiedByOthers(ctx.ref, id));
      final path = approach == null
          ? const <GridPos>[]
          : _findPath(ctx.config, pos, approach, occupiedByOthers(ctx.ref, id));
      if (src == null || path.isEmpty) {
        // Transient shortages must WAIT, not fail. Two cases count as transient:
        //  (a) stock exists but is reserved by another picker, and
        //  (b) there is no stock YET but an inbound replenishment is in flight —
        //      a truck is literally on its way with it.
        // Without (b) the two halves don't run in tandem: outbound kept aborting
        // orders (8 attempts → Order aborted) for stock that inbound was already
        // delivering, which is most of the residual failure rate. If the
        // replenishment itself dies, StockMonitor's stale-order timeout closes it
        // and this falls through to a real failure, so nothing waits forever.
        if (src == null &&
            (_hasAnyStock(ctx.config, job.skuId) ||
                _replenishInFlight(ctx, job.skuId))) {
          board.release(job.id);
        } else {
          board.releaseOrFail(job.id);
        }
        continue;
      }
      _jobId = job.id;
      currentJobId = job.id;
      _idemKey = job.idemKey;
      _orderId = job.orderId;
      _lineId = job.lineId;
      _jobQty = job.qtyUnits;
      _sku = job.skuId;
      _rack = src;
      // Reserve the source face so no concurrent picker over-draws it (SBI-2).
      ctx.ref.read(rackReservationProvider.notifier).claimFirstFree([src], id);
      _path = path;
      _pathIdx = 0;
      _state = _PK.toRack;
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
      case _PK.idle:
        lifecycle = UnitLifecycle.idle;

      case _PK.toRack:
        if (_driveTicks > kGiveUpTicks) return _abort(ctx);
        if (_advance(applier)) {
          _state = _PK.picking;
          _ticksLeft = kPickTicks;
          lifecycle = UnitLifecycle.working;
        }

      case _PK.picking:
        if (--_ticksLeft <= 0) {
          // Secure a free stage cell + path BEFORE consuming the idem key or
          // decrementing the rack (review AC-4/F2): an abort here rolls back
          // cleanly because nothing has been mutated yet.
          final stage = _findStage(ctx);
          final approach = stage == null
              ? null
              : _adjacentWalkable(
                  ctx.config, stage.row, stage.col, occupiedByOthers(ctx.ref, id));
          final path = approach == null
              ? const <GridPos>[]
              : _findPath(ctx.config, pos, approach, occupiedByOthers(ctx.ref, id));
          if (stage == null || path.isEmpty) {
            _abort(ctx); // nothing picked/consumed yet — no orphaned stock
            return;
          }
          // Reserve the stage cell so no other picker double-books it (F3/F5).
          ctx.ref
              .read(stageReservationProvider.notifier)
              .claimFirstFree([stage], id);
          // Now commit the pick. Idem ledger: decrement the rack once per key; a
          // duplicate re-claim just carries (stock already left on the first pass).
          if (ctx.board.consumeIdem(_idemKey)) {
            applier.pickFromRack(this, _rack!, _sku, 1);
          } else {
            applier.pickFromTruck(this, _sku); // load-only, no rack decrement
          }
          // Source-face contention is over now the stock is pulled. Null _rack
          // immediately: keeping it meant a later offline/onReset would release
          // this cell a SECOND time — by then another unit may have reserved it,
          // so the double-release frees someone else's reservation (review #4).
          ctx.ref
              .read(rackReservationProvider.notifier)
              .release(_rack!.row, _rack!.col);
          _rack = null;
          _stage = stage;
          _path = path;
          _pathIdx = 0;
          _state = _PK.toStage;
          lifecycle = UnitLifecycle.navigating;
        }

      case _PK.toStage:
        if (_driveTicks > kGiveUpTicks) return _abort(ctx);
        if (_advance(applier)) {
          _state = _PK.staging;
          _ticksLeft = kDropTicks;
          lifecycle = UnitLifecycle.working;
        }

      case _PK.staging:
        if (--_ticksLeft <= 0) {
          applier.stageOutbound(this, _stage!, _sku);
          // Physically held in outboundStage now → drop the reservation (F3).
          ctx.ref
              .read(stageReservationProvider.notifier)
              .release(_stage!.row, _stage!.col);
          // Handoff: staged goods need packing+loading → mint the Job the
          // OutboundRobotBrain claims once the truck has docked.
          ctx.board.mintJobOf(
            kind: JobKind.packAndLoad,
            requiredRole: UnitRole.outboundRobot,
            skuId: _sku,
            orderId: _orderId,
            lineId: _lineId, // credit THIS line, not a shared order counter
            src: _stage,
            // What this trip actually moved: one native unit's loose-equiv
            // (pallet=48/case=4/loose=1), never more than the Job asked for.
            // A Job demanding more than one native unit is minted as several
            // Jobs — one trip must never claim credit for units it didn't carry.
            qtyUnits: _tripUnits,
          );
          ctx.board.completeJob(_jobId!); // Order advances at load, not here
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

  void _abort(BrainContext ctx) {
    ActionApplier(ctx.ref, ctx.config).clearCargo(this); // roll back any pick
    if (_rack != null) {
      ctx.ref
          .read(rackReservationProvider.notifier)
          .release(_rack!.row, _rack!.col);
    }
    if (_stage != null) {
      ctx.ref
          .read(stageReservationProvider.notifier)
          .release(_stage!.row, _stage!.col);
    }
    final id = _jobId;
    if (id != null) ctx.board.releaseOrFail(id);
    _reset();
    lifecycle = UnitLifecycle.idle;
  }

  @override
  void onReset(BrainContext ctx) {
    if (_rack != null) {
      ctx.ref
          .read(rackReservationProvider.notifier)
          .release(_rack!.row, _rack!.col);
    }
    if (_stage != null) {
      ctx.ref
          .read(stageReservationProvider.notifier)
          .release(_stage!.row, _stage!.col);
    }
    _reset();
  }

  void _reset() {
    _state = _PK.idle;
    _jobId = null;
    _idemKey = null;
    _orderId = null;
    _lineId = null;
    _jobQty = 0;
    currentJobId = null;
    _sku = '';
    _rack = null;
    _stage = null;
    _path = const [];
    _pathIdx = 0;
    _ticksLeft = 0;
    _driveTicks = 0;
  }

  /// An inbound replenishment for [sku] is open/fulfilling — stock is coming, so
  /// a pick shortage right now is transient and must not burn a failure attempt.
  /// This is the link that makes the inbound and outbound loops run in tandem.
  bool _replenishInFlight(BrainContext ctx, String sku) {
    for (final o in ctx.ref.read(jobBoardProvider).orders.values) {
      if (o.kind == OrderKind.inboundReplenish &&
          o.skuId == sku &&
          (o.status == OrderStatus.open ||
              o.status == OrderStatus.fulfilling)) {
        return true;
      }
    }
    return false;
  }

  /// Any rack of this UOM holds stock for [sku] (ignoring reservations) — used
  /// to tell "reserved, wait" apart from "no stock, fail" (P6/DL-3).
  bool _hasAnyStock(WarehouseConfig cfg, String sku) {
    for (final c in cfg.cells) {
      if (c.type == _sourceType && c.skuId == sku && c.quantity > 0) return true;
    }
    return false;
  }

  GridPos? _findSource(
      WarehouseConfig cfg, String sku, Map<String, String> reserved) {
    for (final c in cfg.cells) {
      if (c.type == _sourceType &&
          c.skuId == sku &&
          c.quantity > 0 &&
          !reserved.containsKey('${c.row}_${c.col}')) {
        return (row: c.row, col: c.col);
      }
    }
    return null;
  }

  GridPos? _findStage(BrainContext ctx) {
    final held = ctx.ref.read(outboundStageProvider.notifier);
    final reserved = ctx.ref.read(stageReservationProvider);
    for (final c in ctx.config.cells) {
      if (c.type == CellType.packStation &&
          held.isFree(c.row, c.col) &&
          !reserved.containsKey('${c.row}_${c.col}')) {
        return (row: c.row, col: c.col);
      }
    }
    return null;
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  List<GridPos> _findPath(WarehouseConfig cfg, GridPos from, GridPos to,
      [Set<(int, int)>? occupied, int? penalty]) {
    final pf = AStarPathfinder(cols: cfg.cols, rows: cfg.rows);
    final raw = pf.findPath(
      (from.col, from.row),
      (to.col, to.row),
      occupied: occupied, // soft congestion penalty (P6)
      penalty: penalty, // escalated when a robot is genuinely wedged
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
