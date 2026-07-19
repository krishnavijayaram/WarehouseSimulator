/// blocker_monitor_brain.dart — the "something is wrong on the floor" sense.
///
/// The PERCEIVE half of the anomaly loop the JEPA work demonstrates. A blocker
/// can appear on the floor at any time (a saboteur drops one, or an operator
/// places one by hand). This brain doesn't move; each tick it compares the set of
/// blocked cells against the clear-jobs already on the board and mints one
/// `clearBlocker` Job per NEW obstruction.
///
/// It deliberately does not decide HOW to clear — that is the recovery unit's
/// job. Perception and action stay separate, and they coordinate only through the
/// JobBoard, like every other unit.
library;

import '../../models/warehouse_config.dart';
import '../job_board.dart';
import '../providers.dart';
import 'unit_brain.dart';

class BlockerMonitorBrain extends UnitBrain {
  BlockerMonitorBrain({required super.id})
      : super(role: UnitRole.stockMonitor, pos: const (row: -1, col: -1));

  /// Cells whose clear Job already exhausted its attempts, with the tick we gave
  /// up. Without this the monitor re-mints a Job the instant the failed one is
  /// swept, so an UNSATISFIABLE blocker (unreachable, or no route to a dump)
  /// churns Jobs forever and kMaxJobAttempts never bounds anything.
  final Map<String, int> _gaveUpAt = {};

  /// How long to leave an unsatisfiable blocker alone before trying again. Long
  /// enough to stop churn; short enough that a floor which frees up recovers.
  static const int kRetryAfterTicks = 600;

  @override
  void perceiveAndDecide(BrainContext ctx) {
    final blocked = ctx.ref.read(blockedCellsProvider);
    // Forget give-ups for cells that are no longer blocked, so the same cell
    // blocked again later is treated as a fresh anomaly.
    _gaveUpAt.removeWhere((k, _) => !blocked.contains(k));
    if (blocked.isEmpty) return;
    final board = ctx.board;

    // Cells that already have a live clear Job — don't mint a duplicate. Also
    // record cells whose Job FAILED, so we can back off instead of re-minting.
    final claimedCells = <String>{};
    for (final j in ctx.ref.read(jobBoardProvider).jobs.values) {
      if (j.kind != JobKind.clearBlocker) continue;
      final s = j.src;
      if (s == null) continue;
      final key = '${s.row},${s.col}';
      if (!j.settled) {
        claimedCells.add(key);
      } else if (j.status == JobStatus.failed) {
        _gaveUpAt.putIfAbsent(key, () => ctx.tick);
      }
    }

    for (final key in blocked) {
      if (claimedCells.contains(key)) continue;
      final gaveUp = _gaveUpAt[key];
      if (gaveUp != null && ctx.tick - gaveUp < kRetryAfterTicks) continue;
      if (gaveUp != null) _gaveUpAt.remove(key); // cooled off — try once more
      final parts = key.split(',');
      if (parts.length != 2) continue;
      final r = int.tryParse(parts[0]);
      final c = int.tryParse(parts[1]);
      if (r == null || c == null) continue;
      // A dump yard must exist to put it in; without one there is nowhere to
      // take the obstruction, so raising the Job would only churn.
      if (_dumpCells(ctx).isEmpty) return;
      board.mintJobOf(
        kind: JobKind.clearBlocker,
        requiredRole: UnitRole.recovery,
        skuId: 'BLOCKER',
        src: (row: r, col: c),
      );
    }
  }

  @override
  void act(BrainContext ctx) {
    lifecycle = UnitLifecycle.idle; // never moves
  }

  List<GridPos> _dumpCells(BrainContext ctx) => [
        for (final c in ctx.config.cells)
          if (c.type == CellType.dump) (row: c.row, col: c.col)
      ];
}
