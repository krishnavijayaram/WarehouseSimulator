// P3 capstone: the inbound loop is self-triggering. Nothing is seeded but a
// low rack — the StockMonitorBrain notices, orders stock, and spawns a truck;
// the truck+IR+PR chain replenishes the rack; the monitor then closes the order.
// Steps 1→5 run with no controller and no manual Job.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/stock_monitor_brain.dart';
import 'package:warehouse_simulator/application/brains/inbound_truck_brain.dart';
import 'package:warehouse_simulator/application/brains/inbound_robot_brain.dart';
import 'package:warehouse_simulator/application/brains/putaway_robot_brain.dart';

///   col:  0   1              2   3          4   5      6
///   row0      RACK(SKU1,0/2)     STAGING        DOCK
///   row1  .   .              .   .          .   .      .   (empty)
WarehouseConfig _yard() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'p3-loop',
      rows: 3,
      cols: 7,
      robotSpawns: const [],
      cells: [
        WarehouseCell(
            row: 0,
            col: 1,
            type: CellType.rackPallet,
            skuId: 'SKU1',
            quantity: 0,
            maxQuantity: 2), // below reorder (needs ≥1)
        WarehouseCell(row: 0, col: 3, type: CellType.palletStaging),
        WarehouseCell(row: 0, col: 5, type: CellType.dock),
      ],
    );

void main() {
  testWidgets('P3 loop: low stock self-triggers order → truck → replenish → close',
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
      ..register(StockMonitorBrain(id: 'MON', truckSpawn: (row: 1, col: 6)))
      ..register(InboundRobotBrain(id: 'IR1', pos: (row: 1, col: 4)))
      ..register(PutawayRobotBrain(id: 'PR1', pos: (row: 1, col: 0)));

    final scheduler = UnitScheduler(ref);
    var ticks = 0;
    var racked = false;
    for (; ticks < 250 && !racked; ticks++) {
      scheduler.tick(config, ticks);
      racked =
          (ref.read(warehouseConfigProvider)?.cellAt(0, 1)?.quantity ?? 0) >= 1;
    }
    // Let the system settle (truck departs, monitor closes + sweeps the order).
    for (var k = 0; k < 25; k++) {
      scheduler.tick(config, ticks++);
    }

    expect(racked, isTrue, reason: 'the low rack should get replenished on its own');

    final trucksLeft =
        ref.read(unitRegistryProvider).values.whereType<InboundTruckBrain>();
    expect(trucksLeft, isEmpty, reason: 'the truck departs once emptied');

    final openReplenish = ref.read(jobBoardProvider).orders.values.where((o) =>
        o.kind == OrderKind.inboundReplenish &&
        (o.status == OrderStatus.open || o.status == OrderStatus.fulfilling));
    expect(openReplenish, isEmpty,
        reason: 'the replenish Order closes once stock is back above reorder');
  });
}
