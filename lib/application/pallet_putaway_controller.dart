/// pallet_putaway_controller.dart
///
/// PR (Pallet Pick Robot) picks pallets from the Pallet Staging area and
/// follows the putaway algorithm:
///
///   5.1  Order pending for pallet & no pallet in inventory → drop at Pack Station
///   5.2  Loose pick area below threshold → unwrap pallet, drop as LOOSE qty
///   5.3  Case pick area below threshold  → unwrap pallet, drop as CASE qty
///   5.4  None of the above               → drop as-is in Pallet Pick location
///
/// Quantity tracking:
///   PICK  → staging slot qty decreases, robot qty_held increases (1 pallet)
///   DROP  → robot qty_held decreases, destination rack qty increases
///           Pallet location: +1 pallet
///           Case location:   +N cases  (pallet → cases conversion)
///           Loose location:  +N units  (pallet → loose conversion)
///           Pack Station:    pallet consumed (order fulfilled)
///
/// Works in both MANUAL (user taps) and AI (auto-tick) modes.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';
import '../models/warehouse_config.dart';
import '../warehouse_engine/services/pathfinding.dart';
import 'providers.dart';

// ── Conversion constants ────────────────────────────────────────────────────

/// How many cases in one pallet (standard conversion rate).
const int kCasesPerPallet = 12;

/// How many loose units in one pallet.
const int kLoosePerPallet = 48;

/// Threshold: refill when a rack cell drops below this fraction of capacity.
const double kReplenishThreshold = 0.5;

// ── PR task state machine ───────────────────────────────────────────────────

enum PRTaskState {
  idle,
  navigatingToStaging, // going to pick up a pallet from staging
  pickingFromStaging, // at staging, picking pallet
  navigatingToDest, // going to destination (rack / pack station)
  droppingAtDest, // at destination, dropping items
}

/// Destination type for putaway.
enum PutawayDestType {
  packStation, // 5.1 — order pending, direct to pack
  looseRack, // 5.2 — replenish loose pick area
  caseRack, // 5.3 — replenish case pick area
  palletRack, // 5.4 — default pallet storage
}

/// One PR robot's current task assignment.
class PRTask {
  PRTask({
    required this.robotId,
    required this.skuId,
    required this.stagingRow,
    required this.stagingCol,
    required this.destRow,
    required this.destCol,
    required this.destType,
    required this.dropQty,
  });

  final String robotId;
  final String skuId;
  final int stagingRow, stagingCol;
  int destRow, destCol;
  final PutawayDestType destType;

  /// Quantity to add at destination (in destination UOM).
  /// Pallet rack: 1 pallet. Case rack: kCasesPerPallet. Loose rack: kLoosePerPallet.
  final int dropQty;

  PRTaskState state = PRTaskState.idle;
  List<(int, int)> path = [];
  int pathIndex = 0;
  int ticksRemaining = 0;
}

// ── Controller ──────────────────────────────────────────────────────────────

class PalletPutawayController {
  PalletPutawayController({
    required this.config,
    required this.ref,
  }) : _pathfinder = AStarPathfinder(
          cols: config.cols,
          rows: config.rows,
        );

  final WarehouseConfig config;
  final WidgetRef ref;
  final AStarPathfinder _pathfinder;

  final Map<String, PRTask> _tasks = {};

  static const int kPickTicks = 3;
  static const int kDropTicks = 2;

  // ── Public API ────────────────────────────────────────────────────────────

  Map<String, PRTask> get activeTasks => Map.unmodifiable(_tasks);
  bool hasActiveTask(String robotId) => _tasks.containsKey(robotId);

