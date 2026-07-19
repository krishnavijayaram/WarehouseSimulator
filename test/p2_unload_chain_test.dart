// P2 acceptance: the truck→staging→rack chain runs with no central controller.
// An InboundRobotBrain unloads a docked truck to staging and mints the putaway
// Job; a PutawayRobotBrain independently claims it and finishes to a rack.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/inbound_robot_brain.dart';
import 'package:warehouse_simulator/application/brains/putaway_robot_brain.dart';

///   col:  0        1   2         3   4          5
///   row0  DOCK         STAGING       RACK(pal)
///   row1  .        .   .         .   .          .   (aisle — empty/walkable)
WarehouseConfig _mini() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'p2',
      rows: 3,
      cols: 6,
      robotSpawns: const [],
      cells: [
        WarehouseCell(row: 0, col: 0, type: CellType.dock),
        WarehouseCell(row: 0, col: 2, type: CellType.palletStaging),
        WarehouseCell(row: 0, col: 4, type: CellType.rackPallet),
      ],
    );

void main() {
  testWidgets('P2: docked truck unloaded to staging, then put away to a rack',
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
    ref.read(unitRegistryProvider.notifier)
      ..register(InboundRobotBrain(id: 'IR1', pos: (row: 1, col: 0)))
      ..register(PutawayRobotBrain(id: 'PR1', pos: (row: 1, col: 5)));

    // One docked truck pallet, expressed as an unloadTruck Job at the dock cell.
    ref.read(jobBoardProvider.notifier).mintJobOf(
          kind: JobKind.unloadTruck,
          requiredRole: UnitRole.inboundRobot,
          skuId: 'SKU1',
          src: (row: 0, col: 0),
        );

    final scheduler = UnitScheduler(ref);
    var ticks = 0;
    var racked = false;
    for (; ticks < 120 && !racked; ticks++) {
      scheduler.tick(config, ticks);
      racked =
          (ref.read(warehouseConfigProvider)?.cellAt(0, 4)?.quantity ?? 0) >= 1;
    }

    expect(racked, isTrue,
        reason: 'the pallet should flow truck → staging → rack autonomously');
    expect(ref.read(stagingPalletsProvider).containsKey('0_2'), isFalse,
        reason: 'staging is a transient buffer — emptied by the putaway cart');
    final ir = ref.read(unitRegistryProvider)['IR1']!;
    final pr = ref.read(unitRegistryProvider)['PR1']!;
    expect(ir.currentJobId, isNull, reason: 'inbound robot back to idle');
    expect(pr.currentJobId, isNull, reason: 'putaway cart back to idle');
  });
}
