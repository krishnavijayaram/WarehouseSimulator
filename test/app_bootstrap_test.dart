// The test that would have caught the "app only explores, no robot moves" bug:
// it drives the SAME bootstrap the running app uses (bootstrapSimUnits) on a
// realistic warehouse and asserts robots physically move and work is generated —
// NOT by hand-registering brains + jobs the way the phase tests do.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/sim_bootstrap.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';

/// A small but complete warehouse: aisles (empty), a stocked rack (outbound), a
/// low rack (inbound trigger), staging, pack station, inbound + outbound bays,
/// and a road cell to spawn trucks. Undefined cells default to empty/walkable.
WarehouseConfig _warehouse() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'bootstrap',
      rows: 5,
      cols: 10,
      robotSpawns: const [],
      cells: [
        WarehouseCell(
            row: 0, col: 1, type: CellType.dock), // inbound bay
        WarehouseCell(row: 0, col: 3, type: CellType.palletStaging),
        WarehouseCell(
            row: 0,
            col: 5,
            type: CellType.rackPallet,
            skuId: 'SKU1',
            quantity: 2,
            maxQuantity: 5), // stocked → outbound
        WarehouseCell(row: 0, col: 7, type: CellType.packStation),
        WarehouseCell(row: 0, col: 9, type: CellType.outbound), // outbound bay
        WarehouseCell(
            row: 2,
            col: 5,
            type: CellType.rackPallet,
            skuId: 'SKU2',
            quantity: 0,
            maxQuantity: 5), // low → inbound trigger
        WarehouseCell(row: 4, col: 0, type: CellType.roadH), // truck spawn
      ],
    );

void main() {
  testWidgets('app bootstrap: robots actually MOVE and work is generated',
      (tester) async {
    final config = _warehouse();
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

    // Same call the app makes on start — 4 robots, auto-assigned roles.
    final robots = <SpawnedRobot>[
      (id: 'R0', row: 1, col: 0),
      (id: 'R1', row: 1, col: 1),
      (id: 'R2', row: 1, col: 2),
      (id: 'R3', row: 1, col: 3),
    ];
    bootstrapSimUnits(ref, config, robots);

    final start = {for (final r in robots) r.id: '${r.row}_${r.col}'};
    final scheduler = UnitScheduler(ref);
    for (var t = 0; t < 150; t++) {
      scheduler.tick(config, t);
    }

    final pos = ref.read(manualRobotPositionsProvider);
    final movedCount = robots.where((r) {
      final p = pos[r.id];
      return p != null && '${p.row}_${p.col}' != start[r.id];
    }).length;

    expect(movedCount, greaterThan(0),
        reason: 'at least one robot physically moved — not just fog exploration');
    expect(ref.read(jobBoardProvider).orders, isNotEmpty,
        reason: 'the system-player brains generated work (orders)');
  });
}
