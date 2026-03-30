// warehouse_layout.dart
// Ported from: SyntWare/warehouse_core/models/sim_layout.py
// Pure data model — no network/DB/UI dependency.

/// A horizontal highway row — robots travel at full speed.
class Highway {
  final String id;
  final int row;
  const Highway({required this.id, required this.row});
}

/// A vertical aisle column — access corridor between racks.
class Aisle {
  final String id;
  final int col;
  const Aisle({required this.id, required this.col});
}

/// A horizontal pick aisle — robots travel perpendicular to rack faces.
class PickAisle {
  final String id;
  final int row;
  const PickAisle({required this.id, required this.row});
}

/// A storage zone grouping contiguous columns (e.g. cold, bulk, loose).
class Zone {
  final String id;
  final int colStart;
  final int colEnd;
  final String? label;
  const Zone(
      {required this.id,
      required this.colStart,
      required this.colEnd,
      this.label});
}

/// A station — named drop-off/pick-up point on the floor.
class Station {
  final String id;
  final (int, int) dropOff;
  const Station({required this.id, required this.dropOff});
}

/// A truck loading yard with dock bays.
class Yard {
  final String id;
  final int maxTrucks;
  const Yard({required this.id, required this.maxTrucks});
}

/// A robot charging station at a fixed grid cell.
class ChargeStation {
  final String id;
  final (int, int) cell;
  const ChargeStation({required this.id, required this.cell});
}

/// Complete layout configuration for one warehouse.
class WarehouseLayout {
  final String warehouseId;
  final int gridCols;
  final int gridRows;
  final List<Highway> highways;
  final List<Aisle> aisles;
  final List<PickAisle> pickAisles;
  final List<Zone> zones;
  final List<Station> stations;
  final List<Yard> yards;
  final List<ChargeStation> chargeStations;

  const WarehouseLayout({
    required this.warehouseId,
    required this.gridCols,
    required this.gridRows,
    required this.highways,
    required this.aisles,
    required this.pickAisles,
    required this.zones,
    required this.stations,
    required this.yards,
    required this.chargeStations,
  });

  Station? get outboundStation =>
      stations.where((s) => s.id == 'outbound').firstOrNull;

  Yard? get inboundYard =>
      yards.where((y) => y.id == 'yard_inbound').firstOrNull;

  ChargeStation? chargeStationById(String id) =>
      chargeStations.where((c) => c.id == id).firstOrNull;

  Zone? zoneAt(int col) =>
      zones.where((z) => col >= z.colStart && col <= z.colEnd).firstOrNull;

  /// Default 26×16 layout matching SyntWare warehouse_core defaults.
  static const WarehouseLayout defaultLayout = WarehouseLayout(
    warehouseId: 'wh_default',
    gridCols: 26,
    gridRows: 16,
    highways: [
      Highway(id: 'hw_top', row: 0),
      Highway(id: 'hw_bottom', row: 15),
    ],
    aisles: [
      Aisle(id: 'aisle_A', col: 0),
      Aisle(id: 'aisle_B', col: 1),
      Aisle(id: 'aisle_C', col: 2),
    ],
    pickAisles: [
      PickAisle(id: 'pick_top', row: 2),
      PickAisle(id: 'pick_mid', row: 8),
      PickAisle(id: 'pick_bot', row: 13),
    ],
    zones: [
      Zone(id: 'z_loose', colStart: 2, colEnd: 7, label: 'Loose'),
      Zone(id: 'z_case', colStart: 8, colEnd: 14, label: 'Case'),
      Zone(id: 'z_pallet', colStart: 15, colEnd: 22, label: 'Pallet'),
      Zone(id: 'z_bulk', colStart: 23, colEnd: 25, label: 'Bulk'),
    ],
    stations: [
      Station(id: 'outbound', dropOff: (22, 8)),
      Station(id: 'receiving', dropOff: (0, 13)),
    ],
    yards: [
      Yard(id: 'yard_inbound', maxTrucks: 5),
      Yard(id: 'yard_outbound', maxTrucks: 5),
    ],
    chargeStations: [
      ChargeStation(id: 'cs_0', cell: (32, 50)),
      ChargeStation(id: 'cs_1', cell: (32, 52)),
      ChargeStation(id: 'cs_2', cell: (32, 54)),
      ChargeStation(id: 'cs_3', cell: (32, 56)),
    ],
  );
}
