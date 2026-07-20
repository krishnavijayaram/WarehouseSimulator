// Reproduce the PROD symptom: fog reveals but robots never physically move.
// Mirrors the user's screenshot — named robots (IR-01 etc.) tucked into narrow
// columns among dense racks, restored fog, driven by the REAL sim timer exactly
// as the DASH view does. If robots move here, the sim logic is fine and prod is
// serving a stale cached build; if they DON'T, we have found the bug.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/robot_scout_simulation.dart';

WarehouseConfig _dense() {
  final cells = <WarehouseCell>[];
  // Rack columns at cols 4,5 and 9,10 (like the green/orange stacks), aisles
  // between. Rows 0..9.
  for (var r = 0; r < 10; r++) {
    for (final c in [4, 5, 9, 10]) {
      cells.add(WarehouseCell(
          row: r,
          col: c,
          type: CellType.rackLoose,
          skuId: 'SKU1',
          quantity: 40,
          maxQuantity: 96));
    }
  }
  cells.addAll([
    WarehouseCell(row: 0, col: 1, type: CellType.dock),
    WarehouseCell(row: 0, col: 3, type: CellType.palletStaging),
    WarehouseCell(row: 0, col: 7, type: CellType.packStation),
    WarehouseCell(row: 0, col: 12, type: CellType.outbound),
    WarehouseCell(row: 9, col: 0, type: CellType.roadH),
  ]);
  return WarehouseConfig(
    id: 'prod',
    name: 'prod',
    ownerId: 'prod',
    description: 'dense',
    rows: 10,
    cols: 13,
    // Named by role, like the screenshot, tucked in column 0 and among racks.
    robotSpawns: const [
      RobotSpawn(row: 0, col: 0, robotType: 'AMR', name: 'IR-01'),
      RobotSpawn(row: 1, col: 0, robotType: 'AMR', name: 'OR-01'),
      RobotSpawn(row: 2, col: 0, robotType: 'AMR', name: 'PR-01'),
      RobotSpawn(row: 3, col: 0, robotType: 'AMR', name: 'CR-01'),
      RobotSpawn(row: 4, col: 0, robotType: 'AMR', name: 'LR-01'),
    ],
    cells: cells,
  );
}

void main() {
  testWidgets('PROD repro: robots physically move on a dense named-robot floor',
      (tester) async {
    final config = _dense();
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

    // Simulate a RESTORED session: pre-reveal ~all cells (this is the "fog is
    // perfect" the user sees — it is stale, not from live movement).
    final explored = ref.read(exploredCellsProvider.notifier);
    for (var r = 0; r < config.rows; r++) {
      for (var c = 0; c < config.cols; c++) {
        explored.markExplored(r, c);
      }
    }
    final spawn = {
      'IR-01': '0_0', 'OR-01': '1_0', 'PR-01': '2_0',
      'CR-01': '3_0', 'LR-01': '4_0',
    };

    // Drive the REAL sim exactly as the DASH view does (automated => start()).
    final sim = RobotScoutSimulation(config: config, ref: ref, isSaboteur: false);
    sim.start();
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    final pos = ref.read(manualRobotPositionsProvider);
    final moved = spawn.keys.where((id) {
      final p = pos[id];
      return p != null && '${p.row}_${p.col}' != spawn[id];
    }).toList();

    debugPrint('PROD REPRO: tick=${sim.tickNo} registered=${sim.brainsRegistered} '
        'tracked=${pos.length} moved=${moved.length} -> $moved');
    sim.dispose();

    expect(sim.tickNo, greaterThan(0), reason: 'the tick loop must run');
    expect(pos, isNotEmpty, reason: 'brains must be registered + seeded');
    expect(moved, isNotEmpty,
        reason: 'at least one robot must PHYSICALLY MOVE on a dense floor');
  });
}
