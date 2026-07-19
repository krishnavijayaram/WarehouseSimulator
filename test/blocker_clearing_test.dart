// The anomaly loop the JEPA work demonstrates: a blocker is placed on the floor
// BY HAND, and the system must (1) notice it, (2) treat it as a real obstruction,
// (3) haul it away, and (4) dispose of it in the dump yard — with no human step.
//
// perceive: BlockerMonitorBrain sees the blocked cell and raises a clear Job.
// act:      RecoveryRobotBrain drives to it, lifts it, carries it to the dump.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/bay_resource.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/blocker_monitor_brain.dart';
import 'package:warehouse_simulator/application/brains/recovery_robot_brain.dart';

///  col:  0    1    2    3    4
/// row0                       DUMP
/// row1   .    .    .    .    .     (open aisle — the blocker lands here)
/// row2   .    .    .    .    .
WarehouseConfig _floor() => WarehouseConfig(
      id: 'blk',
      name: 'blk',
      ownerId: 'blk',
      description: 'blocker',
      rows: 3,
      cols: 5,
      robotSpawns: const [],
      cells: [WarehouseCell(row: 0, col: 4, type: CellType.dump)],
    );

void main() {
  testWidgets('a hand-placed blocker is detected, cleared and dumped',
      (tester) async {
    final config = _floor();
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
      ..register(BlockerMonitorBrain(id: 'MON'))
      ..register(RecoveryRobotBrain(id: 'RC1', pos: (row: 2, col: 0)));

    // A human drops a blocker in the middle of the aisle.
    ref.read(blockedCellsProvider.notifier).addLocal(1, 2);
    expect(ref.read(blockedCellsProvider), contains('1,2'));

    final scheduler = UnitScheduler(ref);

    // It must be treated as a REAL obstruction: while it stands, its cell is held
    // in the per-tick reservation map, so no robot can step into it.
    scheduler.tick(config, 0);
    expect(ref.read(cellReservationProvider)['1_2'], kBlockerHolderId,
        reason: 'a blocker must actually block — not just draw an overlay');

    // Detected: a clear Job is raised for that cell without anyone asking.
    final raised = ref
        .read(jobBoardProvider)
        .jobs
        .values
        .where((j) => j.kind == JobKind.clearBlocker);
    expect(raised, isNotEmpty,
        reason: 'the monitor must notice the obstruction on its own');

    // Act: run until the haul is COMPLETE. Note the cell unblocks at the LIFT,
    // partway through — the job only settles once it is dropped at the dump, so
    // wait on the job, not on the cell.
    var cleared = false;
    var done = false;
    for (var t = 1; t < 300 && !done; t++) {
      scheduler.tick(config, t);
      cleared |= !ref.read(blockedCellsProvider).contains('1,2');
      done = ref
          .read(jobBoardProvider)
          .jobs
          .values
          .where((j) => j.kind == JobKind.clearBlocker && !j.settled)
          .isEmpty;
    }

    expect(cleared, isTrue,
        reason: 'the recovery unit must remove the blocker from the path');
    expect(ref.read(blockedCellsProvider).contains('1,2'), isFalse,
        reason: 'the path stays clear after the haul completes');

    // And it ended up AT the dump yard, not merely deleted mid-floor.
    final rc = ref.read(unitRegistryProvider)['RC1']!;
    final atDump = (rc.pos.row - 0).abs() + (rc.pos.col - 4).abs() <= 1;
    expect(atDump, isTrue,
        reason: 'the blocker must be hauled to the dump yard, not vanish in place');

    // The clear Job is settled, so the monitor won't re-raise it forever.
    final live = ref.read(jobBoardProvider).jobs.values.where(
        (j) => j.kind == JobKind.clearBlocker && !j.settled);
    expect(live, isEmpty, reason: 'the clear Job completes once the blocker is gone');
  });

  testWidgets('recovery starting on the FAR side still clears a real UI blocker',
      (tester) async {
    // The review's reproduction. Two defects met here:
    //  (a) the approach cell was always the first walkable neighbour (north), so
    //      a unit standing SOUTH had to route through the blocker itself; the
    //      planner could not see the blocker, so A* returned that path and
    //      tryStep refused it every tick — a permanent wedge.
    //  (b) a real UI blocker is a TWO-PART write (CellType.obstacle + blockedCells)
    //      but the lift reverted only the blocked set, so the cell stayed
    //      impassable after being "cleared".
    final config = WarehouseConfig(
      id: 'blk2',
      name: 'blk2',
      ownerId: 'blk2',
      description: 'far-side',
      rows: 4,
      cols: 5,
      robotSpawns: const [],
      // Blocker placed the way the UI actually does it: the cell TYPE is obstacle.
      cells: [
        WarehouseCell(row: 0, col: 4, type: CellType.dump),
        WarehouseCell(row: 1, col: 2, type: CellType.obstacle),
      ],
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
    ref.read(unitRegistryProvider.notifier)
      ..register(BlockerMonitorBrain(id: 'MON'))
      // Starts SOUTH of the blocker — the case that used to wedge.
      ..register(RecoveryRobotBrain(id: 'RC1', pos: (row: 3, col: 2)));
    ref.read(blockedCellsProvider.notifier).addLocal(1, 2);

    final scheduler = UnitScheduler(ref);
    var done = false;
    for (var t = 0; t < 400 && !done; t++) {
      scheduler.tick(config, t);
      done = ref
          .read(jobBoardProvider)
          .jobs
          .values
          .where((j) => j.kind == JobKind.clearBlocker && !j.settled)
          .isEmpty;
      if (t == 0) done = false; // let the monitor raise it first
    }

    expect(ref.read(blockedCellsProvider).contains('1,2'), isFalse,
        reason: 'a unit approaching from the far side must still clear it');
    // BOTH halves reverted — the cell is walkable again, not just un-overlaid.
    final cellNow = ref.read(warehouseConfigProvider)!.cellAt(1, 2);
    expect(cellNow?.type, isNot(CellType.obstacle),
        reason: 'the obstacle cell type must be reverted too, or it still blocks');
  });
}
