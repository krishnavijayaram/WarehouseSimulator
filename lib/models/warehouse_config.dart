/// warehouse_config.dart — Warehouse layout design model.
///
/// Supports serialisation to/from JSON (share-by-code),
/// and local persistence via SharedPreferences.
library;

import 'dart:convert';
import 'package:flutter/material.dart';

// ── Cell taxonomy ─────────────────────────────────────────────────────────────

enum CellType {
  empty,
  rackLoose,
  rackCase,
  rackPallet,
  aisle,
  crossAisle,
  packStation,
  labelStation,
  looseStaging,
  caseStaging,
  palletStaging,
  outbound,
  inbound,
  charging,
  dock,
  obstacle,
  conveyorH,
  conveyorV,
  // ── Road / path types ────────────────────────────────────────────────────
  roadH,        // horizontal road  ─
  roadV,        // vertical road    │
  roadCornerNE, // corner: open top + right  ↱
  roadCornerNW, // corner: open top + left   ↰
  roadCornerSE, // corner: open bottom + right ↳
  roadCornerSW, // corner: open bottom + left  ↲
  robotPath,    // default robot travel path (saffron dot)
  // ── Operational floor elements ────────────────────────────────────────────
  dump,         // 25 – end-of-line discard; items here are finalised/disposed
  conveyorE,    // 26 – conveyor belt flowing east  →
  conveyorW,    // 27 – conveyor belt flowing west  ←
  conveyorN,    // 28 – conveyor belt flowing north ↑
  conveyorS,    // 29 – conveyor belt flowing south ↓
  chargingFast, // 30 – high-speed dock (~20 min full charge)
  chargingSlow, // 31 – trickle / opportunity charger (~90 min full charge)
  tree,         // 32 – structural column, pillar, or decorative tree (fixed obstacle)
}

extension CellTypeX on CellType {
  String get label => switch (this) {
    CellType.empty        => 'Empty',
    CellType.rackLoose    => 'Rack',              // unified — zone defines pick type
    CellType.rackCase     => 'Rack (legacy)',      // backward-compat; not in palette
    CellType.rackPallet   => 'Rack (legacy)',      // backward-compat; not in palette
    CellType.aisle        => 'Aisle',
    CellType.crossAisle   => 'Aisle (legacy)',     // backward-compat; renders as aisle
    CellType.packStation  => 'Pack Station',
    CellType.labelStation => 'Label Station',
    CellType.looseStaging => 'Staging (legacy)',   // not in palette
    CellType.caseStaging  => 'Staging (legacy)',   // not in palette
    CellType.palletStaging=> 'Pallet Staging',
    CellType.outbound     => 'Outbound Dock',
    CellType.inbound      => 'Inbound Dock',
    CellType.charging     => 'Charging (legacy)',  // not in palette
    CellType.dock         => 'Truck Bay',
    CellType.obstacle     => 'Obstacle',
    CellType.conveyorH    => 'Conveyor H (legacy)',// not in palette
    CellType.conveyorV    => 'Conveyor V (legacy)',// not in palette
    CellType.roadH        => 'Road ─',
    CellType.roadV        => 'Road │',
    CellType.roadCornerNE => 'Corner ↱',
    CellType.roadCornerNW => 'Corner ↰',
    CellType.roadCornerSE => 'Corner ↳',
    CellType.roadCornerSW => 'Corner ↲',
    CellType.robotPath    => 'Robot Path',
    CellType.dump         => 'Dump',
    CellType.conveyorE    => 'Conveyor →',
    CellType.conveyorW    => 'Conveyor ←',
    CellType.conveyorN    => 'Conveyor ↑',
    CellType.conveyorS    => 'Conveyor ↓',
    CellType.chargingFast => 'Fast Charger',
    CellType.chargingSlow => 'Slow Charger',
    CellType.tree         => 'Tree / Pillar',
  };

