// P4 (step 6): a PickRobotBrain autonomously retrieves stock from a rack to an
// outbound stage cell, driven only by an outbound Order's pick Job.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/outbound_stage.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/pick_robot_brain.dart';

///   col:  0   1               2   3           4
///   row0      RACK(SKU1,2/5)      PACK(stage)
///   row1  .   .               .   .           .
WarehouseConfig _mini() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'p4-pick',
      rows: 3,
      cols: 5,
      robotSpawns: const [],
      cells: [
        WarehouseCell(
            row: 0,
            col: 1,
            type: CellType.rackPallet,
            skuId: 'SKU1',
            quantity: 2,
            maxQuantity: 5),
        WarehouseCell(row: 0, col: 3, type: CellType.packStation),
      ],
    );

void main() {
  testWidgets('P4: a pick robot retrieves a pallet from a rack to the stage',
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

    ref.read(warehouseConfigProvider.notifier).state = config;
    ref
        .read(unitRegistryProvider.notifier)
        .register(PickRobotBrain(id: 'PK1', pos: (row: 1, col: 4)));

    // An outbound Order and its single pick line, expressed as a pick Job.
    final board = ref.read(jobBoardProvider.notifier);
    final order = board.mintOrder(
      kind: OrderKind.outboundShip,
      skuId: 'SKU1',
      orderedUnits: kLoosePerPallet,
      nowTick: 0,
    );
    board.mintJobOf(
      kind: JobKind.pickToStage,
      requiredRole: UnitRole.pickRobot,
      skuId: 'SKU1',
      requiredUom: UomKind.pallet,
      orderId: order.id,
      idemKey: '${order.id}:L0:0',
      qtyUnits: kLoosePerPallet,
    );

    final scheduler = UnitScheduler(ref);
    var ticks = 0;
    var staged = false;
    for (; ticks < 80 && !staged; ticks++) {
      scheduler.tick(config, ticks);
      staged = ref.read(outboundStageProvider).containsValue('SKU1');
    }

    expect(staged, isTrue,
        reason: 'the pick robot should stage the pallet for shipping');
    expect(ref.read(outboundStageProvider)['0_3'], 'SKU1',
        reason: 'staged at the pack/stage cell');
    expect(ref.read(warehouseConfigProvider)?.cellAt(0, 1)?.quantity, 1,
        reason: 'the rack is decremented by exactly one pallet (idem-guarded)');
    final pk = ref.read(unitRegistryProvider)['PK1']!;
    expect(pk.currentJobId, isNull, reason: 'picker returns to idle');
  });
}
