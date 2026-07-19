// AGGRESSIVE END-TO-END AUTOMATION PROBE.
//
// Not a unit test — a measurement. Runs the FULL sim on a complete warehouse for
// a long horizon and reports what each subsystem actually achieved, so "we are
// not in complete automation" becomes a specific list rather than a feeling:
//
//   auto ORDER   — does demand keep arriving?
//   auto ROUTES  — do orders explode into pallet/case/loose lines?
//   auto PICK    — do pickers actually pull stock to the stage?
//   auto SHIP    — do staged goods load and orders close?
//   auto TRUCKS  — do inbound + outbound trucks spawn, dock and depart?
//   IN TANDEM    — does it keep going, or stall after the first cycle?

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/outbound_stage.dart';
import 'package:warehouse_simulator/application/sim_bootstrap.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/inbound_truck_brain.dart';
import 'package:warehouse_simulator/application/brains/outbound_truck_brain.dart';

/// A COMPLETE warehouse: truck bay, staging, all three rack UOMs (stocked +
/// one deliberately low to trigger inbound), pack station, outbound bay, road.
///
///  col:   0     1        2      3        4       5        6      7      8
/// row0         DOCK            STAGING          PACK            OUT
/// row1   .     .        .      .        .       .        .      .      .
/// row2         RKp(8)          RKc(10)          RKl(40)         RKp2(0 = low)
/// row3   .     .        .      .        .       .        .      .      .
/// row4   ROAD  .        .      .        .       .        .      .      .
WarehouseConfig _fullWarehouse() => WarehouseConfig(
      id: 'e2e',
      name: 'e2e',
      ownerId: 'e2e',
      description: 'full-automation',
      rows: 5,
      cols: 9,
      robotSpawns: const [
        RobotSpawn(row: 1, col: 0, robotType: 'AMR', name: 'IR-1'),
        RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'OR-1'),
        RobotSpawn(row: 1, col: 2, robotType: 'AMR', name: 'PPR-1'),
        RobotSpawn(row: 3, col: 0, robotType: 'AMR', name: 'PK-1'),
        RobotSpawn(row: 3, col: 1, robotType: 'AMR', name: 'PK-2'),
        RobotSpawn(row: 3, col: 2, robotType: 'AMR', name: 'PK-3'),
        // 7th = pallet picker, 8th = the recovery unit that clears blockers.
        RobotSpawn(row: 3, col: 3, robotType: 'AMR', name: 'PK-4'),
        RobotSpawn(row: 3, col: 4, robotType: 'AMR', name: 'RC-1'),
      ],
      cells: [
        WarehouseCell(row: 0, col: 1, type: CellType.dock),
        WarehouseCell(row: 0, col: 3, type: CellType.palletStaging),
        // THREE pack stations: an order routes into up to three UOM lines, so a
        // single stage cell can never hold a whole order at once — spec-2
        // "grouped together" is structurally impossible with one.
        WarehouseCell(row: 0, col: 4, type: CellType.packStation),
        WarehouseCell(row: 0, col: 5, type: CellType.packStation),
        WarehouseCell(row: 0, col: 6, type: CellType.packStation),
        // EXPERIMENT: +3 pack stations (buffer 3 -> 6) to test whether the
        // pack-station buffer capacity is the binding constraint on ships.
        WarehouseCell(row: 2, col: 2, type: CellType.packStation),
        WarehouseCell(row: 2, col: 4, type: CellType.packStation),
        WarehouseCell(row: 2, col: 6, type: CellType.packStation),
        WarehouseCell(row: 0, col: 7, type: CellType.outbound),
        // Stocked racks — one per UOM so orders can route all three ways.
        WarehouseCell(
            row: 2,
            col: 1,
            type: CellType.rackPallet,
            skuId: 'SKU1',
            quantity: 8,
            maxQuantity: 10),
        WarehouseCell(
            row: 2,
            col: 3,
            type: CellType.rackCase,
            skuId: 'SKU1',
            quantity: 20,
            maxQuantity: 24),
        WarehouseCell(
            row: 2,
            col: 5,
            type: CellType.rackLoose,
            skuId: 'SKU1',
            quantity: 80,
            maxQuantity: 96),
        // A second SKU held at zero → must trigger the inbound replenish loop.
        WarehouseCell(
            row: 2,
            col: 7,
            type: CellType.rackPallet,
            skuId: 'SKU2',
            quantity: 0,
            maxQuantity: 10),
        WarehouseCell(row: 4, col: 0, type: CellType.roadH),
        // Somewhere to put a cleared obstruction.
        WarehouseCell(row: 4, col: 8, type: CellType.dump),
      ],
    );

