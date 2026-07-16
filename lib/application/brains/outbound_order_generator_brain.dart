/// outbound_order_generator_brain.dart — the outbound "system player" (step 9).
///
/// The AoE player for shipping: while under a WIP cap and stock exists, it emits
/// an outbound Order for a stocked SKU, its pick Job, and spawns the truck that
/// will carry it out. Selection is deterministic (first stocked SKU) so runs are
/// reproducible for the JEPA eval; a seeded-random demand pattern can layer on
/// top later without changing the loop.
library;

import '../../models/warehouse_config.dart';
import '../job_board.dart';
import 'outbound_truck_brain.dart';
import 'unit_brain.dart';

class OutboundOrderGeneratorBrain extends UnitBrain {
  OutboundOrderGeneratorBrain({
    required super.id,
    required this.truckSpawn,
    this.wipCap = 1,
    this.orderUnits = kLoosePerPallet,
  }) : super(role: UnitRole.outboundGenerator, pos: const (row: -1, col: -1));

  /// Where spawned outbound trucks appear on the yard.
  final GridPos truckSpawn;

  /// Max simultaneously-open outbound Orders.
  final int wipCap;
  final int orderUnits;

  int _seq = 0;

  @override
  void perceiveAndDecide(BrainContext ctx) {
    final board = ctx.board;
    final orders = ctx.ref.read(jobBoardProvider).orders.values;
    final openOutbound = orders
        .where((o) =>
            o.kind == OrderKind.outboundShip &&
            (o.status == OrderStatus.open ||
                o.status == OrderStatus.fulfilling))
        .length;
    if (openOutbound >= wipCap) return;

    final stocked = _firstStocked(ctx.config);
    if (stocked == null) return;
    final sku = stocked.sku;

    // One UOM-unit per order for now: the pipeline mints exactly one pick Job and
    // ships one unit, so the order must be sized to what a single pick→ship cycle
    // delivers — a loose rack ships 1 loose, a case rack 4, a pallet rack 48
    // (all in loose-equivalent). Larger multi-unit orders would wedge the WIP
    // slot until multi-unit explosion is wired (AC-6).
    final units = stocked.uom.looseUnits;

    final order = board.mintOrder(
      kind: OrderKind.outboundShip,
      skuId: sku,
      orderedUnits: units,
      nowTick: ctx.tick,
    );
    board.mintJobOf(
      kind: JobKind.pickToStage,
      requiredRole: UnitRole.pickRobot,
      skuId: sku,
      requiredUom: stocked.uom,
      orderId: order.id,
      idemKey: '${order.id}:L0:0',
      qtyUnits: units,
    );
    ctx.ref.read(unitRegistryProvider.notifier).register(
          OutboundTruckBrain(
            id: 'OTRUCK-$id-${_seq++}',
            pos: truckSpawn,
            orderId: order.id,
          ),
        );
  }

  @override
  void act(BrainContext ctx) {
    lifecycle = UnitLifecycle.idle; // never moves
  }

  /// First stocked rack of ANY type, with the UOM it holds. Real warehouses are
  /// painted with `rackLoose` (the creator default); scanning only `rackPallet`
  /// was why the whole outbound half stayed idle on a normal warehouse.
  ({String sku, UomKind uom})? _firstStocked(WarehouseConfig cfg) {
    for (final c in cfg.cells) {
      if (!c.type.isRack) continue;
      if (c.skuId == null || c.skuId!.isEmpty || c.quantity <= 0) continue;
      final uom = rackUomOf(c.type);
      if (uom != null) return (sku: c.skuId!, uom: uom);
    }
    return null;
  }
}

/// The UOM a rack of [t] holds, or null if [t] is not a rack type. Shared by the
/// picker bootstrap so the picker's handled UOM matches the warehouse's racks.
UomKind? rackUomOf(CellType t) => switch (t) {
      CellType.rackLoose => UomKind.loose,
      CellType.rackCase => UomKind.caseUom,
      CellType.rackPallet => UomKind.pallet,
      _ => null,
    };
