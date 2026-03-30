// sim_constants.dart
// Ported from: SyntWare/warehouse_core/models/sim_layout.py + shared/constants.py
// Pure configuration constants — no network/DB/UI dependency.

/// Valid simulation speed multipliers.
const List<double> kValidSpeeds = [0.5, 1.0, 1.5, 2.0];

/// Default clock speed on start.
const double kDefaultSpeed = 1.0;

/// Watchdog auto-pause: if no UI heartbeat after this duration, pause clock.
const Duration kWatchdogTimeout = Duration(seconds: 60);

// ── Wave / Pick configuration ─────────────────────────────────────────────────

/// Number of picks released per wave.
const int kWaveSize = 12;

/// Minimum picks in a wave (validation guard).
const int kWaveMinPicks = 15;

/// Maximum picks in a wave (validation guard).
const int kWaveMaxPicks = 25;

/// Seconds between two wave releases.
const int kWaveIntervalSeconds = 120;

/// Seconds between greedy auto-assign sweeps.
const int kAssignIntervalSeconds = 30;

/// Minimum pick duration in milliseconds per task.
const int kPickDurationMinMs = 90;

/// Maximum additional random duration on top of minimum (jitter).
const int kPickDurationRandMs = 60;

/// Expected initial bin fill rate (65% of bins start populated).
const double kDefaultShelfOccupancy = 0.65;

// ── Robot battery dynamics ────────────────────────────────────────────────────

/// Battery drain per simulation tick while working.
const double kBatteryDrainPerTick = 0.15;

/// Battery recharge per simulation tick while idle at charger.
const double kBatteryChargePerTick = 0.80;

/// Battery level below which robot heads to charger.
const double kBatteryLowThreshold = 20.0;

// ── Robot action durations (in ticks) ────────────────────────────────────────

/// Simulation ticks spent picking at a bin.
const int kPickTicks = 3;

/// Simulation ticks spent putting at staging.
const int kPutTicks = 2;

// ── Path planning ─────────────────────────────────────────────────────────────

/// Cost penalty added per step through a cell occupied by another robot.
const int kRobotStepPenalty = 8;

// ── PTL display ───────────────────────────────────────────────────────────────

/// How many ticks a PTL light stays visible in 'done' state before clearing.
const int kPtlDoneLingerticks = 10;