  Color get color => switch (this) {
    CellType.empty        => const Color(0xFF050A0F),   // near-black
    // ── Rack types ── each a clearly distinct family ──────────────────────
    CellType.rackPallet   => const Color(0xFFB45309),   // amber-700  – pallet (gold/value)
    CellType.rackCase     => const Color(0xFF1D4ED8),   // blue-700   – case   (cool, ordered)
    CellType.rackLoose    => const Color(0xFF15803D),   // green-700  – loose  (fresh, accessible)
    // ── Navigation ────────────────────────────────────────────────────────
    CellType.aisle        => const Color(0xFF0F172A),   // slate-900  – main lane
    CellType.crossAisle   => const Color(0xFF1E293B),   // slate-800  – cross lane
    // ── I/O stations ──────────────────────────────────────────────────────
    CellType.inbound      => const Color(0xFF0F766E),   // teal-700   – receiving (trust/in)
    CellType.outbound     => const Color(0xFFB91C1C),   // red-700    – shipping  (urgency/out)
    CellType.dock         => const Color(0xFF1E3A8A),   // blue-900   – truck bay (dark authority)
    CellType.palletStaging=> const Color(0xFF6D28D9),   // violet-700 – SKU buffer
    CellType.looseStaging => const Color(0xFF6D28D9).withAlpha(100),
    CellType.caseStaging  => const Color(0xFF1D4ED8).withAlpha(100),
    // ── Workstations ──────────────────────────────────────────────────────
    CellType.packStation  => const Color(0xFFBE185D),   // pink-700   – packing energy
    CellType.labelStation => const Color(0xFF7E22CE),   // purple-700 – labelling info
    // ── Charging ──────────────────────────────────────────────────────────
    CellType.charging     => const Color(0xFFF59E0B),   // amber-400  – generic charger
    CellType.chargingFast => const Color(0xFFF59E0B),   // amber-400  – fast (bright/electric)
    CellType.chargingSlow => const Color(0xFF475569),   // slate-600  – slow/trickle (grey)
    // ── Conveyors ─────────────────────────────────────────────────────────
    CellType.conveyorH    => const Color(0xFF0E7490),   // cyan-700
    CellType.conveyorV    => const Color(0xFF0E7490),
    CellType.conveyorE    => const Color(0xFF0E7490),
    CellType.conveyorW    => const Color(0xFF0369A1),
    CellType.conveyorN    => const Color(0xFF0891B2),
    CellType.conveyorS    => const Color(0xFF0284C7),
    // ── Road / External ───────────────────────────────────────────────────
    CellType.roadH        => const Color(0xFF111827),   // gray-900  – asphalt
    CellType.roadV        => const Color(0xFF111827),
    CellType.roadCornerNE => const Color(0xFF111827),
    CellType.roadCornerNW => const Color(0xFF111827),
    CellType.roadCornerSE => const Color(0xFF111827),
    CellType.roadCornerSW => const Color(0xFF111827),
    CellType.robotPath    => const Color(0xFF0D1520),
    // ── Utility ───────────────────────────────────────────────────────────
    CellType.obstacle     => const Color(0xFF374151),   // gray-700
    CellType.dump         => const Color(0xFF7F1D1D),   // red-900    – deep crimson
    CellType.tree         => const Color(0xFF14532D),   // green-900  – deep forest
  };

  bool get isRack => this == CellType.rackLoose ||
      this == CellType.rackCase || this == CellType.rackPallet;
  // outbound dock lane is navigatable — outbound robots transit through it
  bool get isWalkable => this == CellType.aisle || this == CellType.crossAisle ||
      isRoad || this == CellType.robotPath || this == CellType.outbound;
  bool get isRoad => this == CellType.roadH || this == CellType.roadV ||
      this == CellType.roadCornerNE || this == CellType.roadCornerNW ||
      this == CellType.roadCornerSE || this == CellType.roadCornerSW;
  bool get isConveyor =>
      this == CellType.conveyorH || this == CellType.conveyorV ||
      this == CellType.conveyorE || this == CellType.conveyorW ||
      this == CellType.conveyorN || this == CellType.conveyorS;
  bool get isCharger => this == CellType.charging ||
      this == CellType.chargingFast || this == CellType.chargingSlow;

  // ── Robot movement domain rules ──────────────────────────────────────────
  //  packStation   : like a rack — NOT navigatable; approached from adjacent path.
  //                  Pallet/case/loose pick robots drop items here via aisle path.
  //                  Outbound robot collects from here (arrives via outbound dock).
  //  outbound dock : navigatable — outbound robot transits it to reach pack/truck.
  //  Pick robots   : path OR charger OR packStation (approach face from aisle)
  //  Inbound robot : inbound dock OR charger OR path
  //  Outbound robot: path (incl. outbound dock) OR dock OR packStation OR charger
  bool get isPickRobotDomain  => isWalkable || isCharger || this == CellType.packStation;
  bool get isInboundRobotDomain  =>
      this == CellType.inbound || this == CellType.dock ||
      isCharger || isWalkable;
  bool get isOutboundRobotDomain =>
      this == CellType.outbound || this == CellType.dock ||
      this == CellType.packStation || isCharger || isWalkable;

