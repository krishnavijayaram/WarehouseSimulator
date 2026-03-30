/// warehouse_templates.dart — Warehouse layout templates.
///
/// Physical left-to-right column layout (inside the road boundary):
///
///  col 0              : roadV (left lane — truck travels this single col)
///  col 1              : inbound dock column  (dock bays + inbound fill)
///  col 2  .. stg1     : SKU staging (2 cols alternating, 5–10 slots)
///  col stg1+1 .. pe   : Loose zone  (closest to inbound)
///  col pe+1   .. ce   : Case  zone
///  col ce+1   .. pal  : Pallet zone (closest to outbound)
///  col pal+1          : Pack station
///  col pal+2          : outbound dock column
///  col C-1            : roadV (right lane — truck travels this single col)
///
///  Outside the road lane (cols < 0 conceptually) → truck waiting area is
///  represented by a single "truckWaiting" row at row 0 & R-1 using roadH.
///
/// Cross-aisles at rows 0, mid, R-1 spanning staging→pack columns.
/// Chargers placed with 3 open sides + ≥4 adjacent aisle/path neighbours.
/// Dump next to pack station at mid row.
/// Zone order (inbound→outbound): Loose → Case → Pallet  (dense items first).
///
/// isSystem: true → UI prevents modification/overwrite.
library;

import 'dart:math';

import '../../models/warehouse_config.dart';

// ─────────────────────────────────────────────────────────────────────────────
// All 20 master SKU IDs (must match seed_master.py SKUS list)
// ─────────────────────────────────────────────────────────────────────────────

const kAllSkuIds = [
  'SKU-E01',
  'SKU-E02',
  'SKU-E03',
  'SKU-E04',
  'SKU-E05',
  'SKU-F01',
  'SKU-F02',
  'SKU-F03',
  'SKU-F04',
  'SKU-F05',
  'SKU-A01',
  'SKU-A02',
  'SKU-A03',
  'SKU-A04',
  'SKU-A05',
  'SKU-I01',
  'SKU-I02',
  'SKU-I03',
  'SKU-I04',
  'SKU-I05',
];

