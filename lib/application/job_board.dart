/// job_board.dart — P0 substrate for the decentralized "one brain per unit" sim.
///
/// The JobBoard is the ONLY channel through which units coordinate: the system
/// (event/rule layer) mints Orders, an Order explodes into Jobs, and idle unit
/// brains pull-claim Jobs via CAS. No brain references another brain.
///
/// Accounting invariants (v2 Amendment C):
///  • ONE authoritative progress counter per Order; `remainingUnits` is DERIVED,
///    never decremented in two places (closes LCC-2).
///  • Rack-mutating completions are guarded by an idem ledger so a released →
///    re-claimed Job cannot double-apply its stock effect (closes LCC-4).
///  • Everything is in LOOSE-equivalent units so pallet/case/loose compose.
///
/// LOCAL sim only — no backend/prod automation.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

// ── UOM ──────────────────────────────────────────────────────────────────────

/// Unit of measure. `loose` is the atomic unit; the others convert to it.
enum UomKind { pallet, caseUom, loose }

/// Sentinel "unit" that holds a manually-placed blocker's cell in the per-tick
/// reservation map, so every robot treats the blocker as impassable without any
/// brain needing its own blocker logic. A recovery unit clears it to the dump.
const String kBlockerHolderId = '__blocker__';

/// Loose-equivalent conversion. 1 pallet = 12 cases = 48 loose; 1 case = 4 loose.
const int kLoosePerPallet = 48;
const int kLoosePerCase = 4;
const int kCasesPerPallet = kLoosePerPallet ~/ kLoosePerCase; // 12

extension UomX on UomKind {
  int get looseUnits => switch (this) {
        UomKind.pallet => kLoosePerPallet,
        UomKind.caseUom => kLoosePerCase,
        UomKind.loose => 1,
      };
  String get label => switch (this) {
        UomKind.pallet => 'pallet',
        UomKind.caseUom => 'case',
        UomKind.loose => 'loose',
      };
}

// ── Roles ────────────────────────────────────────────────────────────────────

/// One role per unit brain. `recovery` (v2 Amendment A) claims JobKind.recovery
/// so offline hulks are actually towed — killing the "minted but never claimed"
/// anti-pattern the whole redesign exists to prevent.
enum UnitRole {
  scout,
  inboundTruck,
  inboundRobot,
  putawayRobot,
  pickRobot,
  outboundRobot,
  outboundTruck,
  bayAllocator,
  recovery,
  stockMonitor, // the inbound "system player": low stock → order + truck
  outboundGenerator, // the outbound "system player": emits ship orders
}

// ── Orders ───────────────────────────────────────────────────────────────────

enum OrderKind { inboundReplenish, outboundShip }

enum OrderStatus { open, fulfilling, closed, aborted }

/// One demand line of an Order: a SKU pulled in a SPECIFIC UOM.
///
/// This is how "route as pallet, case, loose" is represented: an outbound Order
/// explodes into one line per UOM, and each line is claimed by the picker that
/// handles that UOM — so pallet/case/loose pickers work the SAME order
/// concurrently, then it groups at the shipping area before loading.
///
/// The lines are the single source of truth for progress; the Order derives its
/// counters from them, so there is still exactly ONE place a unit is counted
/// (the invariant LCC-2 protects — no second decrement site).
class OrderLine {
  OrderLine({
    required this.lineId,
    required this.skuId,
    required this.uom,
    required this.units,
  });

  final String lineId;
  final String skuId;
  final UomKind uom;

  /// Ordered quantity for this line, in LOOSE-equivalent units.
  final int units;

  /// Units shipped for THIS line (loose-equiv). Monotonic ↑.
  int _progressUnits = 0;
  int get progressUnits => _progressUnits;

  /// Units satisfied by a 5.1 cross-dock diversion instead of a rack pick.
  int _divertedUnits = 0;
  int get divertedUnits => _divertedUnits;

  /// Units of this line physically sitting at the shipping area, awaiting the
  /// group. The spec-2 consolidation gate reads this — NOT progress, which only
  /// advances once the goods actually leave on a truck.
  int stagedUnits = 0;

  int get remainingUnits =>
      (units - _progressUnits - _divertedUnits).clamp(0, units);
  bool get isSatisfied => remainingUnits == 0;
  bool get isFullyStaged => stagedUnits + _progressUnits + _divertedUnits >= units;