  // ── Charger placement constraint ─────────────────────────────────────────
  // A cell is a valid charger position when the caller verifies:
  //   • ≥ 3 of its 4 orthogonal neighbours are free (empty/aisle/path)
  //   • ≥ 4 path cells exist in its immediate 3×3 neighbourhood
  // (Enforced in the creator screen _canPlaceCharger helper.)

  // ── Aisle/rack placement constraint ──────────────────────────────────────
  // An aisle or rack cell must have at least one orthogonal neighbour that
  // is a path cell (aisle, crossAisle, robotPath, or road).
  // (Enforced in the creator screen _hasAdjacentPath helper.)
}

// ── Pick-zone taxonomy (matching ops_simulator zone names exactly) ─────────-

enum PickZoneType {
  pallet,   // 'Pallet'     — PAL/AGV robots; gold   #FFD700
  casePick, // 'Case Pick'  — CS robots;      green  #00FF88
  loosePick,// 'Loose Pick' — LS robots;      purple #B088FF
}

extension PickZoneTypeX on PickZoneType {
  String get label => switch (this) {
    PickZoneType.pallet   => 'Pallet',
    PickZoneType.casePick => 'Case Pick',
    PickZoneType.loosePick=> 'Loose Pick',
  };

  Color get color => switch (this) {
    PickZoneType.pallet   => const Color(0xFFB45309), // amber-700 — matches rackPallet
    PickZoneType.casePick => const Color(0xFF1D4ED8), // blue-700  — matches rackCase
    PickZoneType.loosePick=> const Color(0xFF15803D), // green-700 — matches rackLoose
  };

  /// Icon used in menus / labels
  String get icon => switch (this) {
    PickZoneType.pallet   => '🟨',
    PickZoneType.casePick => '🟩',
    PickZoneType.loosePick=> '🟪',
  };
}

// ── Pick zone rectangular area definition ────────────────────────────────────

class PickZoneDef {
  const PickZoneDef({
    required this.type,
    required this.rowStart,
    required this.rowEnd,
    required this.colStart,
    required this.colEnd,
    this.label,
  });

  final PickZoneType type;
  final int rowStart, rowEnd; // inclusive row bounds
  final int colStart, colEnd; // inclusive col bounds
  final String? label;

  bool containsCell(int row, int col) =>
      row >= rowStart && row <= rowEnd &&
      col >= colStart && col <= colEnd;

  /// Legacy helper used by some callers — checks col only (row-agnostic).
  bool containsCol(int col) => col >= colStart && col <= colEnd;

  Map<String, dynamic> toJson() => {
    'zt':  type.index,
    'rs':  rowStart,
    're':  rowEnd,
    'cs':  colStart,
    'ce':  colEnd,
    if (label != null) 'l': label,
  };

  factory PickZoneDef.fromJson(Map<String, dynamic> j) => PickZoneDef(
    type:     PickZoneType.values[j['zt'] as int],
    rowStart: j['rs'] as int? ?? 0,
    rowEnd:   j['re'] as int? ?? 999,
    colStart: j['cs'] as int,
    colEnd:   j['ce'] as int,
    label:    j['l']  as String?,
  );

  PickZoneDef copyWith({
    PickZoneType? type,
    int? rowStart, int? rowEnd,
    int? colStart, int? colEnd,
    String? label,
  }) => PickZoneDef(
    type:     type     ?? this.type,
    rowStart: rowStart ?? this.rowStart,
    rowEnd:   rowEnd   ?? this.rowEnd,
    colStart: colStart ?? this.colStart,
    colEnd:   colEnd   ?? this.colEnd,
    label:    label    ?? this.label,
  );
}


class WarehouseCell {
  WarehouseCell({
    required this.row,
    required this.col,
    required this.type,
    this.label,
    this.levels = 1,
    this.destId,
    this.skuId,
    this.quantity = 0,
    int? maxQuantity,
  }) : maxQuantity = maxQuantity ?? _defaultMaxQty(type);

  final int    row, col;
  final CellType type;
  final String?  label;
  final int      levels; // rack height levels
  /// Conveyor destination: order-group location ID.
  final String?  destId;

