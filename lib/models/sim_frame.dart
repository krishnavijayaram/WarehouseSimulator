/// Models for the 20 Hz WebSocket frame broadcast by the simulation engine.
/// Schema mirrors WIOS/simulation/main.py SimBroadcastManager.broadcast().
library;

import 'package:flutter/foundation.dart';

// ── Robot ─────────────────────────────────────────────────────────────────────

@immutable
class Robot {
  const Robot({
    required this.id,
    required this.name,
    required this.type,
    required this.x,
    required this.y,
    required this.state,
    required this.battery,
    this.picks = 0,
    this.currentOrder,
    this.pathX = const [],
    this.pathY = const [],
    this.domain = 'ANY',
  });

  final String id;
  final String name;
  final String type;     // AMR | AGV
  final double x;
  final double y;
  final String state;    // IDLE | MOVING | PICKING | CHARGING | ERROR
  final double battery;  // 0.0 – 1.0
  final int picks;
  final String? currentOrder;
  final List<double> pathX;
  final List<double> pathY;
  /// Robot operational domain — controls which zones the robot is allowed in.
  /// Values: INBOUND | OUTBOUND | PICK | REPLEN | ANY
  final String domain;

  factory Robot.fromJson(Map<String, dynamic> j) => Robot(
    id:           j['id']           as String? ?? '',
    name:         j['name']         as String? ?? '',
    type:         j['type']         as String? ?? 'AMR',
    x:            (j['x']  as num? ?? 0).toDouble(),
    y:            (j['y']  as num? ?? 0).toDouble(),
    state:        j['state']        as String? ?? 'IDLE',
    battery:      (j['battery'] as num? ?? 1.0).toDouble(),
    picks:        j['picks']        as int? ?? 0,
    currentOrder: j['current_order'] as String?,
    pathX: (j['path_x'] as List<dynamic>? ?? []).map<double>((e) => (e as num).toDouble()).toList(),
    pathY: (j['path_y'] as List<dynamic>? ?? []).map<double>((e) => (e as num).toDouble()).toList(),
    domain:       j['domain']       as String? ?? 'ANY',
  );

  bool get isCharging  => state == 'CHARGING';
  bool get hasError    => state == 'ERROR';
  bool get isIdle      => state == 'IDLE';
  bool get isInbound   => domain == 'INBOUND';
  bool get isOutbound  => domain == 'OUTBOUND';

  String get batteryPercent => '${(battery * 100).round()}%';

  /// Short label shown in the robot panel domain badge.
  String get domainLabel => switch (domain) {
    'INBOUND'  => 'Inbound',
    'OUTBOUND' => 'Outbound',
    'PICK'     => 'Pick',
    'REPLEN'   => 'Replen',
    _          => 'Any',
  };
}

// ── Order ─────────────────────────────────────────────────────────────────────

@immutable
class WaveOrder {
  const WaveOrder({
    required this.id,
    required this.type,
    required this.status,
    this.robotId,
    this.progress = 0,
  });

  final String id;
  final String type;    // LOOSE_PICK | CASE_PICK | PALLET
  final String status;  // PENDING | IN_PROGRESS | DONE
  final String? robotId;
  final int progress;   // 0-100

  factory WaveOrder.fromJson(Map<String, dynamic> j) => WaveOrder(
    id:       j['id']       as String? ?? '',
    type:     j['type']     as String? ?? 'LOOSE_PICK',
    status:   j['status']   as String? ?? 'PENDING',
    robotId:  j['robot_id'] as String?,
    progress: j['progress'] as int? ?? 0,
  );
}

// ── KPI snapshot ──────────────────────────────────────────────────────────────

@immutable
class KpiSnapshot {
  const KpiSnapshot({
    this.ordersDone = 0,
    this.activeBots = 0,
    this.conflicts  = 0,
    this.efficiency = 0.0,
    this.detectionLatencyMs, 
  });

  final int ordersDone;
  final int activeBots;
  final int conflicts;
  final double efficiency;         // 0.0 – 1.0
  final double? detectionLatencyMs; // null until F3 data arrives

  factory KpiSnapshot.fromJson(Map<String, dynamic> j) => KpiSnapshot(
    ordersDone:         j['orders_done']          as int? ?? 0,
    activeBots:         j['active_bots']           as int? ?? 0,
    conflicts:          j['conflicts']             as int? ?? 0,
    efficiency:         (j['efficiency'] as num? ?? 0).toDouble(),
    detectionLatencyMs: j['detection_latency_ms'] != null
        ? (j['detection_latency_ms'] as num).toDouble()
        : null,
  );

  String get efficiencyLabel => '${(efficiency * 100).round()}%';
}

// ── Self-healing event (D4) ───────────────────────────────────────────────────

@immutable
class SelfHealEvent {
  const SelfHealEvent({
    required this.type,
    required this.description,
    required this.ts,
  });

  final String type;
  final String description;
  final DateTime ts;

  factory SelfHealEvent.fromJson(Map<String, dynamic> j) => SelfHealEvent(
    type:        j['type']        as String? ?? 'ANOMALY',
    description: j['description'] as String? ?? '',
    ts:          j['ts'] != null
        ? DateTime.tryParse(j['ts'] as String) ?? DateTime.now()
        : DateTime.now(),
  );
}

// ── Layout proposal (D5) ─────────────────────────────────────────────────────

