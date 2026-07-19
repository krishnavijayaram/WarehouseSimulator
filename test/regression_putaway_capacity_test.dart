// Regression for review AC-1: a whole pallet (48 loose) must NOT be dropped into
// a loose rack too small to hold it (silently clamping 48→2 and destroying 46).
// With the capacity-aware 5.1–5.4, a pallet that can't fit a loose face falls
// through to a pallet rack — no inventory is annihilated.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/putaway_robot_brain.dart';

///   col:  0   1          2               3               4
///   row0      STAGING    LOOSE(SKU1,0/2) PALLET(SKU1,0/2)
///   row1  .   .          .               .               .
WarehouseConfig _cfg() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'ac1',
      rows: 3,
      cols: 5,
      robotSpawns: const [],
      cells: [
        WarehouseCell(row: 0, col: 1, type: CellType.palletStaging),
        // Loose face for SKU1, below threshold but far too small for a pallet.
        WarehouseCell(
            row: 0, col: 2, type: CellType.rackLoose, skuId: 'SKU1', quantity: 0, maxQuantity: 2),
        WarehouseCell(
            row: 0, col: 3, type: CellType.rackPallet, skuId: 'SKU1', quantity: 0, maxQuantity: 2),
      ],
    );

void main() {
  testWidgets('AC-1: a pallet is never dropped into a too-small loose rack',
      (tester) async {
    final config = _cfg();
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(builder: (_, r, __) {
          ref = r;
          return const SizedBox();
        }),
      ),
    );

    ref.read(warehouseConfigProvider.notifier).state = config;
    ref.read(stagingPalletsProvider.notifier).drop(0, 1, 'SKU1');
    ref
        .read(unitRegistryProvider.notifier)
        .register(PutawayRobotBrain(id: 'PR1', pos: (row: 1, col: 4)));
    ref.read(jobBoardProvider.notifier).mintJobOf(
          kind: JobKind.putaway,
          requiredRole: UnitRole.putawayRobot,
          skuId: 'SKU1',
          src: (row: 0, col: 1),
          qtyUnits: kLoosePerPallet,
        );

    final scheduler = UnitScheduler(ref);
    var done = false;
    for (var t = 0; t < 80 && !done; t++) {
      scheduler.tick(config, t);
      done = (ref.read(warehouseConfigProvider)?.cellAt(0, 3)?.quantity ?? 0) >= 1;
    }

    expect(done, isTrue, reason: 'the pallet is put away into the PALLET rack');
    expect(ref.read(warehouseConfigProvider)?.cellAt(0, 2)?.quantity, 0,
        reason: 'the too-small loose rack is left untouched — no 48→2 destruction');
    expect(ref.read(warehouseConfigProvider)?.cellAt(0, 3)?.quantity, 1,
        reason: 'exactly one pallet landed in the pallet rack');
    expect(ref.read(stagingPalletsProvider).containsKey('0_1'), isFalse,
        reason: 'the staged pallet was consumed, not left behind');
  });
}