  // ── Rack inventory (set during CRAFT stage) ───────────────────────────────
  /// SKU assigned to this rack cell.
  /// For CASE/LOOSE: dedicated to one SKU once set.
  /// For PALLET: the current pallet's SKU. Null = unassigned / empty.
  final String? skuId;

  /// Current quantity held in this rack cell.
  /// Unit: pallets for rackPallet, pallet-case-equiv for rackCase,
  ///       pallet-loose-equiv for rackLoose.
  final int     quantity;

  /// Maximum capacity of this rack cell (configurable; defaults by type).
  /// Pallet = 5, Case = 2, Loose = 2.
  final int     maxQuantity;

  // ── Helpers ───────────────────────────────────────────────────────────────
  /// Fill fraction 0.0–1.0.
  double get fillFraction =>
      maxQuantity > 0 ? (quantity / maxQuantity).clamp(0.0, 1.0) : 0.0;

  /// True when needs replenishment (below 50% of capacity).
  bool get needsReplenishment =>
      type.isRack && maxQuantity > 0 && quantity < maxQuantity * 0.5;

  /// True when the rack is completely empty.
  bool get isEmpty => quantity == 0;

  /// True when the rack is at full capacity.
  bool get isFull => quantity >= maxQuantity;

  static int _defaultMaxQty(CellType t) {
    if (t == CellType.rackPallet) return 5;
    if (t == CellType.rackCase)   return 2;
    if (t == CellType.rackLoose)  return 2;
    return 0;
  }

  Map<String, dynamic> toJson() => {
    'r': row, 'c': col, 't': type.index,
    if (label    != null) 'l':  label,
    if (levels   != 1)    'lv': levels,
    if (destId   != null) 'di': destId,
    if (skuId    != null) 'si': skuId,
    if (quantity != 0)    'q':  quantity,
    if (maxQuantity != _defaultMaxQty(type)) 'mq': maxQuantity,
  };

  factory WarehouseCell.fromJson(Map<String, dynamic> j) {
    final t = CellType.values[j['t'] as int];
    return WarehouseCell(
      row:         j['r']  as int,
      col:         j['c']  as int,
      type:        t,
      label:       j['l']  as String?,
      levels:      j['lv'] as int? ?? 1,
      destId:      j['di'] as String?,
      skuId:       j['si'] as String?,
      quantity:    j['q']  as int? ?? 0,
      maxQuantity: j['mq'] as int? ?? _defaultMaxQty(t),
    );
  }

  WarehouseCell copyWith({
    CellType? type,
    String? label,
    int? levels,
    String? destId,
    String? skuId,
    int? quantity,
    int? maxQuantity,
    bool clearSku = false,
  }) =>
      WarehouseCell(
        row: row, col: col,
        type:        type        ?? this.type,
        label:       label       ?? this.label,
        levels:      levels      ?? this.levels,
        destId:      destId      ?? this.destId,
        skuId:       clearSku ? null : (skuId ?? this.skuId),
        quantity:    quantity    ?? this.quantity,
        maxQuantity: maxQuantity ?? this.maxQuantity,
      );
}

// ── Robot spawn point ─────────────────────────────────────────────────────────

class RobotSpawn {
  const RobotSpawn({
    required this.row,
    required this.col,
    required this.robotType,
    this.name,
  });

  final int    row, col;
  final String robotType; // AMR | AGV
  final String? name;

  Map<String, dynamic> toJson() => {
    'r': row, 'c': col, 't': robotType,
    if (name != null) 'n': name,
  };

  factory RobotSpawn.fromJson(Map<String, dynamic> j) => RobotSpawn(
    row:       j['r'] as int,
    col:       j['c'] as int,
    robotType: j['t'] as String,
    name:      j['n'] as String?,
  );
}

// ── Truck cargo item ─────────────────────────────────────────────────────────

class TruckCargoItem {
  const TruckCargoItem({
    required this.skuId,
    required this.quantity,
    required this.unitType,
    this.poRef,
    this.orderRef,
  });

  final String skuId;
  final int    quantity;
  final String unitType;   // 'PALLET' | 'CASE' | 'LOOSE'
  final String? poRef;     // inbound PO reference
  final String? orderRef;  // outbound order reference

  Map<String, dynamic> toJson() => {
    'si': skuId,
    'q':  quantity,
    'ut': unitType,
    if (poRef    != null) 'po': poRef,
    if (orderRef != null) 'or': orderRef,
  };

