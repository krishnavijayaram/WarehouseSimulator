// robot.dart
// Ported from: ops_simulator/engine/robot_manager.py
// Pure data model — no network/DB/UI dependency.

/// Six-state lifecycle for a warehouse robot.
enum RobotState {
  idle,
  navigatingPick,
  picking,
  navigatingPut,
  putting,
  charging,
}

/// One atomic task: pick from [binCell], deliver to [putCell].
class RobotMission {
  final String missionId;
  final String orderId;
  final String skuId;
  final String binId;
  final (int, int) binCell;
  final (int, int) putCell;
  final int stageSlot;

  const RobotMission({
    required this.missionId,
    required this.orderId,
    required this.skuId,
    required this.binId,
    required this.binCell,
    required this.putCell,
    this.stageSlot = 0,
  });
}

/// Tracks completion of a multi-SKU order across multiple robots.
class OrderProgress {
  final String orderId;
  final List<String> skuList;
  final List<String> missions;
  final List<String> completedMissions = [];
  String status = 'PICKING'; // 'PICKING' | 'COMPLETE'

  OrderProgress({
    required this.orderId,
    required this.skuList,
    required this.missions,
  });

  int get progressPercent => missions.isEmpty
      ? 0
      : (completedMissions.length * 100 ~/ missions.length);

  bool get isComplete => status == 'COMPLETE';
}

/// A single warehouse robot with position, state, battery, and mission.
class Robot {
  final String id;
  final int idx;
  final String color;

  RobotState state = RobotState.idle;
  (int, int) position;
  List<(int, int)> path = [];
  List<(int, int)> pathHistory = [];
  RobotMission? mission;
  int ticksInState = 0;
  double battery = 100.0;
  int ordersCompleted = 0;
  int totalDistance = 0;

  Robot({
    required this.id,
    required this.idx,
    required this.color,
    (int, int) initialPosition = (33, 50),
  }) : position = initialPosition;

  bool get isIdle => state == RobotState.idle;
  bool get needsCharging => battery < 20.0;

  /// Battery as a 0.0–1.0 fraction for progress indicators.
  double get batteryFraction => (battery / 100.0).clamp(0.0, 1.0);

  /// True while the robot has a pending path to follow.
  bool get isNavigating =>
      state == RobotState.navigatingPick || state == RobotState.navigatingPut;

  @override
  String toString() =>
      'Robot($id, state=$state, battery=${battery.toStringAsFixed(0)}%, pos=$position)';
}
