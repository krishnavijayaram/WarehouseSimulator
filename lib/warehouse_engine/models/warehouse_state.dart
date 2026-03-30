// warehouse_state.dart
// Ported from: ops_simulator/engine/state.py + SyntWare warehouse_core models
// Pure data model — no network/DB/UI dependency.

import 'dart:math';

/// Inventory classification (ABC analysis).
enum AbcClass { a, b, c }

/// Dock type.
enum DockType { inbound, outbound, staging }

/// Represents one bin (storage slot) on the warehouse floor.
class Bin {
  final String id;
  final String rack;
  final int position;
  final bool isOccupied;
  final String? skuId;
  final String? zone;
  final (int, int)? faceCell; // Grid cell where robot interacts with this bin

  const Bin({
    required this.id,
    required this.rack,
    required this.position,
    required this.isOccupied,
    this.skuId,
    this.zone,
    this.faceCell,
  });

  factory Bin.fromJson(Map<String, dynamic> json) => Bin(
        id: json['bin_id'] as String,
        rack: json['rack'] as String? ?? '',
        position: json['position'] as int? ?? 0,
        isOccupied: json['is_occupied_actual'] as bool? ?? false,
        skuId: json['assigned_sku_actual'] as String?,
        zone: json['zone'] as String?,
      );
}

/// A pallet sitting on a dock.
class Pallet {
  final String skuId;
  final double weightKg;
  final int quantity;
  final String status; // 'PACKED' | 'STAGED' | 'LOADED'

  const Pallet({
    required this.skuId,
    required this.weightKg,
    required this.quantity,
    this.status = 'PACKED',
  });
}

/// A truck docked at a yard bay.
class Truck {
  final String id;
  final String type; // 'S' | 'M' | 'L' | 'XL'
  final String status; // 'ARRIVING' | 'DOCKED' | 'LOADING' | 'DEPARTING'
  final String? dockId;

  const Truck({
    required this.id,
    required this.type,
    required this.status,
    this.dockId,
  });

  factory Truck.fromJson(Map<String, dynamic> json) => Truck(
        id: json['truck_id'] as String,
        type: json['truck_type'] as String? ?? 'M',
        status: json['status'] as String? ?? 'DOCKED',
        dockId: json['dock_id'] as String?,
      );
}

/// A dock bay in the yard.
class Dock {
  final String id;
  final DockType type;
  final bool isOccupied;
  final String? truckId;

  const Dock({
    required this.id,
    required this.type,
    required this.isOccupied,
    this.truckId,
  });

  factory Dock.fromJson(Map<String, dynamic> json) => Dock(
        id: json['dock_id'] as String,
        type: json['dock_type'] == 'OUTBOUND'
            ? DockType.outbound
            : DockType.inbound,
        isOccupied: json['is_occupied_actual'] as bool? ?? false,
        truckId: json['truck_id'] as String?,
      );
}

/// An active pick task (one SKU to move from bin to staging).
class PickTask {
  final String taskId;
  final String orderId;
  final String skuId;
  final String binId;
  final String status; // 'PENDING' | 'ASSIGNED' | 'COMPLETE'

  const PickTask({
    required this.taskId,
    required this.orderId,
    required this.skuId,
    required this.binId,
    required this.status,
  });
}

/// In-memory snapshot of the full warehouse state.
/// Updated by polling the WIOS API and used by the local simulation engine.
class WarehouseState {
  List<Bin> bins;
  List<Truck> trucks;
  List<Dock> docks;
  List<PickTask> pickTasks;
  Map<String, Bin> binMap;
  Map<String, List<Pallet>> dockPallets;
  DateTime refreshedAt;

  WarehouseState({
    List<Bin>? bins,
    List<Truck>? trucks,
    List<Dock>? docks,
    List<PickTask>? pickTasks,
  })  : bins = bins ?? [],
        trucks = trucks ?? [],
        docks = docks ?? [],
        pickTasks = pickTasks ?? [],
        binMap = {},
        dockPallets = {},
        refreshedAt = DateTime.now() {
    _rebuild();
  }

  void update({
    List<Bin>? bins,
    List<Truck>? trucks,
    List<Dock>? docks,
    List<PickTask>? pickTasks,
  }) {
    if (bins != null) this.bins = bins;
    if (trucks != null) this.trucks = trucks;
    if (docks != null) this.docks = docks;
    if (pickTasks != null) this.pickTasks = pickTasks;
    refreshedAt = DateTime.now();
    _rebuild();
  }

  void _rebuild() {
    binMap = {for (var b in bins) b.id: b};

    // Simulate pallet lists on occupied outbound docks for local rendering.
    dockPallets = {};
    final rng = Random();
    for (final dock in docks) {
      if (dock.type == DockType.outbound && dock.isOccupied) {
        dockPallets[dock.id] = List.generate(
          rng.nextInt(15) + 3,
          (_) => Pallet(
            skuId: 'SKU-${rng.nextInt(9000) + 1000}',
            weightKg: rng.nextDouble() * 75 + 5,
            quantity: rng.nextInt(49) + 1,
            status: rng.nextBool() ? 'PACKED' : 'STAGED',
          ),
        );
      }
    }
  }

  /// Occupied bins not currently being serviced by any robot (pass active bin IDs).
  List<Bin> availableBins(Set<String> activeBinIds) => bins
      .where((b) =>
          b.isOccupied && !activeBinIds.contains(b.id) && b.faceCell != null)
      .toList();

  int get totalBins => bins.length;
  int get occupiedBins => bins.where((b) => b.isOccupied).length;
  double get occupancyRate => totalBins == 0 ? 0 : occupiedBins / totalBins;
}
