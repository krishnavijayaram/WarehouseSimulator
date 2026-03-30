/// manual_robot_controller.dart
///
/// ManualRobotController — user-driven robot movement with standard
/// robot-to-system communication protocol (HARD REQUIREMENT).
///
/// Protocol (identical for physical and simulated robots):
///   1. User presses D-pad or keyboard arrow → robot moves one cell
///   2. Robot "scans" the 3×3 neighbourhood using WarehouseConfig as
///      ground truth (simulates physical sensor read)
///   3. Robot POSTs a RobotObservationReport to POST /api/v1/robot/observation
///   4. System processes:
///        a. reality_robots   — robot position telemetry
///        b. reality_cells    — confirms cell types
///        c. rack_inventory_reality — rack inventory (ground truth)
///        d. rack_inventory_wms     — WMS belief (updated from reality)
///        e. cell_exploration — fog-of-war
///        f. RealityEvent     — audit trail
///   5. Ack returned: alerts → local provider events raised
///
/// NOTE: ManualRobotController is intentionally a plain Dart class with NO
/// dependency on WidgetRef or Riverpod — it communicates with the UI layer
/// exclusively through typed callbacks provided at construction time.
/// This decouples the controller from widget lifecycle (fixing the stale-ref
/// problem) and makes it safe to use from real robot services in future.
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../env.dart';
import '../models/warehouse_config.dart';

// ── Direction ─────────────────────────────────────────────────────────────────

enum RobotMoveDirection { up, down, left, right }

const _kDirDelta = {
  RobotMoveDirection.up:    (-1, 0),
  RobotMoveDirection.down:  ( 1, 0),
  RobotMoveDirection.left:  ( 0,-1),
  RobotMoveDirection.right: ( 0, 1),
};

const _kDirHeading = {
  RobotMoveDirection.up:    'N',
  RobotMoveDirection.down:  'S',
  RobotMoveDirection.left:  'W',
  RobotMoveDirection.right: 'E',
};

// ── Single robot's tracked state ──────────────────────────────────────────────

class RobotState {
  const RobotState({
    required this.robotId,
    required this.row,
    required this.col,
    required this.robotType,
    this.battery = 100.0,
  });

  final String robotId;
  final int    row, col;
  final String robotType;
  final double battery;

  RobotState copyWith({int? row, int? col, double? battery}) => RobotState(
        robotId:   robotId,
        row:       row   ?? this.row,
        col:       col   ?? this.col,
        robotType: robotType,
        battery:   battery ?? this.battery,
      );
}

// ── ManualRobotController ─────────────────────────────────────────────────────

/// Controls one or more robots via user input.
///
/// All UI state updates go through typed callbacks — no Riverpod WidgetRef is
/// stored here. This means the controller can safely outlive any widget, and
/// can be driven by real hardware or AI algorithms with no code changes.
///
/// On each move:
///   1. Validates target cell is walkable
///   2. Updates local position
///   3. Fires [onPositionUpdate] (triggers floor repaint via provider)
///   4. Fires [onMarkExplored] 3×3 (optimistic fog-of-war reveal)
///   5. Scans 3×3 surroundings from WarehouseConfig (simulated sensor read)
///   6. Fires [onEventRaise] for replenishment/out-of-stock conditions
///   7. POSTs [RobotObservationReport] to /api/v1/robot/observation
///      (fire-and-forget; standard protocol — identical for real robots)
class ManualRobotController {
  ManualRobotController({
    required this.config,
    /// Called whenever a robot's position changes. Provider should update its
    /// map state so the floor CustomPainter repaints.
    required void Function(String robotId, int row, int col) onPositionUpdate,
    /// Called for each cell to be revealed (fog-of-war). (row, col)
    required void Function(int row, int col) onMarkExplored,
    /// Raise an alert event on a cell. (row, col, type, color, speed)
    required void Function(int row, int col, String type,
        String color, String speed) onEventRaise,
    /// Read currently selected robot ID.
    required String? Function() readSelectedId,
    /// Write currently selected robot ID.
    required void Function(String? id) writeSelectedId,
    String? backendBase,
    String? token,
  })  : _onPositionUpdate = onPositionUpdate,
        _onMarkExplored   = onMarkExplored,
        _onEventRaise     = onEventRaise,
        _readSelectedId   = readSelectedId,
        _writeSelectedId  = writeSelectedId,
        _backendBase      = backendBase ?? gatewayBaseUrl,
        _token            = token {
    _initRobots();
    _seedInitialReveal();
  }

  final WarehouseConfig config;
  final String _backendBase;
  final String? _token;

