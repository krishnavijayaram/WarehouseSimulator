// Regression for review F2-fsm / SBI-2 / F3: with TWO pickers and only ONE
// pallet of stock, the source-face reservation must stop both from drawing the
// same face — exactly one pallet is staged, none phantom, rack never goes below 0.

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

///   col:  0   1            2   3     4     5
///   row0      RACK(SKU1,1)     PACK  PACK
///   row1  .   .            .   .     .     .
WarehouseConfig _cfg() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'multipicker',
      rows: 3,
      cols: 6,
      robotSpawns: const [],
      cells: [
        WarehouseCell(
            row: 0, col: 1, type: CellType.rackPallet, skuId: 'SKU1', quantity: 1, maxQuantity: 5),
        WarehouseCell(row: 0, col: 3, type: CellType.packStation),
        WarehouseCell(row: 0, col: 4, type: CellType.packStation),
      ],
    );

void main() {
  testWidgets('reservation: two pickers, one pallet → exactly one ships (no phantom)',
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
    ref.read(unitRegistryProvider.notifier)
      ..register(PickRobotBrain(id: 'PK1', pos: (row: 1, col: 0)))
      ..register(PickRobotBrain(id: 'PK2', pos: (row: 1, col: 5)));

    // Two pick Jobs for the same SKU, but stock for only one.
    final board = ref.read(jobBoardProvider.notifier);
    for (var i = 0; i < 2; i++) {
      board.mintJobOf(
        kind: JobKind.pickToStage,
        requiredRole: UnitRole.pickRobot,
        skuId: 'SKU1',
        requiredUom: UomKind.pallet,
        idemKey: 'J$i:L0:0',
        qtyUnits: kLoosePerPallet,
      );
    }

    final scheduler = UnitScheduler(ref);
    for (var t = 0; t < 80; t++) {
      scheduler.tick(config, t);
    }

    final staged =
        ref.read(outboundStageProvider).values.where((v) => v == 'SKU1').length;
    expect(staged, 1, reason: 'exactly one real pallet staged — no phantom second');
    expect(ref.read(warehouseConfigProvider)?.cellAt(0, 1)?.quantity, 0,
        reason: 'the single pallet was pulled once; rack never over-drawn');
  });
}
