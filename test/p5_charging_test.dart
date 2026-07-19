// P5: a low-battery robot, when idle, autonomously drives to a charger dock and
// tops up to the resume threshold — then releases the dock. Hysteresis (seek at
// 20, resume at 60) means it won't immediately re-seek (no charge/work thrash).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/bay_resource.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/putaway_robot_brain.dart';

///   col:  0   1            2   3   4   5
///   row0      CHARGER
///   row1  .   .            .   .   .   .
WarehouseConfig _mini() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'p5',
      rows: 3,
      cols: 6,
      robotSpawns: const [],
      cells: [
        WarehouseCell(row: 0, col: 1, type: CellType.chargingFast),
      ],
    );

void main() {
  testWidgets('P5: an idle low-battery robot recharges and releases the dock',
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
    final pk = PutawayRobotBrain(id: 'PK1', pos: (row: 1, col: 4));
    pk.battery = 15.0; // below the seek threshold
    ref.read(unitRegistryProvider.notifier).register(pk);

    final scheduler = UnitScheduler(ref);
    for (var t = 0; t < 150; t++) {
      scheduler.tick(config, t);
    }

    expect(pk.battery, greaterThanOrEqualTo(UnitBrain.kResumeBattery),
        reason: 'the robot should have charged up to the resume threshold');
    expect(pk.isCharging, isFalse,
        reason: 'it stops charging (and does not re-seek) once topped up');
    expect(ref.read(chargerOccupancyProvider).isEmpty, isTrue,
        reason: 'the charger dock is released when done (no leak)');
  });
}