  // Callbacks (no Riverpod dependency here)
  final void Function(String, int, int) _onPositionUpdate;
  final void Function(int, int) _onMarkExplored;
  final void Function(int, int, String, String, String) _onEventRaise;
  final String? Function() _readSelectedId;
  final void Function(String?) _writeSelectedId;

  final Map<String, RobotState> _robots = {};

  // ── Init ──────────────────────────────────────────────────────────────────

  void _initRobots() {
    for (final spawn in config.robotSpawns) {
      final id = spawn.name ?? '${spawn.robotType}-${spawn.row}-${spawn.col}';
      _robots[id] = RobotState(
        robotId:   id,
        row:       spawn.row,
        col:       spawn.col,
        robotType: spawn.robotType,
      );
    }
    // Fallback: place one robot at the first walkable cell if no spawns defined.
    if (_robots.isEmpty) {
      final first = _firstWalkable();
      const id = 'default-bot';
      _robots[id] = RobotState(
          robotId: id, row: first.row, col: first.col, robotType: 'AMR');
    }

    // Push initial positions into provider (triggers floor repaint).
    for (final r in _robots.values) {
      _onPositionUpdate(r.robotId, r.row, r.col);
    }

    // Auto-select the first robot so D-pad / keyboard work immediately
    // without requiring the user to tap a robot first.
    if (_robots.isNotEmpty && _readSelectedId() == null) {
      _writeSelectedId(_robots.keys.first);
    }
  }

  void _seedInitialReveal() {
    for (final r in _robots.values) {
      _revealAround(r.row, r.col);
      // Send initial observation to backend (robot "powers on" at spawn).
      _postObservation(
        robotId: r.robotId,
        newRow:  r.row,
        newCol:  r.col,
        heading: 'STATIONARY',
        battery: r.battery,
        cells:   _scanSurroundings(r.row, r.col),
      );
    }
  }

  // ── Public API ────────────────────────────────────────────────────────────

  List<RobotState> get allRobots =>
      List.unmodifiable(_robots.values.toList());

  /// Currently selected robot ID.
  String? get selectedRobotId => _readSelectedId();

  /// Select a robot by ID for D-pad control.
  void selectRobot(String? id) => _writeSelectedId(id);

  /// Move the currently selected robot one step in [direction].
  bool moveSelected(RobotMoveDirection direction) {
    final selId = _readSelectedId();
    if (selId == null) return false;
    return moveRobot(selId, direction);
  }

  /// Move a specific robot by ID.
  /// Returns true if the move was valid and executed.
  /// Returns false (no side effects) if the target cell is blocked.
  bool moveRobot(String robotId, RobotMoveDirection direction) {
    final cur = _robots[robotId];
    if (cur == null) return false;

    final delta  = _kDirDelta[direction]!;
    final newRow = cur.row + delta.$1;
    final newCol = cur.col + delta.$2;

    if (!_canMoveTo(newRow, newCol, robotId)) return false;

    // 1. Update local state.
    final updated = cur.copyWith(row: newRow, col: newCol);
    _robots[robotId] = updated;

    // 2. Notify provider → triggers floor repaint.
    _onPositionUpdate(robotId, newRow, newCol);

    // 3. Reveal fog-of-war immediately (optimistic).
    _revealAround(newRow, newCol);

    // 4. Scan surroundings (simulated sensor read from config ground truth).
    final observations = _scanSurroundings(newRow, newCol);

    // 5. Raise local events (replenishment / out-of-stock).
    _raiseLocalEvents(observations);

    // 6. POST observation to backend (fire-and-forget; standard protocol).
    _postObservation(
      robotId: robotId,
      newRow:  newRow,
      newCol:  newCol,
      heading: _kDirHeading[direction]!,
      battery: updated.battery,
      cells:   observations,
    );

    return true;
  }

  void dispose() {} // reserved for future WebSocket/BLE cleanup

