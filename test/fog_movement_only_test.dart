// Locks in the invariant the user demanded: the fog of war unwraps ONLY where a
// robot has PHYSICALLY moved — never in bulk, never around a stationary spawn,
// never restored. A robot's camera/scanner is the only thing that can reveal a
// cell (ActionApplier.moveTo -> revealFog, a 3x3 around the cell it steps onto).
//
// Regression guard for the "warehouse unwraps itself with no robot moving" bug:
//   Q1 root cause was _seedInitialReveal (3x3 around every spawn on init) and the
//   main.dart restore paths bulk-replaying the whole explored set. Both removed.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/robot_scout_simulation.dart';

WarehouseConfig _dense() {
  final cells = <WarehouseCell>[];
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
    id: 'fog',
    name: 'fog',
    ownerId: 'fog',
    description: 'dense',
    rows: 10,
    cols: 13,
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
  testWidgets('fog unwraps ONLY where a robot physically moved', (tester) async {
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

    // INVARIANT 1: before any robot moves, the fog is fully black. No spawn-seed,
    // no bulk restore. Nothing has been scanned because nothing has moved.
    expect(ref.read(exploredCellsProvider), isEmpty,
        reason: 'fog must start black — no reveal without movement');

    final sim = RobotScoutSimulation(config: config, ref: ref, isSaboteur: false);
    sim.start();

    // Track every cell any robot has physically occupied across the whole run.
    final visited = <String>{};
    void snapshotPositions() {
      final pos = ref.read(manualRobotPositionsProvider);
      for (final p in pos.values) {
        visited.add('${p.row},${p.col}');
      }
    }

    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 400));
      snapshotPositions();
    }
    snapshotPositions();

    final explored = ref.read(exploredCellsProvider);
    sim.dispose();

    // INVARIANT 2: robots moved AND revealed fog live (not black, not full grid).
    expect(explored, isNotEmpty,
        reason: 'moving robots must reveal fog live');
    expect(explored.length, lessThan(config.rows * config.cols),
        reason: 'fog must not be fully revealed — only what robots reached');

    // INVARIANT 3 (the crux): every revealed cell lies within the 3x3 scan
    // footprint of SOME cell a robot physically occupied. No cell can be
    // explored unless a robot moved next to it — proving reveal is bound to
    // movement, never bulk/restored/seeded.
    bool nearVisited(int r, int c) {
      for (var dr = -1; dr <= 1; dr++) {
        for (var dc = -1; dc <= 1; dc++) {
          if (visited.contains('${r + dr},${c + dc}')) return true;
        }
      }
      return false;
    }

    final orphans = <String>[];
    for (final key in explored) {
      final parts = key.split(',');
      final r = int.parse(parts[0]);
      final c = int.parse(parts[1]);
      if (!nearVisited(r, c)) orphans.add(key);
    }

    debugPrint('FOG: explored=${explored.length} visited=${visited.length} '
        'orphans=${orphans.length} -> $orphans');
    expect(orphans, isEmpty,
        reason: 'every revealed cell must be within a robot scan footprint — '
            'an orphan means fog unwrapped with no robot there');
  });
}
