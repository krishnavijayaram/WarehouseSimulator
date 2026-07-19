/// warehouse_readiness.dart — a pre-flight check that explains, in plain terms,
/// WHY an autonomous run might sit idle on a given warehouse, expressed against
/// the cells and robots the brains actually require:
///
///   inbound loop : dock/inbound bay → palletStaging → racks
///   outbound loop: stocked rack → packStation (stage) → outbound bay
///   staffing     : roles round-robin inbound→putaway→pick→outbound (needs 4)
///
/// Pure + directly testable; surfaced in the UI when operations start so "robots
/// don't move" turns into "your warehouse has no pack station", etc.
library;

import '../models/warehouse_config.dart';

/// blocker = the loop cannot move any pallet; warning = it runs but a branch is
/// unstaffed or degraded. `index` orders them (blocker first) when sorting.
enum ReadinessSeverity { blocker, warning }

class ReadinessIssue {
  const ReadinessIssue(this.severity, this.message);
  final ReadinessSeverity severity;
  final String message;
  bool get isBlocker => severity == ReadinessSeverity.blocker;
}

/// Reasons [cfg] would idle or stall an autonomous run, most-severe first. An
/// empty list means the layout can run the full material-flow loop.
List<ReadinessIssue> checkWarehouseReadiness(WarehouseConfig cfg) {
  final issues = <ReadinessIssue>[];
  bool has(bool Function(WarehouseCell) p) => cfg.cells.any(p);

  final rackCells = cfg.cells.where((c) => c.type.isRack).toList();
  final hasStock = rackCells.any(
      (c) => c.skuId != null && c.skuId!.isNotEmpty && c.quantity > 0);
  final hasStaging = has((c) => c.type == CellType.palletStaging);
  final hasDock =
      has((c) => c.type == CellType.dock || c.type == CellType.inbound);
  final hasPack = has((c) => c.type == CellType.packStation);
  final hasOutbound = has((c) => c.type == CellType.outbound);
  final spawnCount = cfg.robotSpawns.length;

  // ── Blockers ──────────────────────────────────────────────────────────────
  if (rackCells.isEmpty) {
    issues.add(const ReadinessIssue(ReadinessSeverity.blocker,
        'No racks — there is no stock to pick and nowhere to put away, so robots have no work.'));
  } else if (!hasStock) {
    issues.add(const ReadinessIssue(ReadinessSeverity.blocker,
        'No stocked rack — every rack is empty, so there is nothing to ship. Give at least one rack an SKU and a quantity.'));
  }
  if (!hasPack) {
    issues.add(const ReadinessIssue(ReadinessSeverity.blocker,
        'No pack station — outbound pickers have nowhere to stage picked goods, so the pick→ship loop stalls.'));
  }
  if (!hasOutbound) {
    issues.add(const ReadinessIssue(ReadinessSeverity.blocker,
        'No outbound dock — picked goods can never ship out.'));
  }

  // ── Warnings ──────────────────────────────────────────────────────────────
  if (spawnCount == 0) {
    issues.add(const ReadinessIssue(ReadinessSeverity.warning,
        'No robot spawns — a single fallback robot is created, so only one role runs and most of the loop stays idle. Add robot spawns (4+ for the full loop).'));
  } else if (spawnCount < 4) {
    issues.add(ReadinessIssue(ReadinessSeverity.warning,
        'Only $spawnCount robot spawn(s) — roles round-robin inbound→putaway→pick→outbound, so with fewer than 4 a branch is unstaffed. Add up to 4.'));
  }
  // An outbound order routes into up to THREE lines (pallet + case + loose), and
  // each staged item occupies one pack-station cell until it is loaded. With a
  // single cell an order can never be consolidated, and picking backs up behind
  // the one slot — measured in the E2E probe as the throughput ceiling.
  final packCount = cfg.cells.where((c) => c.type == CellType.packStation).length;
  if (packCount == 1) {
    issues.add(const ReadinessIssue(ReadinessSeverity.warning,
        'Only one pack station — an order\'s pallet/case/loose lines cannot be staged together, and picking stalls behind the single slot. Add 2–3 for a smooth flow.'));
  }
  // Without a dump yard the recovery loop has nowhere to put an obstruction, so
  // the monitor stays silent — yet a blocker is still impassable. It would become
  // a permanent, unclearable obstruction that nothing on the floor can resolve.
  if (!has((c) => c.type == CellType.dump)) {
    issues.add(const ReadinessIssue(ReadinessSeverity.warning,
        'No dump yard — a blocker dropped on the floor can never be cleared (there is nowhere to put it) and stays a permanent obstruction. Add a Dump cell.'));
  }
  if (!hasStaging) {
    issues.add(const ReadinessIssue(ReadinessSeverity.warning,
        'No pallet staging — inbound unload/putaway has nowhere to drop pallets, so the inbound branch stalls.'));
  }
  if (!hasDock) {
    issues.add(const ReadinessIssue(ReadinessSeverity.warning,
        'No truck bay (dock/inbound cell) — replenishment trucks cannot dock, so depleted stock is never refilled.'));
  }

  issues.sort((a, b) => a.severity.index.compareTo(b.severity.index));
  return issues;
}
