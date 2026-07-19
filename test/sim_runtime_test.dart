// The test I should have written first: drive the ACTUAL RobotScoutSimulation
// class — its real Timer.periodic step loop via tester.pump — exactly as the app
// does on Start Operations (automated mode). Every prior test bypassed this class
// and called UnitScheduler directly, so a bug in start()/_tick/bootstrap wiring
// would pass every test yet leave the running app motionless. This closes that.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/robot_scout_simulation.dart';

/// Small rackLoose warehouse with robot spawns — stocked rack + pack + outbound
/// so the outbound loop mints work immediately and a picker should start moving
/// within a few hundred ms. Grid < 75 cells so the discovery cache never early-
/// flushes to the backend within the test window.
WarehouseConfig _config() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'runtime',
      rows: 5,
      cols: 8,
      robotSpawns: const [
        RobotSpawn(row: 1, col: 0, robotType: 'AMR', name: 'R0'),
        RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'R1'),
        RobotSpawn(row: 1, col: 2, robotType: 'AMR', name: 'R2'),
        RobotSpawn(row: 1, col: 3, robotType: 'AMR', name: 'R3'),
      ],
      cells: [
        WarehouseCell(
            row: 0,
            col: 3,
            type: CellType.rackLoose,
            skuId: 'SKU1',
            quantity: 8,
            maxQuantity: 10),
        WarehouseCell(row: 0, col: 5, type: CellType.packStation),
        WarehouseCell(row: 0, col: 7, type: CellType.outbound),
        WarehouseCell(row: 4, col: 0, type: CellType.roadH),
      ],
    );

void main() {
  testWidgets('RobotScoutSimulation.start() actually moves robots on its timer',
      (tester) async {
    final config = _config();
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

    // Exactly what _launchSimulation does in AUTOMATED mode.
    final sim = RobotScoutSimulation(config: config, ref: ref, isSaboteur: false);
    sim.start();

    // Fire the real 400ms step timer ~30 times (12s sim time, under the 15s
    // flush timer) — no manual UnitScheduler calls anywhere.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    final pos = ref.read(manualRobotPositionsProvider);
    final moved = ['R0', 'R1', 'R2', 'R3'].where((id) {
      final p = pos[id];
      // spawns were row 1, cols 0..3
      return p != null && !(p.row == 1);
    }).toList();

    sim.dispose();

    expect(pos.isNotEmpty, isTrue,
        reason: 'the sim must seed robot positions on start');
    expect(moved.isNotEmpty, isTrue,
        reason:
            'at least one robot must physically leave its spawn row on the real timer loop');
  });

  testWidgets('robots still MOVE (idle patrol) when the warehouse has NO work',
      (tester) async {
    // The user's symptom: a warehouse with racks that carry no SKU/stock mints no
    // orders, so ops robots have nothing to claim. They must NOT freeze — they
    // patrol/reveal like scouts until work appears. Bare aisle grid, no SKUs.
    final config = WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'no-work',
      rows: 5,
      cols: 8,
      robotSpawns: const [
        RobotSpawn(row: 0, col: 0, robotType: 'AMR', name: 'IR-01'),
        RobotSpawn(row: 0, col: 7, robotType: 'AMR', name: 'OR-01'),
        RobotSpawn(row: 4, col: 0, robotType: 'AMR', name: 'LR-01'),
        RobotSpawn(row: 4, col: 7, robotType: 'AMR', name: 'CR-01'),
      ],
      cells: const [], // pure empty/walkable floor — zero work possible
    );
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

    final sim = RobotScoutSimulation(config: config, ref: ref, isSaboteur: false);
    sim.start();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    final pos = ref.read(manualRobotPositionsProvider);
    final spawns = {
      'IR-01': '0_0',
      'OR-01': '0_7',
      'LR-01': '4_0',
      'CR-01': '4_7'
    };
    final moved = spawns.keys.where((id) {
      final p = pos[id];
      return p != null && '${p.row}_${p.col}' != spawns[id];
    }).toList();

    sim.dispose();

    expect(moved.isNotEmpty, isTrue,
        reason:
            'with no work at all, idle robots must still patrol — never freeze');
  });
}
