// P4 capstone (steps 6→9): the outbound loop is self-triggering. Given stock,
// the generator emits an Order + pick Job + truck; pick→stage→pack/load ships
// the pallet; the truck departs and the Order closes — no controller.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/bay_resource.dart';
import 'package:warehouse_simulator/application/outbound_stage.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/outbound_order_generator_brain.dart';
import 'package:warehouse_simulator/application/brains/pick_robot_brain.dart';
import 'package:warehouse_simulator/application/brains/outbound_robot_brain.dart';
import 'package:warehouse_simulator/application/brains/outbound_truck_brain.dart';

///   col:  0   1              2   3           4   5        6
///   row0      RACK(SKU1,1/5)     PACK(stage)     OUT(bay)
///   row1  .   .              .   .           .   .        .
WarehouseConfig _yard() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'p4-outbound',
      rows: 3,
      cols: 7,
      robotSpawns: const [],
      cells: [
        WarehouseCell(
            row: 0,
            col: 1,
            type: CellType.rackPallet,
            skuId: 'SKU1',
            quantity: 1,
            maxQuantity: 5),
        WarehouseCell(row: 0, col: 3, type: CellType.packStation),
        WarehouseCell(row: 0, col: 5, type: CellType.outbound),
      ],
    );

void main() {
  testWidgets('P4 loop: stock self-triggers order → pick → pack/load → ship',
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
      ..register(
          OutboundOrderGeneratorBrain(id: 'GEN', truckSpawn: (row: 1, col: 6)))
      ..register(PickRobotBrain(id: 'PK1', pos: (row: 1, col: 0)))
      ..register(OutboundRobotBrain(id: 'OR1', pos: (row: 1, col: 4)));

    final scheduler = UnitScheduler(ref);
    for (var t = 0; t < 220; t++) {
      scheduler.tick(config, t);
    }

    // Stock shipped out.
    expect(ref.read(warehouseConfigProvider)?.cellAt(0, 1)?.quantity, 0,
        reason: 'the pallet was picked from the rack');
    expect(ref.read(outboundStageProvider).isEmpty, isTrue,
        reason: 'nothing left stranded on the stage — it was loaded');
    expect(
        ref.read(unitRegistryProvider).values.whereType<OutboundTruckBrain>(),
        isEmpty,
        reason: 'the loaded truck departed and despawned');
    expect(ref.read(bayOccupancyProvider).isEmpty, isTrue,
        reason: 'the outbound bay was released');
    final openOutbound = ref.read(jobBoardProvider).orders.values.where((o) =>
        o.kind == OrderKind.outboundShip &&
        (o.status == OrderStatus.open || o.status == OrderStatus.fulfilling));
    expect(openOutbound, isEmpty, reason: 'the ship Order closed on departure');
  });
}
