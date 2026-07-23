// Reproduce "automation ran, then SUDDENLY STOPPED — no new inbound/outbound
// orders, no trucks" on a seeded warehouse (the user's live symptom AFTER the
// stock-bootstrap + de-gridlock fixes made the loop actually start).
//
// Method: seed a real template warehouse, run the REAL scheduler for a long
// horizon, and record the tick each order was first minted. If demand keeps
// flowing the late windows have orders too; if the loop wedges, generation
// stops after some tick and the late windows are empty.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/outbound_stage.dart';
import 'package:warehouse_simulator/application/bay_resource.dart';
import 'package:warehouse_simulator/application/sim_bootstrap.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/inbound_truck_brain.dart';
import 'package:warehouse_simulator/application/brains/outbound_truck_brain.dart';
import 'package:warehouse_simulator/warehouse_engine/services/warehouse_template_factory.dart';

WarehouseConfig _seeded(String name) {
  final base =
      kWarehouseTemplates.firstWhere((t) => t.name == name).builder();
  return base.copyWith(cells: assignTemplateInventory(base.cells));
}

void main() {
  testWidgets('STALL: demand keeps flowing on a seeded warehouse (no wedge)',
      (tester) async {
    final cfg = _seeded('Medium Distribution Center B');
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      child: Consumer(builder: (_, r, __) {
        ref = r;
        return const SizedBox();
      }),
    ));
    ref.read(warehouseConfigProvider.notifier).state = cfg;

    final robots = [
      for (final s in cfg.robotSpawns)
        (id: s.name ?? '${s.robotType}-${s.row}-${s.col}', row: s.row, col: s.col),
    ];
    bootstrapSimUnits(ref, cfg, robots);

    final firstSeen = <String, int>{};
    final scheduler = UnitScheduler(ref);
    const horizon = 3000;
    for (var t = 0; t < horizon; t++) {
      scheduler.tick(cfg, t);
      for (final o in ref.read(jobBoardProvider).orders.values) {
        firstSeen.putIfAbsent(o.id, () => t);
      }
    }

    // Bucket order births into 1000-tick windows.
    final w = List.filled(horizon ~/ 1000, 0);
    firstSeen.forEach((_, t) => w[(t ~/ 1000).clamp(0, w.length - 1)]++);

    // Final-state forensics — WHY it stalled, if it did.
    final board = ref.read(jobBoardProvider);
    final openOut = board.orders.values.where((o) =>
        o.kind == OrderKind.outboundShip &&
        (o.status == OrderStatus.open || o.status == OrderStatus.fulfilling));
    final openIn = board.orders.values.where((o) =>
        o.kind == OrderKind.inboundReplenish &&
        (o.status == OrderStatus.open || o.status == OrderStatus.fulfilling));
    final jobsByKind = <JobKind, int>{};
    for (final j in board.jobs.values) {
      if (!j.settled) jobsByKind[j.kind] = (jobsByKind[j.kind] ?? 0) + 1;
    }
    final life = <String, int>{};
    final carrying = <String>[];
    for (final u in ref.read(unitRegistryProvider).values) {
      life[u.lifecycle.name] = (life[u.lifecycle.name] ?? 0) + 1;
    }
    final cargo = ref.read(robotCargoProvider);
    cargo.forEach((id, c) {
      if (c != null) carrying.add(id);
    });
    final trucksIn = ref.read(unitRegistryProvider).values.whereType<InboundTruckBrain>().length;
    final trucksOut = ref.read(unitRegistryProvider).values.whereType<OutboundTruckBrain>().length;

    debugPrint('\n===== STALL REPRO =====');
    debugPrint('orders minted per 1000-tick window: $w  (total=${firstSeen.length})');
    debugPrint('OPEN at end: outbound=${openOut.length} inbound=${openIn.length}');
    debugPrint('  openOut status: ${openOut.map((o) => "${o.id}:${o.status.name}:${o.progressUnits}/${o.orderedUnits}").toList()}');
    debugPrint('  openIn  status: ${openIn.map((o) => "${o.id}:${o.status.name}").toList()}');
    debugPrint('unsettled jobs by kind: $jobsByKind');
    debugPrint('robot lifecycles: $life');
    debugPrint('robots carrying cargo: $carrying');
    debugPrint('live trucks: inbound=$trucksIn outbound=$trucksOut');
    debugPrint('outbound stage occupancy: ${ref.read(outboundStageProvider).length}');
    debugPrint('bays claimed: ${ref.read(bayOccupancyProvider)}');
    debugPrint('=======================\n');

    // Demand MUST still be flowing in the final third — else the loop wedged.
    expect(w.last, greaterThan(0),
        reason: 'automation must NOT suddenly stop: no orders minted in the '
            'final 1000 ticks means the loop wedged');
    // And inbound must NEVER flood: an unbounded wall of replenish orders/trucks
    // saturates every bay (even the outbound ones) and clogs the whole loop.
    expect(openIn.length, lessThanOrEqualTo(8),
        reason: 'inbound replenish orders must stay bounded (was 20 unfixed)');
    expect(trucksIn, lessThanOrEqualTo(6),
        reason: 'inbound trucks must stay near the cap, not pile up (was 42 unfixed)');
  });
}
