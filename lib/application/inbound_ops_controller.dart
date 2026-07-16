/// inbound_ops_controller.dart
///
/// Manages the full inbound pipeline:
///   1. Truck arrives on road (top-left corner)
///   2. User clicks inbound bay → truck docks there
///   3. IR (Inbound Robot) picks pallet from truck
///   4. IR navigates to pallet staging cell
///   5. IR drops pallet at staging (single-SKU enforced)
///
/// Quantity tracking:
///   PICK  → truck cargo qty decreases, robot qty_held increases
///   DROP  → robot qty_held decreases, staging slot qty increases
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

// ── Inbound robot task state machine ────────────────────────────────────────

enum IRTaskState {
  idle, // waiting for assignment
  navigatingToTruck, // following path to truck dock
  pickingFromTruck, // at truck dock, picking pallet
  navigatingToStaging, // following path to staging cell
  droppingAtStaging, // at staging cell, dropping pallet
}

/// One inbound robot's current task assignment.
class IRTask {
  IRTask({
    required this.robotId,
    required this.truckId,
    required this.skuId,
    required this.truckDockRow,
    required this.truckDockCol,
    required this.stagingRow,
    required this.stagingCol,
    this.qty = 1,
  });

  final String robotId;
  final String truckId;
  final String skuId;
  final int truckDockRow, truckDockCol;
  int stagingRow, stagingCol;
  int qty;

  IRTaskState state = IRTaskState.idle;
  List<(int, int)> path = [];
  int pathIndex = 0;
  int ticksRemaining = 0; // ticks left for pick/drop action

  (int, int) get currentTarget => switch (state) {
        IRTaskState.navigatingToTruck || IRTaskState.pickingFromTruck => (
            truckDockRow,
            truckDockCol
          ),
        IRTaskState.navigatingToStaging || IRTaskState.droppingAtStaging => (
            stagingRow,
            stagingCol
          ),
        _ => (truckDockRow, truckDockCol),
      };

  bool get isComplete => state == IRTaskState.idle && path.isEmpty;
}

// ── Controller ──────────────────────────────────────────────────────────────

class InboundOpsController {
  InboundOpsController({
    required this.config,
    required this.ref,
  }) : _pathfinder = AStarPathfinder(
          cols: config.cols,
          rows: config.rows,
        );

  final WarehouseConfig config;
  final WidgetRef ref;
  final AStarPathfinder _pathfinder;

  /// Active tasks keyed by robot ID.
  final Map<String, IRTask> _tasks = {};

  /// Completed unload count per truck.
  final Map<String, int> _unloadedByTruck = {};

  // ── Ticks for pick/drop actions ──────────────────────────────────────────
  static const int kPickTicks = 3;
  static const int kDropTicks = 2;

  // ── Public API ────────────────────────────────────────────────────────────

  Map<String, IRTask> get activeTasks => Map.unmodifiable(_tasks);
  bool hasActiveTask(String robotId) => _tasks.containsKey(robotId);

