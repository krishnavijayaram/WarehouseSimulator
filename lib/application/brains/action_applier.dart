/// action_applier.dart — the ONE surface through which a unit mutates the world.
///
/// Collapses today's split `manual*` (user taps) and `_execute*` (auto tick)
/// paths in the inbound/putaway controllers into a single applier used by every
/// brain, so movement, cargo, staging, rack, fog-reveal, and battery-drain
/// effects are identical whether a human or a brain triggers them.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/warehouse_config.dart';
import '../providers.dart';
import '../bay_resource.dart';
import '../job_board.dart';
import '../outbound_stage.dart';
import 'unit_brain.dart';

/// Battery drained per executed move (P0 local constant; Amendment B reconciles
/// this with the sim_constants energy model + charging).
const double kMoveDrain = 0.15;

class ActionApplier {
  ActionApplier(this.ref, this.config);
  final WidgetRef ref;
  final WarehouseConfig config;

  bool _drains(UnitBrain u) =>
      u.role != UnitRole.inboundTruck && u.role != UnitRole.outboundTruck;

  /// Advance a unit one cell: update the authoritative position, mirror it to
  /// the renderer (manualRobotPositionsProvider), reveal fog, drain battery.
  /// [drainBattery] is false for idle patrol (light repositioning that must not
  /// burn the work-energy budget or it would fight the charging hysteresis).
  void moveTo(UnitBrain unit, GridPos next, {bool drainBattery = true}) {
    unit.pos = next;
    ref
        .read(manualRobotPositionsProvider.notifier)
        .update(unit.id, next.row, next.col);
    revealFog(next);
    if (drainBattery && _drains(unit)) {
      unit.battery = (unit.battery - kMoveDrain).clamp(0.0, 100.0);
    }
  }

  /// Remove a unit from the world entirely: unschedule it (registry) AND clear
  /// its rendered cell (manualRobotPositionsProvider). Truck brains used to clear
  /// only the registry on departure, leaking a stale entry keyed by their unique
  /// TRUCK-…-N / OTRUCK-…-N id that was never overwritten or removed — so every
  /// departed truck stayed painted at its exit (col 0) / bay, accumulating an
  /// unbounded "blast" of ghost robots over a run. Both removals are idempotent.
  void despawn(UnitBrain unit) {
    ref.read(unitRegistryProvider.notifier).remove(unit.id);
    ref.read(manualRobotPositionsProvider.notifier).remove(unit.id);
  }

  /// Move one cell IF it's free this tick — the P6 hard collision guard. Returns
  /// false (the unit holds in place) when [next] is already reserved by another
  /// unit; on success it hands off the reservation from the old cell to [next].
  bool tryStep(UnitBrain unit, GridPos next, {bool drainBattery = true}) {
    final holder = ref.read(cellReservationProvider)['${next.row}_${next.col}'];
    if (holder != null && holder != unit.id) return false;
    final res = ref.read(cellReservationProvider.notifier);
    // Only give up a cell we actually HOLD. A blocker can be dropped onto the
    // cell a unit is standing on, in which case the sentinel owns it — releasing
    // it here would evict a live obstruction and let the next robot drive
    // straight over it (visible on screen as a robot crossing a blocker).
    final hereKey = '${unit.pos.row}_${unit.pos.col}';
    if (ref.read(cellReservationProvider)[hereKey] == unit.id) {
      res.release(unit.pos.row, unit.pos.col);
    }
    res.claimFirstFree([next], unit.id);
    moveTo(unit, next, drainBattery: drainBattery);
    return true;
  }

