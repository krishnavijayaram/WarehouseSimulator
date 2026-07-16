/// unit_scheduler.dart — the tick clock (NOT a controller).
///
/// Each tick it runs the fixed phase order over every registered unit brain:
///   Phase 1   perceive & decide  — each brain senses the world, CAS-claims a
///             Job, and registers its intended move/action for this tick.
///   Phase 1.5 arbiter grants     — resolves contested cells/resources.
///             P0: pass-through GRANT-ALL (real AisleTrafficArbiter lands in P6).
///   Phase 2   act                — each brain executes its granted intent.
///   Phase 3   flush/sweep        — terminal Orders/Jobs are swept so the
///             per-tick scan stays O(active work) (v2 Amendment D / SBI-4).
///
/// Iteration is id-sorted (via UnitRegistry.all()) so runs are reproducible —
/// the determinism prerequisite for the JEPA eval.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/warehouse_config.dart';
import '../bay_resource.dart';
import '../job_board.dart';
import '../providers.dart';
import 'unit_brain.dart';

class UnitScheduler {
  const UnitScheduler(this.ref);
  final WidgetRef ref;

  void tick(WarehouseConfig fallback, int tickNo) {
    // The LIVE config (warehouseConfigProvider) is the single source of truth:
    // rack quantities mutate there via ActionApplier, so every brain decision
    // must read it, not a static snapshot. Fall back only if it's unset.
    final config = ref.read(warehouseConfigProvider) ?? fallback;
    final registry = ref.read(unitRegistryProvider.notifier);
    final units = registry.all(); // deterministic (id-sorted)
    final ctx = BrainContext(ref: ref, config: config, tick: tickNo);

    // Phase 1 — perceive & decide. A DRAINED robot (battery 0) goes offline
    // (drops its Job); a low-battery idle robot diverts to charging (P5). Both
    // skip work-claiming this tick.
    for (final u in units) {
      if (u.isChargeable && u.battery <= 0 && !u.isOffline && !u.isCharging) {
        u.goOffline(ctx);
      }
      if (u.isOffline || u.startChargeIfNeeded(ctx)) continue;
      u.perceiveAndDecide(ctx);
    }

    // Phase 1.5 — seed per-tick cell occupancy with every unit's current cell so
    // Phase-2 moves can't enter an occupied cell (P6 hard collision arbiter).
    final cellRes = ref.read(cellReservationProvider.notifier);
    cellRes.clear();
    for (final u in units) {
      cellRes.claimFirstFree([u.pos], u.id);
    }

    // Phase 2 — act; offline units recover in place, charging units charge. A
    // robot that claimed no Job this tick (still idle after act) patrols one step
    // so the floor never looks frozen — real work always preempts it in Phase 1.
    for (final u in units) {
      if (u.isOffline) {
        u.offlineRecoverStep();
      } else if (u.isCharging) {
        u.chargeStep(ctx);
      } else {
        u.act(ctx);
        if (u.isIdle) u.idleStep(ctx);
      }
    }

    // Phase 3 — sweep terminal work.
    ref.read(jobBoardProvider.notifier).sweepTerminal();
  }
}
