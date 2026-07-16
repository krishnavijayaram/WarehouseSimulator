// Regression for the "outbound half is dead on a real warehouse" bug: the
// creator paints `rackLoose` (pallet racks are legacy), but the outbound
// generator only recognised `rackPallet` stock and always minted pallet-UOM pick
// Jobs — so on a normal warehouse NO outbound order was ever generated and the
// pick/pack/ship robots sat idle. This drives the REAL app bootstrap on a
// rackLoose warehouse and asserts stock is actually picked and shipped.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/sim_bootstrap.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';

/// A rackLoose warehouse (what the creator actually paints): a stocked loose
/// rack, a pack station, an outbound bay, and a road cell for the truck.
WarehouseConfig _looseYard() => WarehouseConfig(
      id: 'test',
      name: 'test',
      ownerId: 'test',
      description: 'p4-outbound-loose',
      rows: 5,
      cols: 8,
      robotSpawns: const [],
      cells: [
        WarehouseCell(
            row: 0,
            col: 3,
            type: CellType.rackLoose, // ← real racks, not legacy rackPallet
            skuId: 'SKU1',
            quantity: 10,
            maxQuantity: 10), // full → never dips below reorder, so no inbound noise
        WarehouseCell(row: 0, col: 5, type: CellType.packStation),
        WarehouseCell(row: 0, col: 7, type: CellType.outbound),
        WarehouseCell(row: 4, col: 0, type: CellType.roadH),
      ],
    );

void main() {
  testWidgets('outbound loop ships from a rackLoose warehouse (not just pallets)',
      (tester) async {
    final config = _looseYard();
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

    // Same call the app makes on start; role round-robin gives us a pick robot
    // (index 2) and an outbound robot (index 3).
    bootstrapSimUnits(ref, config, const [
      (id: 'R0', row: 1, col: 0),
      (id: 'R1', row: 1, col: 1),
      (id: 'R2', row: 1, col: 2),
      (id: 'R3', row: 1, col: 3),
    ]);

    final scheduler = UnitScheduler(ref);
    for (var t = 0; t < 260; t++) {
      scheduler.tick(config, t);
    }

    // The generator recognised the loose stock and minted a ship order...
    final ship = ref.read(jobBoardProvider).orders.values.where(
        (o) => o.kind == OrderKind.outboundShip && o.skuId == 'SKU1');
    expect(ship, isNotEmpty,
        reason: 'outbound generator must recognise rackLoose stock and emit a ship order');

    // ...and the picker actually pulled stock off the loose rack.
    final remaining = ref.read(warehouseConfigProvider)?.cellAt(0, 3)?.quantity;
    expect(remaining, isNotNull);
    expect(remaining! < 10, isTrue,
        reason: 'a picker pulled loose units from the rack and shipped them');
  });
}
