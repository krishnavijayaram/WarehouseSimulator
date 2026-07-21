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
import '../outbound_stage.dart';
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

  // ── Cross-dock (spec 5.1, the PRIMARY rule) ────────────────────────────────
  // When the incoming pallet is already wanted by an open outbound order, it is
  // driven straight to outbound staging instead of being put away. We hold the
  // outbound pallet pick Job it replaces (so no picker races us), then complete
  // it with no progress and mint the pack/load — exactly the accounting a normal
  // rack-pick would produce, so a cross-docked pallet is never double-shipped.
  bool _crossDock = false;
  GridPos? _stageCell;
  String? _heldPickJobId; // the outbound pick Job we hold + replace
  String? _xdockOrderId;
  String? _xdockLineId;
  // The INBOUND replenish Order this pallet's putaway Job belongs to. Cross-dock
  // diverts the pallet to shipping instead of the rack, so replenishment did NOT
  // happen — this Order must be aborted (not silently left open) or its SKU gets
  // no new truck until the 600-tick stale timeout, and the rack stays empty.
  String? _inboundOrderId;


  /// Blockers as of this tick, consulted by [_walkable]. Refreshed at the top of
  /// both phases: the PLANNER must agree with the executor that a blocked cell
  /// is impassable, or A* routes through it and tryStep livelocks forever.
  Set<(int, int)> _blockedNow = const {};

  List<GridPos> _path = const [];
  int _pathIdx = 0;
  int _ticksLeft = 0;

  // ── Phase 1: claim work when idle ──────────────────────────────────────────

  @override
  void perceiveAndDecide(BrainContext ctx) {
    _blockedNow = blockedCellsFor(ctx.ref);
    if (_state != _PR.idle) return;
    final board = ctx.board;
    for (final job in board.claimableFor(UnitRole.putawayRobot)) {
      final src = job.src;
      if (src == null) continue;
      // 5.1 CROSS-DOCK is the PRIMARY rule: if this incoming pallet is already
      // wanted by an open outbound order, send it straight to shipping instead of
      // putting it away. Try it before the 5.2–5.4 putaway rule.
      if (_setupCrossDock(ctx, job, src)) return;
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

  /// Try to route [job]'s incoming pallet straight to outbound staging. Returns
  /// true (and arms the FSM) only if it fully committed: claimed the putaway Job,
  /// is holding the outbound pick Job it replaces, and reserved a stage cell.
  bool _setupCrossDock(BrainContext ctx, Job job, GridPos src) {
    final board = ctx.board;
    // An unclaimed pallet pick Job for this SKU IS the outstanding demand. Holding
    // and later completing it (with no progress) replaces the rack pick 1:1, so
    // the pallet is credited exactly once when it loads — never double-shipped.
    final pick = _replaceablePickJob(ctx, job.skuId);
    if (pick == null) return false;
    final stage = _freeStage(ctx);
    if (stage == null) return false;
    final approach =
        _adjacentWalkable(ctx.config, src.row, src.col, occupiedByOthers(ctx.ref, id));
    final path = approach == null
        ? const <GridPos>[]
        : _findPath(ctx.config, pos, approach, occupiedByOthers(ctx.ref, id));
    if (path.isEmpty) return false;

    if (!board.claim(job.id, id)) return false;
    // Hold the pick Job so no picker races us; back everything out if we can't.
    if (!board.claim(pick.id, id)) {
      board.release(job.id);
      return false;
    }
    if (ctx.ref.read(stageReservationProvider.notifier).claimFirstFree([stage], id) ==
        null) {
      board.release(pick.id);
      board.release(job.id);
      return false;
    }

    _jobId = job.id;
    currentJobId = job.id;
    _sku = job.skuId;
    _staging = src;
    _crossDock = true;
    _stageCell = stage;
    _heldPickJobId = pick.id;
    _xdockOrderId = pick.orderId;
    _xdockLineId = pick.lineId;
    _inboundOrderId = job.orderId; // the replenish Order this pallet came in on
    _path = path;
    _pathIdx = 0;
    _state = _PR.toStaging;
    lifecycle = UnitLifecycle.navigating;
    board.markActive(job.id);
    return true;
  }

  /// An unclaimed pallet-UOM pickToStage Job for [sku] whose Order is still live.
  Job? _replaceablePickJob(BrainContext ctx, String sku) {
    for (final j in ctx.board.claimableFor(UnitRole.pickRobot, uom: UomKind.pallet)) {
      if (j.skuId != sku || j.orderId == null) continue;
      final o = ctx.ref.read(jobBoardProvider).orders[j.orderId];
      if (o != null &&
          (o.status == OrderStatus.open || o.status == OrderStatus.fulfilling)) {
        return j;
      }
    }
    return null;
  }

  /// A free outbound-staging cell (same rule the pick robot stages into).
  GridPos? _freeStage(BrainContext ctx) {
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

  // ── Phase 2: run the FSM one step ──────────────────────────────────────────

  @override
  void act(BrainContext ctx) {
    _blockedNow = blockedCellsFor(ctx.ref);
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
          // Secure the path to the destination (rack, or the cross-dock stage
          // cell) BEFORE draining staging, so an abort never destroys the staged
          // pallet (review DL-2).
          final dest = _crossDock ? _stageCell! : _rack!;
          final approach = _adjacentWalkable(
              ctx.config, dest.row, dest.col, occupiedByOthers(ctx.ref, id));
          final path = approach == null
              ? const <GridPos>[]
              : _findPath(ctx.config, pos, approach, occupiedByOthers(ctx.ref, id));
          if (path.isEmpty) {
            _abort(ctx); // dest now unreachable — staging still intact
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
          if (_crossDock) {
            // The outbound Order can have died while we drove here (its truck gave
            // up on a bay, or a sibling line failed 8×). Staging into a dead Order
            // would strand this pallet on the cell forever and orphan the load Job.
            // If it's gone, fall back to a normal putaway of the carried pallet
            // rather than dropping it into the void.
            final outOrder = _xdockOrderId == null
                ? null
                : ctx.ref.read(jobBoardProvider).orders[_xdockOrderId];
            final outLive = outOrder != null &&
                (outOrder.status == OrderStatus.open ||
                    outOrder.status == OrderStatus.fulfilling);
            if (!outLive) {
              _divertCrossDockToPutaway(ctx);
              return;
            }
            // Drop the pallet into outbound staging and hand it to the pack/load
            // unit exactly as a rack pick would. Completing the held pick Job with
            // NO progress (progress lands at load) replaces it 1:1 — the pallet is
            // credited to its line once, on the truck, never twice.
            applier.stageOutbound(this, _stageCell!, _sku);
            ctx.ref
                .read(stageReservationProvider.notifier)
                .release(_stageCell!.row, _stageCell!.col);
            ctx.board.mintJobOf(
              kind: JobKind.packAndLoad,
              requiredRole: UnitRole.outboundRobot,
              skuId: _sku,
              orderId: _xdockOrderId,
              lineId: _xdockLineId,
              src: _stageCell,
              qtyUnits: kLoosePerPallet,
            );
            ctx.board.completeJob(_heldPickJobId!); // replaced pick: no progress
            ctx.board.completeJob(_jobId!); // putaway Job done
            // The pallet went to shipping, not the rack: abort the replenish Order
            // it arrived on so StockMonitor sends a fresh truck (rack still low)
            // instead of suppressing that SKU until the stale timeout.
            if (_inboundOrderId != null) {
              ctx.board.closeOrder(_inboundOrderId!, aborted: true);
            }
            _reset();
            lifecycle = UnitLifecycle.idle;
            return;
          }
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
    _releaseHeld(ctx);
    final id = _jobId;
    if (id != null) ctx.board.releaseOrFail(id);
    _reset();
    lifecycle = UnitLifecycle.idle;
  }

  /// Give back every reservation/hold this cart is carrying. For a cross-dock
  /// that means the held outbound pick Job goes back to the pool (a real picker
  /// can serve it) and the stage cell is freed — nothing is stranded.
  void _releaseHeld(BrainContext ctx) {
    if (_rack != null) {
      ctx.ref
          .read(rackReservationProvider.notifier)
          .release(_rack!.row, _rack!.col);
    }
    if (_stageCell != null) {
      ctx.ref
          .read(stageReservationProvider.notifier)
          .release(_stageCell!.row, _stageCell!.col);
    }
    if (_heldPickJobId != null) ctx.board.release(_heldPickJobId!);
  }

  /// The outbound Order died mid-cross-dock while we hold its pallet at the stage
  /// cell. Put the pallet away in a rack instead — which legitimately replenishes,
  /// so this cart's putaway Job (carrying the inbound Order) is credited normally
  /// on drop. Give back the outbound hold + stage reservation first.
  void _divertCrossDockToPutaway(BrainContext ctx) {
    if (_heldPickJobId != null) ctx.board.failJob(_heldPickJobId!);
    if (_stageCell != null) {
      ctx.ref
          .read(stageReservationProvider.notifier)
          .release(_stageCell!.row, _stageCell!.col);
    }
    final applier = ActionApplier(ctx.ref, ctx.config);
    void shed() {
      // Nowhere to put it (rack full/unreachable AND order died) — drop the
      // pallet and finish the Job so nothing wedges. Rare exceptional path.
      applier.clearCargo(this);
      ctx.board.completeJob(_jobId!);
      _reset();
      lifecycle = UnitLifecycle.idle;
    }

    final dest = _decideDestination(ctx.config, _sku);
    if (dest == null) return shed();
    final destCell = (row: dest.row, col: dest.col);
    final rackRes = ctx.ref.read(rackReservationProvider.notifier);
    if (rackRes.claimFirstFree([destCell], id) == null) return shed();
    final approach = _adjacentWalkable(
        ctx.config, destCell.row, destCell.col, occupiedByOthers(ctx.ref, id));
    final path = approach == null
        ? const <GridPos>[]
        : _findPath(ctx.config, pos, approach, occupiedByOthers(ctx.ref, id));
    if (path.isEmpty) {
      rackRes.release(destCell.row, destCell.col);
      return shed();
    }
    // Convert to a normal putaway to the rack. _jobId still carries the inbound
    // Order in the board, so dropToRack + completeJob credits it correctly.
    _crossDock = false;
    _stageCell = null;
    _heldPickJobId = null;
    _xdockOrderId = null;
    _xdockLineId = null;
    _inboundOrderId = null;
    _rack = destCell;
    _dropAmount = dest.amount;
    _path = path;
    _pathIdx = 0;
    _state = _PR.toRack;
    lifecycle = UnitLifecycle.navigating;
  }

  @override
  void onReset(BrainContext ctx) {
    // Release every held reservation/job so a revived cart isn't blocked by its
    // own reservation, and a cross-dock's held pick Job isn't stranded (offline).
    _releaseHeld(ctx);
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
    _crossDock = false;
    _stageCell = null;
    _heldPickJobId = null;
    _xdockOrderId = null;
    _xdockLineId = null;
    _inboundOrderId = null;
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
    if (_blockedNow.contains((col, row))) return false;
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