  /// Assign an inbound robot to unload one pallet from a docked truck.
  ///
  /// [robotId]   — ID of the inbound robot (e.g. 'IR-01')
  /// [robotRow], [robotCol] — current position of the robot
  /// [truckId]   — which truck to unload from
  /// [skuId]     — which SKU to pick
  /// [dockRow], [dockCol] — the inbound dock cell where the truck is docked
  ///
  /// The controller will:
  ///   1. Find the nearest free pallet staging cell for this SKU
  ///   2. Compute A* path from robot → adjacent-to-dock cell
  ///   3. Set state = navigatingToTruck
  Future<String?> assignUnload({
    required String robotId,
    required int robotRow,
    required int robotCol,
    required String truckId,
    required String skuId,
    required int dockRow,
    required int dockCol,
  }) async {
    if (_tasks.containsKey(robotId)) {
      return 'Robot $robotId already has an active task';
    }

    // Find a valid staging cell for this SKU
    final staging = _findStagingCell(skuId);
    if (staging == null) {
      return 'No free pallet staging slot for SKU $skuId';
    }

    // Find the walkable cell adjacent to the dock (robots can't step on dock)
    final dockApproach = _adjacentWalkable(dockRow, dockCol);
    if (dockApproach == null) {
      return 'No walkable cell adjacent to dock ($dockRow, $dockCol)';
    }

    // A* path from robot to dock-adjacent cell
    final pathToTruck = _pathfinder.findPath(
      (robotCol, robotRow), // pathfinder uses (col, row)
      (dockApproach.$2, dockApproach.$1),
      walkable: (cell) => _isWalkableForRobot(cell.$2, cell.$1),
    );

    if (pathToTruck.isEmpty) {
      return 'No path from robot to truck dock';
    }

    // Convert pathfinder (col, row) to our (row, col)
    final convertedPath = pathToTruck.map((p) => (p.$2, p.$1)).toList();

    final task = IRTask(
      robotId: robotId,
      truckId: truckId,
      skuId: skuId,
      truckDockRow: dockApproach.$1,
      truckDockCol: dockApproach.$2,
      stagingRow: staging.$1,
      stagingCol: staging.$2,
    )
      ..state = IRTaskState.navigatingToTruck
      ..path = convertedPath
      ..pathIndex = 0;

    _tasks[robotId] = task;
    debugPrint('📥 IR Task assigned: $robotId → truck $truckId SKU $skuId');
    return null; // success
  }