  /// Assign a PR robot to pick a pallet from staging and putaway.
  ///
  /// Runs the 5.1–5.4 algorithm to determine destination.
  /// Returns error string or null on success.
  String? assignPutaway({
    required String robotId,
    required int robotRow,
    required int robotCol,
    required String skuId,
    required int stagingRow,
    required int stagingCol,
  }) {
    if (_tasks.containsKey(robotId)) {
      return 'Robot $robotId already has an active task';
    }

    // Determine destination using the 5.1–5.4 algorithm
    final dest = _determinePutawayDest(skuId);
    if (dest == null) {
      return 'No available destination for SKU $skuId';
    }

    // Find walkable cell adjacent to staging
    final stagingApproach = _adjacentWalkable(stagingRow, stagingCol);
    if (stagingApproach == null) {
      return 'No walkable cell adjacent to staging ($stagingRow, $stagingCol)';
    }

    // A* path from robot to staging-adjacent cell
    final pathToStaging = _pathfinder.findPath(
      (robotCol, robotRow),
      (stagingApproach.$2, stagingApproach.$1),
      walkable: (cell) => _isWalkableForRobot(cell.$2, cell.$1),
    );

    if (pathToStaging.isEmpty) {
      return 'No path from robot to staging';
    }

    final task = PRTask(
      robotId: robotId,
      skuId: skuId,
      stagingRow: stagingApproach.$1,
      stagingCol: stagingApproach.$2,
      destRow: dest.row,
      destCol: dest.col,
      destType: dest.type,
      dropQty: dest.qty,
    )
      ..state = PRTaskState.navigatingToStaging
      ..path = pathToStaging.map((p) => (p.$2, p.$1)).toList()
      ..pathIndex = 0;

    _tasks[robotId] = task;
    debugPrint('🏗 PR Task assigned: $robotId → ${dest.type.name} '
        'for $skuId (drop qty: ${dest.qty})');
    return null;
  }

  /// Advance all PR tasks by one tick.
  List<PutawayEvent> tick() {
    final events = <PutawayEvent>[];
    final completedRobots = <String>[];

    for (final entry in _tasks.entries) {
      final task = entry.value;
      final robotId = entry.key;

      switch (task.state) {
        case PRTaskState.idle:
          completedRobots.add(robotId);
          break;

        case PRTaskState.navigatingToStaging:
          if (task.pathIndex < task.path.length - 1) {
            task.pathIndex++;
            final pos = task.path[task.pathIndex];
            _updateRobotPosition(robotId, pos.$1, pos.$2);
            _revealFog(pos.$1, pos.$2);
          } else {
            task.state = PRTaskState.pickingFromStaging;
            task.ticksRemaining = kPickTicks;
            events.add(PutawayEvent(
              type: PutawayEventType.arrivedAtStaging,
              robotId: robotId,
              skuId: task.skuId,
              message: '$robotId arrived at staging to pick ${task.skuId}',
            ));
          }
          break;

        case PRTaskState.pickingFromStaging:
          task.ticksRemaining--;
          if (task.ticksRemaining <= 0) {
            // PICK: staging qty ↓, robot in-hand ↑
            _executePickFromStaging(task);
            events.add(PutawayEvent(
              type: PutawayEventType.pickedFromStaging,
              robotId: robotId,
              skuId: task.skuId,
              message: '$robotId picked pallet of ${task.skuId} from staging',
            ));

            // Compute path to destination
            final destApproach = _adjacentWalkableForDest(
                task.destRow, task.destCol, task.destType);
            if (destApproach == null) {
              debugPrint('⚠ No walkable cell near dest for $robotId');
              task.state = PRTaskState.idle;
              break;
            }

            final curPos = task.path[task.pathIndex];
            final pathToDest = _pathfinder.findPath(
              (curPos.$2, curPos.$1),
              (destApproach.$2, destApproach.$1),
              walkable: (cell) => _isWalkableForRobot(cell.$2, cell.$1),
            );

            if (pathToDest.isEmpty) {
              debugPrint('⚠ No path to destination for $robotId');
              task.state = PRTaskState.idle;
              break;
            }

            task.path = pathToDest.map((p) => (p.$2, p.$1)).toList();
            task.pathIndex = 0;
            task.destRow = destApproach.$1;
            task.destCol = destApproach.$2;
            task.state = PRTaskState.navigatingToDest;
          }
          break;

        case PRTaskState.navigatingToDest:
          if (task.pathIndex < task.path.length - 1) {
            task.pathIndex++;
            final pos = task.path[task.pathIndex];
            _updateRobotPosition(robotId, pos.$1, pos.$2);
            _revealFog(pos.$1, pos.$2);
          } else {
            task.state = PRTaskState.droppingAtDest;
            task.ticksRemaining = kDropTicks;
            events.add(PutawayEvent(
              type: PutawayEventType.arrivedAtDest,
              robotId: robotId,
              skuId: task.skuId,
              message: '$robotId arrived at ${task.destType.name}',
            ));
          }
          break;

        case PRTaskState.droppingAtDest:
          task.ticksRemaining--;
          if (task.ticksRemaining <= 0) {
            // DROP: robot in-hand ↓, destination rack qty ↑
            _executeDropAtDest(task);
            events.add(PutawayEvent(
              type: PutawayEventType.droppedAtDest,
              robotId: robotId,
              skuId: task.skuId,
              destType: task.destType,
              qty: task.dropQty,
              message:
                  '$robotId dropped ${task.dropQty} ${_uomLabel(task.destType)} '
                  'of ${task.skuId} at ${task.destType.name}',
            ));
            task.state = PRTaskState.idle;
            completedRobots.add(robotId);
          }
          break;
      }
    }

    for (final id in completedRobots) {
      _tasks.remove(id);
    }

    return events;
  }

