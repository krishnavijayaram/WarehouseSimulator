// Regression for P6 hard collision arbiter: no two units ever occupy the same
// cell in the same tick, while both still complete their work (contending over
// one rack + adjacent stage cells).

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

WarehouseConfig _cfg() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'collision',
      rows: 3,
      cols: 7,
      robotSpawns: const [],
      cells: [
        WarehouseCell(
            row: 0, col: 2, type: CellType.rackPallet, skuId: 'SKU1', quantity: 2, maxQuantity: 5),
        WarehouseCell(row: 0, col: 4, type: CellType.packStation),
        WarehouseCell(row: 0, col: 5, type: CellType.packStation),
      ],
    );

void main() {
  testWidgets('P6: two contending robots never share a cell, both finish',
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
      ..register(PickRobotBrain(id: 'PK2', pos: (row: 1, col: 6)));
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
    var collided = false;
    for (var t = 0; t < 140; t++) {
      scheduler.tick(config, t);
      final cells = ref
          .read(manualRobotPositionsProvider)
          .values
          .map((p) => '${p.row}_${p.col}')
          .toList();
      if (cells.toSet().length != cells.length) collided = true; // duplicate cell
    }

    expect(collided, isFalse, reason: 'no two units ever occupied the same cell');
    expect(ref.read(outboundStageProvider).values.where((v) => v == 'SKU1').length, 2,
        reason: 'both pallets were still picked & staged despite contention');
  });
}
