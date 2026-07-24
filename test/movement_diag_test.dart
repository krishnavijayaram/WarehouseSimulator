// REGRESSION GATE for the two reported movement faults:
//   (1) trucks driving OFF the road into the working storage interior, and
//   (2) work robots getting stuck in a stationary LINE and never rerouting.
// Runs the seeded sim and asserts: no truck ever sits on an interior (aisle /
// staging / rack / pack) cell, no large frozen line persists, and the loop still
// ships end-to-end. Guards the truck road-confinement + shared blocked-recovery.

import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/sim_bootstrap.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/warehouse_engine/services/warehouse_template_factory.dart';

bool _isTruck(UnitRole r) =>
    r == UnitRole.inboundTruck || r == UnitRole.outboundTruck;

// A cell a truck is ALLOWED to sit on: road network, the dock/bay lanes, and
// open yard floor. Anything else (aisle, cross-aisle, staging, pack, rack) is
// the working interior a truck must never enter.
bool _truckAllowed(CellType t) =>
    t.isRoad ||
    t == CellType.dock ||
    t == CellType.inbound ||
    t == CellType.outbound ||
    t == CellType.empty;

void main() {
  for (final seed in const [1, 5, 9]) {
    testWidgets('MOVEMENT seed=$seed: trucks stay on the road, robots do not '
        'jam in a frozen line, and the loop ships', (tester) async {
      await _run(tester, seed);
    });
  }
}

Future<void> _run(WidgetTester tester, int seed) async {
  final base = kWarehouseTemplates
      .firstWhere((t) => t.name == 'Medium Distribution Center B')
      .builder();
  final cfg =
      base.copyWith(cells: assignTemplateInventory(base.cells, Random(seed)));
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
  final live = ref.read(warehouseConfigProvider) ?? cfg;

  final stillFor = <String, int>{}; // ticks a unit has not moved
  final lastPos = <String, GridPos>{};
  var truckOffRoad = 0;
  var maxStuckRobots = 0;

  for (var t = 0; t < 2500; t++) {
    scheduler.tick(live, t);
    var stuckNow = 0;
    for (final u in ref.read(unitRegistryProvider.notifier).all()) {
      final p = u.pos;
      final prev = lastPos[u.id];
      stillFor[u.id] =
          (prev != null && prev.row == p.row && prev.col == p.col)
              ? (stillFor[u.id] ?? 0) + 1
              : 0;
      lastPos[u.id] = p;

      if (_isTruck(u.role)) {
        final ct = live.cellAt(p.row, p.col)?.type ?? CellType.empty;
        if (!_truckAllowed(ct)) truckOffRoad++;
      } else if (u.isChargeable &&
          u.currentJobId != null &&
          (stillFor[u.id] ?? 0) >= 40) {
        stuckNow++;
      }
    }
    if (stuckNow > maxStuckRobots) maxStuckRobots = stuckNow;
  }

  final jb = ref.read(jobBoardProvider);
  debugPrint('MOVEMENT seed=$seed | truckOffRoad=$truckOffRoad '
      'maxStuck=$maxStuckRobots shipped=${jb.shippedCount} '
      'aborted=${jb.abortedCount} wave=${ref.read(simWaveProvider)}');

  // (1) A truck must NEVER be found on a working-interior cell.
  expect(truckOffRoad, 0,
      reason: 'a truck entered the storage interior (aisle/staging/rack/pack) — '
          'it must stay on the road, its bay column, or open yard floor');
  // (2) No large frozen line of robots may persist (transient waits are fine).
  expect(maxStuckRobots, lessThanOrEqualTo(6),
      reason: 'too many robots frozen ≥40 ticks at once — the head-of-line '
          'recovery is not clearing the jam');
  // (3) The material loop must actually complete work end-to-end.
  expect(jb.shippedCount, greaterThan(0),
      reason: 'no outbound order shipped — the loop is not closing');
}