  void advanceProgress(int looseUnits) {
    if (looseUnits <= 0) return;
    _progressUnits =
        (_progressUnits + looseUnits).clamp(0, units - _divertedUnits);
  }

  void divert(int looseUnits) {
    if (looseUnits <= 0) return;
    _divertedUnits =
        (_divertedUnits + looseUnits).clamp(0, units - _progressUnits);
  }
}

/// A demand emitted by the system. Progress is tracked by ONE monotonic counter
/// (`_progressUnits`); `remainingUnits` is derived from it. There is no second
/// decrement site anywhere.
class Order {
  Order({
    required this.id,
    required this.kind,
    required this.createdTick,
    required this.lines,
  }) : assert(lines.isNotEmpty, 'an Order must have at least one line');

  final String id;
  final OrderKind kind;
  final List<OrderLine> lines;
  final int createdTick;

  OrderStatus status = OrderStatus.open;

  /// Outbound: the bay cell where this order's truck is docked, set by the
  /// OutboundTruckBrain once it docks. The pack/load robot reads it to find the
  /// truck without ever referencing the truck brain (coordination via the board).
  GridPos? shipBay;

  /// Outbound: the pooled truck carrying this order. Many orders share one truck,
  /// which is what makes "depart when FULL" expressible.
  String? assignedTruckId;

  /// Back-compat for the single-SKU paths (all inbound orders are one SKU).
  String get skuId => lines.isEmpty ? '' : lines.first.skuId;

  /// All counters DERIVE from the lines — the lines are the one source of truth,
  /// so a unit is still counted in exactly one place (LCC-2).
  int get orderedUnits => lines.fold(0, (s, l) => s + l.units);
  int get progressUnits => lines.fold(0, (s, l) => s + l.progressUnits);
  int get divertedUnits => lines.fold(0, (s, l) => s + l.divertedUnits);
  int get remainingUnits => lines.fold(0, (s, l) => s + l.remainingUnits);
  bool get isSatisfied => remainingUnits == 0;

  /// spec-2 GROUPING gate: every line is accounted for at the shipping area, so
  /// the order can be loaded as one group. Distinct from [isSatisfied], which is
  /// a post-hoc "it all left on a truck" test.
  int get stagedUnits => lines.fold(0, (s, l) => s + l.stagedUnits);
  bool get isFullyStaged => lines.every((l) => l.isFullyStaged);

  OrderLine? lineById(String? lineId) {
    if (lineId == null) return null;
    for (final l in lines) {
      if (l.lineId == lineId) return l;
    }
    return null;
  }

  /// Progress mutation. Prefer passing [lineId] (a Job carries one); without it
  /// the units fill unsatisfied lines in order, which is exact for the
  /// single-line orders the inbound path mints.
  void advanceProgress(int looseUnits, {String? lineId}) {
    if (looseUnits <= 0) return;
    final line = lineById(lineId);
    if (line != null) {
      line.advanceProgress(looseUnits);
      return;
    }
    var left = looseUnits;
    for (final l in lines) {
      if (left <= 0) break;
      final take = left < l.remainingUnits ? left : l.remainingUnits;
      if (take <= 0) continue;
      l.advanceProgress(take);
      left -= take;
    }
  }

  /// Cross-dock (5.1): outbound units satisfied by diverting an inbound pallet
  /// straight to outbound staging rather than picking from a rack.
  void divert(int looseUnits, {String? lineId}) {
    if (looseUnits <= 0) return;
    final line = lineById(lineId);
    if (line != null) {
      line.divert(looseUnits);
      return;
    }
    var left = looseUnits;
    for (final l in lines) {
      if (left <= 0) break;
      final take = left < l.remainingUnits ? left : l.remainingUnits;
      if (take <= 0) continue;
      l.divert(take);
      left -= take;
    }
  }
}

// ── Jobs ─────────────────────────────────────────────────────────────────────

enum JobKind {
  driveTruckToBay,
  unloadTruck,
  putaway,
  rebalance, // rack→rack unwrap (v2 Amendment C: fixes UOM-locked starvation)
  crossDock, // 5.1: an inbound pallet diverted straight to outbound staging
  clearBlocker, // a manually-placed obstruction: haul it to the dump yard
  pickToStage,
  packAndLoad,
  departTruck,
  recovery, // tow an offline hulk (v2 Amendment A)
}