  /// Manual pick from staging: user commands PR robot adjacent to staging.
  Future<String?> manualPickFromStaging({
    required String robotId,
    required int robotRow,
    required int robotCol,
  }) async {
    final stagingCell = _adjacentStagingCell(robotRow, robotCol);
    if (stagingCell == null) {
      return 'Robot must be adjacent to a pallet staging cell';
    }

    final staging = ref.read(stagingPalletsProvider);
    final key = '${stagingCell.$1}_${stagingCell.$2}';
    final slot = staging[key];
    if (slot == null || slot.count == 0) {
      return 'Staging cell is empty — nothing to pick';
    }

    final skuId = slot.skuId;

    // Backend call: staging qty ↓, robot_holding qty_held ↑
    final slotId = 'SS-${stagingCell.$1}_${stagingCell.$2}';
    try {
      await ApiClient.instance.pickTransaction(
        robotId: robotId,
        functionalType: 'pallet_pick',
        sourceType: 'STAGING_SLOT',
        sourceId: slotId,
        skuId: skuId,
        qty: 1,
      );
    } catch (e) {
      return 'Pick failed: $e';
    }

    // Local state: staging qty ↓
    ref
        .read(stagingPalletsProvider.notifier)
        .pick(stagingCell.$1, stagingCell.$2);

    // Local state: robot cargo ↑
    ref.read(robotCargoProvider.notifier).loadPallet(
          robotId,
          PalletData(skuId: skuId, truckId: 'STAGING'),
        );

    debugPrint('✅ Manual PR pick: $robotId picked $skuId from staging');
    return null;
  }

  /// Manual drop at destination: user commands PR robot adjacent to a rack or pack station.
  Future<String?> manualDropAtDest({
    required String robotId,
    required int robotRow,
    required int robotCol,
  }) async {
    final cargo = ref.read(robotCargoProvider)[robotId];
    if (cargo == null) {
      return 'Robot $robotId is not carrying anything';
    }

    // Find adjacent rack or pack station
    final destInfo = _findAdjacentDropTarget(robotRow, robotCol, cargo.skuId);
    if (destInfo == null) {
      return 'No valid drop target adjacent to robot. '
          'Must be next to a rack (same SKU or empty) or pack station.';
    }

    // Backend call: robot_holding qty_held ↓, destination inventory ↑
    try {
      if (destInfo.type != PutawayDestType.packStation) {
        final binId = 'R${destInfo.row}C${destInfo.col}';
        await ApiClient.instance.dropTransaction(
          robotId: robotId,
          destType: 'BIN',
          destId: binId,
          qty: destInfo.qty,
        );
      } else {
        await ApiClient.instance.dropTransaction(
          robotId: robotId,
          destType: 'DISPATCH_AREA',
          destId: 'PACK-${destInfo.row}_${destInfo.col}',
          qty: destInfo.qty,
        );
      }
    } catch (e) {
      return 'Drop failed: $e';
    }

    // Local state: update rack qty
    _applyDropToConfig(
      destInfo.row,
      destInfo.col,
      cargo.skuId,
      destInfo.type,
      destInfo.qty,
    );

    // Local state: clear robot cargo
    ref.read(robotCargoProvider.notifier).clearCargo(robotId);

    debugPrint('✅ Manual PR drop: $robotId dropped ${destInfo.qty} '
        '${_uomLabel(destInfo.type)} of ${cargo.skuId} at '
        '(${destInfo.row}, ${destInfo.col})');
    return null;
  }

