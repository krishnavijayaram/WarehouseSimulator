// Spec 5.1 — CROSS-DOCK (the primary putaway rule). When an incoming pallet is
// already wanted by an open outbound order, the cart drives it STRAIGHT to
// outbound staging instead of putting it away. The critical property: it must not
// double-ship — the outbound pick Job it replaces is consumed, and no rack is
// drained to serve that same demand a second time.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/outbound_stage.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/putaway_robot_brain.dart';

///   col:  0    1          2   3          4
///   row0       STAGING        PACK(stage)
///   row1  .    .          .   .          .   (aisle)
WarehouseConfig _yard() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'xdock',
      rows: 3,
      cols: 5,
      robotSpawns: const [],
      cells: [
        WarehouseCell(row: 0, col: 1, type: CellType.palletStaging),
        WarehouseCell(row: 0, col: 3, type: CellType.packStation), // outbound stage
      ],
    );

void main() {
  testWidgets('cross-dock: an inbound pallet wanted by an order goes to shipping',
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
    final board = ref.read(jobBoardProvider.notifier);
    ref.read(warehouseConfigProvider.notifier).state = config;

    // An inbound pallet has landed in staging, and there is a putaway Job for it.
    ref.read(stagingPalletsProvider.notifier).drop(0, 1, 'SKU1');
    ref
        .read(unitRegistryProvider.notifier)
        .register(PutawayRobotBrain(id: 'PR1', pos: (row: 1, col: 0)));
    board.mintJobOf(
      kind: JobKind.putaway,
      requiredRole: UnitRole.putawayRobot,
      skuId: 'SKU1',
      src: (row: 0, col: 1),
      qtyUnits: kLoosePerPallet,
    );

    // An OPEN outbound order wants one pallet of SKU1 — its pick Job is waiting.
    final order = board.mintOrder(
      kind: OrderKind.outboundShip,
      skuId: 'SKU1',
      orderedUnits: kLoosePerPallet,
      nowTick: 0,
    );
    board.mintJobOf(
      kind: JobKind.pickToStage,
      requiredRole: UnitRole.pickRobot,
      skuId: 'SKU1',
      requiredUom: UomKind.pallet,
      orderId: order.id,
      lineId: 'L0',
      idemKey: '${order.id}:L0:0',
      qtyUnits: kLoosePerPallet,
    );

    final scheduler = UnitScheduler(ref);
    var staged = false;
    for (var t = 0; t < 80 && !staged; t++) {
      scheduler.tick(config, t);
      staged = ref.read(outboundStageProvider).isNotEmpty;
    }

    // The pallet reached outbound staging via the cart (not a picker — there is
    // no pick robot registered), so cross-dock fired.
    expect(staged, isTrue,
        reason: 'the incoming pallet should be cross-docked to outbound staging');
    expect(ref.read(stagingPalletsProvider).containsKey('0_1'), isFalse,
        reason: 'the inbound staging slot was emptied by the cross-dock');

    // No double-ship: exactly one packAndLoad handoff exists for the order, and
    // the original pick Job was consumed (done), not left to also drain a rack.
    final jobs = ref.read(jobBoardProvider).jobs.values;
    final packLoads = jobs.where((j) =>
        j.kind == JobKind.packAndLoad && j.orderId == order.id);
    expect(packLoads.length, 1,
        reason: 'exactly one load handoff — the pallet is shipped once');
    // The replaced pick Job is consumed — either already swept, or marked done.
    // No LIVE pick remains that a picker could claim and drain a rack for.
    final livePicks = jobs.where((j) =>
        j.kind == JobKind.pickToStage &&
        j.status != JobStatus.done &&
        j.status != JobStatus.failed);
    expect(livePicks, isEmpty,
        reason: 'no claimable pick survives — the demand is served once, by cross-dock');

    // The order line has NOT been over-credited: progress is still 0 until load.
    expect(ref.read(jobBoardProvider).orders[order.id]!.progressUnits, 0,
        reason: 'cross-dock credits progress at LOAD, exactly once — not twice');
  });
}
