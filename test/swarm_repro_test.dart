// SWARM / UNSTOCKED-WAREHOUSE repro — matches the user's live symptom:
//   robots spawn "like a swarm" and never move; no orders / trucks / inventory.
//
// The e2e_full_automation test proves the loop works when racks are STOCKED. This
// test isolates the case the app actually hits: a warehouse whose rack cells have
// NO skuId (a custom-built or backend-round-tripped layout that was never seeded).
// Because the order generator needs stocked+servable racks and the StockMonitor
// only reorders racks that ALREADY have a skuId, an unstocked warehouse can never
// bootstrap: no orders → no jobs → every robot idle → the frozen swarm.
//
// Scenario A (stocked) is the control and must pass. Scenario B (unstocked) is the
// bug: today it produces no orders and no movement; after the self-bootstrap fix
// it must generate work and move robots just like A.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/sim_bootstrap.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/warehouse_engine/services/warehouse_template_factory.dart';

/// Small Warehouse B — a real, navigable template layout.
WarehouseConfig _template() =>
    kWarehouseTemplates.firstWhere((t) => t.name == 'Small Warehouse B').builder();

List<SpawnedRobot> _robotsOf(WarehouseConfig cfg) => [
      for (final s in cfg.robotSpawns)
        (
          id: s.name ?? '${s.robotType}-${s.row}-${s.col}',
          row: s.row,
          col: s.col
        ),
    ];

/// Run the real scheduler for [ticks] and report orders minted + robots moved.
({int orders, int moved, int pickJobs}) _run(
    WidgetRef ref, WarehouseConfig cfg, int ticks) {
  final robots = _robotsOf(cfg);
  final spawnKey = {for (final r in robots) r.id: '${r.row}_${r.col}'};
  bootstrapSimUnits(ref, cfg, robots);

  final ordersSeen = <String>{};
  final pickJobs = <String>{};
  final moved = <String>{};
  final scheduler = UnitScheduler(ref);
  for (var t = 0; t < ticks; t++) {
    scheduler.tick(cfg, t);
    final board = ref.read(jobBoardProvider);
    for (final o in board.orders.values) {
      ordersSeen.add(o.id);
    }
    for (final j in board.jobs.values) {
      if (j.kind == JobKind.pickToStage) pickJobs.add(j.id);
    }
    final pos = ref.read(manualRobotPositionsProvider);
    spawnKey.forEach((id, home) {
      final p = pos[id];
      if (p != null && '${p.row}_${p.col}' != home) moved.add(id);
    });
  }
  return (orders: ordersSeen.length, moved: moved.length, pickJobs: pickJobs.length);
}

Future<WidgetRef> _ref(WidgetTester tester) async {
  late WidgetRef ref;
  await tester.pumpWidget(ProviderScope(
    child: Consumer(builder: (_, r, __) {
      ref = r;
      return const SizedBox();
    }),
  ));
  return ref;
}

void main() {
  testWidgets('CONTROL: a STOCKED warehouse generates work and moves robots',
      (tester) async {
    final ref = await _ref(tester);
    final base = _template();
    final cfg = base.copyWith(cells: assignTemplateInventory(base.cells));
    ref.read(warehouseConfigProvider.notifier).state = cfg;

    final r = _run(ref, cfg, 400);
    debugPrint('STOCKED  -> orders=${r.orders} pickJobs=${r.pickJobs} moved=${r.moved}');
    expect(r.orders, greaterThan(0), reason: 'stocked racks must generate orders');
    expect(r.moved, greaterThanOrEqualTo(4), reason: 'robots must do work');
  });

  testWidgets('SWARM: robots packed in a 1-wide column disperse once work flows',
      (tester) async {
    final ref = await _ref(tester);
    final base = _template();
    // A tight cluster on a walkable corridor (the mid cross-aisle spans the floor
    // width). This is the realistic "swarm" — many robots bunched on navigable
    // cells — as opposed to a pathological road-lane funnel.
    final rMid = (base.rows - 1) ~/ 2;
    final packed = <RobotSpawn>[
      for (var i = 0; i < 8; i++)
        RobotSpawn(row: rMid, col: 2 + i, robotType: 'AMR', name: 'BOT-$i'),
    ];
    final cfg = base.copyWith(
      robotSpawns: packed,
      cells: assignTemplateInventory(base.cells),
    );
    ref.read(warehouseConfigProvider.notifier).state = cfg;

    final r = _run(ref, cfg, 600);
    // Where did they end up — still stacked in col 0, or spread across columns?
    final pos = ref.read(manualRobotPositionsProvider);
    final cols = {for (final id in packed.map((s) => s.name!)) pos[id]?.col};
    debugPrint('SWARM    -> orders=${r.orders} moved=${r.moved}/8 endCols=$cols');
    expect(r.orders, greaterThan(0), reason: 'work must flow');
    expect(r.moved, greaterThanOrEqualTo(6),
        reason: 'a packed column must NOT stay frozen — most robots disperse');
    expect(cols.length, greaterThan(2),
        reason: 'robots must spread across the floor, not stay in one column');
  });

  testWidgets('BUG: an UNSTOCKED warehouse must self-bootstrap and move robots',
      (tester) async {
    final ref = await _ref(tester);
    // Template builder does NOT seed inventory → every rack has a null skuId.
    final cfg = _template();
    // Guard: confirm this really is unstocked (no rack has a skuId).
    final anyStocked = cfg.cells.any((c) => c.type.isRack && (c.skuId ?? '').isNotEmpty);
    expect(anyStocked, isFalse, reason: 'precondition: racks start with no SKU');

    ref.read(warehouseConfigProvider.notifier).state = cfg;
    final r = _run(ref, cfg, 400);
    debugPrint('UNSTOCKED-> orders=${r.orders} pickJobs=${r.pickJobs} moved=${r.moved}');

    // Desired behaviour: the sim seeds starter stock at bootstrap so the loop can
    // run. Today (pre-fix) this fails: orders=0, moved=0 — the frozen swarm.
    expect(r.orders, greaterThan(0),
        reason: 'BUG: an unstocked warehouse never generates any order');
    expect(r.moved, greaterThanOrEqualTo(4),
        reason: 'BUG: with no work, every robot idles → the frozen swarm');
  });
}
