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
import '../outbound_stage.dart';
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
    // A manually placed BLOCKER is a real obstruction, not just an overlay. It is
    // seeded as a permanent holder of its cell each tick, so ActionApplier.tryStep
    // refuses to enter it and the brains' existing reroute-on-block logic paths
    // around it. Doing it here means no brain needs its own blocker awareness —
    // one place makes every unit respect it. A recovery unit then clears it to the
    // dump yard (the perceive -> reason -> act loop the JEPA work demonstrates).
    for (final key in ref.read(blockedCellsProvider)) {
      final parts = key.split(',');
      if (parts.length != 2) continue;
      final r = int.tryParse(parts[0]);
      final c = int.tryParse(parts[1]);
      if (r == null || c == null) continue;
      cellRes.claimFirstFree([(row: r, col: c)], kBlockerHolderId);
    }
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

    // Phase 3a — reclaim goods stranded by a DEAD Order (review blocker: pack
    // stations leak until outbound wedges). When an outbound Order aborts — a
    // line that can't be served fails 8×, or its truck never wins a bay — its
    // pickers may have ALREADY staged pallets and minted packAndLoad Jobs. Nothing
    // else frees those: the pallet sits on its pack-station cell forever, and the
    // Job orphans (dead Order → no shipBay → no OutboundRobot claims it, and an
    // unclaimed Job is never swept). Left alone the stage cells leak one by one.
    //
    // So: any pick/pack Job whose Order is aborted or already gone gets its staged
    // pallet cleared, its stage reservation released, and the Job failed. A live
    // picker's claimed pickToStage isn't force-freed here — but the packAndLoad it
    // ultimately mints for the dead Order is caught on a later pass, so the cell is
    // always reclaimed in the end and the loop can't wedge.
    _reclaimDeadOrderStage();

    // Phase 3 — sweep terminal work.
    ref.read(jobBoardProvider.notifier).sweepTerminal();
  }

  void _reclaimDeadOrderStage() {
    final board = ref.read(jobBoardProvider.notifier);
    final snapshot = ref.read(jobBoardProvider);
    final stage = ref.read(outboundStageProvider.notifier);
    final stageRes = ref.read(stageReservationProvider.notifier);
    for (final job in snapshot.jobs.values) {
      if (job.settled) continue;
      if (job.kind != JobKind.packAndLoad && job.kind != JobKind.pickToStage) {
        continue;
      }
      final oid = job.orderId;
      if (oid == null) continue;
      final order = snapshot.orders[oid];
      final dead = order == null || order.status == OrderStatus.aborted;
      if (!dead) continue;
      // Only reclaim PARKED work — an unclaimed pick, or an unclaimed packAndLoad
      // (a staged pallet no outbound robot has taken yet). Work a live unit is
      // still driving is left to that unit: a claimed pickToStage's eventual
      // packAndLoad is caught next pass, and a claimed/active packAndLoad's robot
      // owns its own staged pallet (it removes it via takeFromStage). Reclaiming a
      // mid-load packAndLoad would take the pallet out from under the robot and
      // free the cell, letting a DIFFERENT healthy order stage onto it — the
      // robot would then ship the wrong pallet and that healthy order would fail
      // with its stock lost (review: exactly-once inventory).
      if ((job.kind == JobKind.pickToStage ||
              job.kind == JobKind.packAndLoad) &&
          job.status != JobStatus.unclaimed) {
        continue;
      }
      diag('RECLAIM.deadOrderStage.${job.kind.name}');
      final src = job.src;
      if (src != null) {
        stage.take(src.row, src.col); // free the physical pack-station cell
        stageRes.release(src.row, src.col);
      }
      board.failJob(job.id);
    }
  }
}
