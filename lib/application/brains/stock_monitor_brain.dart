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
    this.maxConcurrentInbound = 4,
  }) : super(role: UnitRole.stockMonitor, pos: const (row: -1, col: -1));

  /// Where spawned trucks appear on the yard.
  final GridPos truckSpawn;

  /// Global cap on simultaneously-open inbound replenish Orders. Without it, a
  /// warehouse with many low racks (e.g. a freshly-seeded one) summons a truck
  /// for EVERY low SKU on the same tick — dozens of trucks saturate every bay
  /// (inbound trucks even squat the outbound bays), unload work backs up, and the
  /// whole loop clogs with EFF 0. The cap replenishes low SKUs a few at a time as
  /// bays free, so inbound can never flood outbound out of its own bays.
  final int maxConcurrentInbound;

  /// Legacy knob: a floor on how much a replenishment requests (loose-equiv).
  /// Order size is now DERIVED from the truck manifest so the two can never
  /// disagree — see the note at the mint site.
  final int reorderUnits;

  /// Never send more than this many pallets in one truck.
  static const int kMaxManifest = 4;

  /// An inbound Order still open this long after minting is presumed dead (its
  /// truck departed, or the pallets couldn't be absorbed) and is closed to re-arm
  /// the trigger. Generous: a truck must spawn, drive, dock, unload and be put
  /// away well inside this.
  static const int kStaleOrderTicks = 600;

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

    // How many inbound trucks are already on the floor — the flood cap. Trucks
    // occupy bays and outlive their order while departing, so bounding the TRUCK
    // count (not just open orders) is what keeps inbound from saturating every bay
    // and squeezing outbound out of its own bays.
    var liveInboundTrucks = 0;
    for (final u in ctx.ref.read(unitRegistryProvider).values) {
      if (u is InboundTruckBrain) liveInboundTrucks++;
    }

    // 1) Trigger: a SKU low on the racks with nothing already coming.
    final seen = <String>{};
    for (final c in cfg.cells) {
      if (liveInboundTrucks >= maxConcurrentInbound) break; // don't flood the bays
      if (!c.type.isRack) continue;
      final sku = c.skuId;
      if (sku == null || sku.isEmpty || !c.needsReplenishment) continue;
      if (!seen.add(sku)) continue; // one decision per SKU per tick
      if (inFlight(sku)) continue;

      // Send a truck sized to the ACTUAL deficit, and size the Order to exactly
      // what that truck can deliver. These two MUST agree: one absorbed pallet
      // credits kLoosePerPallet, so if orderedUnits exceeds manifest*48 the Order
      // can never satisfy, and inFlight() below then blocks every future truck for
      // this SKU forever. Today that only works by the accident of reorderUnits
      // and one pallet's credit both being 48 — set reorderUnits to 96 and the
      // SKU stalls permanently. Deriving both from one number removes the trap.
      final pallets = _palletsNeeded(cfg, sku);
      final order = board.mintOrder(
        kind: OrderKind.inboundReplenish,
        skuId: sku,
        orderedUnits: pallets * kLoosePerPallet,
        nowTick: ctx.tick,
      );
      ctx.ref.read(unitRegistryProvider.notifier).register(
            InboundTruckBrain(
              id: 'TRUCK-$id-${_truckSeq++}',
              pos: truckSpawn,
              skuId: sku,
              manifest: pallets,
              orderId: order.id, // thread orderId so putaway advances it (AC-2)
            ),
          );
      liveInboundTrucks++; // count it against the flood cap for the rest of this tick
    }

    // 2) Close: replenish Orders whose SKU is back above reorder (delivered), or
    //    that have gone stale.
    for (final o in orders) {
      if (o.kind != OrderKind.inboundReplenish) continue;
      if (o.status == OrderStatus.closed || o.status == OrderStatus.aborted) {
        continue;
      }
      if (!_lowAnywhere(cfg, o.skuId)) {
        board.closeOrder(o.id); // through the notifier so watchers repaint (HT-6)
      } else if (ctx.tick - o.createdTick > kStaleOrderTicks) {
        // Still low long after its truck should have delivered — the truck died,
        // or the pallets couldn't be absorbed. Close it to RE-ARM the trigger:
        // otherwise inFlight() suppresses every future truck for this SKU and the
        // replenish loop is dead for good. (Order.createdTick was written but read
        // nowhere, so no age-based escape existed at all.)
        board.closeOrder(o.id);
      }
    }
  }

  @override
  void act(BrainContext ctx) {
    lifecycle = UnitLifecycle.idle; // never moves
  }

  /// Pallets to send for [sku]: one per low face, bounded, and at least enough to
  /// cover [reorderUnits]. The truck side has always been multi-pallet capable
  /// (InboundTruckBrain loops the manifest minting one unload Job each) — nothing
  /// ever passed more than 1, so every replenish was a whole spawn→drive→dock→
  /// unload→depart cycle for a single pallet.
  int _palletsNeeded(WarehouseConfig cfg, String sku) {
    var lowFaces = 0;
    for (final c in cfg.cells) {
      if (c.type.isRack && c.skuId == sku && c.needsReplenishment) lowFaces++;
    }
    final floor = (reorderUnits / kLoosePerPallet).ceil();
    var n = lowFaces > floor ? lowFaces : floor;
    if (n < 1) n = 1;
    return n > kMaxManifest ? kMaxManifest : n;
  }

  bool _lowAnywhere(WarehouseConfig cfg, String sku) {
    for (final c in cfg.cells) {
      if (c.type.isRack && c.skuId == sku && c.needsReplenishment) return true;
    }
    return false;
  }
}
