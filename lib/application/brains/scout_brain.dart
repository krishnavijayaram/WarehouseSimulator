/// scout_brain.dart — the exploration unit (v2 Amendment D / SC-1 fix).
///
/// Scouting is a STANDING order, not a claimed Job: the brain always heads
/// toward unexplored territory using the priority frontier rule ported from the
/// retired ScoutBot. This is what makes P0's "scouts still move" hold once the
/// old `_bots` movement is gone and position authority lives in the registry.
library;

import '../../models/warehouse_config.dart';
import '../job_board.dart';
import '../providers.dart';
import 'action_applier.dart';
import 'unit_brain.dart';

class ScoutBrain extends UnitBrain {
  ScoutBrain({required super.id, required super.pos})
      : super(role: UnitRole.scout);

  // Recent cells, to avoid immediate back-tracking.
  final List<GridPos> _history = [];
  static const int _historyDepth = 6;

  // Movement priority: down, left, right, up (toward the dark).
  static const List<(int, int)> _priority = [(1, 0), (0, -1), (0, 1), (-1, 0)];

  GridPos? _nextMove;

  bool _recent(int r, int c) => _history.any((h) => h.row == r && h.col == c);

  @override
  void perceiveAndDecide(BrainContext ctx) {
    _nextMove = null;
    final cfg = ctx.config;
    final explored = ctx.ref.read(exploredCellsProvider);

    (int, int)? best;
    // 1) Highest-priority walkable, non-recent direction that leads to darkness.
    for (final d in _priority) {
      final nr = pos.row + d.$1;
      final nc = pos.col + d.$2;
      if (!_walkable(cfg, nr, nc) || _recent(nr, nc)) continue;
      if (_leadsToDark(cfg, explored, nr, nc)) {
        best = (nr, nc);
        break;
      }
    }
    // 2) Fallback: any walkable, non-recent direction.
    if (best == null) {
      for (final d in _priority) {
        final nr = pos.row + d.$1;
        final nc = pos.col + d.$2;
        if (!_walkable(cfg, nr, nc) || _recent(nr, nc)) continue;
        best = (nr, nc);
        break;
      }
    }
    if (best != null) {
      _nextMove = (row: best.$1, col: best.$2);
    } else {
      _history.clear(); // boxed in → reset so we can retrace next tick
    }
  }

  @override
  void act(BrainContext ctx) {
    final nm = _nextMove;
    if (nm == null) {
      lifecycle = UnitLifecycle.idle;
      return;
    }
    _history.add(pos);
    if (_history.length > _historyDepth) _history.removeAt(0);
    ActionApplier(ctx.ref, ctx.config).moveTo(this, nm);
    lifecycle = UnitLifecycle.navigating;
  }

  bool _walkable(WarehouseConfig cfg, int r, int c) {
    if (r < 0 || r >= cfg.rows || c < 0 || c >= cfg.cols) return false;
    final t = cfg.cellAt(r, c)?.type ?? CellType.empty;
    if (t.isRack ||
        t == CellType.obstacle ||
        t == CellType.tree ||
        t == CellType.packStation) {
      return false;
    }
    return true;
  }

  bool _leadsToDark(
      WarehouseConfig cfg, Set<String> explored, int tr, int tc) {
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        if (dr == 0 && dc == 0) continue;
        final nr = tr + dr;
        final nc = tc + dc;
        if (nr < 0 || nr >= cfg.rows || nc < 0 || nc >= cfg.cols) continue;
        if (!explored.contains('$nr,$nc')) return true;
      }
    }
    return false;
  }
}
