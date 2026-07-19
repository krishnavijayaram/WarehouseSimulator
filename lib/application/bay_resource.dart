/// bay_resource.dart — the single authority for inbound/outbound bay occupancy.
///
/// CAS allocation prevents double-booking (the round-robin `slotIndex % docks`
/// bug the review flagged). A truck claims the first free bay atomically; the
/// map holds only OCCUPIED bays, keyed by cell, valued by the owning truck id.
///
/// A dedicated BayAllocatorBrain (fairness / anti-starvation, DLS-5) refines
/// this in a later pass; the CAS invariant here already makes it collision-safe.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'job_board.dart' show GridPos;

class BayOccupancyNotifier extends StateNotifier<Map<String, String>> {
  BayOccupancyNotifier() : super(const {});

  String _key(int row, int col) => '${row}_$col';

  bool isOccupied(int row, int col) => state.containsKey(_key(row, col));

  /// CAS-claim the first free bay from [bays]. Returns the claimed cell, or null
  /// if every candidate bay is occupied.
  GridPos? claimFirstFree(List<GridPos> bays, String truckId) {
    for (final b in bays) {
      final k = _key(b.row, b.col);
      if (!state.containsKey(k)) {
        state = {...state, k: truckId};
        return b;
      }
    }
    return null;
  }

  void release(int row, int col) {
    final k = _key(row, col);
    if (!state.containsKey(k)) return;
    state = {...state}..remove(k);
  }

  /// Release every cell held by [unitId] (e.g. when a unit despawns mid-hold).
  void releaseAllBy(String unitId) {
    final next = {
      for (final e in state.entries)
        if (e.value != unitId) e.key: e.value
    };
    if (next.length != state.length) state = next;
  }

  void clear() => state = const {};
}

final bayOccupancyProvider =
    StateNotifierProvider<BayOccupancyNotifier, Map<String, String>>(
  (_) => BayOccupancyNotifier(),
);

/// Charger docks use the same CAS cell-occupancy mechanism as bays (one robot
/// per dock, claimed atomically). Separate provider, same notifier.
final chargerOccupancyProvider =
    StateNotifierProvider<BayOccupancyNotifier, Map<String, String>>(
  (_) => BayOccupancyNotifier(),
);

// ── Decision-time cell reservations ──────────────────────────────────────────
// A unit reserves a target cell when it DECIDES to use it (not just when it
// arrives), so two units in the same tick can't both pick the same rack face /
// stage cell / staging slot. Phase 1 runs sequentially, so a reservation made by
// an earlier brain is seen by a later one — same safety as the CAS job-claim.
// Closes the review's F2-fsm (dest rack), F3/F5 (stage cell), SBI-2 (source face).

/// Rack faces reserved as a pick SOURCE or a putaway DEST.
final rackReservationProvider =
    StateNotifierProvider<BayOccupancyNotifier, Map<String, String>>(
  (_) => BayOccupancyNotifier(),
);

/// Outbound stage cells reserved by a picker until it places the pallet.
final stageReservationProvider =
    StateNotifierProvider<BayOccupancyNotifier, Map<String, String>>(
  (_) => BayOccupancyNotifier(),
);

/// Per-TICK cell occupancy for move arbitration (P6 hard layer): the scheduler
/// re-seeds it each tick with every unit's current cell; a mover reserves its
/// next cell before entering, so two units never occupy one cell in a tick.
final cellReservationProvider =
    StateNotifierProvider<BayOccupancyNotifier, Map<String, String>>(
  (_) => BayOccupancyNotifier(),
);