  /// Advance all active inbound robot tasks by one tick.
  /// Called from the simulation loop (auto mode) or STEP button (manual mode).
  ///
  /// Returns a list of events that occurred this tick for UI feedback.
  List<InboundEvent> tick() {
    final events = <InboundEvent>[];
    final completedRobots = <String>[];

    for (final entry in _tasks.entries) {
      final task = entry.value;
      final robotId = entry.key;

      switch (task.state) {
        case IRTaskState.idle:
          completedRobots.add(robotId);
          break;

        case IRTaskState.navigatingToTruck:
          if (task.pathIndex < task.path.length - 1) {
            task.pathIndex++;
            final pos = task.path[task.pathIndex];
            _updateRobotPosition(robotId, pos.$1, pos.$2);
            _revealFog(pos.$1, pos.$2);
          } else {
            // Arrived at truck — start picking
            task.state = IRTaskState.pickingFromTruck;
            task.ticksRemaining = kPickTicks;
            events.add(InboundEvent(
              type: InboundEventType.arrivedAtTruck,
              robotId: robotId,
              truckId: task.truckId,
              skuId: task.skuId,
              message: '$robotId arrived at truck ${task.truckId}',
            ));
          }
          break;

        case IRTaskState.pickingFromTruck:
          task.ticksRemaining--;
          if (task.ticksRemaining <= 0) {
            // PICK TRANSACTION: truck qty ↓, robot qty_held ↑
            _executePickFromTruck(task);
            events.add(InboundEvent(
              type: InboundEventType.pickedFromTruck,
              robotId: robotId,
              truckId: task.truckId,
              skuId: task.skuId,
              message:
                  '$robotId picked ${task.skuId} from truck ${task.truckId}',
            ));

            // Now compute path to staging
            final stagingApproach =
                _adjacentWalkable(task.stagingRow, task.stagingCol);
            if (stagingApproach == null) {
              debugPrint('⚠ No walkable cell near staging for $robotId');
              task.state = IRTaskState.idle;
              break;
            }

            final curPos = task.path[task.pathIndex];
            final pathToStaging = _pathfinder.findPath(
              (curPos.$2, curPos.$1), // (col, row)
              (stagingApproach.$2, stagingApproach.$1),
              walkable: (cell) => _isWalkableForRobot(cell.$2, cell.$1),
            );

            if (pathToStaging.isEmpty) {
              debugPrint('⚠ No path to staging for $robotId');
              task.state = IRTaskState.idle;
              break;
            }

            task.path = pathToStaging.map((p) => (p.$2, p.$1)).toList();
            task.pathIndex = 0;
            task.stagingRow = stagingApproach.$1;
            task.stagingCol = stagingApproach.$2;
            task.state = IRTaskState.navigatingToStaging;
          }
          break;

        case IRTaskState.navigatingToStaging:
          if (task.pathIndex < task.path.length - 1) {
            task.pathIndex++;
            final pos = task.path[task.pathIndex];
            _updateRobotPosition(robotId, pos.$1, pos.$2);
            _revealFog(pos.$1, pos.$2);
          } else {
            // Arrived at staging — start dropping
            task.state = IRTaskState.droppingAtStaging;
            task.ticksRemaining = kDropTicks;
            events.add(InboundEvent(
              type: InboundEventType.arrivedAtStaging,
              robotId: robotId,
              truckId: task.truckId,
              skuId: task.skuId,
              message: '$robotId arrived at staging',
            ));
          }
          break;

        case IRTaskState.droppingAtStaging:
          task.ticksRemaining--;
          if (task.ticksRemaining <= 0) {
            // DROP TRANSACTION: robot qty_held ↓, staging qty ↑
            _executeDropAtStaging(task);
            events.add(InboundEvent(
              type: InboundEventType.droppedAtStaging,
              robotId: robotId,
              truckId: task.truckId,
              skuId: task.skuId,
              message: '$robotId dropped ${task.skuId} at staging',
            ));
            task.state = IRTaskState.idle;
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

  /// Manual pick: user commands IR robot to pick from the truck it's adjacent to.
  /// Returns error string or null on success.
  Future<String?> manualPickFromTruck({
    required String robotId,
    required int robotRow,
    required int robotCol,
    required String truckId,
    required String skuId,
  }) async {
    // Verify robot is adjacent to an inbound/dock cell
    if (!_isAdjacentToDock(robotRow, robotCol)) {
      return 'Robot must be adjacent to a dock/inbound cell to pick';
    }

    // Call backend pick transaction
    try {
      await ApiClient.instance.pickTransaction(
        robotId: robotId,
        functionalType: 'inbound_pick',
        sourceType: 'TRUCK',
        sourceId: truckId,
        skuId: skuId,
        qty: 1,
      );
    } catch (e) {
      return 'Pick failed: $e';
    }

    // Update local cargo state
    ref.read(robotCargoProvider.notifier).loadPallet(
          robotId,
          PalletData(skuId: skuId, truckId: truckId),
        );

    debugPrint('✅ Manual pick: $robotId picked $skuId from truck $truckId');
    return null;
  }

  /// Manual drop: user commands IR robot to drop at the staging cell it's adjacent to.
  /// Returns error string or null on success.
  Future<String?> manualDropAtStaging({
    required String robotId,
    required int robotRow,
    required int robotCol,
  }) async {
    final cargo = ref.read(robotCargoProvider)[robotId];
    if (cargo == null) {
      return 'Robot $robotId is not carrying anything';
    }

    // Find adjacent staging cell
    final stagingCell = _adjacentStagingCell(robotRow, robotCol);
    if (stagingCell == null) {
      return 'Robot must be adjacent to a pallet staging cell to drop';
    }

    // Check single-SKU rule
    final stagingN = ref.read(stagingPalletsProvider.notifier);
    final error = stagingN.canDrop(stagingCell.$1, stagingCell.$2, cargo.skuId);
    if (error != null) return error;

    // Call backend drop transaction
    try {
      final slotResult =
          await ApiClient.instance.getAvailableStagingSlot(cargo.skuId);
      final slotId = slotResult['slot_id'] as String? ??
          'SS-${stagingCell.$1}_${stagingCell.$2}';
      await ApiClient.instance.dropTransaction(
        robotId: robotId,
        destType: 'STAGING_SLOT',
        destId: slotId,
        qty: 1,
      );
    } catch (e) {
      return 'Drop failed: $e';
    }

    // Update local state: robot cargo ↓, staging qty ↑
    ref.read(robotCargoProvider.notifier).clearCargo(robotId);
    stagingN.drop(stagingCell.$1, stagingCell.$2, cargo.skuId);

    debugPrint('✅ Manual drop: $robotId dropped ${cargo.skuId} at staging '
        '(${stagingCell.$1}, ${stagingCell.$2})');
    return null;
  }

  void dispose() {
    _tasks.clear();
  }

  // ── Private: pick/drop execution ──────────────────────────────────────────

  void _executePickFromTruck(IRTask task) {
    // Backend call (fire-and-forget)
    ApiClient.instance
        .pickTransaction(
      robotId: task.robotId,
      functionalType: 'inbound_pick',
      sourceType: 'TRUCK',
      sourceId: task.truckId,
      skuId: task.skuId,
      qty: task.qty,
    )
        .catchError((e) {
      debugPrint('⚠ Pick backend error: $e');
      return <String, dynamic>{};
    });

    // Local state: robot now carries the pallet
    ref.read(robotCargoProvider.notifier).loadPallet(
          task.robotId,
          PalletData(skuId: task.skuId, truckId: task.truckId),
        );

    _unloadedByTruck.update(
      task.truckId,
      (v) => v + task.qty,
      ifAbsent: () => task.qty,
    );
  }

  void _executeDropAtStaging(IRTask task) {
    // Backend call (fire-and-forget)
    final slotId = 'SS-${task.stagingRow}_${task.stagingCol}';
    ApiClient.instance
        .dropTransaction(
      robotId: task.robotId,
      destType: 'STAGING_SLOT',
      destId: slotId,
      qty: task.qty,
    )
        .catchError((e) {
      debugPrint('⚠ Drop backend error: $e');
      return <String, dynamic>{};
    });

    // Local state: robot cargo cleared, staging qty increased
    ref.read(robotCargoProvider.notifier).clearCargo(task.robotId);
    ref.read(stagingPalletsProvider.notifier).drop(
          task.stagingRow,
          task.stagingCol,
          task.skuId,
        );
  }

  // ── Private: position & fog helpers ───────────────────────────────────────

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

  // ── Private: pathfinding walkability ──────────────────────────────────────

  bool _isWalkableForRobot(int row, int col) {
    if (row < 0 || row >= config.rows || col < 0 || col >= config.cols) {
      return false;
    }
    final cell = config.cellAt(row, col);
    final t = cell?.type ?? CellType.empty;
    return t.isWalkable || t == CellType.empty || t == CellType.inbound;
  }

  /// Find a walkable cell orthogonally adjacent to (row, col).
  (int, int)? _adjacentWalkable(int row, int col) {
    const dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)];
    for (final (dr, dc) in dirs) {
      final nr = row + dr;
      final nc = col + dc;
      if (_isWalkableForRobot(nr, nc)) return (nr, nc);
    }
    return null;
  }

  bool _isAdjacentToDock(int row, int col) {
    const dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)];
    for (final (dr, dc) in dirs) {
      final nr = row + dr;
      final nc = col + dc;
      if (nr < 0 || nr >= config.rows || nc < 0 || nc >= config.cols) continue;
      final t = config.typeAt(nr, nc);
      if (t == CellType.inbound || t == CellType.dock) return true;
    }
    return false;
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

  /// Find the best pallet staging cell for this SKU.
  /// Priority: existing slot with same SKU (not full) → empty slot.
  (int, int)? _findStagingCell(String skuId) {
    final stagingCells =
        config.cells.where((c) => c.type == CellType.palletStaging).toList();
    if (stagingCells.isEmpty) return null;

    final staging = ref.read(stagingPalletsProvider);

    // First: find existing slot with same SKU and room
    for (final cell in stagingCells) {
      final key = '${cell.row}_${cell.col}';
      final slot = staging[key];
      if (slot != null &&
          slot.skuId == skuId &&
          slot.count < kMaxStagingPallets) {
        return (cell.row, cell.col);
      }
    }

    // Second: find empty slot
    for (final cell in stagingCells) {
      final key = '${cell.row}_${cell.col}';
      final slot = staging[key];
      if (slot == null || slot.count == 0) {
        return (cell.row, cell.col);
      }
    }

    return null; // all full
  }
}

// ── Event model ─────────────────────────────────────────────────────────────

enum InboundEventType {
  arrivedAtTruck,
  pickedFromTruck,
  arrivedAtStaging,
  droppedAtStaging,
}

class InboundEvent {
  const InboundEvent({
    required this.type,
    required this.robotId,
    required this.truckId,
    required this.skuId,
    required this.message,
  });
  final InboundEventType type;
  final String robotId;
  final String truckId;
  final String skuId;
  final String message;
}
