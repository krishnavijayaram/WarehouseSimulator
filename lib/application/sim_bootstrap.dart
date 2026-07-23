/// sim_bootstrap.dart — wire the FULL autonomous loop into a running sim.
///
/// THIS is what makes robots actually work in the app (not just explore): it
/// assigns every spawned robot an operational role (round-robin) and registers
/// the "system player" brains that GENERATE work — StockMonitor (replenish low
/// stock) and OutboundOrderGenerator (emit ship orders). Without this the only
/// registered units are scouts, so the app fog-reveals but no robot moves.
///
/// Standalone + directly testable (see test/app_bootstrap_test.dart) so the
/// "brains work in tests but not in the app" gap can't recur silently.
library;

import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/warehouse_config.dart';
import '../warehouse_engine/services/warehouse_template_factory.dart';
import 'bay_resource.dart';
import 'job_board.dart';
import 'outbound_stage.dart';
import 'providers.dart';
import 'sim_random.dart';
import 'brains/blocker_monitor_brain.dart';
import 'brains/inbound_robot_brain.dart';
import 'brains/recovery_robot_brain.dart';
import 'brains/outbound_order_generator_brain.dart';
import 'brains/outbound_robot_brain.dart';
import 'brains/pick_robot_brain.dart';
import 'brains/putaway_robot_brain.dart';
import 'brains/stock_monitor_brain.dart';
import 'brains/unit_brain.dart';

/// A robot to place in the sim: its id and spawn cell.
typedef SpawnedRobot = ({String id, int row, int col});

/// One seat in the robot cast. Each `pick` seat is assigned a UOM at bootstrap
/// from the UOMs the warehouse actually stocks — the Job's UOM gates who may
/// claim it, so coverage matters (see the note in [bootstrapSimUnits]).
enum _Slot { inbound, outbound, putaway, pick, recovery }

/// Order dedicated picker seats fill UOMs in. Pallets come LAST on purpose: the
/// three pallet-class robots (IR, OR, pallet-pick/putaway) already handle pallet
/// work, so a scarce picker seat is better spent on cases and loose — nothing
/// else can move those. This is what makes a 5-robot floor
/// (IR + OR + PPR + case + loose) the working minimum, with a 6th robot adding
/// the dedicated pallet picker.
const _pickerUomPriority = [UomKind.caseUom, UomKind.loose, UomKind.pallet];

