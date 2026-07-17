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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/warehouse_config.dart';
import 'bay_resource.dart';
import 'job_board.dart';
import 'outbound_stage.dart';
import 'providers.dart';
import 'sim_random.dart';
import 'brains/inbound_robot_brain.dart';
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
enum _Slot { inbound, putaway, pick, outbound }

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
  const cast = <_Slot>[
    _Slot.inbound,
    _Slot.putaway,
    _Slot.pick,
    _Slot.pick,
    _Slot.pick,
    _Slot.outbound,
  ];
  // Pickers specialise over the UOMs THIS warehouse actually stocks — not a fixed
  // pallet/case/loose triple. A rackLoose-only floor with 4 robots would otherwise
  // get a pallet picker and a case picker and NO loose picker, leaving every loose
  // line unclaimable. Round-robin over the present UOMs guarantees that each one
  // has a picker for any robot count >= the number of rack UOMs.
  final rackUoms = _warehouseRackUoms(config).toList()
    ..sort((a, b) => a.index.compareTo(b.index));
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
