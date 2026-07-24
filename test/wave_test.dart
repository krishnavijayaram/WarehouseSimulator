// WMS WAVE PICKING — verify the outbound generator releases SERIAL, truckload-
// sized waves: one wave on the floor at a time, each ~fills a truck, routes across
// pallet/case/loose, and the wave number advances as waves complete and ship.

import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/sim_bootstrap.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/outbound_truck_brain.dart';
import 'package:warehouse_simulator/warehouse_engine/services/warehouse_template_factory.dart';

void main() {
  testWidgets('WMS waves: serial, truckload-sized, multi-UOM, advancing',
      (tester) async {
    final base = kWarehouseTemplates
        .firstWhere((t) => t.name == 'Medium Distribution Center B')
        .builder();
    final cfg = base.copyWith(cells: assignTemplateInventory(base.cells, Random(1)));
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      child: Consumer(builder: (_, r, __) {
        ref = r;
        return const SizedBox();
      }),
    ));
    ref.read(warehouseConfigProvider.notifier).state = cfg;
    bootstrapSimUnits(ref, cfg, [
      for (final s in cfg.robotSpawns)
        (id: s.name ?? '${s.robotType}-${s.row}-${s.col}', row: s.row, col: s.col),
    ]);

    final scheduler = UnitScheduler(ref);
    final uomsSeen = <UomKind>{};
    var maxConcurrentWaves = 0;
    var maxWaveUnits = 0;
    for (var t = 0; t < 4000; t++) {
      scheduler.tick(cfg, t);
      final out = ref
          .read(jobBoardProvider)
          .orders
          .values
          .where((o) => o.kind == OrderKind.outboundShip);
      // Distinct ACTIVE (non-terminal) wave ids — serial ⇒ at most one.
      final active = out
          .where((o) =>
              o.status == OrderStatus.open ||
              o.status == OrderStatus.fulfilling)
          .map((o) => o.waveId)
          .toSet();
      if (active.length > maxConcurrentWaves) maxConcurrentWaves = active.length;
      for (final o in out) {
        for (final l in o.lines) {
          uomsSeen.add(l.uom);
        }
      }
      final w = ref.read(simWaveProvider);
      final units =
          out.where((o) => o.waveId == w).fold<int>(0, (s, o) => s + o.orderedUnits);
      if (units > maxWaveUnits) maxWaveUnits = units;
    }
    final finalWave = ref.read(simWaveProvider);
    debugPrint('WAVES: reached #$finalWave  maxConcurrentActive=$maxConcurrentWaves '
        ' maxWaveUnits=$maxWaveUnits/$kOutboundTruckCapacityUnits  uoms=$uomsSeen');

    expect(finalWave, greaterThanOrEqualTo(2),
        reason: 'waves must ADVANCE (serial completion), not stall on wave 1');
    expect(maxConcurrentWaves, lessThanOrEqualTo(1),
        reason: 'SERIAL wave picking: only one wave is on the floor at a time');
    expect(uomsSeen.length, greaterThanOrEqualTo(2),
        reason: 'a wave routes across multiple UOMs (pallet / case / loose)');
    expect(maxWaveUnits, greaterThan(kOutboundTruckCapacityUnits ~/ 3),
        reason: 'a wave should carry a real truckload, not a single tiny order');
  });
}
