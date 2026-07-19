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

  @override
  void perceiveAndDecide(BrainContext ctx) {
    final blocked = ctx.ref.read(blockedCellsProvider);
    if (blocked.isEmpty) return;
    final board = ctx.board;

    // Cells that already have a live clear Job — don't mint a duplicate.
    final claimedCells = <String>{};
    for (final j in ctx.ref.read(jobBoardProvider).jobs.values) {
      if (j.kind != JobKind.clearBlocker || j.settled) continue;
      final s = j.src;
      if (s != null) claimedCells.add('${s.row},${s.col}');
    }

    for (final key in blocked) {
      if (claimedCells.contains(key)) continue;
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