  /// Reveal the 3×3 block around a cell.
  void revealFog(GridPos p) {
    final n = ref.read(exploredCellsProvider.notifier);
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        final nr = p.row + dr;
        final nc = p.col + dc;
        if (nr >= 0 && nr < config.rows && nc >= 0 && nc < config.cols) {
          n.markExplored(nr, nc);
        }
      }
    }
  }

  /// Pick a pallet out of a staging slot into the unit's cargo.
  void pickFromStaging(UnitBrain unit, GridPos staging, String skuId) {
    ref.read(stagingPalletsProvider.notifier).pick(staging.row, staging.col);
    ref
        .read(robotCargoProvider.notifier)
        .loadPallet(unit.id, PalletData(skuId: skuId, truckId: 'STAGING'));
  }

  /// Deposit the carried pallet's contents into a rack cell, in loose-equivalent
  /// units, capped at the cell's capacity (no silent over-fill). Clears cargo.
  /// Returns the units actually absorbed (newQty - oldQty) so the caller credits
  /// the Order by what the rack really took, not a fixed amount (review F2-fsm).
  int dropToRack(UnitBrain unit, GridPos rack, String skuId, int addUnits) {
    var absorbed = 0;
    final cfg = ref.read(warehouseConfigProvider);
    if (cfg != null) {
      final cell = cfg.cellAt(rack.row, rack.col);
      if (cell != null) {
        final newQty = (cell.quantity + addUnits).clamp(0, cell.maxQuantity);
        absorbed = newQty - cell.quantity;
        ref.read(warehouseConfigProvider.notifier).state =
            cfg.setCell(cell.copyWith(quantity: newQty, skuId: skuId));
      }
    }
    ref.read(robotCargoProvider.notifier).clearCargo(unit.id);
    return absorbed;
  }

  /// Clear a unit's cargo (roll back a pick on an aborted job).
  void clearCargo(UnitBrain unit) =>
      ref.read(robotCargoProvider.notifier).clearCargo(unit.id);

  /// Load a pallet into the unit's cargo (picked off a docked truck).
  void pickFromTruck(UnitBrain unit, String skuId, {String truckId = 'TRUCK'}) {
    ref
        .read(robotCargoProvider.notifier)
        .loadPallet(unit.id, PalletData(skuId: skuId, truckId: truckId));
  }

  /// Deposit the carried pallet into a staging slot and clear cargo.
  void dropAtStaging(UnitBrain unit, GridPos staging, String skuId) {
    ref
        .read(stagingPalletsProvider.notifier)
        .drop(staging.row, staging.col, skuId);
    ref.read(robotCargoProvider.notifier).clearCargo(unit.id);
  }

  /// Retrieve [units] (rack-native) from a rack cell into cargo, decrementing
  /// the rack (clamped ≥0). The load side of an outbound pick.
  void pickFromRack(UnitBrain unit, GridPos rack, String skuId, int units) {
    final cfg = ref.read(warehouseConfigProvider);
    if (cfg != null) {
      final cell = cfg.cellAt(rack.row, rack.col);
      if (cell != null) {
        final newQty = (cell.quantity - units).clamp(0, cell.maxQuantity);
        ref.read(warehouseConfigProvider.notifier).state =
            cfg.setCell(cell.copyWith(quantity: newQty));
      }
    }
    ref
        .read(robotCargoProvider.notifier)
        .loadPallet(unit.id, PalletData(skuId: skuId, truckId: 'RACK'));
  }

  /// Place the carried pallet on an outbound stage cell and clear cargo.
  void stageOutbound(UnitBrain unit, GridPos stage, String skuId) {
    ref.read(outboundStageProvider.notifier).place(stage.row, stage.col, skuId);
    ref.read(robotCargoProvider.notifier).clearCargo(unit.id);
  }

  /// Take a staged pallet off an outbound stage cell into cargo. Returns false
  /// if the cell was already empty — the caller must NOT load/ship a phantom
  /// (review HT-1): a re-claim of an already-taken stage cell loads nothing.
  bool takeFromStage(UnitBrain unit, GridPos stage, String skuId) {
    final took = ref.read(outboundStageProvider.notifier).take(stage.row, stage.col);
    if (took == null) return false;
    ref
        .read(robotCargoProvider.notifier)
        .loadPallet(unit.id, PalletData(skuId: skuId, truckId: 'STAGE'));
    return true;
  }

  /// Hand the carried pallet onto a truck (clears cargo; the load is accounted
  /// on the Order by the caller — the single increment point).
  void loadOntoTruck(UnitBrain unit) {
    ref.read(robotCargoProvider.notifier).clearCargo(unit.id);
  }
}
