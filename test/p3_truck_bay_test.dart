// P3 acceptance: a truck is an autonomous agent. It CAS-claims a bay, drives to
// it, docks, posts its unload work, waits to be emptied, then frees the bay and
// departs — while the pallet flows truck → staging → rack via the P2 chain.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/bay_resource.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/inbound_truck_brain.dart';
import 'package:warehouse_simulator/application/brains/inbound_robot_brain.dart';
import 'package:warehouse_simulator/application/brains/putaway_robot_brain.dart';

///   col:  0   1          2   3         4   5      6
///   row0      RACK(pal)      STAGING       DOCK
///   row1  .   .          .   .         .   .      .   (empty — robots + trucks)
WarehouseConfig _yard() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'p3',
      rows: 3,
      cols: 7,
      robotSpawns: const [],
      cells: [
        WarehouseCell(row: 0, col: 1, type: CellType.rackPallet),
        WarehouseCell(row: 0, col: 3, type: CellType.palletStaging),
        WarehouseCell(row: 0, col: 5, type: CellType.dock),
      ],
    );

void main() {
  testWidgets('P3: truck claims a bay, is unloaded, and departs; pallet reaches rack',
      (tester) async {
    final config = _yard();
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
      ..register(InboundTruckBrain(
          id: 'TRUCK1', pos: (row: 1, col: 6), skuId: 'SKU1', manifest: 1))
      ..register(InboundRobotBrain(id: 'IR1', pos: (row: 1, col: 4)))
      ..register(PutawayRobotBrain(id: 'PR1', pos: (row: 1, col: 0)));

    final scheduler = UnitScheduler(ref);
    var ticks = 0;
    var racked = false;
    for (; ticks < 200 && !racked; ticks++) {
      scheduler.tick(config, ticks);
      racked =
          (ref.read(warehouseConfigProvider)?.cellAt(0, 1)?.quantity ?? 0) >= 1;
    }

    expect(racked, isTrue,
        reason: 'pallet should flow truck → staging → rack with no controller');
    expect(ref.read(unitRegistryProvider).containsKey('TRUCK1'), isFalse,
        reason: 'the emptied truck departs and despawns');
    expect(ref.read(bayOccupancyProvider).isEmpty, isTrue,
        reason: 'the bay is released when the truck leaves (no leak)');
  });
}