  void dispose() {
    _tasks.clear();
  }

  // ── 5.1–5.4 Algorithm ────────────────────────────────────────────────────

  _PutawayDest? _determinePutawayDest(String skuId) {
    // 5.1: Order pending for pallet AND no pallet in inventory → pack station
    if (_hasOrderPending(skuId) && !_hasPalletInInventory(skuId)) {
      final packCell = _findPackStation();
      if (packCell != null) {
        return _PutawayDest(
          row: packCell.$1,
          col: packCell.$2,
          type: PutawayDestType.packStation,
          qty: 1, // pallet consumed by order
        );
      }
    }

    // 5.2: Loose pick area below threshold → unwrap, drop as loose
    final looseRack = _findBelowThresholdRack(CellType.rackLoose, skuId);
    if (looseRack != null) {
      return _PutawayDest(
        row: looseRack.$1,
        col: looseRack.$2,
        type: PutawayDestType.looseRack,
        qty: kLoosePerPallet,
      );
    }

    // 5.3: Case pick area below threshold → unwrap, drop as cases
    final caseRack = _findBelowThresholdRack(CellType.rackCase, skuId);
    if (caseRack != null) {
      return _PutawayDest(
        row: caseRack.$1,
        col: caseRack.$2,
        type: PutawayDestType.caseRack,
        qty: kCasesPerPallet,
      );
    }

    // 5.4: Default — store pallet as-is in pallet pick location
    final palletRack = _findAvailablePalletRack(skuId);
    if (palletRack != null) {
      return _PutawayDest(
        row: palletRack.$1,
        col: palletRack.$2,
        type: PutawayDestType.palletRack,
        qty: 1,
      );
    }

    return null; // no destination available
  }

  /// 5.1 check: is there an outbound order pending that needs this SKU as pallet?
  bool _hasOrderPending(String skuId) {
    // Check outbound orders from the latest frame
    // We look at WarehouseConfig's truckSpawns with outbound cargo referencing this SKU
    // In real implementation this would query backend orders
    // For now, check if any outbound truck spawns reference this SKU
    for (final truck in config.truckSpawns) {
      if (truck.truckType == TruckType.outbound) {
        for (final cargo in truck.cargo) {
          if (cargo.skuId == skuId && cargo.unitType == 'PALLET') {
            return true;
          }
        }
      }
    }
    return false;
  }

  /// 5.1 check: is there any pallet of this SKU already in an inventory rack?
  bool _hasPalletInInventory(String skuId) {
    for (final cell in config.cells) {
      if (cell.type == CellType.rackPallet &&
          cell.skuId == skuId &&
          cell.quantity > 0) {
        return true;
      }
    }
    return false;
  }

  /// Find a rack cell of [rackType] assigned to [skuId] (or empty) that
  /// is below the replenishment threshold.
  (int, int)? _findBelowThresholdRack(CellType rackType, String skuId) {
    for (final cell in config.cells) {
      if (cell.type != rackType) continue;
      // Same SKU and below threshold
      if (cell.skuId == skuId && cell.fillFraction < kReplenishThreshold) {
        final remaining = cell.maxQuantity - cell.quantity;
        if (remaining > 0) return (cell.row, cell.col);
      }
      // Empty/unassigned rack — can accept this SKU
      if ((cell.skuId == null || cell.skuId!.isEmpty) && cell.quantity == 0) {
        return (cell.row, cell.col);
      }
    }
    return null;
  }

  /// Find an available pallet rack location (same SKU with room, or empty).
  (int, int)? _findAvailablePalletRack(String skuId) {
    // First: same SKU with room
    for (final cell in config.cells) {
      if (cell.type == CellType.rackPallet &&
          cell.skuId == skuId &&
          !cell.isFull) {
        return (cell.row, cell.col);
      }
    }
    // Second: empty pallet rack
    for (final cell in config.cells) {
      if (cell.type == CellType.rackPallet &&
          cell.quantity == 0 &&
          (cell.skuId == null || cell.skuId!.isEmpty)) {
        return (cell.row, cell.col);
      }
    }
    return null;
  }

