/// stock_monitor_brain.dart — the inbound "system player" (P3, step 1).
///
/// Age-of-Empires framing: this is the *player* clicking "go get more stock."
/// It doesn't move — each tick it scans the racks and, for any SKU below its
/// reorder point with nothing already in flight, mints an inbound Order and
/// spawns an InboundTruckBrain carrying that SKU. It closes the Order once the
/// SKU is back above reorder (rack delivery), which re-arms the trigger.
///
/// Debounce is the open-Order itself (one in-flight replenish per SKU), so no
/// separate bookkeeping set is needed. Truck ids are a deterministic counter —
/// no wall-clock / RNG — to keep runs reproducible for the JEPA eval.
library;

import '../../models/warehouse_config.dart';
import '../job_board.dart';
import 'inbound_truck_brain.dart';
import 'unit_brain.dart';

class StockMonitorBrain extends UnitBrain {
  StockMonitorBrain({
    required super.id,
    required this.truckSpawn,
    this.reorderUnits = kLoosePerPallet,
  }) : super(role: UnitRole.stockMonitor, pos: const (row: -1, col: -1));

  /// Where spawned trucks appear on the yard.
  final GridPos truckSpawn;

  /// How much each replenishment Order requests (loose-equiv).
  final int reorderUnits;

  int _truckSeq = 0;

  @override
  void perceiveAndDecide(BrainContext ctx) {
    final cfg = ctx.config;
    final board = ctx.board;
    final orders = ctx.ref.read(jobBoardProvider).orders.values;

    bool inFlight(String sku) => orders.any((o) =>
        o.kind == OrderKind.inboundReplenish &&
        o.skuId == sku &&
        (o.status == OrderStatus.open || o.status == OrderStatus.fulfilling));

    // 1) Trigger: a SKU low on the racks with nothing already coming.
    final seen = <String>{};
    for (final c in cfg.cells) {
      if (!c.type.isRack) continue;
      final sku = c.skuId;
      if (sku == null || sku.isEmpty || !c.needsReplenishment) continue;
      if (!seen.add(sku)) continue; // one decision per SKU per tick
      if (inFlight(sku)) continue;

      final order = board.mintOrder(
        kind: OrderKind.inboundReplenish,
        skuId: sku,
        orderedUnits: reorderUnits,
        nowTick: ctx.tick,
      );
      ctx.ref.read(unitRegistryProvider.notifier).register(
            InboundTruckBrain(
              id: 'TRUCK-$id-${_truckSeq++}',
              pos: truckSpawn,
              skuId: sku,
              manifest: 1,
              orderId: order.id, // thread orderId so putaway advances it (AC-2)
            ),
          );
    }

    // 2) Close: replenish Orders whose SKU is back above reorder (delivered).
    for (final o in orders) {
      if (o.kind != OrderKind.inboundReplenish) continue;
      if (o.status == OrderStatus.closed || o.status == OrderStatus.aborted) {
        continue;
      }
      if (!_lowAnywhere(cfg, o.skuId)) {
        board.closeOrder(o.id); // through the notifier so watchers repaint (HT-6)
      }
    }
  }

  @override
  void act(BrainContext ctx) {
    lifecycle = UnitLifecycle.idle; // never moves
  }

  bool _lowAnywhere(WarehouseConfig cfg, String sku) {
    for (final c in cfg.cells) {
      if (c.type.isRack && c.skuId == sku && c.needsReplenishment) return true;
    }
    return false;
  }
}
