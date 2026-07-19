/// outbound_order_generator_brain.dart — the outbound "system player" (step 9).
///
/// The AoE player for shipping: on a jittered interval, while under a WIP cap, it
/// emits a RANDOM outbound Order — random SKU, random UOM mix, random quantity —
/// explodes it into one line per UOM (pallet / case / loose), mints one pick Job
/// per native unit, and spawns the truck that carries it out.
///
/// Randomness is SEEDED and injected ([SimRng]), never a clock or a bare
/// `Random()`, so demand looks random yet a run replays byte-identically — the
/// property the JEPA eval depends on.
///
/// It only ever asks for a UOM in [servableUoms] (a picker handles it AND a rack
/// type supplies it). Minting outside that set produces a Job no picker can claim,
/// and `claimableFor` filters such a Job out BEFORE the attempts counter can fire
/// the watchdog — so it would never be claimed, never fail, and pin its Order open
/// forever, stalling the WIP cap and the whole outbound loop.
library;

import '../../models/warehouse_config.dart';
import '../job_board.dart';
import '../sim_random.dart';
import 'outbound_truck_brain.dart';
import 'unit_brain.dart';

class OutboundOrderGeneratorBrain extends UnitBrain {
  OutboundOrderGeneratorBrain({
    required super.id,
    required this.truckSpawn,
    required this.rng,
    Set<UomKind>? servableUoms,
    this.wipCap = 3,
    this.emitEveryTicks = 40,
    this.emitJitterTicks = 15,
    this.maxUnitsPerLine = 2,
  })  : servableUoms = servableUoms ?? const {UomKind.pallet},
        super(role: UnitRole.outboundGenerator, pos: const (row: -1, col: -1));

  /// Where spawned outbound trucks appear on the yard.
  final GridPos truckSpawn;

  /// Seeded — demand LOOKS random but a run replays exactly (JEPA eval).
  final SimRng rng;

  /// UOMs this floor can actually serve: a picker handles it AND a rack type
  /// supplies it. Minting outside this set creates a Job nobody can claim, which
  /// claimableFor hides from the failure watchdog → the Order pins open forever.
  final Set<UomKind> servableUoms;

  /// Max simultaneously-open outbound Orders.
  final int wipCap;

  /// Demand arrives on a jittered interval rather than every tick.
  final int emitEveryTicks;
  final int emitJitterTicks;

  /// Max native units (pallets / cases / handfuls) per line.
  final int maxUnitsPerLine;

  int _seq = 0;
  int _nextEmitAtTick = 0;

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

    // Demand arrives on a jittered interval — not every single tick.
    if (ctx.tick < _nextEmitAtTick) return;

    // Sample a SKU that is actually stocked in a SERVABLE rack type. Demand for a
    // SKU nothing can supply would mint an unpickable Job and pin the Order open;
    // the inbound loop is still driven, because shipping depletes these racks and
    // the StockMonitor reorders them.
    final byUom = _stockedByUom(ctx.config);
    if (byUom.isEmpty) return;
    final skus = byUom.keys.toList()..sort(); // deterministic candidate order
    final sku = rng.pick(skus);
    final available = byUom[sku]!.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (available.isEmpty) return;

    // Explode into ONE LINE PER UOM — this is "route as pallet, case, loose".
    // Each line is claimed by the picker handling that UOM, so all three work the
    // same order concurrently and it groups at the shipping area.
    final lines = <OrderLine>[];
    for (final uom in available) {
      // Coin-flip EVERY UOM (including the first) so order shapes really vary —
      // the old `lines.isNotEmpty &&` guard made the lowest-index UOM appear in
      // every order and left the fallback below dead (review #6). If all flips
      // miss, the fallback guarantees at least one line.
      if (!rng.chance(0.6)) continue;
      final nativeUnits = rng.nextIntIn(1, maxUnitsPerLine);
      lines.add(OrderLine(
        lineId: 'L${lines.length}',
        skuId: sku,
        uom: uom,
        units: nativeUnits * uom.looseUnits,
      ));
    }
    if (lines.isEmpty) {
      final uom = rng.pick(available);
      lines.add(OrderLine(
        lineId: 'L0',
        skuId: sku,
        uom: uom,
        units: rng.nextIntIn(1, maxUnitsPerLine) * uom.looseUnits,
      ));
    }

    final order = board.mintOrderOf(
      kind: OrderKind.outboundShip,
      nowTick: ctx.tick,
      lines: lines,
    );

    // One Job PER NATIVE UNIT: a robot carries one pallet/case/handful per trip,
    // so a 3-pallet line is 3 Jobs. Minting one fat Job instead would let a single
    // trip settle it after moving one unit, wedging the Order at 48/144 forever.
    for (final line in lines) {
      final perTrip = line.uom.looseUnits;
      final trips = (line.units / perTrip).ceil();
      for (var k = 0; k < trips; k++) {
        board.mintJobOf(
          kind: JobKind.pickToStage,
          requiredRole: UnitRole.pickRobot,
          skuId: line.skuId,
          requiredUom: line.uom,
          orderId: order.id,
          lineId: line.lineId,
          idemKey: '${order.id}:${line.lineId}:$k',
          qtyUnits: perTrip,
        );
      }
    }

    // POOL the truck: put this order on an existing truck that still has room,
    // and only summon a new one when none can take it. One truck per order meant
    // N trucks competing for a single bay — most never docked before their
    // seek timeout and aborted their own order (~87% failure in the E2E probe).
    final registry = ctx.ref.read(unitRegistryProvider.notifier);
    final units = lines.fold<int>(0, (s, l) => s + l.units);
    OutboundTruckBrain? host;
    for (final u in registry.all()) {
      if (u is OutboundTruckBrain && u.canAccept(ctx, units)) {
        host = u;
        break; // deterministic: registry.all() is id-sorted
      }
    }
    if (host != null) {
      host.addOrder(ctx, order.id);
    } else {
      registry.register(OutboundTruckBrain(
        id: 'OTRUCK-$id-${_seq++}',
        pos: truckSpawn,
        orderId: order.id,
      ));
    }

    _nextEmitAtTick = ctx.tick + rng.jitter(emitEveryTicks, emitJitterTicks);
  }

  /// SKU → the servable UOMs it currently has stock in.
  Map<String, Set<UomKind>> _stockedByUom(WarehouseConfig cfg) {
    final out = <String, Set<UomKind>>{};
    for (final c in cfg.cells) {
      if (!c.type.isRack || c.quantity <= 0) continue;
      final sku = c.skuId;
      if (sku == null || sku.isEmpty) continue;
      final uom = rackUomOf(c.type);
      if (uom == null || !servableUoms.contains(uom)) continue;
      (out[sku] ??= <UomKind>{}).add(uom);
    }
    return out;
  }

  @override
  void act(BrainContext ctx) {
    lifecycle = UnitLifecycle.idle; // never moves
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