/// Register the operational robot brains + the work-generating system brains for
/// [config] and [robots]. Clears prior registry/resource state first (fresh sim).
void bootstrapSimUnits(
    WidgetRef ref, WarehouseConfig config, List<SpawnedRobot> robots) {
  final registry = ref.read(unitRegistryProvider.notifier);
  registry.clear();
  ref.read(bayOccupancyProvider.notifier).clear();
  ref.read(chargerOccupancyProvider.notifier).clear();
  ref.read(rackReservationProvider.notifier).clear();
  ref.read(stageReservationProvider.notifier).clear();
  ref.read(cellReservationProvider.notifier).clear();
  ref.read(outboundStageProvider.notifier).clear();

  // ── Self-bootstrap starter stock ─────────────────────────────────────────
  // The whole material loop is demand-driven off STOCKED racks: the outbound
  // generator only ships a SKU that sits in a servable rack, and StockMonitor
  // only reorders a rack that ALREADY has a skuId. A warehouse whose racks were
  // never seeded — a custom build, or a layout round-tripped through the backend
  // without per-cell inventory — can therefore NEVER start: no orders, no trucks,
  // no picks, so every robot idles and (packed at spawn) reads as a frozen swarm
  // (see test/swarm_repro_test.dart). If nothing is stocked, seed deterministic
  // starter inventory now — a no-op for an already-stocked warehouse, and local
  // client state only (never a backend write, so it stays EX-safe).
  final anyStock = config.cells.any(
      (c) => c.type.isRack && c.quantity > 0 && (c.skuId ?? '').isNotEmpty);
  if (!anyStock) {
    config = config.copyWith(
      cells: assignTemplateInventory(
          config.cells, Random(ref.read(simSeedProvider))),
    );
    ref.read(warehouseConfigProvider.notifier).state = config;
  }

  // ── De-gridlock a packed spawn ───────────────────────────────────────────
  // If robots are packed so tightly that most have NO free walkable neighbour to
  // step into — stacked in a narrow inbound lane or a 1-wide strip, the user's
  // "swarm" — they can never disperse and read as frozen even once work flows.
  // Detect that and spread them across the floor's walkable cells so the loop can
  // start. Conservative: a normally-spread layout (templates, sensible creator
  // builds) has plenty of escape room and is left exactly as placed.
  if (_isGridlockedSpawn(config, robots)) {
    robots = _spreadRobots(config, robots);
  }

  final positions = ref.read(manualRobotPositionsProvider.notifier);

  // Every robot gets a role so it does real work; roles round-robin so the whole
  // truck→unload→putaway→pick→pack→ship loop is staffed. Each robot still reveals
  // fog as it moves (ActionApplier.moveTo), so exploration happens too.
  // The full cast the material flow needs. Round-robin, so 6+ robots staff every
  // branch; with fewer, some branch is unstaffed (checkWarehouseReadiness warns).
  //   IR   truck -> landing        PPR  landing -> pick areas / cross-dock
  //   3 pickers, ONE PER UOM       OR   shipping -> outbound truck
  // Pickers MUST be heterogeneous: a Job's UOM gates claiming (Job.matchesRole),
  // and a job no picker's UOM matches is filtered out by claimableFor BEFORE the
  // attempts counter can fire the watchdog — it would never be claimed, never
  // fail, and pin its Order open forever. Which UOMs actually exist here is fed
  // to the generator below so it can never mint a line nobody can pick.
  // The cast, in fill order. The first three are the PALLET-CLASS robots — every
  // one of them handles pallets, which is why 5 robots is the working minimum:
  //   IR  inbound truck -> landing        OR   shipping -> outbound truck
  //   PPR the spec-5 rule: pallet area / break->cases / break->loose /
  //       cross-dock->outbound staging when an order is waiting
  // then the dedicated pickers for the UOMs nothing else can move.
  // Fill order matters. Each pick trip stages ONE item that then needs ONE load
  // trip, so pickers and outbound loaders must be roughly 1:1. The old order gave
  // 3 pickers to 1 loader at six robots: the E2E probe showed stage cells filling
  // faster than the single loader could drain them (staging events doubled while
  // ships did not rise), with pickers backing up behind full cells.
  //   5 robots -> IR, OR, PPR, case-picker, loose-picker   (the agreed minimum)
  //   6 robots -> + a SECOND loader, giving 2 pickers : 2 loaders
  //   7+       -> pallet picker, then further loaders, staying ~balanced
  const cast = <_Slot>[
    _Slot.inbound,
    _Slot.outbound,
    _Slot.putaway,
    _Slot.pick, // case picker  ─┐ UOM chosen by _pickerUomPriority
    _Slot.pick, // loose picker ─┘
    _Slot.outbound, // 2nd loader — keeps loaders in step with pickers
    _Slot.pick, // 7th: PALLET picker — must come before the recovery seat, or
    //            pallet racks are write-only: putaway keeps filling them, nothing
    //            drains them, and eventually putaway itself has nowhere to drop.
    _Slot.recovery, // 8th: clears manually-placed blockers to the dump yard
    _Slot.outbound,
  ];
  // Pickers specialise over the UOMs THIS warehouse actually stocks — not a fixed
  // pallet/case/loose triple. A rackLoose-only floor would otherwise get a pallet
  // picker and a case picker with nothing to pick and NO loose picker, leaving
  // every loose line unclaimable. Ordering by _pickerUomPriority spends scarce
  // picker seats on cases/loose first, since pallets already have three robots.
  final rackUoms = _warehouseRackUoms(config).toList()
    ..sort((a, b) => _pickerUomPriority
        .indexOf(a)
        .compareTo(_pickerUomPriority.indexOf(b)));
  if (rackUoms.isEmpty) rackUoms.add(UomKind.pallet);

  final pickerUoms = <UomKind>{};
  var pickerSeat = 0;
  for (var i = 0; i < robots.length; i++) {
    final r = robots[i];
    final pos = (row: r.row, col: r.col);
    final slot = cast[i % cast.length];
    final UnitBrain brain;
    switch (slot) {
      case _Slot.inbound:
        brain = InboundRobotBrain(id: r.id, pos: pos);
      case _Slot.putaway:
        brain = PutawayRobotBrain(id: r.id, pos: pos);
      case _Slot.pick:
        final uom = rackUoms[pickerSeat++ % rackUoms.length];
        pickerUoms.add(uom);
        brain = PickRobotBrain(id: r.id, pos: pos, handledUom: uom);
      case _Slot.outbound:
        brain = OutboundRobotBrain(id: r.id, pos: pos);
      case _Slot.recovery:
        brain = RecoveryRobotBrain(id: r.id, pos: pos);
    }
    registry.register(brain);
    positions.update(r.id, r.row, r.col);
  }

  // The AoE "players" that issue work — they don't move, they trigger the loop.
  final spawn = truckSpawnCell(config);
  // Demand may only ask for a UOM that BOTH a picker handles and a rack type can
  // supply. Anything else mints a Job nobody can claim, which claimableFor hides
  // from the failure watchdog → the Order pins open → the WIP cap stalls the
  // whole outbound loop. This intersection is the guarantee against that.
  final servable = pickerUoms.intersection(_warehouseRackUoms(config));

  // One seeded root RNG; each generator gets its OWN derived stream, so adding a
  // consumer never shifts another's draws and a replay stays byte-identical.
  final rng = SimRng(ref.read(simSeedProvider));

  registry.register(StockMonitorBrain(id: 'stock-monitor', truckSpawn: spawn));
  // Anomaly loop: the monitor SEES a manually-placed blocker and raises a clear
  // Job; the recovery unit hauls it to the dump yard. Perception and action stay
  // separate units coordinating only through the JobBoard.
  registry.register(BlockerMonitorBrain(id: 'blocker-monitor'));
  registry.register(OutboundOrderGeneratorBrain(
    id: 'order-gen',
    truckSpawn: spawn,
    rng: rng.derive('order-gen'),
    servableUoms: servable,
  ));
}