  factory TruckCargoItem.fromJson(Map<String, dynamic> j) => TruckCargoItem(
    skuId:    j['si'] as String,
    quantity: j['q']  as int,
    unitType: j['ut'] as String? ?? 'PALLET',
    poRef:    j['po'] as String?,
    orderRef: j['or'] as String?,
  );

  TruckCargoItem copyWith({int? quantity}) => TruckCargoItem(
    skuId:    skuId,
    quantity: quantity ?? this.quantity,
    unitType: unitType,
    poRef:    poRef,
    orderRef: orderRef,
  );
}

// ── Truck spawn (initial truck state at publish) ───────────────────────────────

enum TruckType { inbound, outbound }

extension TruckTypeX on TruckType {
  String get label => this == TruckType.inbound ? 'Inbound' : 'Outbound';
  String get icon  => this == TruckType.inbound ? '🟢' : '🔴';
  String get apiKey => this == TruckType.inbound ? 'INBOUND' : 'OUTBOUND';
}

class TruckSpawn {
  const TruckSpawn({
    required this.truckId,
    required this.dockRow,
    required this.dockCol,
    required this.truckType,
    this.carrierName,
    this.cargo = const [],
  });

  final String truckId;
  final int    dockRow;
  final int    dockCol;
  final TruckType truckType;
  final String? carrierName;
  final List<TruckCargoItem> cargo;

  Map<String, dynamic> toJson() => {
    'tid': truckId,
    'dr':  dockRow,
    'dc':  dockCol,
    'tt':  truckType.apiKey,
    if (carrierName != null) 'cn': carrierName,
    if (cargo.isNotEmpty) 'cg': cargo.map((i) => i.toJson()).toList(),
  };