  (int, int)? _findPackStation() {
    for (final cell in config.cells) {
      if (cell.type == CellType.packStation) {
        return (cell.row, cell.col);
      }
    }
    return null;
  }

  // ── Private: execution ────────────────────────────────────────────────────

  void _executePickFromStaging(PRTask task) {
    // Backend call: staging qty ↓, robot_holding qty_held ↑
    final slotId = 'SS-${task.stagingRow}_${task.stagingCol}';
    ApiClient.instance
        .pickTransaction(
      robotId: task.robotId,
      functionalType: 'pallet_pick',
      sourceType: 'STAGING_SLOT',
      sourceId: slotId,
      skuId: task.skuId,
      qty: 1,
    )
        .catchError((e) {
      debugPrint('⚠ PR pick backend error: $e');
      return <String, dynamic>{};
    });

    // Local state: staging qty ↓
    ref.read(stagingPalletsProvider.notifier).pick(
          task.stagingRow,
          task.stagingCol,
        );

    // Local state: robot cargo ↑
    ref.read(robotCargoProvider.notifier).loadPallet(
          task.robotId,
          PalletData(skuId: task.skuId, truckId: 'STAGING'),
        );
  }

  void _executeDropAtDest(PRTask task) {
    // Backend call: robot_holding qty_held ↓, destination inventory ↑
    if (task.destType != PutawayDestType.packStation) {
      final binId = 'R${task.destRow}C${task.destCol}';
      ApiClient.instance
          .dropTransaction(
        robotId: task.robotId,
        destType: 'BIN',
        destId: binId,
        qty: task.dropQty,
      )
          .catchError((e) {
        debugPrint('⚠ PR drop backend error: $e');
        return <String, dynamic>{};
      });
    } else {
      // Pack station: just clear the robot holding on backend
      ApiClient.instance
          .dropTransaction(
        robotId: task.robotId,
        destType: 'DISPATCH_AREA',
        destId: 'PACK-${task.destRow}_${task.destCol}',
        qty: task.dropQty,
      )
          .catchError((e) {
        debugPrint('⚠ PR drop (pack) backend error: $e');
        return <String, dynamic>{};
      });
    }

    // Local state: robot cargo ↓
    ref.read(robotCargoProvider.notifier).clearCargo(task.robotId);

    // Local state: destination rack qty ↑ (in correct UOM)
    _applyDropToConfig(
      task.destRow,
      task.destCol,
      task.skuId,
      task.destType,
      task.dropQty,
    );
  }

  /// Updates the WarehouseConfig cell in-place with increased inventory.
  void _applyDropToConfig(
    int row,
    int col,
    String skuId,
    PutawayDestType destType,
    int qty,
  ) {
    final cfg = ref.read(warehouseConfigProvider);
    if (cfg == null) return;

    final cell = cfg.cellAt(row, col);
    if (cell == null) return;

    // For pack station, the pallet is consumed (order fulfillment)
    if (destType == PutawayDestType.packStation) {
      debugPrint('📦 Pallet of $skuId consumed at pack station ($row, $col)');
      return;
    }

    // For racks: increase quantity, cap at maxQuantity, assign SKU if empty
    final newQty = (cell.quantity + qty).clamp(0, cell.maxQuantity);
    final updatedCell = cell.copyWith(
      quantity: newQty,
      skuId: skuId,
    );
    final updatedConfig = cfg.setCell(updatedCell);
    ref.read(warehouseConfigProvider.notifier).state = updatedConfig;

    debugPrint('📈 Rack ($row, $col): ${cell.quantity} → $newQty '
        '${_uomLabel(destType)} of $skuId');
  }

  // ── Private: navigation helpers ───────────────────────────────────────────

  void _updateRobotPosition(String robotId, int row, int col) {
    ref.read(manualRobotPositionsProvider.notifier).update(robotId, row, col);
  }

