// The layout self-check turns "robots don't move" into a concrete reason. These
// pin the diagnosis: a complete warehouse is clean; a bare one lists the exact
// missing pieces (pack station, outbound, stock, spawns) as blockers/warnings.

import 'package:flutter_test/flutter_test.dart';
import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/warehouse_readiness.dart';

WarehouseConfig _cfg(List<WarehouseCell> cells,
        {List<RobotSpawn> spawns = const []}) =>
    WarehouseConfig(
      id: 't',
      name: 't',
      ownerId: 't',
      description: 't',
      rows: 6,
      cols: 10,
      robotSpawns: spawns,
      cells: cells,
    );

void main() {
  test('a complete, staffed warehouse reports no issues', () {
    final cfg = _cfg(
      [
        WarehouseCell(row: 0, col: 1, type: CellType.dock),
        WarehouseCell(row: 0, col: 3, type: CellType.palletStaging),
        WarehouseCell(
            row: 0,
            col: 5,
            type: CellType.rackLoose,
            skuId: 'SKU1',
            quantity: 8,
            maxQuantity: 10),
        // Three pack stations: an order routes into up to three UOM lines, so a
        // single stage cell can neither group an order nor keep picking flowing.
        WarehouseCell(row: 0, col: 6, type: CellType.packStation),
        WarehouseCell(row: 0, col: 7, type: CellType.packStation),
        WarehouseCell(row: 0, col: 8, type: CellType.packStation),
        WarehouseCell(row: 0, col: 9, type: CellType.outbound),
      ],
      spawns: const [
        RobotSpawn(row: 1, col: 0, robotType: 'AMR'),
        RobotSpawn(row: 1, col: 1, robotType: 'AMR'),
        RobotSpawn(row: 1, col: 2, robotType: 'AMR'),
        RobotSpawn(row: 1, col: 3, robotType: 'AMR'),
      ],
    );
    expect(checkWarehouseReadiness(cfg), isEmpty);
  });

  test('a bare warehouse flags the outbound blockers + staffing warning', () {
    // Racks exist and are stocked, but no pack station, no outbound, no spawns.
    final cfg = _cfg([
      WarehouseCell(
          row: 0,
          col: 5,
          type: CellType.rackLoose,
          skuId: 'SKU1',
          quantity: 8,
          maxQuantity: 10),
    ]);
    final issues = checkWarehouseReadiness(cfg);
    final blockers = issues.where((i) => i.isBlocker).toList();

    // Blockers sort ahead of warnings.
    expect(issues.first.isBlocker, isTrue);
    // Missing pack station + outbound are blockers.
    expect(blockers.any((i) => i.message.contains('pack station')), isTrue);
    expect(blockers.any((i) => i.message.contains('outbound')), isTrue);
    // No spawns is a (non-blocking) warning.
    expect(
        issues.any(
            (i) => !i.isBlocker && i.message.contains('No robot spawns')),
        isTrue);
  });

  test('empty racks are a blocker (nothing to ship)', () {
    final cfg = _cfg([
      WarehouseCell(
          row: 0,
          col: 5,
          type: CellType.rackLoose,
          skuId: 'SKU1',
          quantity: 0,
          maxQuantity: 10),
      WarehouseCell(row: 0, col: 7, type: CellType.packStation),
      WarehouseCell(row: 0, col: 9, type: CellType.outbound),
    ]);
    final issues = checkWarehouseReadiness(cfg);
    expect(issues.any((i) => i.isBlocker && i.message.contains('No stocked rack')),
        isTrue);
  });
}