enum JobStatus { unclaimed, claimed, active, done, failed }

typedef GridPos = ({int row, int col});

/// One atomic unit-of-work a single unit runs to completion.
class Job {
  Job({
    required this.id,
    required this.kind,
    required this.requiredRole,
    required this.skuId,
    this.orderId,
    this.lineId,
    this.requiredUom,
    this.idemKey,
    this.src,
    this.dst,
    this.qtyUnits = 0,
    this.subjectUnitId,
  });

  final String id;
  final JobKind kind;
  final UnitRole requiredRole;
  final String skuId;

  /// Parent Order (null for order-less Jobs: rebalance, recovery, truck moves).
  final String? orderId;

  /// The Order LINE this Job serves. Progress is attributed here first and then
  /// rolls up, so a pallet/case/loose picker each credit their own line of the
  /// same order instead of racing one shared counter.
  final String? lineId;

  /// For pick Jobs, the UOM this Job draws (role gate is UOM-aware — SC-9).
  final UomKind? requiredUom;

  /// Rack-decrement idempotency key (v2 Amendment C / LCC-4). Preserved across
  /// release→re-claim so the idem ledger can reject a duplicate stock effect.
  final String? idemKey;

  GridPos? src;
  GridPos? dst;

  /// Quantity in LOOSE-equivalent units.
  int qtyUnits;

  /// For recovery Jobs: the offline unit being towed.
  final String? subjectUnitId;

  JobStatus status = JobStatus.unclaimed;
  String? claimedBy;

  /// How many times this Job has been claimed then released without completing.
  /// Bounds the "unclaimable job churns forever" livelock (review DL-6/F8).
  int attempts = 0;

  /// Set once a terminal accounting effect has been applied — makes offline
  /// release idempotent regardless of which owner (brain FSM or arbiter) calls
  /// it (v2 Amendment A / SBI-3).
  bool settled = false;

  bool get isClaimable => status == JobStatus.unclaimed;

  /// UOM-aware role gate (closes SC-9): pick Jobs must also match the picker UOM.
  bool matchesRole(UnitRole role, {UomKind? uom}) {
    if (requiredRole != role) return false;
    if (requiredUom != null && uom != requiredUom) return false;
    return true;
  }
}

// ── Board state + notifier ───────────────────────────────────────────────────

/// Immutable-ish snapshot of the board. Maps preserve insertion order, which we
/// lean on (plus explicit id sort) for deterministic iteration — the JEPA-eval
/// prerequisite.
class JobBoardState {
  const JobBoardState({
    required this.orders,
    required this.jobs,
    required this.consumedIdemKeys,
  });

  final Map<String, Order> orders;
  final Map<String, Job> jobs;

  /// Idem ledger (v2 Amendment C / LCC-4): idemKeys whose rack effect is applied.
  final Set<String> consumedIdemKeys;

  JobBoardState copyWith({
    Map<String, Order>? orders,
    Map<String, Job>? jobs,
    Set<String>? consumedIdemKeys,
  }) =>
      JobBoardState(
        orders: orders ?? this.orders,
        jobs: jobs ?? this.jobs,
        consumedIdemKeys: consumedIdemKeys ?? this.consumedIdemKeys,
      );

  static const empty =
      JobBoardState(orders: {}, jobs: {}, consumedIdemKeys: {});
}

/// TEMP DIAGNOSTIC COUNTERS (remove after analysis).
final Map<String, int> kDiag = <String, int>{};
void diag(String k, [int n = 1]) => kDiag[k] = (kDiag[k] ?? 0) + n;

class JobBoardNotifier extends StateNotifier<JobBoardState> {
  JobBoardNotifier() : super(JobBoardState.empty);

  int _seq = 0;
  // Zero-padded so lexicographic id sort matches creation order (FIFO). Without
  // padding, 'JOB-10' < 'JOB-2' and claim priority jumps by digit prefix (F1).
  String _nextId(String prefix) => '$prefix-${(_seq++).toString().padLeft(6, '0')}';

  // ── Minting ────────────────────────────────────────────────────────────────

