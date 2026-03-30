// sim_clock.dart
// Ported from: ops_simulator/engine/clock.py
// Pure simulation clock with speed multiplier, event queue, and watchdog pause.

import 'dart:collection';

import '../constants/sim_constants.dart';

/// Whether the clock is running autonomously or stepping manually.
enum ClockMode { simulation, manual }

/// An event that requires operator approval or automatic execution at a future tick.
class SimEvent {
  final String id;
  final String type;
  final String description;
  final Map<String, dynamic> params;
  final DateTime timestamp;
  bool approved;

  SimEvent({
    required this.id,
    required this.type,
    required this.description,
    required this.params,
    DateTime? timestamp,
    this.approved = false,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() => 'SimEvent($type, approved=$approved, $description)';
}

/// Core simulation clock.
///
/// Tracks simulated time (fractional seconds), supports speed multipliers,
/// owns the "watchdog" auto-pause logic (if the UI stops calling [uiHeartbeat]
/// for [kWatchdogTimeout], the clock automatically pauses), and holds a
/// pending-event queue for the dispatcher.
class SimulationClock {
  ClockMode mode;
  double _speed;
  double _simTime; // Accumulated simulated seconds
  bool _running;

  DateTime? _realStart;
  double _simTimeAtLastResume;
  DateTime? _lastHeartbeat;

  final Queue<SimEvent> _eventQueue = Queue();
  int _eventSeq = 0;

  SimulationClock({
    ClockMode mode = ClockMode.simulation,
    double speed = kDefaultSpeed,
  })  : mode = mode,
        _speed = speed,
        _simTime = 0,
        _running = false,
        _simTimeAtLastResume = 0;

  // ── Queries ──────────────────────────────────────────────────────────────

  bool get isRunning => _running;
  double get speed => _speed;

  /// Current simulated time in seconds.
  double getSimTime() {
    if (!_running || _realStart == null) return _simTime;
    final elapsed = DateTime.now().difference(_realStart!).inMicroseconds / 1e6;
    return _simTimeAtLastResume + elapsed * _speed;
  }

  /// Convenience: whole seconds elapsed.
  int get simSeconds => getSimTime().truncate();

  // ── Control ──────────────────────────────────────────────────────────────

  /// Start or resume the clock.
  void resumeClock() {
    if (_running) return;
    _simTimeAtLastResume = _simTime;
    _realStart = DateTime.now();
    _lastHeartbeat = DateTime.now();
    _running = true;
  }

  /// Pause the clock, snapshotting current simTime.
  void pauseClock() {
    if (!_running) return;
    _simTime = getSimTime();
    _running = false;
    _realStart = null;
  }

  /// Change speed multiplier. Must be in [kValidSpeeds].
  void setSpeed(double newSpeed) {
    assert(
        kValidSpeeds.contains(newSpeed), 'Speed $newSpeed not in kValidSpeeds');
    if (_running) {
      // Snapshot current time before changing speed so continuity is preserved.
      _simTime = getSimTime();
      _simTimeAtLastResume = _simTime;
      _realStart = DateTime.now();
    }
    _speed = newSpeed;
  }

  /// Reset to zero.
  void reset() {
    _running = false;
    _realStart = null;
    _simTime = 0;
    _simTimeAtLastResume = 0;
    _eventQueue.clear();
  }

  // ── Watchdog ─────────────────────────────────────────────────────────────

  /// Called by the UI render loop each frame to prove the client is alive.
  /// If this stops being called for [kWatchdogTimeout], the clock auto-pauses.
  void uiHeartbeat() {
    _lastHeartbeat = DateTime.now();
  }

  /// Checks the watchdog condition. Returns `true` if the clock was paused.
  /// Call this on each simulation tick.
  bool checkWatchdog() {
    if (!_running || _lastHeartbeat == null) return false;
    if (DateTime.now().difference(_lastHeartbeat!) > kWatchdogTimeout) {
      pauseClock();
      return true;
    }
    return false;
  }

  // ── Event queue ───────────────────────────────────────────────────────────

  /// Add an event to the approval queue. Returns the created event.
  SimEvent queueEvent(
    String type,
    String description, [
    Map<String, dynamic>? params,
  ]) {
    final event = SimEvent(
      id: 'evt-${++_eventSeq}',
      type: type,
      description: description,
      params: params ?? {},
    );
    _eventQueue.addLast(event);
    return event;
  }

  /// Pop the next pending (unapproved) event, if any.
  SimEvent? nextEvent() =>
      _eventQueue.isEmpty ? null : _eventQueue.removeFirst();

  /// Approve all queued events that match [type].
  void approveEventsOfType(String type) {
    for (final e in _eventQueue) {
      if (e.type == type) e.approved = true;
    }
  }

  int get pendingEventCount => _eventQueue.length;

  // ── Manual step (for testing / replay) ───────────────────────────────────

  /// Advance simulated time by exactly [deltaSeconds] regardless of clock mode.
  void manualStep(double deltaSeconds) {
    _simTime += deltaSeconds;
  }

  @override
  String toString() =>
      'SimClock(running=$_running, speed=${_speed}x, t=${getSimTime().toStringAsFixed(1)}s)';
}
