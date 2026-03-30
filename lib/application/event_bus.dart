/// event_bus.dart — Global warehouse event chain + manual-mode state.
///
/// Event chain:
///   WAVE_START → ORDER_RELEASED → ROBOT_ASSIGNED → PATH_COMPUTED
///   → MOVE_START → AISLE_ENTRY → PICK_START → PICK_COMPLETE
///   → PACK_START → PACK_COMPLETE → LABEL_APPLIED
///   → TRUCK_LOAD → SHIP_DEPART
///
/// In Manual Mode the simulator is paused and every event the system
/// *would* have fired is instead queued for user approval.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/sim_frame.dart';
import '../core/api_client.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Event types (aligned with IEC 61512 / S95 terminology)
// ─────────────────────────────────────────────────────────────────────────────

enum WoisEventType {
  // Wave / order lifecycle
  waveStart,
  orderReleased,
  robotAssigned,
  pathComputed,
  // Robot mission lifecycle
  moveStart,
  aisleEntry,
  pickStart,
  pickComplete,
  packStart,
  packComplete,
  labelApplied,
  // Shipping
  truckLoad,
  shipDepart,
  // Exceptions
  aisleConflict,
  robotError,
  robotCharge,
  // Intelligence
  selfHeal,
  sabotage,
  // Generic
  simPaused,
  simResumed,
  custom,
  // WMS / inventory
  inboundOrder,
}

extension WoisEventTypeX on WoisEventType {
  String get icon => switch (this) {
        WoisEventType.waveStart => '🌊',
        WoisEventType.orderReleased => '📋',
        WoisEventType.robotAssigned => '🤖',
        WoisEventType.pathComputed => '🗺',
        WoisEventType.moveStart => '▶',
        WoisEventType.aisleEntry => '🚪',
        WoisEventType.pickStart => '🫳',
        WoisEventType.pickComplete => '✅',
        WoisEventType.packStart => '📦',
        WoisEventType.packComplete => '📫',
        WoisEventType.labelApplied => '🏷',
        WoisEventType.truckLoad => '🔃',
        WoisEventType.shipDepart => '🚛',
        WoisEventType.aisleConflict => '⚠',
        WoisEventType.robotError => '❌',
        WoisEventType.robotCharge => '⚡',
        WoisEventType.selfHeal => '💚',
        WoisEventType.sabotage => '💀',
        WoisEventType.simPaused => '⏸',
        WoisEventType.simResumed => '▶',
        WoisEventType.custom => '🔔',
        WoisEventType.inboundOrder => '📥',
      };