  /// Single-SKU, single-line convenience — the shape the inbound path mints.
  /// [orderedUnits] is loose-equivalent; [uom] describes how it is pulled.
  Order mintOrder({
    required OrderKind kind,
    required String skuId,
    required int orderedUnits,
    required int nowTick,
    UomKind uom = UomKind.pallet,
  }) =>
      mintOrderOf(
        kind: kind,
        nowTick: nowTick,
        lines: [
          OrderLine(
            lineId: 'L0',
            skuId: skuId,
            uom: uom,
            units: orderedUnits,
          ),
        ],
      );

  /// Multi-line mint: one line per UOM is how an outbound order routes as
  /// pallet + case + loose and is then grouped at the shipping area.
  Order mintOrderOf({
    required OrderKind kind,
    required int nowTick,
    required List<OrderLine> lines,
  }) {
    final order = Order(
      id: _nextId('ORD'),
      kind: kind,
      createdTick: nowTick,
      lines: lines,
    );
    state = state.copyWith(orders: {...state.orders, order.id: order});
    return order;
  }

  Job mintJob(Job job) {
    state = state.copyWith(jobs: {...state.jobs, job.id: job});
    return job;
  }

  Job mintJobOf({
    required JobKind kind,
    required UnitRole requiredRole,
    required String skuId,
    String? orderId,
    String? lineId,
    UomKind? requiredUom,
    String? idemKey,
    GridPos? src,
    GridPos? dst,
    int qtyUnits = 0,
    String? subjectUnitId,
  }) =>
      mintJob(Job(
        id: _nextId('JOB'),
        kind: kind,
        requiredRole: requiredRole,
        skuId: skuId,
        orderId: orderId,
        lineId: lineId,
        requiredUom: requiredUom,
        idemKey: idemKey,
        src: src,
        dst: dst,
        qtyUnits: qtyUnits,
        subjectUnitId: subjectUnitId,
      ));

  // ── Claiming (CAS) ───────────────────────────────────────────────────────────