@immutable
class LayoutProposal {
  const LayoutProposal({
    required this.id,
    required this.description,
    required this.status,
    this.gainPercent = 0.0,
  });

  final String id;
  final String description;
  final String status;      // PENDING | APPROVED | REJECTED
  final double gainPercent;

  factory LayoutProposal.fromJson(Map<String, dynamic> j) => LayoutProposal(
    id:          j['id']          as String? ?? '',
    description: j['description'] as String? ?? '',
    status:      j['status']      as String? ?? 'PENDING',
    gainPercent: (j['gain_percent'] as num? ?? 0).toDouble(),
  );

  bool get isPending => status == 'PENDING';
}

// ── Charger station (config + runtime status stub) ──────────────────────────────────────

/// Physical type — determines charge rate and compatible robot variants.
enum ChargerKind { fast, slow }

/// Operational health. A saboteur may flip this to [fault];
/// the self-healing layer monitors detection latency and recovery time.
enum ChargerOperational { working, fault }

/// Whether a robot currently occupies the berth.
enum ChargerOccupancy { free, busy }

/// Runtime snapshot of a single charger station.
///
/// [kind] is derived from the configured cell type (chargingFast / chargingSlow).
/// [operational] and [occupancy] are emitted per sim-frame by the Python engine.
/// [faultCode] carries sabotage/fault descriptors for the self-healing layer.
@immutable
class ChargerStation {
  const ChargerStation({
    required this.id,
    required this.row,
    required this.col,
    required this.kind,
    this.operational = ChargerOperational.working,
    this.occupancy   = ChargerOccupancy.free,
    this.faultCode,
  });

  final String id;
  final int    row, col;
  final ChargerKind        kind;
  final ChargerOperational operational;
  final ChargerOccupancy   occupancy;

  /// Non-null when [operational] == fault; carries the sabotage event descriptor.
  final String? faultCode;

  bool get isAvailable =>
      operational == ChargerOperational.working &&
      occupancy   == ChargerOccupancy.free;

  factory ChargerStation.fromJson(Map<String, dynamic> j) => ChargerStation(
    id:          j['id']    as String? ?? '',
    row:         j['row']   as int?    ?? 0,
    col:         j['col']   as int?    ?? 0,
    kind:        j['kind'] == 'fast' ? ChargerKind.fast : ChargerKind.slow,
    operational: j['operational'] == 'fault'
        ? ChargerOperational.fault : ChargerOperational.working,
    occupancy:   j['occupancy'] == 'busy'
        ? ChargerOccupancy.busy : ChargerOccupancy.free,
    faultCode:   j['fault_code'] as String?,
  );
}

// ── Full sim frame ────────────────────────────────────────────────────────────

@immutable
class SimFrame {
  const SimFrame({
    required this.robots,
    required this.orders,
    required this.kpi,
    required this.gameMode,
    required this.saboteurCredits,
    required this.selfHealingEvents,
    required this.layoutProposals,
    required this.waveNumber,
    required this.simStatus,
    required this.ts,
    this.chargers = const [],  // stub: populated once sim broadcasts charger[]
  });

  static const empty = SimFrame(
    robots: [],
    orders: [],
    kpi: KpiSnapshot(),
    gameMode: 'OPTION_3',
    saboteurCredits: 100,
    selfHealingEvents: [],
    layoutProposals: [],
    waveNumber: 0,
    simStatus: 'STOPPED',
    ts: '',
  );

  final List<Robot> robots;
  final List<WaveOrder> orders;
  final KpiSnapshot kpi;
  final String gameMode;
  final int saboteurCredits;
  final List<SelfHealEvent> selfHealingEvents;
  final List<LayoutProposal> layoutProposals;
  final int waveNumber;
  final String simStatus;   // RUNNING | PAUSED | STOPPED
  final String ts;
  final List<ChargerStation> chargers;

  factory SimFrame.fromJson(Map<String, dynamic> j) => SimFrame(
    robots: (j['robots'] as List<dynamic>? ?? [])
        .map((r) => Robot.fromJson(r as Map<String, dynamic>))
        .toList(),
    orders: (j['orders'] as List<dynamic>? ?? [])
        .map((o) => WaveOrder.fromJson(o as Map<String, dynamic>))
        .toList(),
    kpi:    j['kpi'] != null
        ? KpiSnapshot.fromJson(j['kpi'] as Map<String, dynamic>)
        : const KpiSnapshot(),
    gameMode:        j['game_mode']        as String? ?? 'OPTION_3',
    saboteurCredits: j['saboteur_credits'] as int? ?? 100,
    selfHealingEvents: (j['self_healing_events'] as List<dynamic>? ?? [])
        .map((e) => SelfHealEvent.fromJson(e as Map<String, dynamic>))
        .toList(),
    layoutProposals: (j['layout_proposals'] as List<dynamic>? ?? [])
        .map((p) => LayoutProposal.fromJson(p as Map<String, dynamic>))
        .toList(),
    waveNumber: j['wave_number'] as int? ?? 0,
    simStatus:  j['sim_status']  as String? ?? 'STOPPED',
    ts:         j['ts']          as String? ?? '',
    chargers: (j['chargers'] as List<dynamic>? ?? [])
        .map((c) => ChargerStation.fromJson(c as Map<String, dynamic>))
        .toList(),
  );
}