// ─────────────────────────────────────────────────────────────────────────────
// Inventory seed helper
//   • 10 pallet rack cells → 1 pallet each (different cells, different SKUs)
//   • 10 case  rack cells  → 50 % ± 20 % fill  (max=2 → qty 1 or 2)
//   • 10 loose rack cells  → 50 % ± 20 % fill
// Called after deduplication so each (row, col) exists exactly once.
// ─────────────────────────────────────────────────────────────────────────────
/// Assigns random starter inventory to rack cells in [cells].
/// Call this when a template is applied — NOT during construction — so each
/// load produces a fresh randomised layout.
///
///  • Up to 10 pallet rack cells → 1 pallet each
///  • Up to 10 case  rack cells  → 30 %–70 % fill
///  • Up to 10 loose rack cells  → 30 %–70 % fill
List<WarehouseCell> assignTemplateInventory(List<WarehouseCell> cells,
    [Random? rng]) {
  final r = rng ?? Random();
  final palletCells =
      cells.where((c) => c.type == CellType.rackPallet).toList();
  final caseCells = cells.where((c) => c.type == CellType.rackCase).toList();
  final looseCells = cells.where((c) => c.type == CellType.rackLoose).toList();

  final updates = <String, WarehouseCell>{};

  // Pick `count` cells at random from `pool` and assign a unique SKU each.
  void seedPool(
    List<WarehouseCell> pool,
    int count,
    int Function(int maxQty) qtyFn,
  ) {
    final shuffledCells = List<WarehouseCell>.from(pool)..shuffle(r);
    final shuffledSkus = List<String>.from(kAllSkuIds)..shuffle(r);
    final limit = count.clamp(0, shuffledCells.length);
    for (var i = 0; i < limit; i++) {
      final cell = shuffledCells[i];
      final sku = shuffledSkus[i % shuffledSkus.length];
      final qty = qtyFn(cell.maxQuantity);
      updates['${cell.row},${cell.col}'] =
          cell.copyWith(skuId: sku, quantity: qty);
    }
  }

  // Randomly seed 50–75 % of each rack type — not every cell needs stock.
  // Pallets: 1–5 units per cell.  Case/Loose: 30–70 % of capacity.
  final palletCount = (palletCells.length * (0.50 + r.nextDouble() * 0.25))
      .round()
      .clamp(0, palletCells.length);
  seedPool(palletCells, palletCount, (_) => 1 + r.nextInt(5));

  final caseCount = (caseCells.length * (0.50 + r.nextDouble() * 0.25))
      .round()
      .clamp(0, caseCells.length);
  seedPool(
    caseCells,
    caseCount,
    (maxQty) =>
        ((maxQty * (0.30 + r.nextDouble() * 0.40)).round()).clamp(1, maxQty),
  );

  final looseCount = (looseCells.length * (0.50 + r.nextDouble() * 0.25))
      .round()
      .clamp(0, looseCells.length);
  seedPool(
    looseCells,
    looseCount,
    (maxQty) =>
        ((maxQty * (0.30 + r.nextDouble() * 0.40)).round()).clamp(1, maxQty),
  );

  return [
    for (final c in cells) updates['${c.row},${c.col}'] ?? c,
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
// Public descriptor
// ─────────────────────────────────────────────────────────────────────────────

class WarehouseTemplate {
  const WarehouseTemplate({
    required this.name,
    required this.description,
    required this.rows,
    required this.cols,
    required this.tags,
    required this.builder,
    this.isSystem = true,
  });

  final String name;
  final String description;
  final int rows, cols;
  final List<String> tags;
  final bool isSystem;
  final WarehouseConfig Function() builder;
}

// ─────────────────────────────────────────────────────────────────────────────
// Cell helpers
// ─────────────────────────────────────────────────────────────────────────────

String _uid() => 'wh-${DateTime.now().millisecondsSinceEpoch}';

List<WarehouseCell> _rect(int r0, int c0, int r1, int c1, CellType type,
    {String? label, int levels = 1}) {
  final out = <WarehouseCell>[];
  for (var r = r0; r <= r1; r++) {
    for (var c = c0; c <= c1; c++) {
      out.add(WarehouseCell(
          row: r, col: c, type: type, label: label, levels: levels));
    }
  }
  return out;
}

List<WarehouseCell> _row(int r, int c0, int c1, CellType t, {String? label}) =>
    _rect(r, c0, r, c1, t, label: label);

List<WarehouseCell> _col(int c, int r0, int r1, CellType t, {String? label}) =>
    _rect(r0, c, r1, c, t, label: label);

WarehouseCell _cell(int r, int c, CellType t, {String? label}) =>
    WarehouseCell(row: r, col: c, type: t, label: label);

// ─────────────────────────────────────────────────────────────────────────────
// Dock column helper
// Bays emitted FIRST so WarehouseConfig.cellAt (first-match) finds them.
// Non-bay rows are lane type (inbound or outbound).
// ─────────────────────────────────────────────────────────────────────────────
List<WarehouseCell> _dockCol(
  int c,
  int r0,
  int r1,
  int bayCount, {
  String prefix = 'BAY',
  CellType lane = CellType.inbound,
  int? bayR0, // optional: confine bays to this sub-range of r0..r1
  int? bayR1,
}) {
  final cells = <WarehouseCell>[];
  final br0 = bayR0 ?? r0;
  final br1 = bayR1 ?? r1;
  final total = br1 - br0 + 1;
  final baySet = <int>{};

  for (var i = 0; i < bayCount; i++) {
    final r = br0 + ((total / bayCount) * (i + 0.5)).round();
    baySet.add(r.clamp(br0, br1));
  }

  final sorted = baySet.toList()..sort();
  for (var i = 0; i < sorted.length; i++) {
    cells.add(_cell(sorted[i], c, CellType.dock, label: '$prefix${i + 1}'));
  }
  for (var r = r0; r <= r1; r++) {
    if (!baySet.contains(r)) cells.add(_cell(r, c, lane));
  }
  return cells;
}

// ─────────────────────────────────────────────────────────────────────────────
// SKU Staging helper
// 5-10 labeled slots alternating two adjacent staging columns.
// ─────────────────────────────────────────────────────────────────────────────
List<WarehouseCell> _stagingSlots(
  int stgCol0,
  int stgCol1,
  int r0,
  int r1,
  int slotCount,
) {
  final cells = <WarehouseCell>[];
  final total = r1 - r0 + 1;
  final staged = <int, int>{}; // row → slot number

  for (var i = 0; i < slotCount; i++) {
    final r = (r0 + ((total / slotCount) * (i + 0.5)).round()).clamp(r0, r1);
    staged[r] = i + 1;
  }

  for (var r = r0; r <= r1; r++) {
    final slot = staged[r];
    if (slot != null) {
      final label = 'STG-${slot.toString().padLeft(2, '0')}';
      final c = slot.isOdd ? stgCol0 : stgCol1;
      final other = c == stgCol0 ? stgCol1 : stgCol0;
      cells.add(_cell(r, c, CellType.palletStaging, label: label));
      cells.add(_cell(r, other, CellType.aisle));
    } else {
      cells.add(_cell(r, stgCol0, CellType.aisle));
      cells.add(_cell(r, stgCol1, CellType.aisle));
    }
  }
  return cells;
}

// ─────────────────────────────────────────────────────────────────────────────
// Rack zone builder (no gap cells on odd-width zones)
// ─────────────────────────────────────────────────────────────────────────────
({List<WarehouseCell> cells, List<PickZoneDef> zones}) _racks({
  required int colStart,
  required int colEnd,
  required int rowStart,
  required int rowEnd,
  required CellType rackType,
  required PickZoneType zoneType,
}) {
  final cells = <WarehouseCell>[];
  final zones = <PickZoneDef>[];

  // Wall aisles (path adjacent to racks)
  cells.addAll(_col(colStart, rowStart, rowEnd, CellType.aisle));
  cells.addAll(_col(colEnd, rowStart, rowEnd, CellType.aisle));

  var c = colStart + 1;
  int? first;
  int last = colStart + 1;

  while (c <= colEnd - 2) {
    cells.addAll(_col(c, rowStart, rowEnd, rackType));
    cells.addAll(_col(c + 1, rowStart, rowEnd, rackType));
    first ??= c;
    last = c + 1;
    c += 2;
    if (c <= colEnd - 3) {
      cells.addAll(_col(c, rowStart, rowEnd, CellType.aisle));
      c++;
    }
  }
  while (c < colEnd) {
    cells.addAll(_col(c, rowStart, rowEnd, CellType.aisle));
    c++;
  }

  if (first != null) {
    zones.add(PickZoneDef(
      type: zoneType,
      rowStart: rowStart,
      rowEnd: rowEnd,
      colStart: first,
      colEnd: last,
    ));
  }
  return (cells: cells, zones: zones);
}

// ─────────────────────────────────────────────────────────────────────────────
// Master builder
//
// Column layout (C = total cols):
//
//   col 0         roadV  (left truck lane — INSIDE left boundary)
//   col 1         inbound dock column  (dock bays + inbound fill)
//   col 2         SKU staging col 0
//   col 3         SKU staging col 1
//   col 4..x      Loose zone   (closest to inbound / left)
//   col x+1..y    Case  zone
//   col y+1..z    Pallet zone  (closest to outbound / right)
//   col z+1       Pack station
//   col z+2       outbound dock column
//   col C-1       roadV  (right truck lane — INSIDE right boundary)
//
//   row 0 & R-1:  crossAisle for interior cols (warehouse floor path),
//                 roadCornerSW/SE at road lane intersections (top),
//                 roadCornerNW/NE at road lane intersections (bottom).
//   rows 1..R-2:  interior working area
//
// Road is LEFT col and RIGHT col only (roadV). Top/bottom are warehouse paths.
// Chargers alternate fast→slow at each side (never two fast adjacent).
// Dump at pack station mid-height.
// ─────────────────────────────────────────────────────────────────────────────
WarehouseConfig _make({
  required String name,
  required String desc,
  required int rows,
  required int cols,
  required int docks, // dock bays per side (2–10)
  required int stagingSlots, // SKU staging slots  (5–10)
  required int looseCols,
  required int caseCols,
  required int palletCols,
  required List<RobotSpawn> robots,
  required List<String> tags,
  bool coldExtra = false,
  double outboundAnchor =
      0.5, // 0.25 = bays at top 25%, 0.5 = mid, 0.75 = bottom 75%
}) {
  var cells = <WarehouseCell>[];
  final zones = <PickZoneDef>[];
  final R = rows;
  final C = cols;

  // Interior row bounds (all rows are interior — no road strip top/bottom)
  const r0 = 0;
  final r1 = R - 1;
  final rMid = r1 ~/ 2;

  // Fixed column indices:
  //   col 0    = left road lane  (roadV full height)
  //   col 1    = inbound dock column
  //   col 2-3  = staging
  //   col 4..  = zones
  //   col C-3  = pack station
  //   col C-2  = outbound dock column
  //   col C-1  = right road lane (roadV full height)
  const laneL = 0;
  const dockIn = 1;
  const stg0 = 2;
  const stg1 = 3;
  const zoneS = 4;
  final packCol = C - 3;
  final dockOut = C - 2;
  final laneR = C - 1;

  // Interior row bounds for dock/staging/racks (between road corners)
  const iR0 = 1; // first interior row (skip road corner row)
  final iR1 = R - 2; // last  interior row

  // ── LEFT ROAD LANE (col 0, full height) ─────────────────────────────────
  // Top corner: truck enters from top going south  → roadCornerSW
  // Body: roadV
  // Bottom corner: truck exits eastward            → roadCornerNE
  cells.add(_cell(r0, laneL, CellType.roadCornerSW));
  for (var r = iR0; r <= iR1; r++) {
    cells.add(_cell(r, laneL, CellType.roadV));
  }
  cells.add(_cell(r1, laneL, CellType.roadCornerNE));

  // ── RIGHT ROAD LANE (col C-1, full height) ──────────────────────────────
  // Top corner: roadCornerSE (enters from top, exits eastward)
  // Bottom corner: roadCornerNW
  cells.add(_cell(r0, laneR, CellType.roadCornerSE));
  for (var r = iR0; r <= iR1; r++) {
    cells.add(_cell(r, laneR, CellType.roadV));
  }
  cells.add(_cell(r1, laneR, CellType.roadCornerNW));

  // ── TOP ROW (row 0): warehouse crossAisle for interior cols ─────────────
  cells.addAll(_row(r0, dockIn, dockOut, CellType.crossAisle));

  // ── BOTTOM ROW (row R-1): warehouse crossAisle for interior cols ─────────
  cells.addAll(_row(r1, dockIn, dockOut, CellType.crossAisle));

  // ── INBOUND DOCK COLUMN (col 1, interior rows iR0..iR1) ─────────────────
  cells.addAll(_dockCol(dockIn, iR0, iR1, docks, prefix: 'IN-'));

  // ── SKU STAGING (cols 2-3, interior rows) ───────────────────────────────
  cells.addAll(_stagingSlots(stg0, stg1, iR0, iR1, stagingSlots));

  // ── STORAGE ZONES: Loose → Case → Pallet (L→R toward outbound) ──────────
  var c = zoneS;

  final looseEnd = c + looseCols - 1;
  final lo = _racks(
      colStart: c,
      colEnd: looseEnd,
      rowStart: iR0,
      rowEnd: iR1,
      rackType: CellType.rackLoose,
      zoneType: PickZoneType.loosePick);
  cells.addAll(lo.cells);
  zones.addAll(lo.zones);
  c = looseEnd + 1;

  final caseEnd = c + caseCols - 1;
  final cs = _racks(
      colStart: c,
      colEnd: caseEnd,
      rowStart: iR0,
      rowEnd: iR1,
      rackType: CellType.rackCase,
      zoneType: PickZoneType.casePick);
  cells.addAll(cs.cells);
  zones.addAll(cs.zones);
  c = caseEnd + 1;

  final palletEnd = c + palletCols - 1;
  final pal = _racks(
      colStart: c,
      colEnd: palletEnd,
      rowStart: iR0,
      rowEnd: iR1,
      rackType: CellType.rackPallet,
      zoneType: PickZoneType.pallet);
  cells.addAll(pal.cells);
  zones.addAll(pal.zones);

  // ── OUTBOUND BAY RANGE (computed early so pack station aligns with it) ────
  // Pack station must always sit directly adjacent to the dock bays, never
  // spanning a tall column that visually reads as "middle of the warehouse".
  final obCenter = iR0 + ((iR1 - iR0) * outboundAnchor).round();
  final obHalf = ((iR1 - iR0) / 4).round().clamp(docks, (iR1 - iR0) ~/ 2);
  final obBayR0 = (obCenter - obHalf).clamp(iR0, iR1);
  final obBayR1 = (obCenter + obHalf).clamp(iR0, iR1);

  // ── PACK STATION (col C-3, bay rows only) ─────────────────────────────────
  // Fill the full column height with aisle first (ensures robot can navigate
  // past the pack area), then override the bay row range with packStation.
  cells.addAll(_col(packCol, iR0, iR1, CellType.aisle));
  cells.addAll(
      _col(packCol, obBayR0, obBayR1, CellType.packStation, label: 'PACK'));

  // ── OUTBOUND DOCK COLUMN (col C-2, interior rows) ─────────────────────────
  cells.addAll(_dockCol(dockOut, iR0, iR1, docks,
      prefix: 'OUT-', lane: CellType.outbound, bayR0: obBayR0, bayR1: obBayR1));

  // ── CROSS-AISLE at rMid: added AFTER all structural cells (racks, staging,
  // pack, dock) so that 'last added wins' dedup makes crossAisle override
  // racks and staging at mid-row — creating a clear horizontal corridor.
  // The dump (packCol) and outbound-dock (dockOut) cells below use
  // removeWhere to override this crossAisle where needed.
  cells.addAll(_row(rMid, dockIn, dockOut, CellType.crossAisle));

  // ── CHARGERS: alternate fast→slow, never two fast adjacent ──────────────
  // IMPORTANT: crossAisle rows (r0, rMid, r1) were added above and cellAt()
  // returns the first-match cell. We removeWhere at each charger position
  // first so the charger cell wins the first-match lookup.
  const chgLCol = stg1 + 1; // left-side charger column
  final chgRCol = packCol - 1; // right-side charger column

  // Clear any existing cells at perimeter charger positions
  cells.removeWhere((x) =>
      (x.col == chgLCol || x.col == chgRCol) && (x.row == r0 || x.row == r1));
  // Left side: top fast, bottom slow (never two fast adjacent)
  cells.add(_cell(r0, chgLCol, CellType.chargingFast, label: 'IN-CHG1'));
  cells.add(_cell(r1, chgLCol, CellType.chargingSlow, label: 'IN-CHG2'));
  // Right side: top fast, bottom slow
  cells.add(_cell(r0, chgRCol, CellType.chargingFast, label: 'OR-CHG1'));
  cells.add(_cell(r1, chgRCol, CellType.chargingSlow, label: 'OR-CHG2'));

  if (coldExtra) {
    // Extra cold-storage chargers placed at the case-zone right wall-aisle
    // column (caseEnd) on the guaranteed-safe crossAisle rows r0 and r1.
    // At these positions every orthogonal neighbour within the grid is a
    // walkable cell (crossAisle left/right, wall-aisle below/above) — Rule 3 ✓
    cells.removeWhere((x) => x.col == caseEnd && (x.row == r0 || x.row == r1));
    cells.add(_cell(r0, caseEnd, CellType.chargingFast, label: 'CX-CHG1'));
    cells.add(_cell(r1, caseEnd, CellType.chargingSlow, label: 'CX-CHG2'));
  }

  // NOTE: mid-zone slow charger (slowChgCol) removed.
  // Mid-row positions inside rack zones always have rack cells as orthogonal
  // neighbours — this violates Rule 3 (all adjacent cells must be paths).

  // ── DUMP: in pack station column, at center of outbound bay range ────────
  // Placed at the bay-range center rather than rMid so it stays co-located
  // with the pack station regardless of which anchor row the bays use.
  final dumpRow = (obBayR0 + obBayR1) ~/ 2;
  cells.removeWhere((x) => x.row == dumpRow && x.col == packCol);
  cells.add(_cell(dumpRow, packCol, CellType.dump, label: 'DUMP'));
  // Ensure crossAisle at the outbound dock column at mid-row so every outbound
  // cell in the column has at least one walkable neighbour (the cell above/below
  // or this crossAisle).
  cells.removeWhere((x) => x.row == rMid && x.col == dockOut);
  cells.add(_cell(rMid, dockOut, CellType.crossAisle));

  // ── RULE 1: deduplicate — each (row, col) holds exactly one cell type ─────
  // Last-added wins. Because crossAisle is added after _racks() and staging,
  // it wins at rMid positions — creating a clean horizontal corridor with no
  // cell that is simultaneously Rack AND Aisle.
  // Charger / dump / dockOut crossAisle cells use removeWhere before adding,
  // so they correctly override the crossAisle row where needed.
  {
    final seen = <String>{};
    final deduped = <WarehouseCell>[];
    for (var i = cells.length - 1; i >= 0; i--) {
      final key = '${cells[i].row},${cells[i].col}';
      if (seen.add(key)) deduped.add(cells[i]);
    }
    cells = deduped;
  }

  return WarehouseConfig(
    id: _uid(),
    name: name,
    description: desc,
    rows: rows,
    cols: cols,
    cells: cells,
    robotSpawns: robots,
    zones: zones,
    ownerId: '',
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Robot spawn helper: always on cross-aisle rows (r0=1, rMid, r1=R-2)
// col = mid of given zone column range
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// SMALL TEMPLATES  cols 22-26  rows 12-16  docks 3-4  staging 5-7
//   overhead: laneL(1) + dockIn(1) + stg(2) + pack(1) + dockOut(1) + laneR(1) = 7
//   zone budget = cols - 7
// ─────────────────────────────────────────────────────────────────────────────

WarehouseConfig _buildSmallA() {
  const R = 12, C = 22, docks = 3, slots = 5;
  // budget=15 → loose=4 case=4 pallet=7
  // cross-aisles at r=1, r=6, r=10
  return _make(
    name: 'Small Warehouse A',
    desc: '$C×$R | 3 bays | Top dock △',
    rows: R,
    cols: C,
    docks: docks,
    stagingSlots: slots,
    looseCols: 4,
    caseCols: 4,
    palletCols: 7,
    outboundAnchor: 0.25,
    tags: ['small'],
    robots: const [
      RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'IR-01'),
      RobotSpawn(row: 10, col: 1, robotType: 'AMR', name: 'IR-02'),
      RobotSpawn(row: 1, col: 7, robotType: 'AMR', name: 'LR-01'),
      RobotSpawn(row: 10, col: 7, robotType: 'AMR', name: 'PR-01'),
      RobotSpawn(row: 1, col: 11, robotType: 'AMR', name: 'CR-01'),
      RobotSpawn(row: 1, col: 15, robotType: 'AMR', name: 'PR-02'),
      RobotSpawn(row: 1, col: 20, robotType: 'AMR', name: 'OR-01'),
      RobotSpawn(row: 10, col: 20, robotType: 'AMR', name: 'OR-02'),
    ],
  );
}

WarehouseConfig _buildSmallB() {
  const R = 14, C = 24, docks = 3, slots = 6;
  // budget=17 → loose=4 case=5 pallet=8
  return _make(
    name: 'Small Warehouse B',
    desc: '$C×$R | 3 bays | Mid dock □',
    rows: R,
    cols: C,
    docks: docks,
    stagingSlots: slots,
    looseCols: 4,
    caseCols: 5,
    palletCols: 8,
    outboundAnchor: 0.5,
    tags: ['small', 'cross-aisle'],
    robots: const [
      RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'IR-01'),
      RobotSpawn(row: 12, col: 1, robotType: 'AMR', name: 'IR-02'),
      RobotSpawn(row: 1, col: 7, robotType: 'AMR', name: 'LR-01'),
      RobotSpawn(row: 12, col: 7, robotType: 'AMR', name: 'PR-01'),
      RobotSpawn(row: 1, col: 12, robotType: 'AMR', name: 'CR-01'),
      RobotSpawn(row: 1, col: 17, robotType: 'AMR', name: 'PR-02'),
      RobotSpawn(row: 1, col: 22, robotType: 'AMR', name: 'OR-01'),
      RobotSpawn(row: 12, col: 22, robotType: 'AMR', name: 'OR-02'),
    ],
  );
}

WarehouseConfig _buildSmallC() {
  const R = 16, C = 26, docks = 4, slots = 7;
  // budget=19 → loose=4 case=5 pallet=10
  return _make(
    name: 'Small Warehouse C',
    desc: '$C×$R | 4 bays | Bottom dock ▽',
    rows: R,
    cols: C,
    docks: docks,
    stagingSlots: slots,
    looseCols: 4,
    caseCols: 5,
    palletCols: 10,
    outboundAnchor: 0.75,
    tags: ['small', 'high-density'],
    robots: const [
      RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'IR-01'),
      RobotSpawn(row: 14, col: 1, robotType: 'AMR', name: 'IR-02'),
      RobotSpawn(row: 1, col: 7, robotType: 'AMR', name: 'LR-01'),
      RobotSpawn(row: 14, col: 7, robotType: 'AMR', name: 'PR-01'),
      RobotSpawn(row: 1, col: 12, robotType: 'AMR', name: 'CR-01'),
      RobotSpawn(row: 1, col: 18, robotType: 'AMR', name: 'PR-02'),
      RobotSpawn(row: 1, col: 24, robotType: 'AMR', name: 'OR-01'),
      RobotSpawn(row: 14, col: 24, robotType: 'AMR', name: 'OR-02'),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// MEDIUM TEMPLATES  cols 34-40  rows 18-22  docks 4-6  staging 7-10
// ─────────────────────────────────────────────────────────────────────────────

WarehouseConfig _buildMediumA() {
  const R = 18, C = 34, docks = 4, slots = 7;
  // budget=27 → loose=5 case=8 pallet=14
  return _make(
    name: 'Medium Distribution Center A',
    desc: '$C×$R | 4 bays | Top dock △',
    rows: R,
    cols: C,
    docks: docks,
    stagingSlots: slots,
    looseCols: 5,
    caseCols: 8,
    palletCols: 14,
    outboundAnchor: 0.25,
    tags: ['medium', 'distribution'],
    robots: const [
      RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'IR-01'),
      RobotSpawn(row: 16, col: 1, robotType: 'AMR', name: 'IR-02'),
      RobotSpawn(row: 9, col: 1, robotType: 'AMR', name: 'IR-03'),
      RobotSpawn(row: 1, col: 8, robotType: 'AMR', name: 'LR-01'),
      RobotSpawn(row: 16, col: 8, robotType: 'AMR', name: 'LR-02'),
      RobotSpawn(row: 1, col: 14, robotType: 'AMR', name: 'CR-01'),
      RobotSpawn(row: 16, col: 14, robotType: 'AMR', name: 'CR-02'),
      RobotSpawn(row: 1, col: 22, robotType: 'AMR', name: 'PR-01'),
      RobotSpawn(row: 16, col: 22, robotType: 'AMR', name: 'PR-02'),
      RobotSpawn(row: 1, col: 32, robotType: 'AMR', name: 'OR-01'),
      RobotSpawn(row: 16, col: 32, robotType: 'AMR', name: 'OR-02'),
    ],
  );
}

WarehouseConfig _buildMediumB() {
  const R = 20, C = 36, docks = 5, slots = 9;
  // budget=29 → loose=5 case=8 pallet=16
  return _make(
    name: 'Medium Distribution Center B',
    desc: '$C×$R | 5 bays | Mid dock □',
    rows: R,
    cols: C,
    docks: docks,
    stagingSlots: slots,
    looseCols: 5,
    caseCols: 8,
    palletCols: 16,
    outboundAnchor: 0.5,
    tags: ['medium', 'dual-dock'],
    robots: const [
      RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'IR-01'),
      RobotSpawn(row: 18, col: 1, robotType: 'AMR', name: 'IR-02'),
      RobotSpawn(row: 10, col: 1, robotType: 'AMR', name: 'IR-03'),
      RobotSpawn(row: 1, col: 8, robotType: 'AMR', name: 'LR-01'),
      RobotSpawn(row: 18, col: 8, robotType: 'AMR', name: 'LR-02'),
      RobotSpawn(row: 1, col: 14, robotType: 'AMR', name: 'CR-01'),
      RobotSpawn(row: 18, col: 14, robotType: 'AMR', name: 'CR-02'),
      RobotSpawn(row: 1, col: 23, robotType: 'AMR', name: 'PR-01'),
      RobotSpawn(row: 18, col: 23, robotType: 'AGV', name: 'PR-AGV'),
      RobotSpawn(row: 1, col: 34, robotType: 'AMR', name: 'OR-01'),
      RobotSpawn(row: 18, col: 34, robotType: 'AMR', name: 'OR-02'),
    ],
  );
}

WarehouseConfig _buildMediumC() {
  const R = 22, C = 40, docks = 6, slots = 10;
  // budget=33 → loose=5 case=9 pallet=19
  return _make(
    name: 'Medium Distribution Center C',
    desc: '$C×$R | 6 bays | Bottom dock ▽',
    rows: R,
    cols: C,
    docks: docks,
    stagingSlots: slots,
    looseCols: 5,
    caseCols: 9,
    palletCols: 19,
    outboundAnchor: 0.75,
    tags: ['medium', 'conveyor'],
    robots: const [
      RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'IR-01'),
      RobotSpawn(row: 20, col: 1, robotType: 'AMR', name: 'IR-02'),
      RobotSpawn(row: 11, col: 1, robotType: 'AMR', name: 'IR-03'),
      RobotSpawn(row: 1, col: 8, robotType: 'AMR', name: 'LR-01'),
      RobotSpawn(row: 20, col: 8, robotType: 'AMR', name: 'LR-02'),
      RobotSpawn(row: 1, col: 16, robotType: 'AMR', name: 'CR-01'),
      RobotSpawn(row: 20, col: 16, robotType: 'AMR', name: 'CR-02'),
      RobotSpawn(row: 1, col: 26, robotType: 'AMR', name: 'PR-01'),
      RobotSpawn(row: 20, col: 26, robotType: 'AGV', name: 'PR-AGV'),
      RobotSpawn(row: 1, col: 38, robotType: 'AMR', name: 'OR-01'),
      RobotSpawn(row: 20, col: 38, robotType: 'AMR', name: 'OR-02'),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// LARGE TEMPLATES  cols 48-58  rows 24-30  docks 6-8  staging 10
// ─────────────────────────────────────────────────────────────────────────────

WarehouseConfig _buildLargeA() {
  const R = 24, C = 48, docks = 6, slots = 10;
  // budget=41 → loose=6 case=12 pallet=23
  return _make(
    name: 'Large Fulfilment Center A',
    desc: '$C×$R | 6 bays | Top dock △',
    rows: R,
    cols: C,
    docks: docks,
    stagingSlots: slots,
    looseCols: 6,
    caseCols: 12,
    palletCols: 23,
    outboundAnchor: 0.25,
    tags: ['large', 'enterprise', 'agv'],
    robots: const [
      RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'IR-01'),
      RobotSpawn(row: 22, col: 1, robotType: 'AMR', name: 'IR-02'),
      RobotSpawn(row: 12, col: 1, robotType: 'AMR', name: 'IR-03'),
      RobotSpawn(row: 1, col: 9, robotType: 'AMR', name: 'LR-01'),
      RobotSpawn(row: 22, col: 9, robotType: 'AMR', name: 'LR-02'),
      RobotSpawn(row: 1, col: 17, robotType: 'AMR', name: 'CR-01'),
      RobotSpawn(row: 22, col: 17, robotType: 'AMR', name: 'CR-02'),
      RobotSpawn(row: 1, col: 30, robotType: 'AMR', name: 'PR-01'),
      RobotSpawn(row: 22, col: 30, robotType: 'AGV', name: 'PR-AGV1'),
      RobotSpawn(row: 12, col: 30, robotType: 'AGV', name: 'PR-AGV2'),
      RobotSpawn(row: 1, col: 46, robotType: 'AMR', name: 'OR-01'),
      RobotSpawn(row: 22, col: 46, robotType: 'AMR', name: 'OR-02'),
      RobotSpawn(row: 12, col: 46, robotType: 'AMR', name: 'OR-03'),
    ],
  );
}

WarehouseConfig _buildLargeB() {
  const R = 26, C = 52, docks = 7, slots = 10;
  // budget=45 → loose=6 case=12 pallet=27
  return _make(
    name: 'Large Fulfilment Center B',
    desc: '$C×$R | 7 bays | Mid dock □',
    rows: R,
    cols: C,
    docks: docks,
    stagingSlots: slots,
    looseCols: 6,
    caseCols: 12,
    palletCols: 27,
    outboundAnchor: 0.5,
    tags: ['large', 'high-throughput'],
    robots: const [
      RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'IR-01'),
      RobotSpawn(row: 24, col: 1, robotType: 'AMR', name: 'IR-02'),
      RobotSpawn(row: 13, col: 1, robotType: 'AMR', name: 'IR-03'),
      RobotSpawn(row: 1, col: 9, robotType: 'AMR', name: 'LR-01'),
      RobotSpawn(row: 24, col: 9, robotType: 'AMR', name: 'LR-02'),
      RobotSpawn(row: 1, col: 18, robotType: 'AMR', name: 'CR-01'),
      RobotSpawn(row: 24, col: 18, robotType: 'AMR', name: 'CR-02'),
      RobotSpawn(row: 1, col: 32, robotType: 'AMR', name: 'PR-01'),
      RobotSpawn(row: 24, col: 32, robotType: 'AGV', name: 'PR-AGV1'),
      RobotSpawn(row: 13, col: 32, robotType: 'AGV', name: 'PR-AGV2'),
      RobotSpawn(row: 1, col: 50, robotType: 'AMR', name: 'OR-01'),
      RobotSpawn(row: 24, col: 50, robotType: 'AMR', name: 'OR-02'),
      RobotSpawn(row: 13, col: 50, robotType: 'AMR', name: 'OR-03'),
    ],
  );
}

WarehouseConfig _buildLargeC() {
  const R = 28, C = 56, docks = 8, slots = 10;
  // budget=49 → loose=6 case=14 pallet=29
  return _make(
    name: 'Large Fulfilment Center C',
    desc: '$C×$R | 8 bays | Bottom dock ▽',
    rows: R,
    cols: C,
    docks: docks,
    stagingSlots: slots,
    looseCols: 6,
    caseCols: 14,
    palletCols: 29,
    outboundAnchor: 0.75,
    tags: ['large', 'gated'],
    robots: const [
      RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'IR-01'),
      RobotSpawn(row: 26, col: 1, robotType: 'AMR', name: 'IR-02'),
      RobotSpawn(row: 14, col: 1, robotType: 'AMR', name: 'IR-03'),
      RobotSpawn(row: 1, col: 9, robotType: 'AMR', name: 'LR-01'),
      RobotSpawn(row: 26, col: 9, robotType: 'AMR', name: 'LR-02'),
      RobotSpawn(row: 1, col: 20, robotType: 'AMR', name: 'CR-01'),
      RobotSpawn(row: 26, col: 20, robotType: 'AMR', name: 'CR-02'),
      RobotSpawn(row: 1, col: 37, robotType: 'AMR', name: 'PR-01'),
      RobotSpawn(row: 26, col: 37, robotType: 'AGV', name: 'PR-AGV1'),
      RobotSpawn(row: 14, col: 37, robotType: 'AGV', name: 'PR-AGV2'),
      RobotSpawn(row: 1, col: 54, robotType: 'AMR', name: 'OR-01'),
      RobotSpawn(row: 26, col: 54, robotType: 'AMR', name: 'OR-02'),
      RobotSpawn(row: 14, col: 54, robotType: 'AMR', name: 'OR-03'),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// COLD STORAGE TEMPLATES  (coldExtra=true → extra mid-row chargers)
// ─────────────────────────────────────────────────────────────────────────────

WarehouseConfig _buildColdA() {
  const R = 18, C = 34, docks = 4, slots = 7;
  // budget=27 → loose=5 case=8 pallet=14
  return _make(
    name: 'Cold Storage A',
    desc: '$C×$R | 4 bays | Top dock △',
    rows: R,
    cols: C,
    docks: docks,
    stagingSlots: slots,
    looseCols: 5,
    caseCols: 8,
    palletCols: 14,
    outboundAnchor: 0.25,
    tags: ['cold', 'frozen'],
    coldExtra: true,
    robots: const [
      RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'IR-01'),
      RobotSpawn(row: 16, col: 1, robotType: 'AMR', name: 'IR-02'),
      RobotSpawn(row: 9, col: 1, robotType: 'AMR', name: 'IR-03'),
      RobotSpawn(row: 1, col: 8, robotType: 'AMR', name: 'LR-01'),
      RobotSpawn(row: 16, col: 8, robotType: 'AMR', name: 'LR-02'),
      RobotSpawn(row: 1, col: 14, robotType: 'AMR', name: 'CR-01'),
      RobotSpawn(row: 1, col: 22, robotType: 'AMR', name: 'PR-01'),
      RobotSpawn(row: 16, col: 22, robotType: 'AGV', name: 'PR-AGV'),
      RobotSpawn(row: 1, col: 32, robotType: 'AMR', name: 'OR-01'),
      RobotSpawn(row: 16, col: 32, robotType: 'AMR', name: 'OR-02'),
    ],
  );
}

WarehouseConfig _buildColdB() {
  const R = 14, C = 28, docks = 3, slots = 6;
  // budget=21 → loose=4 case=7 pallet=10
  return _make(
    name: 'Cold Storage B',
    desc: '$C×$R | 3 bays | Mid dock □',
    rows: R,
    cols: C,
    docks: docks,
    stagingSlots: slots,
    looseCols: 4,
    caseCols: 7,
    palletCols: 10,
    outboundAnchor: 0.5,
    tags: ['cold', 'compact'],
    coldExtra: true,
    robots: const [
      RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'IR-01'),
      RobotSpawn(row: 12, col: 1, robotType: 'AMR', name: 'IR-02'),
      RobotSpawn(row: 1, col: 7, robotType: 'AMR', name: 'LR-01'),
      RobotSpawn(row: 12, col: 7, robotType: 'AMR', name: 'PR-01'),
      RobotSpawn(row: 1, col: 13, robotType: 'AMR', name: 'CR-01'),
      RobotSpawn(row: 1, col: 19, robotType: 'AMR', name: 'PR-02'),
      RobotSpawn(row: 1, col: 26, robotType: 'AMR', name: 'OR-01'),
      RobotSpawn(row: 12, col: 26, robotType: 'AMR', name: 'OR-02'),
    ],
  );
}

WarehouseConfig _buildColdC() {
  const R = 22, C = 44, docks = 6, slots = 10;
  // budget=37 → loose=5 case=10 pallet=22
  return _make(
    name: 'Cold Storage C',
    desc: '$C×$R | 6 bays | Bottom dock ▽',
    rows: R,
    cols: C,
    docks: docks,
    stagingSlots: slots,
    looseCols: 5,
    caseCols: 10,
    palletCols: 22,
    outboundAnchor: 0.75,
    tags: ['cold', 'large', 'multi-temp'],
    coldExtra: true,
    robots: const [
      RobotSpawn(row: 1, col: 1, robotType: 'AMR', name: 'IR-01'),
      RobotSpawn(row: 20, col: 1, robotType: 'AMR', name: 'IR-02'),
      RobotSpawn(row: 11, col: 1, robotType: 'AMR', name: 'IR-03'),
      RobotSpawn(row: 1, col: 8, robotType: 'AMR', name: 'LR-01'),
      RobotSpawn(row: 20, col: 8, robotType: 'AMR', name: 'LR-02'),
      RobotSpawn(row: 1, col: 16, robotType: 'AMR', name: 'CR-01'),
      RobotSpawn(row: 20, col: 16, robotType: 'AMR', name: 'CR-02'),
      RobotSpawn(row: 1, col: 27, robotType: 'AMR', name: 'PR-01'),
      RobotSpawn(row: 20, col: 27, robotType: 'AGV', name: 'PR-AGV1'),
      RobotSpawn(row: 11, col: 27, robotType: 'AGV', name: 'PR-AGV2'),
      RobotSpawn(row: 1, col: 42, robotType: 'AMR', name: 'OR-01'),
      RobotSpawn(row: 20, col: 42, robotType: 'AMR', name: 'OR-02'),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Blank canvas — a completely clear 56×28 all-path grid (large size).
// Every cell is an aisle so the user can paint from scratch.
// ─────────────────────────────────────────────────────────────────────────────
WarehouseConfig _buildBlankCanvas() {
  const R = 28, C = 56;
  final cells = _rect(0, 0, R - 1, C - 1, CellType.aisle);
  return WarehouseConfig(
    id: _uid(),
    name: 'Blank Canvas',
    description: 'All open paths — build from scratch',
    rows: R,
    cols: C,
    cells: cells,
    robotSpawns: [],
    zones: [],
    ownerId: '',
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Public catalogue
// ─────────────────────────────────────────────────────────────────────────────

final kWarehouseTemplates = <WarehouseTemplate>[
  const WarehouseTemplate(
    name: 'Small Warehouse A',
    description: '22×12 | 3 bays | Top dock ▲',
    rows: 12,
    cols: 22,
    tags: ['small'],
    builder: _buildSmallA,
  ),
  const WarehouseTemplate(
    name: 'Small Warehouse B',
    description: '24×14 | 3 bays | Mid dock ■',
    rows: 14,
    cols: 24,
    tags: ['small', 'cross-aisle'],
    builder: _buildSmallB,
  ),
  const WarehouseTemplate(
    name: 'Small Warehouse C',
    description: '26×16 | 4 bays | Bottom dock ▼',
    rows: 16,
    cols: 26,
    tags: ['small', 'high-density'],
    builder: _buildSmallC,
  ),
  const WarehouseTemplate(
    name: 'Medium Distribution Center A',
    description: '34×18 | 4 bays | Top dock ▲',
    rows: 18,
    cols: 34,
    tags: ['medium', 'distribution'],
    builder: _buildMediumA,
  ),
  const WarehouseTemplate(
    name: 'Medium Distribution Center B',
    description: '36×20 | 5 bays | Mid dock ■',
    rows: 20,
    cols: 36,
    tags: ['medium', 'dual-dock'],
    builder: _buildMediumB,
  ),
  const WarehouseTemplate(
    name: 'Medium Distribution Center C',
    description: '40×22 | 6 bays | Bottom dock ▼',
    rows: 22,
    cols: 40,
    tags: ['medium', 'conveyor'],
    builder: _buildMediumC,
  ),
  const WarehouseTemplate(
    name: 'Large Fulfilment Center A',
    description: '48×24 | 6 bays | Top dock ▲',
    rows: 24,
    cols: 48,
    tags: ['large', 'enterprise', 'agv'],
    builder: _buildLargeA,
  ),
  const WarehouseTemplate(
    name: 'Large Fulfilment Center B',
    description: '52×26 | 7 bays | Mid dock ■',
    rows: 26,
    cols: 52,
    tags: ['large', 'high-throughput'],
    builder: _buildLargeB,
  ),
  const WarehouseTemplate(
    name: 'Large Fulfilment Center C',
    description: '56×28 | 8 bays | Bottom dock ▼',
    rows: 28,
    cols: 56,
    tags: ['large', 'gated'],
    builder: _buildLargeC,
  ),
  const WarehouseTemplate(
    name: 'Cold Storage A',
    description: '34×18 | 4 bays | Top dock ▲',
    rows: 18,
    cols: 34,
    tags: ['cold', 'frozen'],
    builder: _buildColdA,
  ),
  const WarehouseTemplate(
    name: 'Cold Storage B',
    description: '28×14 | 3 bays | Mid dock ■',
    rows: 14,
    cols: 28,
    tags: ['cold', 'compact'],
    builder: _buildColdB,
  ),
  const WarehouseTemplate(
    name: 'Cold Storage C',
    description: '44×22 | 6 bays | Bottom dock ▼',
    rows: 22,
    cols: 44,
    tags: ['cold', 'large', 'multi-temp'],
    builder: _buildColdC,
  ),
  const WarehouseTemplate(
    name: 'Blank Canvas',
    description: '56×28 · All open paths — build from scratch',
    rows: 28,
    cols: 56,
    tags: ['blank', 'custom', 'large'],
    builder: _buildBlankCanvas,
  ),
];
