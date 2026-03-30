// pathfinding.dart
// Ported from: ops_simulator/engine/pathfinding.py
// A* pathfinding on a rectangular warehouse grid — pure Dart, no imports.

import '../constants/grid_constants.dart';
import '../constants/sim_constants.dart';

// ---------------------------------------------------------------------------
// Minimal heap implementation (min-heap on double keys) — avoids external deps
// ---------------------------------------------------------------------------

class _HeapNode {
  final double f;
  final (int, int) cell;
  const _HeapNode(this.f, this.cell);
}

class _MinHeap {
  final List<_HeapNode> _data = [];

  bool get isEmpty => _data.isEmpty;

  void push(_HeapNode node) {
    _data.add(node);
    _siftUp(_data.length - 1);
  }

  _HeapNode pop() {
    final top = _data[0];
    final last = _data.removeLast();
    if (_data.isNotEmpty) {
      _data[0] = last;
      _siftDown(0);
    }
    return top;
  }

  void _siftUp(int i) {
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_data[parent].f > _data[i].f) {
        final tmp = _data[parent];
        _data[parent] = _data[i];
        _data[i] = tmp;
        i = parent;
      } else {
        break;
      }
    }
  }

  void _siftDown(int i) {
    final n = _data.length;
    while (true) {
      var smallest = i;
      final l = 2 * i + 1, r = 2 * i + 2;
      if (l < n && _data[l].f < _data[smallest].f) smallest = l;
      if (r < n && _data[r].f < _data[smallest].f) smallest = r;
      if (smallest == i) break;
      final tmp = _data[smallest];
      _data[smallest] = _data[i];
      _data[i] = tmp;
      i = smallest;
    }
  }
}

// ---------------------------------------------------------------------------
// A* Pathfinder
// ---------------------------------------------------------------------------

/// A* pathfinder for the warehouse grid.
///
/// * Supports mandatory soft penalties for cells occupied by other robots
///   (via [occupied] set) — doesn't block but raises cost.
/// * Returns an empty list when no path exists.
/// * [smoothPath] removes redundant collinear waypoints for smoother rendering.
class AStarPathfinder {
  /// The walkable-cell grid. Computed once from [isCellWalkable].
  final int cols;
  final int rows;

  AStarPathfinder({int? cols, int? rows})
      : cols = cols ?? kGridCols,
        rows = rows ?? kGridRows;

  // 4-directional neighbours (no diagonal movement in narrow aisles).
  static const List<(int, int)> _dirs = [(0, 1), (0, -1), (1, 0), (-1, 0)];

  static int _manhattan((int, int) a, (int, int) b) =>
      (a.$1 - b.$1).abs() + (a.$2 - b.$2).abs();

  bool _inBounds((int, int) c) =>
      c.$1 >= 0 && c.$1 < cols && c.$2 >= 0 && c.$2 < rows;

  /// Find the shortest path from [start] to [goal].
  ///
  /// [occupied] — cells temporarily blocked by other robots (soft penalty).
  /// [grid] — optional override for walkability; defaults to [isCellWalkable].
  List<(int, int)> findPath(
    (int, int) start,
    (int, int) goal, {
    Set<(int, int)>? occupied,
    bool Function((int, int))? walkable,
  }) {
    if (start == goal) return [start];
    final bool Function((int, int)) isWalkable = walkable ?? (_) => true;

    final gScore = <(int, int), double>{start: 0};
    final fScore = <(int, int), double>{
      start: _manhattan(start, goal).toDouble()
    };
    final cameFrom = <(int, int), (int, int)>{};
    final closed = <(int, int)>{};
    final heap = _MinHeap();
    heap.push(_HeapNode(fScore[start]!, start));

    while (!heap.isEmpty) {
      final current = heap.pop().cell;
      if (current == goal) return _reconstruct(cameFrom, goal);
      if (closed.contains(current)) continue;
      closed.add(current);

      for (final d in _dirs) {
        final nb = (current.$1 + d.$1, current.$2 + d.$2);
        if (!_inBounds(nb)) continue;
        if (closed.contains(nb)) continue;
        if (!isWalkable(nb) && nb != goal) continue;

        final extra =
            (occupied != null && occupied.contains(nb)) ? kRobotStepPenalty : 0;
        final tentative = gScore[current]! + 1 + extra;

        if (tentative < (gScore[nb] ?? double.infinity)) {
          cameFrom[nb] = current;
          gScore[nb] = tentative;
          final f = tentative + _manhattan(nb, goal);
          fScore[nb] = f.toDouble();
          heap.push(_HeapNode(f.toDouble(), nb));
        }
      }
    }
    return []; // No path found
  }

  List<(int, int)> _reconstruct(
      Map<(int, int), (int, int)> cameFrom, (int, int) goal) {
    final path = <(int, int)>[];
    (int, int)? current = goal;
    while (current != null) {
      path.add(current);
      final (int, int)? parent = cameFrom[current];
      current = parent;
    }
    return path.reversed.toList();
  }

  /// Remove collinear intermediate waypoints for smoother movement display.
  /// Keeps start, end, and any point where direction changes.
  List<(int, int)> smoothPath(List<(int, int)> path) {
    if (path.length <= 2) return List.of(path);
    final result = <(int, int)>[path.first];
    for (int i = 1; i < path.length - 1; i++) {
      final prev = path[i - 1];
      final curr = path[i];
      final next = path[i + 1];
      final dx1 = curr.$1 - prev.$1;
      final dy1 = curr.$2 - prev.$2;
      final dx2 = next.$1 - curr.$1;
      final dy2 = next.$2 - curr.$2;
      if (dx1 != dx2 || dy1 != dy2) result.add(curr);
    }
    result.add(path.last);
    return result;
  }

  /// Estimate travel ticks (= steps) from A* path length.
  int estimateTicks((int, int) from, (int, int) to,
      {Set<(int, int)>? occupied}) {
    final p = findPath(from, to, occupied: occupied);
    return p.isEmpty ? 9999 : p.length - 1;
  }
}
