// P1 acceptance: one autonomous cart claims a putaway Job, drives to a staged
// pallet, picks it, runs 5.1–5.4, drives to a rack, and drops it — with no
// central controller. This is the "no cart moves" bug, dead.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/putaway_robot_brain.dart';

/// A 3×5 mini-warehouse. Undefined cells default to empty (walkable). Only the
/// staging source and the pallet-rack destination are non-walkable.
///
///   col:   0    1        2   3          4
///   row 0       STAGING      RACK(pal)
///   row 1  .    .        .   .          .   (aisle — all empty/walkable)
WarehouseConfig _mini() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'p1',
      rows: 3,
      cols: 5,
      robotSpawns: const [],
      cells: [
        WarehouseCell(row: 0, col: 1, type: CellType.palletStaging),
        WarehouseCell(row: 0, col: 3, type: CellType.rackPallet), // empty, unassigned
      ],
    );

void main() {
  testWidgets('P1: one cart autonomously puts a staged pallet into a rack',
      (tester) async {
    final config = _mini();
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(builder: (_, r, __) {
          ref = r;
          return const SizedBox();
        }),
      ),
    );

    // Seed the world: config, one staged pallet, one idle cart, one putaway Job.
    ref.read(warehouseConfigProvider.notifier).state = config;
    ref.read(stagingPalletsProvider.notifier).drop(0, 1, 'SKU1');
    ref
        .read(unitRegistryProvider.notifier)
        .register(PutawayRobotBrain(id: 'PR1', pos: (row: 1, col: 0)));
    ref.read(jobBoardProvider.notifier).mintJobOf(
          kind: JobKind.putaway,
          requiredRole: UnitRole.putawayRobot,
          skuId: 'SKU1',
          src: (row: 0, col: 1),
          qtyUnits: kLoosePerPallet,
        );

    // Run the tick clock until the rack fills (or time out).
    final scheduler = UnitScheduler(ref);
    var ticks = 0;
    var deposited = false;
    for (; ticks < 80 && !deposited; ticks++) {
      scheduler.tick(config, ticks);
      deposited =
          (ref.read(warehouseConfigProvider)?.cellAt(0, 3)?.quantity ?? 0) >= 1;
    }

    expect(deposited, isTrue,
        reason: 'the cart should deposit the pallet in the rack on its own');
    expect(ref.read(stagingPalletsProvider).containsKey('0_1'), isFalse,
        reason: 'the staging slot should be emptied by the pick');
    final cart = ref.read(unitRegistryProvider)['PR1']!;
    expect(cart.currentJobId, isNull,
        reason: 'the cart returns to idle after completing the Job');
    expect(cart.pos, isNot((row: 1, col: 0)),
        reason: 'the cart actually moved from its spawn');
  });
}
