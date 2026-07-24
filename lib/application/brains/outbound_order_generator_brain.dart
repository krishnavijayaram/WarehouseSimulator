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
import '../providers.dart';
import '../sim_random.dart';
import 'outbound_truck_brain.dart';
import 'unit_brain.dart';

class OutboundOrderGeneratorBrain extends UnitBrain {
  OutboundOrderGeneratorBrain({
    required super.id,
    required this.truckSpawn,
    required this.rng,
    Set<UomKind>? servableUoms,
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

  /// Max native units (pallets / cases / handfuls) per line.
  final int maxUnitsPerLine;

  /// Safety cap on how many orders one wave may contain (a wave normally fills a
  /// truck well before this).
  static const int kMaxOrdersPerWave = 25;

  int _seq = 0;
  int _wave = 0; // current outbound WAVE number (WMS wave picking)
  Set<String> _waveOrderIds = const {}; // orders released in the current wave

  @override
  void perceiveAndDecide(BrainContext ctx) {
    final orders = ctx.ref.read(jobBoardProvider).orders;

    // WMS serial waves — ONE wave on the floor at a time. A wave is still running
    // while any order it released is not yet terminal (shipped or aborted); only
    // once the whole set has shipped do we release the next wave.
    final waveRunning = _waveOrderIds.any((oid) {
      final o = orders[oid];
      return o != null &&
          o.status != OrderStatus.closed &&
          o.status != OrderStatus.aborted;
    });
    if (waveRunning) return;

    // Nothing to ship until something is stocked in a servable rack.
    if (_stockedByUom(ctx.config).isEmpty) return;

    // ── Release the next wave: a truckload of random orders, each routed across
    //    the UOMs it stocks (pallet / case / loose), all picked concurrently. ──
    _wave++;
    ctx.ref.read(simWaveProvider.notifier).state = _wave;
    final released = <String>{};
    final registry = ctx.ref.read(unitRegistryProvider.notifier);
    OutboundTruckBrain? truck;
    var waveUnits = 0;
    // Fill to ~one truckload, with headroom so the wave rides on a single truck.
    final target = (kOutboundTruckCapacityUnits * 0.75).round();
    while (waveUnits < target && released.length < kMaxOrdersPerWave) {
      final order = _mintOneOrder(ctx);
      if (order == null) break; // transient shortage — stop the wave here
      released.add(order.id);
      waveUnits += order.orderedUnits;
      // Pool onto the wave's truck; only open a fresh one if this order overflows
      // (a big wave may span two trucks — the pooling handles it).
      if (truck != null && truck.canAccept(ctx, order.orderedUnits)) {
        truck.addOrder(ctx, order.id);
      } else {
        truck = OutboundTruckBrain(
          id: 'OTRUCK-$id-${_seq++}',
          pos: truckSpawn,
          orderId: order.id,
        );
        registry.register(truck);
      }
    }

    if (released.isEmpty) {
      _wave--; // couldn't release anything this tick — retry the same wave number
      ctx.ref.read(simWaveProvider.notifier).state = _wave;
    } else {
      _waveOrderIds = released;
    }
  }

  /// Mint ONE random outbound Order (one line per UOM it stocks) plus its
  /// pick-to-stage Jobs, tagged with the current wave. Null on a transient
  /// shortage (nothing servable stocked right now).
  Order? _mintOneOrder(BrainContext ctx) {
    final board = ctx.board;
    final byUom = _stockedByUom(ctx.config);
    if (byUom.isEmpty) return null;
    final skus = byUom.keys.toList()..sort(); // deterministic candidate order
    final sku = rng.pick(skus);
    final available = byUom[sku]!.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (available.isEmpty) return null;

    // Explode into ONE LINE PER UOM — "route as pallet, case, loose". Each line
    // is claimed by the picker for that UOM, so all three routes work the order
    // concurrently and it groups at the shipping area.
    final lines = <OrderLine>[];
    for (final uom in available) {
      if (!rng.chance(0.6)) continue; // coin-flip every UOM so shapes vary
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
      waveId: _wave,
    );

    // One Job PER NATIVE UNIT (a robot carries one pallet/case/handful per trip).
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
    return order;
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
