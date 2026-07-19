// Regression for review CHG-3: a robot that drains to 0 mid-job must go OFFLINE
// (drop its Job so nothing is stuck), then recover in place and finish the work
// — battery-0 now has a real consequence AND a recovery path.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/putaway_robot_brain.dart';

// Long floor, NO charger (so the robot claims work instead of diverting to
// charge), staging far from spawn so it drains to 0 mid-haul.
WarehouseConfig _cfg() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'offline',
      rows: 3,
      cols: 12,
      robotSpawns: const [],
      cells: [
        WarehouseCell(row: 0, col: 2, type: CellType.rackPallet),
        WarehouseCell(row: 0, col: 10, type: CellType.palletStaging),
      ],
    );

void main() {
  testWidgets('CHG-3: a robot drained to 0 goes offline, then recovers & finishes',
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
    final pk = PutawayRobotBrain(id: 'PR1', pos: (row: 1, col: 0));
    pk.battery = 1.0; // will hit 0 a few cells into the haul
    ref.read(unitRegistryProvider.notifier).register(pk);
    ref.read(stagingPalletsProvider.notifier).drop(0, 10, 'SKU1');
    ref.read(jobBoardProvider.notifier).mintJobOf(
          kind: JobKind.putaway,
          requiredRole: UnitRole.putawayRobot,
          skuId: 'SKU1',
          src: (row: 0, col: 10),
          qtyUnits: kLoosePerPallet,
        );

    final scheduler = UnitScheduler(ref);
    var sawOffline = false;
    for (var t = 0; t < 400; t++) {
      scheduler.tick(config, t);
      if (pk.lifecycle == UnitLifecycle.offline) sawOffline = true;
    }

    expect(sawOffline, isTrue,
        reason: 'draining to 0 mid-job must take the robot offline');
    expect(pk.battery, greaterThan(0.0), reason: 'it recovered off zero');
    expect(pk.lifecycle, isNot(UnitLifecycle.offline),
        reason: 'it came back online');
    expect(ref.read(warehouseConfigProvider)?.cellAt(0, 2)?.quantity, 1,
        reason: 'after recovery it finished the putaway it had dropped');
  });
}
