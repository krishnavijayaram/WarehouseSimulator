// ptl_light.dart
// Ported from: SyntWare warehouse_core PTL light system + ops_simulator visual state
// Put-to-Light (PTL) display system — pure business logic, no UI imports.

import '../constants/sim_constants.dart';

/// Operating mode of a single PTL light cell.
enum PTLMode {
  /// Idle — no active instruction.
  idle,

  /// Robot is navigating to this bin to pick.
  pick,

  /// Robot has arrived and is actively picking.
  active,

  /// Robot has picked and is navigating to put-wall.
  put,

  /// Operation complete, cooling down before cleared.
  done,
}

/// A single PTL display node associated with one bin on the warehouse floor.
class PTLLight {
  /// Grid cell coordinate matching the bin face cell.
  final (int, int) cell;

  /// Bin this light is attached to.
  final String binId;

  /// Currently active robot handling this task.
  String robotId;

  /// Order driving this task.
  String orderId;

  /// Current display mode.
  PTLMode mode;

  /// Display color (hex string, e.g. '#FF5722').
  String color;

  /// Whether the light should pulse on the UI.
  bool pulse;

  /// Tick timestamp when mode last changed (for expiry of 'done' state).
  int modeChangedAtTick;

  PTLLight({
    required this.cell,
    required this.binId,
    required this.robotId,
    required this.orderId,
    this.mode = PTLMode.idle,
    this.color = '#FFFFFF',
    this.pulse = false,
    this.modeChangedAtTick = 0,
  });

  /// Quick copy with updated fields.
  PTLLight copyWith({
    PTLMode? mode,
    String? color,
    bool? pulse,
    String? robotId,
    String? orderId,
    int? modeChangedAtTick,
  }) =>
      PTLLight(
        cell: cell,
        binId: binId,
        robotId: robotId ?? this.robotId,
        orderId: orderId ?? this.orderId,
        mode: mode ?? this.mode,
        color: color ?? this.color,
        pulse: pulse ?? this.pulse,
        modeChangedAtTick: modeChangedAtTick ?? this.modeChangedAtTick,
      );
}

/// Manages the active set of PTL lights for the entire warehouse floor.
/// Keyed by binId; at most one light per bin at a time.
class PTLManager {
  final Map<String, PTLLight> _lights = {};

  Map<String, PTLLight> get lights => Map.unmodifiable(_lights);

  /// Assign a new PTL mission (robot starting navigation to bin).
  /// If a light already exists for the bin it will be replaced.
  void assignMission({
    required (int, int) cell,
    required String binId,
    required String robotId,
    required String orderId,
    required String color,
    required int tick,
  }) {
    _lights[binId] = PTLLight(
      cell: cell,
      binId: binId,
      robotId: robotId,
      orderId: orderId,
      mode: PTLMode.pick,
      color: color,
      pulse: true,
      modeChangedAtTick: tick,
    );
  }

  /// Called when a robot arrives at the bin to pick.
  void onRobotArrivalAtBin(String binId, int tick) {
    if (!_lights.containsKey(binId)) return;
    _lights[binId] = _lights[binId]!.copyWith(
      mode: PTLMode.active,
      pulse: true,
      modeChangedAtTick: tick,
    );
  }

  /// Called when pick completes; robot now navigating to put-wall.
  void onPickComplete(String binId, int tick) {
    if (!_lights.containsKey(binId)) return;
    _lights[binId] = _lights[binId]!.copyWith(
      mode: PTLMode.put,
      pulse: false,
      modeChangedAtTick: tick,
    );
  }

  /// Called when put is confirmed; switch to done for brief display.
  void onPutComplete(String binId, int tick) {
    if (!_lights.containsKey(binId)) return;
    _lights[binId] = _lights[binId]!.copyWith(
      mode: PTLMode.done,
      pulse: false,
      modeChangedAtTick: tick,
    );
  }

  /// Remove any 'done' lights that have been visible long enough.
  /// Call once per simulation tick.
  void removeExpiredDones(int currentTick) {
    _lights.removeWhere(
      (_, light) =>
          light.mode == PTLMode.done &&
          (currentTick - light.modeChangedAtTick) >= kPtlDoneLingerticks,
    );
  }

  /// Remove the light for a specific bin (e.g., mission cancelled).
  void clear(String binId) => _lights.remove(binId);

  /// Remove all lights owned by a specific robot (e.g., robot going offline).
  void clearRobot(String robotId) =>
      _lights.removeWhere((_, l) => l.robotId == robotId);

  /// Lights currently in 'pick' or 'active' mode — shown bright.
  Iterable<PTLLight> get activeLights => _lights.values
      .where((l) => l.mode == PTLMode.active || l.mode == PTLMode.pick);

  int get count => _lights.length;
}
