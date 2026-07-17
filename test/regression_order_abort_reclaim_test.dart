// Review blocker (#3/#5): when an outbound Order dies (its truck never won a bay,
// or a sibling line failed 8×), the pallets its pickers already staged were
// stranded on pack-station cells forever and their packAndLoad Jobs orphaned —
// pack stations leaked one by one until outbound wedged. The scheduler's reclaim
// pass must free the cell and fail the Job.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/outbound_stage.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';

WarehouseConfig _cfg() => WarehouseConfig(
      id: 't',
      name: 't',
      ownerId: 't',
      description: 'reclaim',
      rows: 3,
      cols: 5,
      robotSpawns: const [],
      cells: [WarehouseCell(row: 0, col: 3, type: CellType.packStation)],
    );

void main() {
  testWidgets('an aborted order\'s staged pallet is reclaimed, not leaked forever',
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
    final board = ref.read(jobBoardProvider.notifier);
    ref.read(warehouseConfigProvider.notifier).state = config;

    // An order whose picker already staged a pallet at the pack cell and minted a
    // load Job — then the order aborts (its truck could never get a bay).
    final order = board.mintOrder(
      kind: OrderKind.outboundShip,
      skuId: 'SKU1',
      orderedUnits: kLoosePerPallet,
      nowTick: 0,
    );
    ref.read(outboundStageProvider.notifier).place(0, 3, 'SKU1');
    final load = board.mintJobOf(
      kind: JobKind.packAndLoad,
      requiredRole: UnitRole.outboundRobot,
      skuId: 'SKU1',
      orderId: order.id,
      lineId: 'L0',
      src: (row: 0, col: 3),
      qtyUnits: kLoosePerPallet,
    );
    board.closeOrder(order.id, aborted: true);

    // The pack cell is occupied and the load Job is live — the leak, pre-fix.
    expect(ref.read(outboundStageProvider).isNotEmpty, isTrue);

    // One scheduler tick runs the reclaim pass.
    UnitScheduler(ref).tick(config, 1);

    expect(ref.read(outboundStageProvider).isEmpty, isTrue,
        reason: 'the stranded pallet is cleared, freeing the pack-station cell');
    final j = ref.read(jobBoardProvider).jobs[load.id];
    expect(j == null || j.status == JobStatus.failed, isTrue,
        reason: 'the orphaned load Job is failed (or swept), not left claimable forever');
  });
}