  /// Deterministic, sorted list of Jobs a role/uom may claim right now.
  List<Job> claimableFor(UnitRole role, {UomKind? uom}) {
    final out = state.jobs.values
        .where((j) => j.isClaimable && j.matchesRole(role, uom: uom))
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  /// Compare-and-set claim: succeeds only if the Job is still UNCLAIMED, so two
  /// brains cannot grab the same Job in one tick. Returns true on success.
  bool claim(String jobId, String unitId) {
    final j = state.jobs[jobId];
    if (j == null || !j.isClaimable) return false;
    j.status = JobStatus.claimed;
    j.claimedBy = unitId;
    _touch();
    return true;
  }

  void markActive(String jobId) {
    final j = state.jobs[jobId];
    if (j == null) return;
    j.status = JobStatus.active;
    _touch();
  }

  /// Return a claimed/active Job to the pool. Restores nothing twice: progress
  /// lives only on the Order and is only advanced on genuine completion.
  void release(String jobId) {
    final j = state.jobs[jobId];
    if (j == null || j.status == JobStatus.done) return;
    j.status = JobStatus.unclaimed;
    j.claimedBy = null;
    _touch();
  }

  /// Release for a genuinely-unsatisfiable attempt (no source/dest/stage/path).
  /// After [kMaxJobAttempts] such attempts the Job fails and its parent Order is
  /// aborted, so a permanently-stuck Job stops churning and frees held resources
  /// (a waiting outbound truck sees the aborted Order and departs) — review
  /// DL-3/DL-6/F8. This is the lightweight recovery net (no tow yet).
  static const int kMaxJobAttempts = 8;
  void releaseOrFail(String jobId) {
    final j = state.jobs[jobId];
    if (j == null || j.settled) return;
    j.attempts++;
    diag('releaseOrFail.attempt.${j.kind.name}');
    if (j.attempts >= kMaxJobAttempts) {
      j.status = JobStatus.failed;
      j.settled = true;
      diag('JOBFAILED.maxAttempts.${j.kind.name}');
      final o = j.orderId == null ? null : state.orders[j.orderId];
      if (o != null &&
          o.status != OrderStatus.closed &&
          o.status != OrderStatus.aborted) {
        o.status = OrderStatus.aborted;
        diag('ORDERDEATH.jobMaxAttempts.${j.kind.name}');
      }
    } else {
      j.status = JobStatus.unclaimed;
      j.claimedBy = null;
    }
    _touch();
  }

  // ── Completion ───────────────────────────────────────────────────────────────

  /// Idempotency gate for a rack-mutating completion. Returns true exactly once
  /// per idemKey; a re-claimed duplicate returns false and the caller skips the
  /// stock mutation (closes LCC-4).
  bool consumeIdem(String? idemKey) {
    if (idemKey == null) return true; // order-less effects are self-guarded
    if (state.consumedIdemKeys.contains(idemKey)) return false;
    state = state.copyWith(consumedIdemKeys: {...state.consumedIdemKeys, idemKey});
    return true;
  }

  /// Mark a Job done and advance its parent Order by ONE authoritative counter.
  /// `progressUnits` is applied to the Order only if this is an accounted kind
  /// (the single Phase-3 decrement point — closes LCC-2).
  void completeJob(String jobId, {int progressUnits = 0}) {
    final j = state.jobs[jobId];
    if (j == null || j.settled) return;
    j.status = JobStatus.done;
    j.settled = true;
    final order = j.orderId == null ? null : state.orders[j.orderId];
    if (order != null && progressUnits > 0) {
      // Attribute to the Job's OWN line first, then roll up: a pallet, case and
      // loose picker all serving one order each credit their own line instead of
      // racing a single shared counter.
      order.advanceProgress(progressUnits, lineId: j.lineId);
      diag('progressCredited.${j.kind.name}', progressUnits);
      // `fulfilling` was declared and read but never assigned anywhere.
      if (order.status == OrderStatus.open) {
        order.status = OrderStatus.fulfilling;
      }
      if (order.isSatisfied) {
        order.status = OrderStatus.closed;
        diag('ORDERCLOSED.satisfied.${order.kind.name}');
      }
    }
    _touch();
  }

  void failJob(String jobId) {
    final j = state.jobs[jobId];
    if (j == null || j.settled) return;
    j.status = JobStatus.failed;
    j.settled = true;
    _touch();
  }

  /// Close (or abort) an Order through the notifier so watchers repaint (HT-6):
  /// direct `order.status = …` writes don't bump state identity.
  void closeOrder(String orderId, {bool aborted = false}) {
    final o = state.orders[orderId];
    if (o == null || o.status == OrderStatus.closed) return;
    o.status = aborted ? OrderStatus.aborted : OrderStatus.closed;
    diag('closeOrder.${aborted ? "aborted" : "closed"}');
    _touch();
  }

  /// Publish/clear an Order's ship bay through the notifier (HT-6).
  void setShipBay(String orderId, GridPos? bay) {
    final o = state.orders[orderId];
    if (o == null) return;
    o.shipBay = bay;
    _touch();
  }

  // ── Sweep (v2 Amendment D / SBI-4): drop terminal Orders + Jobs so the
  //    per-tick scan stays O(active work), not O(cumulative work). ────────────
  void sweepTerminal() {
    final jobs = {
      for (final e in state.jobs.entries)
        if (e.value.status != JobStatus.done && e.value.status != JobStatus.failed)
          e.key: e.value
    };
    final sweptOrderIds = [
      for (final e in state.orders.entries)
        if (e.value.status == OrderStatus.closed ||
            e.value.status == OrderStatus.aborted)
          e.key
    ];
    final orders = {
      for (final e in state.orders.entries)
        if (e.value.status != OrderStatus.closed &&
            e.value.status != OrderStatus.aborted)
          e.key: e.value
    };
    // Prune idem keys owned by swept Orders ('ORD-x:L…') so the ledger stays
    // O(active work) instead of growing forever (review F6).
    var idem = state.consumedIdemKeys;
    if (sweptOrderIds.isNotEmpty && idem.isNotEmpty) {
      idem = {
        for (final k in idem)
          if (!sweptOrderIds.any((oid) => k.startsWith('$oid:'))) k
      };
    }
    if (jobs.length != state.jobs.length ||
        orders.length != state.orders.length ||
        idem.length != state.consumedIdemKeys.length) {
      state = state.copyWith(jobs: jobs, orders: orders, consumedIdemKeys: idem);
    }
  }

  /// Force a new state identity so watchers rebuild after an in-place mutation.
  void _touch() => state = state.copyWith();
}

final jobBoardProvider =
    StateNotifierProvider<JobBoardNotifier, JobBoardState>(
  (_) => JobBoardNotifier(),
);
