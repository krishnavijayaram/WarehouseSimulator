// grid_constants.dart
// Ported from: ops_simulator/engine/grid.py
// Pure constants — no network/DB/UI dependency.

/// Warehouse grid dimensions (cols × rows).
const int kGridCols = 58;
const int kGridRows = 34;

/// Pixel size of each grid cell for rendering.
const int kCellPx = 20;

/// Cell type codes stored in the grid matrix.
enum CellType {
  free(0), // Walkable open floor
  rack(1), // Solid obstacle (impassable)
  binFace(2), // Aisle cell in front of a bin (interaction point)
  zone(3); // Functional zone (Receiving, Staging, etc.)

  const CellType(this.value);
  final int value;

  static CellType fromInt(int v) => CellType.values
      .firstWhere((t) => t.value == v, orElse: () => CellType.free);
}

/// Home/charging positions for robots.
/// Format: (row, col)
const List<(int, int)> kChargingPositions = [
  (32, 50),
  (32, 52),
  (32, 54),
  (32, 56),
];

/// Staging drop-off slots (5 slots at bottom of the floor).
/// Used by greedy dispatcher to assign drop-off cells.
const List<(int, int)> kStagingSlots = [
  (30, 10),
  (30, 14),
  (30, 18),
  (30, 22),
  (30, 26),
];

/// Returns the pixel centre of a grid cell.
(double, double) gridToPixel(int row, int col) => (
      col * kCellPx + kCellPx / 2,
      row * kCellPx + kCellPx / 2,
    );

/// Whether a cell is walkable (not a rack).
bool isCellWalkable(CellType type) => type != CellType.rack;
