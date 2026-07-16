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

/// One demand line of an outbound Order (a SKU pulled in a specific UOM).
class OrderLine {
  OrderLine({required this.id, required this.uom, required this.units});
  final String id;
  final UomKind uom;

  /// Ordered quantity for this line, in LOOSE-equivalent units.
  final int units;
}

/// A demand emitted by the system. Progress is tracked by ONE monotonic counter
/// (`_progressUnits`); `remainingUnits` is derived from it. There is no second
/// decrement site anywhere.
class Order {
  Order({
    required this.id,
    required this.kind,
    required this.skuId,
    required this.orderedUnits,
    required this.createdTick,
    List<OrderLine>? lines,
  }) : lines = lines ?? const [];

  final String id;
  final OrderKind kind;
  final String skuId;

  /// Total demand in LOOSE-equivalent units (Σ lines for outbound).
  final int orderedUnits;
  final List<OrderLine> lines;
  final int createdTick;

  OrderStatus status = OrderStatus.open;

  /// Outbound: the bay cell where this order's truck is docked, set by the
  /// OutboundTruckBrain once it docks. The pack/load robot reads it to find the
  /// truck without ever referencing the truck brain (coordination via the board).
  GridPos? shipBay;

  /// THE single authoritative progress counter (loose-equiv). Monotonic ↑.
  /// Inbound: units actually put away to rack. Outbound: units actually shipped.
  int _progressUnits = 0;

  /// Cross-dock (v2 Amendment C): outbound units satisfied by a 5.1 inbound
  /// diversion rather than a rack pick — counted here so pick demand shrinks.
  int divertedUnits = 0;

  int get progressUnits => _progressUnits;

  /// Derived, never stored twice.
  int get remainingUnits =>
      (orderedUnits - _progressUnits - divertedUnits).clamp(0, orderedUnits);

  bool get isSatisfied => remainingUnits == 0;

  /// The single mutation point for progress. Clamped monotonic.
  void advanceProgress(int looseUnits) {
    if (looseUnits <= 0) return;
    _progressUnits = (_progressUnits + looseUnits).clamp(0, orderedUnits);
  }

  void divert(int looseUnits) {
    if (looseUnits <= 0) return;
    divertedUnits = (divertedUnits + looseUnits).clamp(0, orderedUnits);
  }
}

// ── Jobs ─────────────────────────────────────────────────────────────────────

enum JobKind {
  driveTruckToBay,
  unloadTruck,
  putaway,
  rebalance, // rack→rack unwrap (v2 Amendment C: fixes UOM-locked starvation)
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

class JobBoardNotifier extends StateNotifier<JobBoardState> {
  JobBoardNotifier() : super(JobBoardState.empty);

  int _seq = 0;
  // Zero-padded so lexicographic id sort matches creation order (FIFO). Without
  // padding, 'JOB-10' < 'JOB-2' and claim priority jumps by digit prefix (F1).
  String _nextId(String prefix) => '$prefix-${(_seq++).toString().padLeft(6, '0')}';

  // ── Minting ────────────────────────────────────────────────────────────────

  Order mintOrder({
    required OrderKind kind,
    required String skuId,
    required int orderedUnits,
    required int nowTick,
    List<OrderLine>? lines,
  }) {
    final order = Order(
      id: _nextId('ORD'),
      kind: kind,
      skuId: skuId,
      orderedUnits: orderedUnits,
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
    if (j.attempts >= kMaxJobAttempts) {
      j.status = JobStatus.failed;
      j.settled = true;
      final o = j.orderId == null ? null : state.orders[j.orderId];
      if (o != null &&
          o.status != OrderStatus.closed &&
          o.status != OrderStatus.aborted) {
        o.status = OrderStatus.aborted;
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
      order.advanceProgress(progressUnits);
      if (order.isSatisfied) order.status = OrderStatus.closed;
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