  // ── Movement validation ───────────────────────────────────────────────────
  // Hard physics: these rules are ABSOLUTE and apply to every robot type.
  // No robot may ever occupy a cell that matches any condition below.
  bool _canMoveTo(int row, int col, String movingRobotId) {
    // ── 1. Grid boundary ────────────────────────────────────────────────────
    if (row < 0 || row >= config.rows || col < 0 || col >= config.cols) {
      return false;
    }

    final t = _cellAt(row, col)?.type ?? CellType.empty;

    // ── 2. Impassable structure types ────────────────────────────────────────
    //  Rack       — shelf units (all sub-types)
    //  Pillar     — tree / structural column
    //  Obstacle   — loose physical obstacle
    //  Truck bay  — dock cell where a truck is parked
    //  Workstation— pack / label station (approached from adjacent aisle)
    //  Staging    — pallet / case / loose SKU staging areas
    if (t.isRack            ||  // rackLoose, rackCase, rackPallet
        t == CellType.tree         ||  // pillar / structural column
        t == CellType.obstacle     ||  // physical obstacle
        t == CellType.dock         ||  // truck bay (truck occupies this cell)
        t == CellType.packStation  ||  // pack workstation
        t == CellType.labelStation ||  // label workstation
        t == CellType.palletStaging || // pallet / SKU staging area
        t == CellType.looseStaging  || // loose staging area
        t == CellType.caseStaging) {   // case staging area
      return false;
    }

    // ── 3. Robot-robot collision (hard physics: no two robots share a cell) ──
    //  Covers: another robot, an inbound robot, an outbound robot parked here.
    for (final r in _robots.values) {
      if (r.robotId != movingRobotId && r.row == row && r.col == col) {
        return false;
      }
    }

    return true;
  }

  // ── Fog-of-war reveal ─────────────────────────────────────────────────────

  void _revealAround(int r, int c) {
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        final nr = r + dr;
        final nc = c + dc;
        if (nr >= 0 && nr < config.rows && nc >= 0 && nc < config.cols) {
          _onMarkExplored(nr, nc);
        }
      }
    }
  }

  // ── Sensor scan (simulates robot reading its 3×3 neighbourhood) ───────────

  List<Map<String, dynamic>> _scanSurroundings(int r, int c) {
    final result = <Map<String, dynamic>>[];
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        final nr = r + dr;
        final nc = c + dc;
        if (nr < 0 || nr >= config.rows || nc < 0 || nc >= config.cols) continue;
        final cell = _cellAt(nr, nc);
        result.add({
          'row':          nr,
          'col':          nc,
          'cell_type':    cell?.type.name ?? 'empty',
          if (cell?.skuId != null) 'sku_id': cell!.skuId,
          'quantity':     cell?.quantity    ?? 0,
          'max_quantity': cell?.maxQuantity ?? 5,
          'condition':    'nominal',
        });
      }
    }
    return result;
  }

  // ── Local event raising ───────────────────────────────────────────────────

  void _raiseLocalEvents(List<Map<String, dynamic>> observations) {
    const rackTypes = {'rackPallet', 'rackCase', 'rackLoose'};
    for (final obs in observations) {
      final t      = obs['cell_type'] as String;
      final r      = obs['row']          as int;
      final c      = obs['col']          as int;
      final qty    = (obs['quantity']     as num?)?.toInt() ?? 0;
      final maxQty = (obs['max_quantity'] as num?)?.toInt() ?? 5;
      if (rackTypes.contains(t) && maxQty > 0) {
        final fill = qty / maxQty;
        if (fill == 0) {
          _onEventRaise(r, c, 'OUT_OF_STOCK', '#EF4444', 'fast');
        } else if (fill < 0.5) {
          _onEventRaise(r, c, 'REPLENISHMENT_NEEDED', '#F97316', 'slow');
        }
      }
    }
  }

  // ── Backend POST (fire-and-forget) ────────────────────────────────────────

  void _postObservation({
    required String robotId,
    required int    newRow,
    required int    newCol,
    required String heading,
    required double battery,
    required List<Map<String, dynamic>> cells,
  }) {
    final payload = jsonEncode({
      'robot_id':      robotId,
      'warehouse_id':  config.id,
      'position':      {'row': newRow, 'col': newCol},
      'heading':       heading,
      'battery_level': battery,
      'timestamp':     DateTime.now().toUtc().toIso8601String(),
      'cells':         cells,
    });

    http.post(
      Uri.parse('$_backendBase/api/v1/robot/observation'),
      headers: {
        'Content-Type': 'application/json',
        'X-API-Key': 'wois-gateway-internal-key-2026',
        if (_token != null) 'Authorization': 'Bearer $_token',
      },
      body: payload,
    ).then((resp) {
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint('RobotObservation: server ${resp.statusCode} — ${resp.body}');
      }
    }).catchError((e) {
      debugPrint('RobotObservation: network error: $e');
    });
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  WarehouseCell? _cellAt(int r, int c) {
    try {
      return config.cells.lastWhere((x) => x.row == r && x.col == c);
    } catch (_) {
      return null;
    }
  }

  WarehouseCell _firstWalkable() {
    try {
      return config.cells.firstWhere((c) => c.type.isWalkable);
    } catch (_) {
      return WarehouseCell(row: 0, col: 0, type: CellType.empty);
    }
  }
}