void main() {
  testWidgets('E2E: order -> route -> pick -> ship -> trucks, running in tandem',
      (tester) async {
    final config = _fullWarehouse();
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

    bootstrapSimUnits(ref, config, const [
      (id: 'IR-1', row: 1, col: 0),
      (id: 'OR-1', row: 1, col: 1),
      (id: 'PPR-1', row: 1, col: 2),
      (id: 'PK-1', row: 3, col: 0),
      (id: 'PK-2', row: 3, col: 1),
      (id: 'PK-3', row: 3, col: 2),
      (id: 'PK-4', row: 3, col: 3),
      (id: 'RC-1', row: 3, col: 4),
    ]);

    // Cumulative counters — the board sweeps terminal work, so sample per tick.
    final ordersSeen = <String>{};
    final ordersClosed = <String>{};
    final ordersAborted = <String>{};
    // Terminal-cycle tracking that survives same-tick sweeping.
    final vanished = <String>{}; // swept => the cycle ended (shipped or aborted)
    final shippedSome = <String>{}; // vanished with progress > 0 => really shipped
    final lastProgress = <String, int>{};
    final orderedUnitsSeen = <String, int>{};
    final jobsByKind = <JobKind, Set<String>>{};
    final linesByUom = <UomKind, int>{};
    final inboundTrucks = <String>{};
    final outboundTrucks = <String>{};
    var maxStaged = 0;
    var stagedEvents = 0;
    var fullBufferTicks = 0;
    var fullBufferWithStuckTicks = 0;
    var anyTruckDockedTicks = 0; // ticks >=1 outbound order has shipBay!=null
    var loaderBusyTicks = 0; // ticks >=1 outbound robot has a current job
    final movedRobots = <String>{};
    const spawns = {
      'IR-1': '1_0', 'OR-1': '1_1', 'PPR-1': '1_2',
      'PK-1': '3_0', 'PK-2': '3_1', 'PK-3': '3_2',
    };

    // Manually injected obstructions, mid-run, right on the working aisles — the
    // anomaly the system must notice and rectify WITHOUT the flow seizing up.
    // Spaced so each has time to be found, hauled to the dump and disposed of
    // before the next lands — one recovery unit serves them serially.
    const injections = {200: (1, 4), 500: (3, 5), 800: (1, 6)};
    final injected = <String>{};
    final clearedBlockers = <String>{};

    final scheduler = UnitScheduler(ref);
    const horizon = 1500;
    for (var t = 0; t < horizon; t++) {
      final inj = injections[t];
      if (inj != null) {
        ref.read(blockedCellsProvider.notifier).addLocal(inj.$1, inj.$2);
        injected.add('${inj.$1},${inj.$2}');
      }
      scheduler.tick(config, t);
      // A blocker counts as cleared once it leaves the blocked set again.
      final nowBlocked = ref.read(blockedCellsProvider);
      for (final k in injected) {
        if (!nowBlocked.contains(k)) clearedBlockers.add(k);
      }

      final board = ref.read(jobBoardProvider);
      // sweepTerminal prunes an Order in the SAME tick it goes terminal, so
      // sampling status alone under-reports completions. Track DISAPPEARANCE
      // (seen before, gone now) as the reliable "cycle finished" signal, and
      // record the last progress we saw to tell shipped from abandoned.
      final present = board.orders.keys.toSet();
      for (final id in ordersSeen) {
        if (!present.contains(id) && !vanished.contains(id)) {
          vanished.add(id);
          if ((lastProgress[id] ?? 0) > 0) shippedSome.add(id);
        }
      }
      for (final o in board.orders.values) {
        if (ordersSeen.add(o.id)) {
          for (final l in o.lines) {
            linesByUom[l.uom] = (linesByUom[l.uom] ?? 0) + 1;
          }
        }
        lastProgress[o.id] = o.progressUnits;
        orderedUnitsSeen[o.id] = o.orderedUnits;
        if (o.status == OrderStatus.closed) ordersClosed.add(o.id);
        if (o.status == OrderStatus.aborted) ordersAborted.add(o.id);
      }
      for (final j in board.jobs.values) {
        (jobsByKind[j.kind] ??= <String>{}).add(j.id);
      }
      for (final u in ref.read(unitRegistryProvider).values) {
        if (u is InboundTruckBrain) inboundTrucks.add(u.id);
        if (u is OutboundTruckBrain) outboundTrucks.add(u.id);
      }
      final staged = ref.read(outboundStageProvider).length;
      if (staged > maxStaged) maxStaged = staged;
      if (staged > 0) stagedEvents++;
      if (board.orders.values
          .any((o) => o.kind == OrderKind.outboundShip && o.shipBay != null)) {
        anyTruckDockedTicks++;
      }
      if (ref.read(unitRegistryProvider).values.any(
          (u) => u.role == UnitRole.outboundRobot && u.currentJobId != null)) {
        loaderBusyTicks++;
      }
      // BUFFER COMPOSITION: when the buffer is FULL (all 3 pack stations taken),
      // classify each occupied cell as drainable (a packAndLoad job exists for it
      // whose order has a docked truck, shipBay!=null) or STUCK (no such job /
      // order has shipBay==null → an outbound robot can never claim it).
      if (staged >= 3) {
        fullBufferTicks++;
        final stageMap = ref.read(outboundStageProvider);
        final jobs = board.jobs.values
            .where((j) => j.kind == JobKind.packAndLoad)
            .toList();
        var anyStuck = false;
        for (final key in stageMap.keys) {
          final parts = key.split('_');
          final r = int.parse(parts[0]);
          final c = int.parse(parts[1]);
          Job? pl;
          for (final j in jobs) {
            if (j.src != null && j.src!.row == r && j.src!.col == c) {
              pl = j;
              break;
            }
          }
          final ord = pl?.orderId == null ? null : board.orders[pl!.orderId];
          if (pl == null || ord == null || ord.shipBay == null) anyStuck = true;
        }
        if (anyStuck) fullBufferWithStuckTicks++;
      }
      final pos = ref.read(manualRobotPositionsProvider);
      spawns.forEach((id, home) {
        final p = pos[id];
        if (p != null && '${p.row}_${p.col}' != home) movedRobots.add(id);
      });
    }

    final cfgNow = ref.read(warehouseConfigProvider)!;
    int qty(int r, int c) => cfgNow.cellAt(r, c)?.quantity ?? -1;

    // ── REPORT ───────────────────────────────────────────────────────────────
    debugPrint('\n===== E2E AUTOMATION REPORT ($horizon ticks) =====');
    debugPrint('AUTO ORDER  : minted=${ordersSeen.length} '
        'closed=${ordersClosed.length} aborted=${ordersAborted.length}');
    debugPrint('CYCLES      : completed(swept)=${vanished.length} '
        'ofWhichShipped=${shippedSome.length} stillOpen=${ordersSeen.length - vanished.length}');
    debugPrint('AUTO ROUTES : lines by UOM = $linesByUom');
    debugPrint('AUTO PICK   : pickToStage jobs=${jobsByKind[JobKind.pickToStage]?.length ?? 0} '
        'stagedEvents=$stagedEvents maxConcurrentStaged=$maxStaged');
    debugPrint('AUTO SHIP   : packAndLoad jobs=${jobsByKind[JobKind.packAndLoad]?.length ?? 0}');
    debugPrint('AUTO TRUCKS : inbound=${inboundTrucks.length} outbound=${outboundTrucks.length}');
    debugPrint('INBOUND     : unload=${jobsByKind[JobKind.unloadTruck]?.length ?? 0} '
        'putaway=${jobsByKind[JobKind.putaway]?.length ?? 0}');
    debugPrint('ROBOTS MOVED: ${movedRobots.length}/6 -> ${movedRobots.toList()..sort()}');
    debugPrint('STOCK       : pallet(2,1)=${qty(2, 1)} case(2,3)=${qty(2, 3)} '
        'loose(2,5)=${qty(2, 5)} lowSKU2(2,7)=${qty(2, 7)}');
    final rc = ref.read(unitRegistryProvider)['RC-1'];
    final stuckJobs = ref
        .read(jobBoardProvider)
        .jobs
        .values
        .where((j) => j.kind == JobKind.clearBlocker && !j.settled)
        .map((j) => '${j.id}:${j.status.name}:att${j.attempts}:src=${j.src}')
        .toList();
    debugPrint('BLOCKERS    : injected=${injected.length} '
        'cleared=${clearedBlockers.length} stillBlocked=${ref.read(blockedCellsProvider)}');
    debugPrint('RECOVERY    : pos=${rc?.pos} job=${rc?.currentJobId} '
        'life=${rc?.lifecycle.name} liveClearJobs=$stuckJobs');
    debugPrint('=================================================');
    debugPrint('----- LIFECYCLE DIAG -----');
    final keys = kDiag.keys.toList()..sort();
    for (final k in keys) {
      debugPrint('  $k = ${kDiag[k]}');
    }
    // Per-order: did the ones we saw ever reach full progress?
    var fullyShipped = 0, partial = 0, zero = 0;
    lastProgress.forEach((id, prog) {
      final ordered = orderedUnitsSeen[id] ?? -1;
      if (prog <= 0) {
        zero++;
      } else if (ordered > 0 && prog >= ordered) {
        fullyShipped++;
      } else {
        partial++;
      }
    });
    debugPrint('ORDERS by final progress: fully=$fullyShipped '
        'partial=$partial zero=$zero (ordered map size=${orderedUnitsSeen.length})');
    // End-of-run OUTBOUND order autopsy: what state are the survivors in, and
    // are pack stations clogged with un-loadable staged goods?
    final endBoard = ref.read(jobBoardProvider);
    var obOpenNoBay = 0, obOpenWithBay = 0, obFulfilling = 0, obStagedStuck = 0;
    for (final o in endBoard.orders.values) {
      if (o.kind != OrderKind.outboundShip) continue;
      if (o.status == OrderStatus.open || o.status == OrderStatus.fulfilling) {
        if (o.shipBay == null) obOpenNoBay++; else obOpenWithBay++;
        if (o.status == OrderStatus.fulfilling) obFulfilling++;
        if (o.stagedUnits > 0) obStagedStuck++;
      }
    }
    final endStage = ref.read(outboundStageProvider);
    final unclaimedPackLoad = endBoard.jobs.values
        .where((j) => j.kind == JobKind.packAndLoad &&
            j.status == JobStatus.unclaimed)
        .length;
    debugPrint('OUTBOUND SURVIVORS: openNoBay=$obOpenNoBay openWithBay=$obOpenWithBay '
        'fulfilling=$obFulfilling withStagedUnits=$obStagedStuck');
    debugPrint('DOCK/LOADER TICKS: anyOutboundDocked=$anyTruckDockedTicks/$horizon '
        'loaderBusy=$loaderBusyTicks/$horizon');
    debugPrint('BUFFER FULL TICKS: full=$fullBufferTicks '
        'ofWhichHaveStuckCell=$fullBufferWithStuckTicks '
        '(${horizon > 0 ? (100 * fullBufferWithStuckTicks / (fullBufferTicks == 0 ? 1 : fullBufferTicks)).toStringAsFixed(0) : 0}% of full-buffer ticks blocked by an un-drainable cell)');
    debugPrint('END STAGE OCCUPANCY: cells=${endStage.length} $endStage '
        'unclaimedPackLoadJobs=$unclaimedPackLoad');
    debugPrint('=================================================\n');

    // The anomaly loop must work INSIDE the running warehouse, not just in
    // isolation: every injected obstruction is found and hauled away, and the
    // flow keeps producing afterwards rather than seizing up behind it.
    expect(clearedBlockers.length, injected.length,
        reason: 'every manually injected blocker must be identified and removed');
    expect(ref.read(blockedCellsProvider), isEmpty,
        reason: 'the floor ends clear of obstructions');

    // ── ASSERTIONS: each subsystem must actually function ────────────────────
    expect(ordersSeen, isNotEmpty, reason: 'AUTO ORDER: demand must be generated');
    expect(linesByUom.keys.length, greaterThan(1),
        reason: 'AUTO ROUTES: orders must route across more than one UOM');
    expect(jobsByKind[JobKind.pickToStage], isNotNull,
        reason: 'AUTO PICK: pick jobs must be minted');
    expect(stagedEvents, greaterThan(0),
        reason: 'AUTO PICK: stock must actually reach the shipping area');
    expect(jobsByKind[JobKind.packAndLoad], isNotNull,
        reason: 'AUTO SHIP: staged goods must produce load jobs');
    expect(shippedSome, isNotEmpty,
        reason:
            'AUTO SHIP: at least one order must complete end-to-end (shipped, then swept)');
    expect(inboundTrucks, isNotEmpty,
        reason: 'AUTO TRUCKS: low stock (SKU2=0) must summon an inbound truck');
    expect(outboundTrucks, isNotEmpty,
        reason: 'AUTO TRUCKS: outbound orders must spawn a shipping truck');
    expect(movedRobots.length, greaterThanOrEqualTo(3),
        reason: 'IN TANDEM: most of the cast must be doing work, not idling');
    // The loop must be CONTINUOUS, not a single cycle that then stalls.
    expect(ordersSeen.length, greaterThan(1),
        reason: 'IN TANDEM: demand must keep flowing, not stop after one order');
  });
}