  factory TruckSpawn.fromJson(Map<String, dynamic> j) => TruckSpawn(
    truckId:     j['tid'] as String,
    dockRow:     j['dr']  as int,
    dockCol:     j['dc']  as int,
    truckType:   (j['tt'] as String? ?? 'INBOUND') == 'INBOUND'
                     ? TruckType.inbound
                     : TruckType.outbound,
    carrierName: j['cn'] as String?,
    cargo: ((j['cg'] as List?) ?? [])
        .map((e) => TruckCargoItem.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  TruckSpawn copyWith({
    String? carrierName,
    List<TruckCargoItem>? cargo,
  }) => TruckSpawn(
    truckId:     truckId,
    dockRow:     dockRow,
    dockCol:     dockCol,
    truckType:   truckType,
    carrierName: carrierName ?? this.carrierName,
    cargo:       cargo       ?? this.cargo,
  );
}

// ── Warehouse configuration ───────────────────────────────────────────────────

class WarehouseConfig {
  WarehouseConfig({
    required this.id,
    required this.name,
    required this.rows,
    required this.cols,
    required this.cells,
    required this.robotSpawns,
    required this.ownerId,
    required this.description,
    List<PickZoneDef>? zones,
    List<TruckSpawn>?  truckSpawns,
    DateTime? createdAt,
  })  : zones       = zones       ?? const [],
        truckSpawns = truckSpawns ?? const [],
        createdAt   = createdAt   ?? DateTime.now();

  final String id;
  final String name;
  final String description;
  final int rows, cols;
  final List<WarehouseCell> cells;
  final List<RobotSpawn>   robotSpawns;
  final List<PickZoneDef>  zones;        // pick-zone column bands
  final List<TruckSpawn>   truckSpawns;  // trucks present at publish
  final String ownerId;
  final DateTime createdAt;

  // ── Accessors ────────────────────────────────────────────────────────────

  WarehouseCell? cellAt(int row, int col) {
    for (final c in cells) {
      if (c.row == row && c.col == col) return c;
    }
    return null;
  }

  CellType typeAt(int row, int col) =>
      cellAt(row, col)?.type ?? CellType.empty;

  /// Returns the pick zone type for a given cell, or null if unassigned.
  PickZoneType? zoneForCell(int row, int col) {
    for (final z in zones) {
      if (z.containsCell(row, col)) return z.type;
    }
    return null;
  }

  /// Legacy column-only lookup (kept for compatibility).
  PickZoneType? zoneForCol(int col) {
    for (final z in zones) {
      if (z.containsCol(col)) return z.type;
    }
    return null;
  }

  // ── Mutations ─────────────────────────────────────────────────────────────

  WarehouseConfig setCell(WarehouseCell cell) {
    final updated = cells.where((c) => !(c.row == cell.row && c.col == cell.col)).toList()
      ..add(cell);
    return copyWith(cells: updated);
  }

  WarehouseConfig clearCell(int row, int col) {
    return copyWith(
      cells: cells.where((c) => !(c.row == row && c.col == col)).toList(),
    );
  }

  /// Assign a rectangular area to a pick zone, removing any overlapping zones.
  WarehouseConfig setZone(PickZoneDef zone) {
    bool overlaps(PickZoneDef z) =>
        z.rowStart <= zone.rowEnd   && z.rowEnd   >= zone.rowStart &&
        z.colStart <= zone.colEnd   && z.colEnd   >= zone.colStart;
    final filtered = zones.where((z) => !overlaps(z)).toList()..add(zone);
    return copyWith(zones: filtered);
  }

  /// Remove all zones that contain the given cell.
  WarehouseConfig removeZoneForCell(int row, int col) {
    return copyWith(
      zones: zones.where((z) => !z.containsCell(row, col)).toList(),
    );
  }

  /// Remove all zones that contain [col] in any row (legacy).
  WarehouseConfig removeZoneForCol(int col) {
    return copyWith(
      zones: zones.where((z) => !z.containsCol(col)).toList(),
    );
  }

  WarehouseConfig copyWith({
    String? id,
    String? name,
    String? description,
    String? ownerId,
    List<WarehouseCell>? cells,
    List<RobotSpawn>?   robotSpawns,
    List<PickZoneDef>?  zones,
    List<TruckSpawn>?   truckSpawns,
  }) => WarehouseConfig(
    id:          id          ?? this.id,
    name:        name        ?? this.name,
    description: description ?? this.description,
    rows:        rows,
    cols:        cols,
    cells:       cells       ?? this.cells,
    robotSpawns: robotSpawns ?? this.robotSpawns,
    zones:       zones       ?? this.zones,
    truckSpawns: truckSpawns ?? this.truckSpawns,
    ownerId:     ownerId     ?? this.ownerId,
    createdAt:   createdAt,
  );

  // ── Serialisation ─────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
    'id':      id,
    'name':    name,
    'desc':    description,
    'rows':    rows,
    'cols':    cols,
    'cells':   cells.map((c) => c.toJson()).toList(),
    'spawns':  robotSpawns.map((r) => r.toJson()).toList(),
    'zones':   zones.map((z) => z.toJson()).toList(),
    if (truckSpawns.isNotEmpty)
      'trucks': truckSpawns.map((t) => t.toJson()).toList(),
    'owner':   ownerId,
    'created': createdAt.toIso8601String(),
  };

  factory WarehouseConfig.fromJson(Map<String, dynamic> j) => WarehouseConfig(
    id:          j['id']   as String,
    name:        j['name'] as String,
    description: j['desc'] as String? ?? '',
    rows:        j['rows'] as int,
    cols:        j['cols'] as int,
    cells:       (j['cells'] as List)
        .map((e) => WarehouseCell.fromJson(e as Map<String, dynamic>))
        .toList(),
    robotSpawns: (j['spawns'] as List)
        .map((e) => RobotSpawn.fromJson(e as Map<String, dynamic>))
        .toList(),
    zones:       ((j['zones'] as List?) ?? [])
        .map((e) => PickZoneDef.fromJson(e as Map<String, dynamic>))
        .toList(),
    truckSpawns: ((j['trucks'] as List?) ?? [])
        .map((e) => TruckSpawn.fromJson(e as Map<String, dynamic>))
        .toList(),
    ownerId:     j['owner']   as String? ?? '',
    createdAt:   DateTime.tryParse(j['created'] as String? ?? '') ?? DateTime.now(),
  );

  /// Encode as URL-safe base64 for sharing.
  String toShareCode() =>
      base64Url.encode(utf8.encode(jsonEncode(toJson())));

  /// Decode a share code (returns null on parse failure).
  static WarehouseConfig? fromShareCode(String code) {
    try {
      final decoded = utf8.decode(base64Url.decode(code));
      return WarehouseConfig.fromJson(
          jsonDecode(decoded) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  // ── Stats ─────────────────────────────────────────────────────────────────

  int get cellCount     => cells.length;
  int get rackCount     => cells.where((c) => c.type.isRack).length;
  int get aisleCount    => cells.where((c) => c.type.isWalkable).length;
  int get chargingCount => cells.where((c) => c.type == CellType.charging).length;
  int get zoneCount     => zones.length;
}