  void _revealFog(int row, int col) {
    final n = ref.read(exploredCellsProvider.notifier);
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        final nr = row + dr;
        final nc = col + dc;
        if (nr >= 0 && nr < config.rows && nc >= 0 && nc < config.cols) {
          n.markExplored(nr, nc);
        }
      }
    }
  }

  bool _isWalkableForRobot(int row, int col) {
    if (row < 0 || row >= config.rows || col < 0 || col >= config.cols) {
      return false;
    }
    final cell = config.cellAt(row, col);
    final t = cell?.type ?? CellType.empty;
    return t.isWalkable || t == CellType.empty;
  }

  (int, int)? _adjacentWalkable(int row, int col) {
    const dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)];
    for (final (dr, dc) in dirs) {
      final nr = row + dr;
      final nc = col + dc;
      if (_isWalkableForRobot(nr, nc)) return (nr, nc);
    }
    return null;
  }

  /// For destination cells: pack station needs approach from aisle; racks too.
  (int, int)? _adjacentWalkableForDest(
      int row, int col, PutawayDestType destType) {
    return _adjacentWalkable(row, col);
  }

  (int, int)? _adjacentStagingCell(int row, int col) {
    const dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)];
    for (final (dr, dc) in dirs) {
      final nr = row + dr;
      final nc = col + dc;
      if (nr < 0 || nr >= config.rows || nc < 0 || nc >= config.cols) continue;
      final t = config.typeAt(nr, nc);
      if (t == CellType.palletStaging) return (nr, nc);
    }
    return null;
  }

  /// Find a valid adjacent drop target for manual drop.
  _PutawayDest? _findAdjacentDropTarget(int row, int col, String skuId) {
    const dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)];
    for (final (dr, dc) in dirs) {
      final nr = row + dr;
      final nc = col + dc;
      if (nr < 0 || nr >= config.rows || nc < 0 || nc >= config.cols) continue;
      final cell = config.cellAt(nr, nc);
      if (cell == null) continue;

      // Pack station — always valid
      if (cell.type == CellType.packStation) {
        return _PutawayDest(
          row: nr,
          col: nc,
          type: PutawayDestType.packStation,
          qty: 1,
        );
      }

      // Rack cells — must be same SKU or empty, and not full
      if (cell.type == CellType.rackPallet) {
        if ((cell.skuId == null ||
                cell.skuId!.isEmpty ||
                cell.skuId == skuId) &&
            !cell.isFull) {
          return _PutawayDest(
            row: nr,
            col: nc,
            type: PutawayDestType.palletRack,
            qty: 1,
          );
        }
      }
      if (cell.type == CellType.rackCase) {
        if ((cell.skuId == null ||
                cell.skuId!.isEmpty ||
                cell.skuId == skuId) &&
            !cell.isFull) {
          return _PutawayDest(
            row: nr,
            col: nc,
            type: PutawayDestType.caseRack,
            qty: kCasesPerPallet,
          );
        }
      }
      if (cell.type == CellType.rackLoose) {
        if ((cell.skuId == null ||
                cell.skuId!.isEmpty ||
                cell.skuId == skuId) &&
            !cell.isFull) {
          return _PutawayDest(
            row: nr,
            col: nc,
            type: PutawayDestType.looseRack,
            qty: kLoosePerPallet,
          );
        }
      }
    }
    return null;
  }

  String _uomLabel(PutawayDestType type) => switch (type) {
        PutawayDestType.palletRack => 'pallets',
        PutawayDestType.caseRack => 'cases',
        PutawayDestType.looseRack => 'units',
        PutawayDestType.packStation => 'pallets (consumed)',
      };
}

// ── Internal dest model ────────────────────────────────────────────────────

class _PutawayDest {
  const _PutawayDest({
    required this.row,
    required this.col,
    required this.type,
    required this.qty,
  });
  final int row, col;
  final PutawayDestType type;
  final int qty;
}

// ── Event model ─────────────────────────────────────────────────────────────

enum PutawayEventType {
  arrivedAtStaging,
  pickedFromStaging,
  arrivedAtDest,
  droppedAtDest,
}

class PutawayEvent {
  const PutawayEvent({
    required this.type,
    required this.robotId,
    required this.skuId,
    required this.message,
    this.destType,
    this.qty,
  });
  final PutawayEventType type;
  final String robotId;
  final String skuId;
  final String message;
  final PutawayDestType? destType;
  final int? qty;
}
