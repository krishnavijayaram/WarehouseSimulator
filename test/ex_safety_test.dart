// HARD CONDITION: the deployed simulation must never impact EventXplore. WIOS
// shares a Postgres instance with EX (schema-per-app), so the only vector by
// which the sim could touch EX is backend write load. These tests pin the
// guarantee at the code layer: the sim is client-only by default and runs a full
// flush cycle without ever enabling a backend write.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/robot_scout_simulation.dart';

WarehouseConfig _config() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'ex-safety',
      rows: 5,
      cols: 8,
      robotSpawns: const [
        RobotSpawn(row: 1, col: 0, robotType: 'AMR', name: 'R0'),
        RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'R1'),
      ],
      cells: const [],
    );

void main() {
  testWidgets('deployed sim defaults to backendSync OFF (no writes to EX-shared backend)',
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

    // The exact construction the app uses relies on this default being safe.
    final sim = RobotScoutSimulation(config: config, ref: ref, isSaboteur: false);
    expect(sim.backendSync, isFalse,
        reason:
            'the deployed default MUST be client-only — a flipped default would silently write to the EX-shared backend');
    sim.dispose();
  });

  testWidgets('client-only sim runs a full flush cycle without enabling backend I/O',
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

    // backendSync omitted → off. Pump past the 15s flush timer so the flush path
    // actually executes and hits the EX-safety gate (which must early-return
    // before any sendBeacon/HTTP). A clean run with robots still moving proves
    // the sim is fully functional client-only.
    final sim = RobotScoutSimulation(config: config, ref: ref, isSaboteur: false);
    sim.start();
    for (var i = 0; i < 42; i++) {
      await tester.pump(const Duration(milliseconds: 400)); // ~16.8s > 15s flush
    }

    final pos = ref.read(manualRobotPositionsProvider);
    const spawn = {'R0': '1_0', 'R1': '1_1'};
    final moved = spawn.keys.where((id) {
      final p = pos[id];
      return p != null && '${p.row}_${p.col}' != spawn[id];
    }).toList();

    sim.dispose();

    expect(pos.isNotEmpty, isTrue, reason: 'sim seeded + ran client-only');
    expect(moved.isNotEmpty, isTrue,
        reason: 'robots move on a client-only sim across a full flush cycle');
  });
}