  String get label => switch (this) {
        WoisEventType.waveStart => 'Wave Start',
        WoisEventType.orderReleased => 'Order Released',
        WoisEventType.robotAssigned => 'Robot Assigned',
        WoisEventType.pathComputed => 'Path Computed',
        WoisEventType.moveStart => 'Move Start',
        WoisEventType.aisleEntry => 'Aisle Entry',
        WoisEventType.pickStart => 'Pick Start',
        WoisEventType.pickComplete => 'Pick Complete',
        WoisEventType.packStart => 'Pack Start',
        WoisEventType.packComplete => 'Pack Complete',
        WoisEventType.labelApplied => 'Label Applied',
        WoisEventType.truckLoad => 'Truck Load',
        WoisEventType.shipDepart => 'Shipment Depart',
        WoisEventType.aisleConflict => 'Aisle Conflict',
        WoisEventType.robotError => 'Robot Error',
        WoisEventType.robotCharge => 'Charging Dispatch',
        WoisEventType.selfHeal => 'Self-Heal',
        WoisEventType.sabotage => 'Sabotage Detected',
        WoisEventType.simPaused => 'Sim Paused',
        WoisEventType.simResumed => 'Sim Resumed',
        WoisEventType.custom => 'Custom Event',
        WoisEventType.inboundOrder => 'Inbound Order Required',
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Event model
// ─────────────────────────────────────────────────────────────────────────────

class WoisEvent {
  const WoisEvent({
    required this.id,
    required this.type,
    required this.title,
    required this.description,
    required this.ts,
    this.parentId,
    this.robotId,
    this.requiresApproval = false,
    this.approved,
    this.childIds = const [],
  });

  final String id;
  final WoisEventType type;
  final String title;
  final String description;
  final DateTime ts;
  final String? parentId; // causal parent event
  final String? robotId;
  final bool requiresApproval;
  final bool? approved; // null = pending, true = approved, false = skipped
  final List<String> childIds; // events triggered by this one

  bool get isPending => requiresApproval && approved == null;
  bool get isApproved => approved == true;
  bool get isSkipped => approved == false;

  WoisEvent copyWith({bool? approved, List<String>? childIds}) => WoisEvent(
        id: id,
        type: type,
        title: title,
        description: description,
        ts: ts,
        parentId: parentId,
        robotId: robotId,
        requiresApproval: requiresApproval,
        approved: approved ?? this.approved,
        childIds: childIds ?? this.childIds,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────────────────────

class ManualModeState {
  const ManualModeState({
    this.isManual = false,
    this.pendingEvents = const [],
    this.eventHistory = const [],
    this.seenDescriptions = const {},
  });

  final bool isManual;
  final List<WoisEvent> pendingEvents;
  final List<WoisEvent> eventHistory;

  /// Track which SelfHealEvent descriptions we've already ingested
  /// to avoid duplicates across frames.
  final Set<String> seenDescriptions;

  ManualModeState copyWith({
    bool? isManual,
    List<WoisEvent>? pendingEvents,
    List<WoisEvent>? eventHistory,
    Set<String>? seenDescriptions,
  }) =>
      ManualModeState(
        isManual: isManual ?? this.isManual,
        pendingEvents: pendingEvents ?? this.pendingEvents,
        eventHistory: eventHistory ?? this.eventHistory,
        seenDescriptions: seenDescriptions ?? this.seenDescriptions,
      );

  /// All events chronologically (history newest-first, pending at end).
  List<WoisEvent> get all => [...eventHistory, ...pendingEvents];
}

// ─────────────────────────────────────────────────────────────────────────────
// Notifier
// ─────────────────────────────────────────────────────────────────────────────

class ManualModeNotifier extends StateNotifier<ManualModeState> {
  ManualModeNotifier() : super(const ManualModeState());

  int _seq = 0;
  String _newId() => 'evt-${DateTime.now().millisecondsSinceEpoch}-${_seq++}';

  // ── Manual mode toggle ───────────────────────────────────────────────────

  Future<void> toggleManual() async {
    if (state.isManual) {
      // Turn OFF → resume simulation
      try {
        await ApiClient.instance.resumeSim();
      } catch (_) {}
      final resumeEvt = WoisEvent(
        id: _newId(),
        type: WoisEventType.simResumed,
        title: 'Simulation Resumed',
        description: 'Manual mode disabled — simulation running automatically.',
        ts: DateTime.now(),
      );
      state = state.copyWith(
        isManual: false,
        pendingEvents: [],
        eventHistory: [resumeEvt, ...state.eventHistory],
      );
    } else {
      // Turn ON → pause simulation
      try {
        await ApiClient.instance.pauseSim();
      } catch (_) {}
      final now = DateTime.now();
      final pauseEvt = WoisEvent(
        id: _newId(),
        type: WoisEventType.simPaused,
        title: 'Simulation Paused — Manual Mode Active',
        description: 'All events now require your approval before executing.',
        ts: now,
      );
      // Seed two common approval prompts
      final seedWave = WoisEvent(
        id: _newId(),
        type: WoisEventType.waveStart,
        title: 'Trigger Next Wave',
        description:
            'Launch the next wave of orders into the fulfilment pipeline.',
        ts: now,
        requiresApproval: true,
      );
      final seedCharge = WoisEvent(
        id: _newId(),
        type: WoisEventType.robotCharge,
        title: 'Dispatch Low-Battery Robots',
        description:
            'Route all robots with battery < 20 % to the nearest charging station.',
        ts: now,
        requiresApproval: true,
      );
      state = state.copyWith(
        isManual: true,
        pendingEvents: [seedWave, seedCharge],
        eventHistory: [pauseEvt, ...state.eventHistory],
      );
    }
  }

  // ── Approve ──────────────────────────────────────────────────────────────

  Future<void> approveEvent(String id) async {
    final event = state.pendingEvents.firstWhere((e) => e.id == id,
        orElse: () => throw StateError('Event $id not found'));

    // Fire the corresponding API call
    switch (event.type) {
      case WoisEventType.waveStart:
        try {
          await ApiClient.instance.triggerWave();
        } catch (_) {}
      case WoisEventType.inboundOrder:
        try {
          await ApiClient.instance.triggerWave();
        } catch (_) {}
      case WoisEventType.robotCharge:
      case WoisEventType.selfHeal:
        // handled internally by simulation after resume
        break;
      default:
        break;
    }

    final approved = event.copyWith(approved: true);
    state = state.copyWith(
      pendingEvents: state.pendingEvents.where((e) => e.id != id).toList(),
      eventHistory: [approved, ...state.eventHistory],
    );
  }

  // ── Skip ─────────────────────────────────────────────────────────────────

  void skipEvent(String id) {
    final event = state.pendingEvents.firstWhere((e) => e.id == id,
        orElse: () => throw StateError('Event $id not found'));
    final skipped = event.copyWith(approved: false);
    state = state.copyWith(
      pendingEvents: state.pendingEvents.where((e) => e.id != id).toList(),
      eventHistory: [skipped, ...state.eventHistory],
    );
  }

  // ── Ingest from SimFrame ──────────────────────────────────────────────────

  void ingestFromFrame(SimFrame frame) {
    final newSeen = Set<String>.from(state.seenDescriptions);
    final newPending = List<WoisEvent>.from(state.pendingEvents);
    final newHistory = List<WoisEvent>.from(state.eventHistory);

    for (final e in frame.selfHealingEvents) {
      final key = '${e.type}|${e.description}|${e.ts.toIso8601String()}';
      if (newSeen.contains(key)) continue;
      newSeen.add(key);

      final evt = WoisEvent(
        id: _newId(),
        type: WoisEventType.selfHeal,
        title: 'Self-Heal: ${e.type}',
        description: e.description,
        ts: e.ts,
        requiresApproval: state.isManual,
      );

      if (state.isManual) {
        newPending.add(evt);
      } else {
        newHistory.insert(0, evt);
      }
    }

    state = state.copyWith(
      pendingEvents: newPending,
      eventHistory: newHistory,
      seenDescriptions: newSeen,
    );
  }

  // ── Custom event injection ────────────────────────────────────────────────

  void addCustomEvent(String title, String description) {
    final evt = WoisEvent(
      id: _newId(),
      type: WoisEventType.custom,
      title: title,
      description: description,
      ts: DateTime.now(),
      requiresApproval: state.isManual,
    );
    if (state.isManual) {
      state = state.copyWith(pendingEvents: [...state.pendingEvents, evt]);
    } else {
      state = state.copyWith(eventHistory: [evt, ...state.eventHistory]);
    }
  }

  // ── Inbound-order approval event (always requires approval) ──────────────

  /// Creates an inbound-order event that ALWAYS requires approval, even when
  /// the simulation is running. Approve → calls triggerWave / triggers A1.
  void addInboundOrderEvent(String skuId, String description) {
    final evt = WoisEvent(
      id: _newId(),
      type: WoisEventType.inboundOrder,
      title: 'Inbound Order Required — $skuId',
      description: description,
      ts: DateTime.now(),
      requiresApproval: true, // always pending regardless of manual mode
    );
    state = state.copyWith(pendingEvents: [...state.pendingEvents, evt]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

final manualModeProvider =
    StateNotifierProvider<ManualModeNotifier, ManualModeState>(
  (ref) => ManualModeNotifier(),
);

// ─────────────────────────────────────────────────────────────────────────────
// Speech Bubble — temporary canvas overlays (3 s auto-dismiss)
// ─────────────────────────────────────────────────────────────────────────────

/// A transient annotation shown on the floor canvas when an event fires.
class SpeechBubble {
  const SpeechBubble({
    required this.id,
    required this.text,
    required this.row,
    required this.col,
  });

  final String id;
  final String text; // e.g. "📥 Inbound Order Required"
  final int row;
  final int col;
}

class SpeechBubbleNotifier extends StateNotifier<List<SpeechBubble>> {
  SpeechBubbleNotifier() : super(const []);

  int _seq = 0;

  void add({required String text, required int row, required int col}) {
    final id = 'sbl-${DateTime.now().millisecondsSinceEpoch}-${_seq++}';
    final bubble = SpeechBubble(id: id, text: text, row: row, col: col);
    state = [...state, bubble];
    // Auto-dismiss after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) state = state.where((b) => b.id != id).toList();
    });
  }
}

final speechBubbleProvider =
    StateNotifierProvider<SpeechBubbleNotifier, List<SpeechBubble>>(
  (ref) => SpeechBubbleNotifier(),
);
