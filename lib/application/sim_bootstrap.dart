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
import 'brains/inbound_robot_brain.dart';
import 'brains/outbound_order_generator_brain.dart';
import 'brains/outbound_robot_brain.dart';
import 'brains/pick_robot_brain.dart';
import 'brains/putaway_robot_brain.dart';
import 'brains/stock_monitor_brain.dart';
import 'brains/unit_brain.dart';

/// A robot to place in the sim: its id and spawn cell.
typedef SpawnedRobot = ({String id, int row, int col});

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
  const roles = [
    UnitRole.inboundRobot,
    UnitRole.putawayRobot,
    UnitRole.pickRobot,
    UnitRole.outboundRobot,
  ];
  // Match the picker to the warehouse's rack type so it can actually pull stock:
  // real warehouses paint rackLoose, and a pallet-only picker would find nothing
  // to pick (the outbound half would sit idle). Same source of truth the outbound
  // generator uses, so the minted Job's UOM and the picker's handled UOM agree.
  final pickUom = _warehousePickUom(config);
  for (var i = 0; i < robots.length; i++) {
    final r = robots[i];
    final pos = (row: r.row, col: r.col);
    final UnitBrain brain = switch (roles[i % roles.length]) {
      UnitRole.inboundRobot => InboundRobotBrain(id: r.id, pos: pos),
      UnitRole.putawayRobot => PutawayRobotBrain(id: r.id, pos: pos),
      UnitRole.pickRobot =>
        PickRobotBrain(id: r.id, pos: pos, handledUom: pickUom),
      _ => OutboundRobotBrain(id: r.id, pos: pos),
    };
    registry.register(brain);
    positions.update(r.id, r.row, r.col);
  }

  // The AoE "players" that issue work — they don't move, they trigger the loop.
  final spawn = truckSpawnCell(config);
  registry.register(StockMonitorBrain(id: 'stock-monitor', truckSpawn: spawn));
  registry
      .register(OutboundOrderGeneratorBrain(id: 'order-gen', truckSpawn: spawn));
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
UomKind _warehousePickUom(WarehouseConfig cfg) {
  for (final c in cfg.cells) {
    if (c.type.isRack && c.quantity > 0) {
      final u = rackUomOf(c.type);
      if (u != null) return u;
    }
  }
  for (final c in cfg.cells) {
    final u = rackUomOf(c.type);
    if (u != null) return u;
  }
  return UomKind.pallet;
}
