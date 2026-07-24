// Reproduce "automation ran, then SUDDENLY STOPPED — no new inbound/outbound
// orders, robots stuck holding cargo" on a seeded warehouse (the user's live
// symptom AFTER the stock-bootstrap + de-gridlock fixes made the loop start).
//
// Method: seed a real template warehouse, run the REAL scheduler for a long
// horizon, and record the tick each order was first minted. If demand keeps
// flowing the late windows have orders too; if the loop wedges, generation
// stops and robots pile up holding cargo they can never drop.

import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:warehouse_simulator/models/warehouse_config.dart';
import 'package:warehouse_simulator/application/providers.dart';
import 'package:warehouse_simulator/application/job_board.dart';
import 'package:warehouse_simulator/application/outbound_stage.dart';
import 'package:warehouse_simulator/application/sim_bootstrap.dart';
import 'package:warehouse_simulator/application/brains/unit_brain.dart';
import 'package:warehouse_simulator/application/brains/unit_scheduler.dart';
import 'package:warehouse_simulator/application/brains/inbound_truck_brain.dart';
import 'package:warehouse_simulator/application/brains/outbound_truck_brain.dart';
import 'package:warehouse_simulator/warehouse_engine/services/warehouse_template_factory.dart';

WarehouseConfig _seeded(String name, int seed) {
  final base = kWarehouseTemplates.firstWhere((t) => t.name == name).builder();
  // Deterministic inventory: without a seeded Random the stock distribution — and
  // therefore whether any robot wedges — changes every run, making the test flaky.
  return base.copyWith(cells: assignTemplateInventory(base.cells, Random(seed)));
}

Future<void> _runAndCheck(
    WidgetTester tester, String templateName, int seed) async {
  final cfg = _seeded(templateName, seed);
  late WidgetRef ref;
  await tester.pumpWidget(ProviderScope(
    child: Consumer(builder: (_, r, __) {
      ref = r;
      return const SizedBox();
    }),
  ));
  ref.read(warehouseConfigProvider.notifier).state = cfg;

  final robots = [
    for (final s in cfg.robotSpawns)
      (id: s.name ?? '${s.robotType}-${s.row}-${s.col}', row: s.row, col: s.col),
  ];
  bootstrapSimUnits(ref, cfg, robots);

  final firstSeen = <String, int>{};
  // Track how long each robot has continuously held cargo — a robot stuck
  // holding a pallet it can never drop is the "stuck carrying SKU-x" symptom.
  final cargoSince = <String, int>{};
  final maxHoldPerRobot = <String, int>{};
  var maxCargoHeld = 0;
  var maxCargoHeldId = '';
  final scheduler = UnitScheduler(ref);
  const horizon = 3500;
  for (var t = 0; t < horizon; t++) {
    scheduler.tick(cfg, t);
    for (final o in ref.read(jobBoardProvider).orders.values) {
      firstSeen.putIfAbsent(o.id, () => t);
    }
    // Iterate ALL robots (not the cargo map): clearCargo REMOVES the key, so a
    // map-only scan never resets cargoSince and would measure time-since-first-
    // load instead of the current continuous hold.
    final cargo = ref.read(robotCargoProvider);
    for (final u in ref.read(unitRegistryProvider).values) {
      if (cargo.containsKey(u.id)) {
        cargoSince.putIfAbsent(u.id, () => t);
        final held = t - cargoSince[u.id]!;
        if (held > (maxHoldPerRobot[u.id] ?? 0)) maxHoldPerRobot[u.id] = held;
        if (held > maxCargoHeld) {
          maxCargoHeld = held;
          maxCargoHeldId = u.id;
        }
      } else {
        cargoSince.remove(u.id);
      }
    }
  }
  // Forensics on the worst holder — is it wedged in a drive, or frozen
  // offline/charging (which the drive give-up can't see)?
  final worst = ref.read(unitRegistryProvider)[maxCargoHeldId];
  debugPrint('WORST HOLDER: id=$maxCargoHeldId role=${worst?.role.name} '
      'life=${worst?.lifecycle.name} battery=${worst?.battery?.toStringAsFixed(0)} '
      'held=$maxCargoHeld');
  final topHolders = maxHoldPerRobot.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  debugPrint('TOP HOLDS: ${topHolders.take(5).map((e) => "${e.key}:${e.value}").toList()}');

  final w = List.filled(horizon ~/ 1000, 0);
  firstSeen.forEach((_, t) => w[(t ~/ 1000).clamp(0, w.length - 1)]++);

  final board = ref.read(jobBoardProvider);
  final openIn = board.orders.values
      .where((o) =>
          o.kind == OrderKind.inboundReplenish &&
          (o.status == OrderStatus.open || o.status == OrderStatus.fulfilling))
      .length;
  final trucksIn = ref
      .read(unitRegistryProvider)
      .values
      .whereType<InboundTruckBrain>()
      .length;
  final trucksOut = ref
      .read(unitRegistryProvider)
      .values
      .whereType<OutboundTruckBrain>()
      .length;
  final carrying = <String>[];
  ref.read(robotCargoProvider).forEach((id, c) {
    if (c != null) carrying.add(id);
  });

  debugPrint('\n===== STALL [$templateName] =====');
  debugPrint('orders/1000t: $w  (total=${firstSeen.length})');
  debugPrint('open inbound=$openIn  trucks in=$trucksIn out=$trucksOut');
  debugPrint('stage occupancy=${ref.read(outboundStageProvider).length}  '
      'carrying now=${carrying.length} $carrying  maxCargoHeldTicks=$maxCargoHeld');
  debugPrint('================================\n');

  expect(w.last, greaterThan(0),
      reason: '$templateName: automation must NOT suddenly stop — no orders '
          'minted in the final 1000 ticks means the loop wedged');
  expect(openIn, lessThanOrEqualTo(8),
      reason: '$templateName: inbound orders must stay bounded (flood cap)');
  expect(trucksIn, lessThanOrEqualTo(6),
      reason: '$templateName: inbound trucks must not pile up on the bays');
  // No robot may hold the SAME cargo for the whole run — that is the "stuck
  // carrying SKU-x, all frozen" symptom.
  // The global cargo-hold safety net force-drops at kCargoHoldCap=500, so no hold
  // should exceed that by more than a little abort slack. A value near the horizon
  // means a pallet is stranded forever — the "stuck carrying SKU-x" symptom.
  expect(maxCargoHeld, lessThan(700),
      reason:
          '$templateName(seed=$seed): a robot must not be stuck holding cargo it '
          'can never drop (the stuck "carrying SKU-x" robots in the screenshot)');
}

void main() {
  // Sweep several deterministic stock distributions per size — different seeds
  // wedge different robots, so one fixed seed can hide the bug.
  for (final seed in [1, 2, 3, 4, 5]) {
    testWidgets('STALL medium seed=$seed: demand flows, no cargo-stuck robot',
        (t) => _runAndCheck(t, 'Medium Distribution Center B', seed));
    testWidgets('STALL large seed=$seed: demand flows, no cargo-stuck robot',
        (t) => _runAndCheck(t, 'Large Fulfilment Center B', seed));
  }
}