/// A driveable yard cell for trucks to appear at: a road cell if any, else the
/// first empty/walkable cell, else (0,0).
GridPos truckSpawnCell(WarehouseConfig cfg) {
  for (final c in cfg.cells) {
    if (c.type.isRoad) return (row: c.row, col: c.col);
  }
  for (final c in cfg.cells) {
    if (c.type == CellType.empty || c.type.isWalkable) {
      return (row: c.row, col: c.col);
    }
  }
  return (row: 0, col: 0);
}

bool _cellWalkable(WarehouseConfig cfg, int r, int c) {
  if (r < 0 || r >= cfg.rows || c < 0 || c >= cfg.cols) return false;
  final t = cfg.cellAt(r, c)?.type ?? CellType.empty;
  return t.isWalkable || t == CellType.empty;
}

/// True when the spawn is so packed that most robots have NO free walkable
/// neighbour (every adjacent walkable cell is another robot's spawn) — a swarm
/// that cannot disperse. Only fires for genuine gridlock, so a normally-spread
/// layout is never disturbed.
bool _isGridlockedSpawn(WarehouseConfig cfg, List<SpawnedRobot> robots) {
  if (robots.length < 4) return false;
  final occupied = {for (final r in robots) '${r.row}_${r.col}'};
  const dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)];
  var boxed = 0;
  for (final r in robots) {
    final hasEscape = dirs.any((d) {
      final nr = r.row + d.$1, nc = r.col + d.$2;
      return _cellWalkable(cfg, nr, nc) && !occupied.contains('${nr}_$nc');
    });
    if (!hasEscape) boxed++;
  }
  return boxed >= (robots.length * 0.6).ceil();
}

/// Re-place [robots] (keeping their ids) on evenly-spaced walkable cells across
/// the floor so a gridlocked swarm can disperse. Deterministic (row-major scan +
/// even stride). No-op if there aren't enough walkable cells to hold them all.
List<SpawnedRobot> _spreadRobots(WarehouseConfig cfg, List<SpawnedRobot> robots) {
  final cells = <GridPos>[];
  for (var r = 0; r < cfg.rows; r++) {
    for (var c = 0; c < cfg.cols; c++) {
      if (_cellWalkable(cfg, r, c)) cells.add((row: r, col: c));
    }
  }
  if (cells.length < robots.length) return robots;
  return [
    for (var i = 0; i < robots.length; i++)
      (
        id: robots[i].id,
        row: cells[i * cells.length ~/ robots.length].row,
        col: cells[i * cells.length ~/ robots.length].col,
      ),
  ];
}

/// The UOM a general-purpose picker should handle for [cfg]: the type of the
/// first stocked rack, else the first rack of any kind, else pallet (legacy
/// default). Scanned in cell order — the same order the outbound generator uses
/// to choose the SKU — so the picker and the minted Job always agree on UOM.
/// The rack UOMs this warehouse can actually serve — a line whose UOM has no
/// stocked rack type can never be picked. Intersected with the picker coverage
/// so demand only ever asks for something the floor can deliver.
Set<UomKind> _warehouseRackUoms(WarehouseConfig cfg) {
  final out = <UomKind>{};
  for (final c in cfg.cells) {
    final u = rackUomOf(c.type);
    if (u != null) out.add(u);
  }
  return out;
}
