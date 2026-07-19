# AUTONOMOUS_UNITS_DESIGN.md
## WIOS Warehouse Simulator — Decentralized, One-Brain-Per-Unit, System-as-Player

**Scope:** LOCAL sim only (per the standing no-prod-automation rule — no automation, AI, or agent loop runs in WIOS prod; prod is the app/API surface). This document is the definitive, gap-closed design that every unit brain, provider, and scheduler phase is authored against. It supersedes the ad-hoc controller loop in `RobotScoutSimulation._tick()`.

**Status:** Frozen v1 contract + 11 brain specs, with every blocker/major/minor from the gap-hunt folded in as a resolved decision. Where a gap fix changes the World Contract, the fix is normative here and the earlier brain-spec prose is overridden.

---

## 1. Overview + the Age-of-Empires mental model

### 1.1 The metaphor, made literal

In Age of Empires, a human clicks "gather wood." The villager then **autonomously** walks to the forest, chops, hauls the wood to the town center, deposits, and repeats — until the trees are gone or it is re-tasked — then stands **idle** awaiting the next order.

WIOS mirrors this exactly, with one inversion: **the "player" is not a human — it is the warehouse's own event/rule layer.** World state emits an instruction; a unit with its **own brain** (`perceive → decide → act`, one action per tick) runs its role behavior **to completion on its own**, then **recharges** and **idles** waiting for the next system instruction.

Four invariants define the model:

1. **Decentralized.** No central controller drives a unit. `RobotScoutSimulation._tick()` is a *clock*, not a *controller*; it only calls `brain.step()` on each registered unit and pumps the shared blackboard once. No brain references another brain — coordination is *only* through shared providers.
2. **Run-to-completion.** A unit that claims a Job advances its own FSM one atomic step per tick until the Job is done; it never abandons work mid-flight except for the energy self-interrupt (§6), which is cargo-safe.
3. **Recharge.** Work drains a per-unit battery; when low, the unit breaks off, tops up at a charger dock, then rejoins the work market. Trucks carry fuel but effectively never bind (a single dock-and-depart is a few dozen ticks) and never seek a charger.
4. **Idle-wait.** After a Job (or when no Job is claimable) the unit stands still on its last cell, drains nothing, and re-scans the blackboard each tick — the villager standing idle after the forest is gone.

### 1.2 The three nouns (never conflated)

| Noun | Grain | Lifetime | Analogy |
|---|---|---|---|
| **Order** (`Order`, `OrderKind.inboundReplenish` / `outboundShip`) | A *demand* emitted by the SYSTEM. May spawn many Jobs. | Long-lived; closes when its true satisfaction condition is met. | "gather wood until the pile is full" |
| **Job** (`Job`, `JobKind.driveTruckToBay/unloadTruck/putaway/pickToStage/packAndLoad/departTruck`) | One atomic unit-of-work a single unit runs to completion (one pallet A→B, one truck to a bay). | Cycles `UNCLAIMED → CLAIMED → ACTIVE → DONE/FAILED`. | "chop one tree" |
| **UnitBrain** | The persistent villager: identity, position, battery, role, and *at most one* claimed Job. | Immortal (per sim). Only its `currentJob` slot cycles `null → Job → null`. | the villager itself |

> Key inversion vs. today: today a "task" (`IRTask`/`PRTask`) is created, ticked by a global loop, then **deleted**. Here the **unit persists**; only its `currentJob` slot cycles.

### 1.3 The canonical closed loop (the 9 arrows this design must realize with no gaps)

1. **Stock low** → a monitor detects a SKU below reorder point → fires an inbound Order.
2. **Order fired** → an inbound truck arrives carrying that stock.
3. **Truck routing** → truck is directed to a FREE INBOUND BAY on the LEFT.
4. **Unload** → an inbound robot picks a pallet from the docked truck → drops it in INBOUND STAGING.
5. **Putaway** → a pallet-pick robot picks from staging → drops into PALLET / CASE / LOOSE area (unwrapping as required by area need + current stock).
6. **Outbound retrieval** → based on ORDERS, pallet/case/loose robots move inventory from racks to the OUTBOUND STAGE.
7–8. **Pack & load** → from the stage, an outbound robot packs & loads the OUTBOUND TRUCK.
9a. **Depart** → when full, the outbound truck leaves; 9b. **Demand** → outbound Orders emitted randomly over time.

The loop closes: outbound consumption drops rack stock → step 1 re-fires. §5 proves self-propagation; §6–§7 prove no deadlock/starvation.

---

## 2. Root-cause recap — what we keep vs. replace

### 2.1 Verified defects driving the redesign

| Defect (verified) | Consequence | Disposition |
|---|---|---|
| `InboundOpsController.assignUnload()` and `PalletPutawayController.assignPutaway()` are **defined but never called** — `tick()` only advances *existing* tasks. | In automation, no unload/putaway tasks are ever built → only scouts move. | **Replace the trigger.** The `SystemOrderEmitter` (JobBoard `pump()`) mints Jobs; idle brains pull-claim them. The *bodies* of `assignUnload`/`_determinePutawayDest`/`assignPutaway` are lifted verbatim into brain `claiming` logic. |
| Only scout bots move (`RobotScoutSimulation._bots`); ops controllers write `manualRobotPositionsProvider` but are never invoked. | Ops units are stationary. | **Replace the driver.** 3-phase scheduler steps every unit brain; scouts become `ScoutBrain`. |
| Two position systems, same id scheme (`spawn.name ?? '<robotType>-<row>-<col>'`): `ScoutBot._bots[i].row/col` vs `manualRobotPositionsProvider`. `floor_screen` overrides the scout's drawn position with the `manualRobotPositions` entry. | Position double-drive; a unit can appear in two places. | **`manualRobotPositionsProvider` is THE sole authority** (§3.6). `ScoutBot.row/col` retired. |
| `stagingPalletsProvider` (`StagingNotifier`, `kMaxStagingPallets=5`) starts **empty**. | Putaway has nothing to consume until unload runs. | **Ordering is guaranteed by data flow**, not by a scheduler hack: a `putaway` Job only materializes *after* a `drop()` fills a slot. |
| `AStarPathfinder.findPath({walkable, occupied})` — the `occupied` param is **never passed**, and is only a **soft** penalty (`kRobotStepPenalty=8`), not a hard block. | No collision avoidance; feeding "walls" through `occupied` fails. | **Wire `occupied` for soft congestion bias only; add a hard `blocked` set fed through the `walkable` predicate** (§3.4, §6.2). |
| `activeEventsProvider` raises `REPLENISHMENT_NEEDED`/`OUT_OF_STOCK`/sabotage — **raised, never consumed/resolved**; keyed one-descriptor-per-cell (clobbers). | Signal leak; UI blink livelock. | **Emitter owns marker lifecycle (raise + resolve); traffic/energy alerts live in a separate namespaced provider** (§3.7, §6, §7). |
| `inboundTrucksProvider` is a read-only `StreamProvider.autoDispose` polling every 5s, returns `Map.unmodifiable`, emits `[]` on any network error, lags the tick. | Cannot be written with `claimedBay`/position; clobbers local fields; empty-on-error mass release; stale DEPARTED. | **Replace as authority with local `StateNotifier` truck-entity registries; the poll only reconciles non-authoritative fields; local terminal state wins via a tombstone set** (§3.3). |
| Battery consts `kBatteryDrainPerTick=0.15`, `kBatteryChargePerTick=0.80`, `kBatteryLowThreshold=20.0` are **dead** (defined, never read). `RobotState.battery` is inert `100.0`. | No energy model. | **Wired live** into `UnitBrain.battery` via `ActionApplier` and `EnergyGovernor` (§6). |
| Round-robin bay assignment `dockCells[slotIndex % dockCells.length]` in `_drawInboundTrucks`; backend `slot_id` from `dispatchTruck` **discarded**; `_findDockedTruckAtCell` tests the dead string `'DOCKED'` (backend emits `status_actual`). | Bay double-booking; wrong bay; dead-string branch. | **`bayOccupancyProvider` CAS is the single bay authority; brains key on `status_actual`.** |
| Outbound side (steps 6–9) is largely **unimplemented**. | No retrieval/pack/load/depart/random demand. | **Greenfield** per §4.7–§4.9. |

### 2.2 Keep / Replace ledger

- **KEEP (lifted verbatim):** the IR/PR movement FSMs (`navigating → picking(kPickTicks=3) → navigating → dropping(kDropTicks=2)`), `_determinePutawayDest` (rules 5.1–5.4), `_findStagingCell`, `_adjacentWalkable`, `_isWalkableForRobot`, `_findBelowThresholdRack`, `_findAvailablePalletRack`, `_findPackStation`, `_applyDropToConfig`, `AStarPathfinder`, `StagingNotifier` (single-SKU, max 5), `robotCargoProvider`, `PalletData`, the `CHARGING` render (`0xFFFFCC00` + badge), the UOM constants `kCasesPerPallet=12`/`kLoosePerPallet=48`, the scout fog-reveal 3×3 pattern.
- **REPLACE:** the trigger (dead `assign*` → emitter-minted Jobs), the driver (monolithic `_tick()` → 3-phase scheduler), the position authority (dual → single), truck state (read-only poll → local entity registries), duplicated pick/drop (`manual*` vs `_execute*` → one `ActionApplier`), bay geometry (modulo → CAS ledger).
- **RETIRE:** `ScoutBot.row/col` authority, `_truckApproach` binary 0.0/1.0 teleport, `PalletPutawayController._hasOrderPending` reading static `config.truckSpawns`, the `'DOCKED'` string branch, per-controller `_tasks` maps.

---

## 3. The World Contract v1

**Design axiom:** There is no orchestrator. All coordination flows through an append-only **JobBoard** blackboard that units *pull* from, plus a small set of single-writer resource-arbiter providers. The "player" is `SystemOrderEmitter` (which contains `StockMonitorBrain` and `RandomOrderGenerator`) — it only *emits* Orders and *explodes* them into Jobs; it never names a unit.

### 3.1 The `UnitBrain` base (new: `lib/application/brains/unit_brain.dart`)

```dart
enum UnitRole { scout, inboundTruck, inboundRobot, putawayRobot,
                pickRobot, outboundRobot, outboundTruck, bayAllocator }

enum UnitLifecycle { idle, claiming, working, returningToCharge, charging, offline }

abstract class UnitBrain {
  String  get id;                 // spawn.name ?? '<robotType>-<row>-<col>' (unchanged)
  UnitRole get role;              // fixed capability gate
  UnitLifecycle lifecycle;
  Job? currentJob;                // the claimed villager task; null == idle
  double battery;                 // 0..100 (robots); trucks pin 100 & never drain

  void perceiveAndDecide(WorldFacts facts); // Phase 1: read-only + CAS claims only
  void act(ActionApplier applier);          // Phase 2: exactly one move / one work tick
  bool canClaim(Job j);           // role gate: j.requiredRole == role (Jobs, never Orders)
}
```

`BrainContext` (callback-injection, modeled on the existing `ManualRobotController` injection `onPositionUpdate`/`onEventRaise`/`read+writeSelectedId`) gives a brain read/write access to the JobBoard, `manualRobotPositionsProvider`, `stagingPalletsProvider`, `robotCargoProvider`, `AStarPathfinder`, and the reservation registries **without hard Riverpod coupling inside the brain**.

**Gap fix (canClaim):** the pull path claims *Jobs* gated by `Job.requiredRole`, never Orders. `canClaim(Order)` is removed everywhere.

### 3.2 The JobBoard data model (new: `lib/application/job_board.dart`)

**Orders — multi-line (gap fix: the single-SKU `Order` could not represent a customer order).**

```dart
enum OrderKind { inboundReplenish, outboundShip }
enum OrderStatus { open, fulfilling, closed, aborted }

class OrderLine { final String skuId; final UnitType unitType; // PALLET|CASE|LOOSE
                  int remainingUnits; final int looseEquiv; }   // looseEquiv derived once

class Order {
  final String id;                 // 'PO-...' / 'OO-...'
  final OrderKind kind;
  final List<OrderLine> lines;     // >=1; role routing keys on line.unitType
  int remainingUnits;              // Σ line.remainingUnits, in LOOSE-equivalent units
  OrderStatus status;
  final int emittedTick;
  String? truckId;                 // bound truck (in/out); null until entity exists
}
```

Every quantity is normalized to LOOSE-equivalent on entry using `kLoosePerPallet=48`, `kCasesPerPallet=12`, and the **new** `kLoosePerCase = kLoosePerPallet ~/ kCasesPerPallet = 4` (gap fix: cases→loose was hand-waved as "48/12"). The original `unitType` is preserved per line for role routing; `looseEquiv` is a secondary field for stock math only.

**Jobs — carry the `IRTask`/`PRTask` movement payload verbatim.**

```dart
enum JobKind { driveTruckToBay, unloadTruck, putaway, pickToStage, packAndLoad, departTruck, recovery }
enum JobStatus { unclaimed, claimed, active, done, failed }

class Job {
  final String id;
  final String orderId;            // parent
  final JobKind kind;
  final String skuId;
  final UnitType uom;              // pallet/case/loose — the role discriminator
  int qtyUnits;                    // this Job's slice, LOOSE-equiv
  JobStatus status;
  String? claimedBy;
  UnitRole get requiredRole;       // derived from kind (+uom for pick)
  String? boundTruckId;            // set on driveTruckToBay/unloadTruck/packAndLoad/departTruck
  int? srcRow, srcCol, dstRow, dstCol;
  List<(int,int)>? path; int pathIndex; int ticksRemaining;
  ReservationSet reservations;     // slots/racks/bays/charger this Job holds
  int attempts; int lastFailTick;  // gap fix: bounded livelock escape
  String idemKey;                  // gap fix: rack decrement idempotency
}
```

**World facts (read-only tick-stable snapshot, Phase 0).** Extended so brains never read live providers (gap fix: `StockMonitorBrain` was reading `warehouseConfigProvider.cells` live).

```dart
class WorldFacts {
  final Map<String,(int,int)> unitPositions;   // snapshot of manualRobotPositionsProvider
  final Set<(int,int)> occupiedCells;          // all unit cells (movers + stationary)
  final Set<(int,int)> blockedCells;           // offline hulks + parked terminals (hard walls)
  final Map<String,int> stagingFreeBySku;      // inbound staging
  final List<SkuStockView> stockViews;         // per-SKU: onHandLoose, reorderPointLoose,
                                               //   targetLoose, homeCells, status(OK|LOW|OUT)
  final List<TruckFact> inboundTrucks;         // from inboundTruckRegistryProvider
  final List<TruckFact> outboundTrucks;        // from outboundTruckRegistryProvider
  final int tick;
}
```

### 3.3 Provider inventory (final)

| Provider | Kind | Owns / fix |
|---|---|---|
| `jobBoardProvider` | **new** StateNotifier | Orders, Jobs, `WorldFacts` snapshot, `claim/complete/release/fail`. Single WIP source of truth for outbound cap (local only). |
| `unitRegistryProvider` | **new** StateNotifier | `Map<String,UnitBrain>` — the per-unit brain registry (mirrors backend `_agents`). |
| `inboundTruckRegistryProvider` | **new** StateNotifier | Authoritative inbound truck entities `{id,row,col,approach,claimedBay,fuel,lifecycle,statusActual,backendSlotId,parentOrderId}`. Poll only reconciles; **local-departed tombstone set wins** (gap fix: zombie respawn). |
| `outboundTruckRegistryProvider` | **new** StateNotifier | Authoritative outbound truck entities `{…,currentLoadUnits,targetLoadUnits,acceptingLoad}`. Greenfield. |
| `truckManifestProvider` | **new** StateNotifier | `Map<truckId,int>` remaining pallets, **locally mutable**, decremented by unload drops (gap fix: `shipmentsByTruck` poll can't decrement offline). |
| `bayOccupancyProvider` | **new** StateNotifier | `Map<CellKey,String?>` bayCell→truckId, inbound + outbound pools. Sole bay writer via `BayAllocatorBrain`. |
| `chargerOccupancyProvider` | **new** StateNotifier | `Map<CellKey,{occupant:String?, status:working\|fault}>` chargerCell → unitId. Sole writer via `ChargerDockArbiter`. |
| `cellReservationProvider` | **new** StateNotifier | `Map<CellKey,String>` next-cell reservations; **pre-seeded with every non-moving unit's cell each tick**; cleared at tick top. Owned by `AisleTrafficArbiter`. |
| `offlineObstacleProvider` | **new** StateNotifier | `Set<CellKey>` dead-unit cells — **hard walls** (fed to A* `walkable`, not soft `occupied`). |
| `truckLoadSlotProvider` | **new** StateNotifier | `Map<truckId,int>` reservable remaining load slots (gap fix: load counter had no CAS). |
| `pickFaceReservationProvider` | **new** StateNotifier | `Map<CellKey, {holders:Set, cap:int}>` counted rack-face reservations (gap fix: whole-face binary lock serialized big faces). |
| `rackReservationProvider` | **new** StateNotifier | `Map<CellKey,String>` durable dest-rack reservation for putaway (held across the multi-tick haul). |
| `outboundDemandReservationProvider` | **new** StateNotifier | `Map<skuId,int>` pending outbound pallet demand (gap fix: 5.1 multi-PR over-consumption). |
| `energyPolicyProvider` | **new** StateNotifier | `{forceChargeEpoch:int}` — the `WoisEventType.robotCharge` player channel (latched, read-and-consume in Phase 1). |
| `skuHomeRegistryProvider` | **new** StateNotifier | `Map<skuId,Set<CellKey>>` persistent home cells seeded at config-load (gap fix: emptied `rackPallet.skuId==null` made a SKU invisible). |
| `trafficAlertsProvider` | **new** StateNotifier | Namespaced traffic/energy alerts (`AISLE_BLOCKED`, `GRIDLOCK`, `DOCK_BLOCKED`, `BATTERY_CRITICAL`) — separate from `activeEventsProvider` (gap fix: cell-key clobber). |
| `manualRobotPositionsProvider` | existing | **THE authoritative unit `(row,col)`** (§3.6). |
| `stagingPalletsProvider` / `StagingNotifier` | existing | inbound staging (max 5, single-SKU) + counted `stagingReserve` extension. |
| `outboundStageProvider` | **new** StateNotifier | outbound stage slots at `CellType.outboundStage` cells — **multi-SKU, capacity in lines** (gap fix: reusing inbound single-SKU/max-5 rejected 2nd SKU). |
| `robotCargoProvider` | existing | per-unit in-hand pallet. |
| `activeEventsProvider` | existing | functional world signals (`REPLENISHMENT_NEEDED`, `OUT_OF_STOCK`, `STAGING_MAPPED`, `PICK_NEEDED`, `DEMAND`), **owner-namespaced**, raise+resolve owned by the emitter. |

### 3.4 Resource arbitration primitives

All resource claims are **single-threaded compare-and-set inside the tick**, holder = unitId/truckId, released on Job completion/failure or lifecycle exit. The tick is single-threaded so CAS is defensive, but it makes double-booking impossible even across scheduler phases.

- **Bays** (`bayOccupancyProvider`, §4.3 `BayAllocatorBrain`): inbound pool = `config.cells.where(c => c.type==CellType.dock && c.col <= cols/2)` **per-cell** (gap fix: the set-level `fromLeft` average could not classify individual cells) with the historic fallback `allDocks.isNotEmpty ? docks-on-side : inbound-marker-cells-on-side` preserved (gap fix: layouts model bays as `CellType.inbound` markers). Outbound pool uses **dedicated `CellType.outboundDock`** cells, loaded from an **adjacent walkable approach cell** (gap fix: `CellType.outbound` is a walkable transit lane — using it as an exclusive truck bay deadlocks the loader).
- **Charger docks** (`chargerOccupancyProvider`, §6): `config.cells.where(isCharger)` (`chargingFast`×2 / `chargingSlow`×1 / legacy `charging`). Claim the nearest free *working* dock **before** pathing.
- **Staging slots** (`stagingPalletsProvider` + counted `stagingReserve(slotKey, unitId, palletIndex)`): reservation by `(slotKey, palletIndex)` so up to `count` robots drain one 5-deep slot concurrently (gap fix: single-holder lock serialized multi-pallet slots).
- **Aisle cells** (`cellReservationProvider`, `AisleTrafficArbiter`, §7): global move-graph resolution each tick, not pairwise CAS — so whole swap/rotation cycles are visible.

### 3.5 Pathfinding contract

`AStarPathfinder.findPath(start, goal, {walkable, occupied})` — **(col,row) tuple convention**; always convert results back with `(p.$2, p.$1)`.

- `walkable`: the per-domain predicate (`isInboundRobotDomain`, `isPickRobotDomain`, `isOutboundRobotDomain`, `isOutboundRobotDomain` for trucks) **minus `offlineObstacleProvider` cells and other units' current cells that are not vacating this tick** — a **hard** exclusion (gap fix: `occupied` is only a +8 soft penalty and cannot represent a wall).
- `occupied`: soft congestion bias only (live positions + `cellReservationProvider` + per-unit reroute injections).
- The single goal cell is exempt from the hard exclusion (the existing `nb == goal` escape) so an approach cell can still be reached.

### 3.6 Position authority (single source)

**`manualRobotPositionsProvider` is the ONE source of truth for every robot's `(row,col)`.** `ScoutBot._bots[i].row/col` is retired.

- Every brain writes position **only** via `ActionApplier.move(id,row,col)` → `manualRobotPositionsProvider.update`. `floor_screen` already draws the `manualRobotPositions` entry over any scout position, so this is the value already winning on screen; we make it the sole writer.
- **Seeded at registration** (gap fix: the provider starts empty → tick-1 A* has no start cell): on unit registration, `ActionApplier.seed(id, spawn.row, spawn.col)` writes the spawn cell before the first tick. Phase 0 asserts every registered unit has a position.
- Scouts are a *role*, not a rival system: `ScoutBrain extends UnitBrain` writes through the same `ActionApplier.move`. **Fog reveal (3×3 `exploredCellsProvider.markExplored`) is a side effect of `ActionApplier.move` on every move**, so any moving unit reveals fog. Dock/inbound neighborhoods are additionally fog-seeded at ops-start (gap fix: retiring static dock scouts left the receiving area fogged until the first truck).
- **Trucks** get their own authoritative `(row,col)+approach` in the truck registries (§3.3), advanced one cell/tick by their brain (no `_truckApproach` teleport). `ActionApplier.driveTruck` writes truck position and **does not drain battery** (role-gated inside the applier; gap fix: single-chokepoint drain must skip trucks).
- **ID scheme unchanged**, and the **local spawn id is reconciled to the backend `robot_id` via one canonical id map** (gap fix: `rb_01` ≠ `AGV-3-4` broke cargo hydration and role assignment).

### 3.7 The Applier (collapses `manual*` vs `_execute*`)

```dart
class ActionApplier {                 // lib/application/brains/action_applier.dart
  void seed(String id, int r, int c);
  void move(String id, int r, int c);  // manualRobotPositionsProvider.update + fog + drain(if robot)
  void driveTruck(String id, int r, int c); // truck registry position + fuel drain, NO battery
  void pick(String id, PickSpec s);    // robotCargo.loadPallet + config/staging mutate + ApiClient.pickTransaction (fire-and-forget)
  void drop(String id, DropSpec s);    // staging/outboundStage/config mutate + robotCargo.clearCargo + ApiClient.dropTransaction (fire-and-forget)
}
```

Both automated brains and any residual manual D-pad path funnel through `ActionApplier`, so there is exactly one code path that mutates cargo/staging/position/energy/fog. All `ApiClient` calls are fire-and-forget `.catchError` (local providers are authoritative; local-sim rule).

### 3.8 Energy model (see §6 for full subsystem)

Scale 0–100 (matches `RobotState.battery` default and `kBatteryLowThreshold=20.0`).

| Quantity | Value | Applied |
|---|---|---|
| Full | `100.0` | spawn / after charge |
| Drain | `kBatteryDrainPerTick = 0.15` | per `ActionApplier.move` and per pick/drop work tick. **Never while idle or charging.** |
| Low (seek) | `kBatteryLowThreshold = 20.0` | self-interrupt (distance-aware, §6) |
| Critical | `kBatteryCritical = 5.0` (new) | `BATTERY_CRITICAL`; top priority; offline at 0 |
| Charge | `kBatteryChargePerTick = 0.80 × rate` | rate = `kFastChargerMultiplier=2.0` (fast) / `1.0` (slow) |
| Vacate | `kBatteryChargeFull = 95.0` (new) | release dock → idle |
| Safe-yield | `kBatterySafeYield = 50.0` (new, gap fix: was ==low) | min level to emergency-yield a dock |

### 3.9 Tick / scheduler (see §7 for detail)

The 400ms `RobotScoutSimulation._tick()` becomes a **4-phase barrier scheduler**: Phase 0 SENSE+PLAYER (freeze `WorldFacts`, drain the async pending-results queue, run `SystemOrderEmitter.pump`), Phase 1 DECIDE (read-only + CAS claims), **Phase 1.5 ARBITRATE** (`AisleTrafficArbiter.resolve` — global move-graph verdicts), Phase 2 ACT (one move / one work tick, gated by verdict), Phase 3 COMMIT (flush completions; successors visible next tick).

---

## 4. Per-brain specifications

Every brain lives in `lib/application/brains/`, is registered in `unitRegistryProvider`, references no other brain, and interlocks only through providers + `ActionApplier`. Gap fixes are folded inline and marked **[fix]**.

---

### 4.1 `StockMonitorBrain` — inbound player (step 1)

**Role.** The inbound "player": a non-physical, energy-exempt Phase-0 emitter inside `SystemOrderEmitter.scanReorder()`. Aggregates on-hand per SKU across rack cells; for each SKU below reorder point with no in-flight order, emits an `Order(inboundReplenish)`, raises the visible marker, and requests a truck+PO.

**Perception.** `WorldFacts.stockViews` (per-SKU `SkuStockView{onHandLoose, reorderPointLoose, targetLoose, homeCells, status}`, computed once at snapshot from `warehouseConfigProvider.cells` — **[fix]** the brain never reads the live provider); open inbound Orders on `jobBoardProvider`; `inboundTruckRegistryProvider` (second dedup); `activeEventsProvider` (its own markers); scan-cadence counter; `energyPolicyProvider`/`forceRescanRequestProvider`; `skuHomeRegistryProvider`.

**Memory.** `_ticksSinceScan`, `_openReplenishBySku: Map<sku,ReplenishLedgerEntry{orderId,poId?,truckId?,emittedTick,confirmed}>`, `_lastEmittedTick` (hysteresis), `_criticalSkus`, `_postFailBackoff`, `_watchStartTick` (stuck-truck watchdog), `_configHash`. Consts: `kReorderScanTicks≈10`, `kReorderPointFraction=0.5`, `kReorderTargetFraction=0.9`, `kMaxInboundOrdersPerScan`, `kReorderCooldownTicks`, `kInboundTruckWaitTimeoutTicks`.

**System trigger.** The clock: `SystemOrderEmitter.pump(facts)` calls `scanReorder()` every `kReorderScanTicks`. Force-rescan channel: an approved `WoisEventType.inboundOrder` writes `forceRescanRequestProvider` (nullable skuId preserved — **[fix]** the per-SKU intent is not dropped), consumed at pump top.

**Decision policy (deterministic ladder).** Build per-SKU `SkuStockView` with **both sides normalized to loose** — `onHandLoose = Σ(pallet_q*48 + case_q*4 + loose_q*1)`, `reorderPointLoose = Σ(maxQ_in_loose * 0.5)`, `targetLoose = Σ(maxQ_in_loose * 0.9)` (**[fix]** the mixed-UOM reorder comparison is gone). Candidates = `onHandLoose < reorderPointLoose`. Filter out SKUs with an open ledger/JobBoard order, a bound inbound truck, or inside cooldown. **Emit only if fully serviceable** (**[fix]**): a rack home AND ≥1 dock bay AND ≥1 reachable pallet-staging slot, else raise a distinct config-error alert. Rank OUT_OF_STOCK before LOW; tiebreak lexicographic `skuId` (**[fix]** deterministic, no unrecorded age). Cap at `kMaxInboundOrdersPerScan`; defer surplus (backpressure) **and back off when `bayOccupancyProvider` free-inbound-bay count ≤ pending unbound trucks** (**[fix]** backpressure is a *pulled* world-fact, not an unread event). `orderQtyLoose = min( max(kReorderQtyUnits, targetLoose-onHandLoose), Σ(maxQ-quantity in loose across home cells) )` — bounded by real absorptive headroom (**[fix]** over-order beyond rack capacity clogged staging and deadlocked the bay); if headroom < 1 pallet, do not emit. `qtyPallets = ceil / kLoosePerPallet`, clamped ≥1.

**Action FSM.** `idle → scanning → emitting → confirming → backoff`.
- `emitting`: **CAS a ledger placeholder before POST** (dup-emission guard); append `Order(inboundReplenish, status:open)`; raise `REPLENISHMENT_NEEDED`/`OUT_OF_STOCK` at a home cell.
- `confirming`: **[fix]** `createInboundOrder` is called **once, by the emitter/pump only** (single owner). Its result `{truck_id, po_id}` is written to a **pending-results queue drained synchronously at the next Phase-0 pump** (**[fix]** never mutate the blackboard from an async `.then`), where `truckId` is bound. A **hard timeout treats an unresolved future like a throw → backoff** (**[fix]** hung requests can't strand an Order).
- `backoff`: keep the placeholder + marker, exponential retry.

**Handoff split (the createInboundOrder double-owner blocker) — [fix].** Two independently-gated pump actions: (a) *create truck* fires when `Order.truckId==null`; (b) *mint `driveTruckToBay`* fires when `Order.truckId != null AND no drive-Job exists yet AND a matching entity exists in `inboundTruckRegistryProvider``. Binding `truckId` can therefore never suppress the drive-Job, and there is exactly one PO per SKU.

**Order closure — [fix].** An `inboundReplenish` Order closes only when **rack stock actually reaches target** (driven by putaway `complete()`), not at truck-depart/staging arrival. `remainingUnits` is decremented in **loose-equiv per pallet put away** (§4.5), closing on `remainingUnits <= 0`. Watchdog exhaustion → Order `aborted`, ledger cleared, alert kept (**[fix]** no permanent dedup lock with no recovery path). Marker lifecycle owned here: resolve on recovery ≥ target or on close.

**OUT_OF_STOCK visibility — [fix].** `skuHomeRegistryProvider` (seeded at config-load) is scanned so a SKU whose cells all went `skuId==null` at zero is still detected. Demand-only SKUs (open outbound line, zero rack footprint) are cross-referenced and either replenished against their designated home zone or raise a no-slotting alert.

**Energy.** Exempt (non-physical). Cost is bounded by the `kReorderScanTicks` cadence.

**Failure handling.** 404 "Warehouse missing" → `publishWarehouse` then retry once → else backoff. Config reload flushes ledgers **atomically with a jobBoard inbound-Order purge and reconciles against live `inboundTruckRegistryProvider`** (**[fix]** no duplicate-PO storm). The old `_recordDiscoveriesAt` marker-raising branch is **deleted** (**[fix]** scouts reveal fog only; StockMonitor is sole owner of `REPLENISHMENT_NEEDED`/`OUT_OF_STOCK`). `inboundTruckRegistryProvider` is kept alive for sim lifetime (**[fix]** no autoDispose teardown disabling the watchdog).

**Consumes / Produces.** Consumes world stock + dedup facts + force-rescan. Produces `Order(inboundReplenish)` + marker + (via pump) `createInboundOrder` and the truck entity seed.

**File/symbol changes.** New `system_order_emitter.dart :: SystemOrderEmitter{pump, scanReorder}` hosting `StockMonitorBrain`; `SkuStockView`, `ReplenishLedgerEntry`; sim_constants above; repoint `event_bus.dart` `approveEvent(WoisEventType.inboundOrder)` from its mis-wired `triggerWave` to `forceRescanRequestProvider`.

---

### 4.2 `InboundTruckBrain` — carrier (steps 2–3, 8-analog depart)

**Role.** One brain per backend `truck_id`; self-claims a free left inbound bay, drives one cell/tick, docks WAITING while robots unload, departs empty, releases the bay, then despawns (single-run villager).

**Perception.** Own entity from `inboundTruckRegistryProvider` (authoritative `(row,col)+approach+claimedBay+fuel+lifecycle+backendSlotId+parentOrderId`); `truckManifestProvider[id]` remaining (**[fix]** locally-mutable manifest, not the read-only `shipmentsByTruck` poll); `bayOccupancyProvider` free left bays; `cellReservationProvider`; `WorldFacts.occupiedCells/blockedCells`; own `driveTruckToBay`/`departTruck` Jobs; `status_actual` for reconcile only (never sets position; keys on `WAITING`, never `'DOCKED'`).

**Memory.** `id` (=truck_id), `TruckLifecycle{created, enrouteNoBay, drivingToBay, waitingAtBay, departing, departed, stalled}`, owned position+approach, `claimedBayCell`, `backendSlotId`, `parentOrderId`, `path/pathIndex/ticksRemaining`, `fuel (kTruckFuelFull=100)`, `lastUnloadJobId` (**[fix]** observe IR death/release), `emittedTick` (FIFO), stall/queue/wait counters, raised-marker set (**[fix]** resolve on terminal).

**System trigger.** Pull: the emitter creates the entity + registers the brain + appends `driveTruckToBay` (bound to this truck_id). The truck is the only unit whose id matches that Job. Manual "MOVE TO INBOUND BAY" button is demoted to optional debug override.

**Decision policy.** Guard ladder: G0 never depart while `truckManifestProvider[id] > 0`; G1 fuel 0 → stalled; [1] claim own `driveTruckToBay`; [2] `enrouteNoBay` claim a bay (prefer `bayCellForSlotId(backendSlotId)` **only if force-arrive supplied slot_id, else deterministic first-free** — **[fix]** the slot_id path is not dead code but is explicitly optional); [3] `drivingToBay` drive one cell (verdict-gated); [4] arrival → `waitingAtBay` + emit `unloadTruck`; [5] manifest 0 → `departing`; [6] release bay **only after physically vacating the bay cell** (**[fix]** head-on with an inbound claimant), drive to exit. **Trucks sort before robots and after energy-critical; `emittedTick` is a real FIFO tiebreak for queued trucks** (**[fix]** lexicographic id starved older arrivals).

**Action FSM.** `created → enrouteNoBay → drivingToBay → waitingAtBay → departing → departed(terminal) → stalled`.
- **Empty-path handling [fix]:** `drivingToBay` on empty/failed A* → release bay, revert to `enrouteNoBay`, alert, retry (mark stalled after N). `departing` on empty path → hold and re-A* an alternate exit; never release the bay until an exit is confirmed. Road→dock adjacency (inbound-marker cells) is included in the truck's `walkable` domain.
- **unloadTruck emission single-owner [fix]:** the truck emits at most one live `unloadTruck` per remaining pallet, gated by a live count of outstanding+claimed `unloadTruck` Jobs for this truck_id (never more than `manifest.remaining`). The §3 `complete()`-side re-emit is removed for inbound; re-emit only when `lastUnloadJobId` is `failed`/released with manifest>0.
- **No-IR / staging-full wedge escalation [fix]:** after `kUnloadStallTicks` with zero manifest progress, either yield the bay and re-queue (so an unloadable truck can dock) or trigger supervisory recovery; the pipeline cannot deadlock solely on a starved staging/IR resource.

**Completion.** `driveTruckToBay` DONE = reached bay + WAITING (this emits `unloadTruck`). `departTruck` DONE = reached exit; bay released, entity removed, **local-departed tombstone recorded** (**[fix]** the reconcile poll never re-seeds a departed truck).

**Order integrity on truck death [fix].** On `stalled → despawn` with cargo aboard, the emitter **unbinds the Order (`truckId=null`) and restores the undelivered remainder** (re-emit a fresh Order or short-close with alert). Truck death returns demand to the board (gather-until-gone survives a lost carrier). On any truck vanish/early-depart, its outstanding `unloadTruck` Jobs are cancelled/re-targeted (**[fix]** IR keying on WAITING can't strand the Order).

**Energy.** Fuel only; exempt from the charger loop; `ActionApplier.driveTruck` drains only on drive-cell steps; never drains queued/waiting/stalled. `< kTruckFuelCritical=5` → `TRUCK_LOW_FUEL`; 0 → `stalled` (and **always release any held bay**, since a stall in `drivingToBay` *does* hold a bay — **[fix]** the "only if enroute" clause was backwards). Battery pinned 100 so the §6 preemption clause is hard-bypassed (**[fix]**).

**Spawn geometry [fix].** Concurrent inbound queue is capped at the number of road-lane cells (emitter backpressure); the spawn cell is verified to be a road cell and reserved via CAS; overflow waits a tick.

**File/symbol changes.** New `inbound_truck_brain.dart`, `TruckLifecycle`, `inboundTruckRegistryProvider`, `TruckEntity`/`TruckFact`, `JobKind.driveTruckToBay/departTruck`, `ActionApplier.driveTruck`, `truckManifestProvider`, `bayCellForSlotId`. Retire `_truckApproach`, `_drawInboundTrucks` round-robin (now reads the registry), `_findDockedTruckAtCell`'s `'DOCKED'` branch, and the `for (bot in _bots){ if (bot.isTruck) continue; }` short-circuit.

---

### 4.3 `BayAllocatorBrain` — stationary bay arbiter (step 3 + step 9 routing)

**Role.** Singleton infrastructure brain; sole owner/writer of `bayOccupancyProvider` for both pools; grants, leases, and releases bays; prevents double-booking and starvation. It labels bays; it never moves anything.

**Substrate fix — [fix, blocker].** The allocator reads truck lifecycle and writes `claimedBay` through the **local `inboundTruckRegistryProvider`/`outboundTruckRegistryProvider`**, never the read-only `inboundTrucksProvider` stream. The 5s poll only merges backend `status_actual`/manifest into local entities without clobbering allocator-owned fields. Arrival/lease/release are driven by **tick-fresh entity position (`entity.pos == grantedCell`)**, not by polled status; `kBayGrantLeaseTicks` is set strictly greater than worst-case approach ticks. A poll returning `[]` on error is treated as **no data** (skip the vanish sweep) — release requires a positive DEPARTED transition or `departTruck`-DONE (**[fix]** transient empty list can't mass-release occupied bays).

**Pools.** Inbound = per-cell `col <= cols/2` docks (or the inbound-marker fallback). Outbound = **dedicated `CellType.outboundDock`** cells (**[fix]** never walkable `CellType.outbound` lanes). Empty-pool config → a faulted state raising a persistent, non-deduped `BAY_NO_CAPACITY(direction)` (**[fix]**).

**Memory.** `_inboundBays`/`_outboundBays` ledgers; `_grants: Map<truckId,BayGrant{bayCell,grantTick,leaseExpiryTick}>`; two FIFO queues with starvation aging; `_waitTicks`; `_reservedButUnoccupied`; `_dwellTicks`; **per-bay/per-grant FSM state** (`free→reservedButUnoccupied→occupied→releasing`) plus a small brain-level rollup (`serving/contended/idle`) (**[fix]** one enum could not represent 8 simultaneous bay states). Dedup keyed on an **episode id, re-armable** so recurring contention re-signals (**[fix]** the permanent tuple swallowed the second real contention).

**Decision policy (Phase 0, before trucks perceive).** (1) RELEASE sweep; (2) GRANT sweep per pool (FIFO + aging, prefer `slotIdHint` cell only if a real `slot_id→cell` map exists — **[fix]** otherwise deterministic first-free; the map is defined in a config table or dropped, never a null lookup); (3) STARVATION/CONTENTION sweep. On reclaim, **atomically clear the truck's stale `claimedBay`** and rotate retry to a *different* free bay, counting consecutive failed grants → after k, `BAY_UNREACHABLE` and stop reserving capacity for that truck (**[fix]** same-bay re-grant livelock + double-drive on stale claimedBay).

**Backpressure semantics [fix].** For **outbound** contention, *accelerate* departs and throttle upstream (hold new outbound-truck creation), never hold departures (**[fix]** holding departs blocks the only event that frees an outbound bay). Backpressure is consumed as a pulled world-fact by `SystemOrderEmitter` (free-bay count), not a fire-and-forget marker.

**Dwell teeth [fix].** `BAY_DWELL_TIMEOUT` after a hard cap `>> normal unload` either force-releases with `BAY_FORCE_RECLAIM` or requires a progress ack; a genuinely stuck unload cannot leak a bay forever. Dwell accounting stays active whenever any grant is `occupied`, independent of queue emptiness (**[fix]** idle disabled the very monitor that mattered).

**Head-on / approach [fix].** The outbound bay's loading adjacency is validated at config-load (every bay has ≥1 walkable neighbor); the departing truck's approach segment is reserved for egress before any new claimant may enter (coordinated with §4.2/§4.9 and the arbiter).

**Render source [fix].** Trucks render from the **entity's live `(row,col)/approach`**; `bayOccupancyProvider` is used only for docked-detection/hit-test — no teleport-to-bay on grant.

**Energy.** Exempt; Phase-0 always-on service; excluded from `priorityKey` energy band; determinism holds over the local substrate (the poll is out-of-band / mocked during JEPA eval — **[fix]**).

**File/symbol changes.** New `bay_allocator_brain.dart`, `UnitRole.bayAllocator`, `bayOccupancyProvider`, `bayRequestProvider`, `BayRequest`/`BayGrant`/`BayDirection`, per-bay FSM, `ActionApplier.grantBay/releaseBay` (sole writers). `_drawInboundTrucks`/`_truckAtLocal`/`_findDockedTruckAtCell` read `bayOccupancyProvider` + entity; delete re-derived geometry.

---

### 4.4 `InboundRobotBrain` — unload (step 4)

**Role.** Claims one `unloadTruck` Job for a WAITING truck, A* to the dock-adjacent cell, picks one pallet, hauls to a reserved single-SKU inbound staging slot, drops (IR→PR handoff), then idles/recharges. Reuses `IRTask` FSM, `_findStagingCell`, `_adjacentWalkable`, A* verbatim.

**Perception.** `board.unclaimedJobs(forRole: inboundRobot)` (only materialized when the truck is WAITING **and** a droppable staging slot exists); own `(row,col)` from `WorldFacts.unitPositions` (**seeded at spawn**, tolerates a spawn-fallback — **[fix]** null on tick 1); battery/cargo; `stagingPalletsProvider` + counted `stagingReserve`; `WorldFacts.occupiedCells/blockedCells` + `cellReservationProvider`; truck facts from `WorldFacts.inboundTrucks` (key on `status_actual=='WAITING'`); `chargerOccupancyProvider`.

**Memory.** `id` (reconciled to backend robot_id — **[fix]**), `role`, lifecycle, `battery`, `currentJob` (IRTask payload), `irSubState`, `reservedStagingKey` (with palletIndex), `claimedChargerCell`, `preemptAfterDrop`, `idleCell`.

**System trigger.** Pull; the emitter mints one `unloadTruck` per pallet (gated on a droppable slot). Role assignment: **`RobotSpawn` gains a `functionalRole` field (or a spawn→role map)** so the registry builds the correct brain (**[fix]** `RobotSpawn` had no role).

**Decision policy (a9 ladder).** Energy first (§6, distance-aware, cargo-safe). CLAIM: filter Jobs to WAITING truck + `_findStagingCell(sku)!=null` (reservation-aware — skips reserved slots) + battery-feasible round-trip (**[fix]**); rank by **Order FIFO age then true A* path cost with a reachability check** (**[fix]** raw Manhattan preferred unroutable-near Jobs and starved old Orders); paired all-or-nothing CAS of `claim(jobId)` + `stagingReserve(slotKey)` — on partial failure roll back the claim in the same tick (**[fix]**).

**Action FSM.** `idle → claiming → navigatingToTruck → pickingFromTruck(kPickTicks=3) → navigatingToStaging → droppingAtStaging(kDropTicks=2) → completing → (idle | returningToCharge) → charging | recovering | offline`.
- Movement is verdict-gated (Phase 1.5). Never drop in an aisle: staging full on arrival → hold with cargo, retry `canDrop` each tick (raise `URGENT_STAGE_CLEAR`).
- Truck early-depart while carrying → divert straight to staging and complete the drop (the pallet is already off the truck).

**Manifest + Order accounting [fix].** On drop `complete()`, decrement **`truckManifestProvider[truckId]`** (locally-mutable) so the truck can eventually depart even offline-of-backend. The parent inbound Order's `remainingUnits` is **not** decremented here — inbound Orders close on *rack* delivery via putaway (§4.1/§4.5), so unload-to-staging never prematurely closes the Order (**[fix]** the pallet-vs-loose off-by-48 and premature closure).

**Putaway handoff [fix].** The emitter mints **exactly one `putaway` Job per pallet dropped** (level-count: outstanding putaway Jobs + slot count == drops), not one per slot-occupancy edge (**[fix]** pallets 2..5 in a slot were never put away).

**Offline recovery [fix].** Battery 0 mid-aisle → `offline`: release Job + staging reservation **+ charger reservation** (**[fix]** charger leak) via a single `release()` helper; cell enters `offlineObstacleProvider` (hard wall). An **autonomous `recovery` Job** is minted after N ticks (auto-tow/relocate/recharge) — no human reset required (**[fix]** absorbing offline in a driver-less sim). If carrying, the recovery Job's *source* is the hulk cell (pick the retained cargo off the hulk to its original dest) so exactly one pallet flows (**[fix]** re-minting the same UNCLAIMED Job double-decremented; `idemKey` guards rack decrements).

**Livelock escape [fix].** Structurally impossible Jobs (unreachable dock, `_adjacentWalkable==null`, permanently contended staging) increment `Job.attempts`; after N, `status=failed` + escalate (alert/defer), instead of infinite release↔re-claim.

**Energy / idle / failure.** Per §6. Blocked next cell → hold + re-plan (verdict handles fairness). Backend pick/drop failures swallowed. Staggered initial battery (**[fix]** synchronized fleet recharge cliff).

**File/symbol changes.** New `inbound_robot_brain.dart`; lift `IRTask`/`IRTaskState`/`assignUnload` body/`tick()` switch into it; collapse `_executePickFromTruck`/`manualPickFromTruck` → `ActionApplier.pick`, `_executeDropAtStaging`/`manualDropAtStaging` → `ActionApplier.drop`; `_updateRobotPosition`+`_revealFog` → `ActionApplier.move`; `stagingReserve`/`stagingRelease` on `StagingNotifier`. Retire `_unloadedByTruck`, `inboundOpsControllerProvider` (subsumed by registry).

---

### 4.5 `PutawayRobotBrain` — putaway (step 5, rules 5.1–5.4)

**Role.** Claims one staged pallet, decides PALLET/CASE/LOOSE/PACK by `_determinePutawayDest`, unwraps as needed, hauls staging→rack/pack, deposits, loops until staging is drained, then idles. `UnitRole.putawayRobot`.

**Perception.** `board.unclaimedJobs(forRole: putawayRobot)`; `stagingPalletsProvider` at each Job src; `config.cells` (rackLoose/rackCase/rackPallet/packStation) for the decision; `rackReservationProvider` (durable dest reservation); **live outbound Orders on `jobBoardProvider`** for rule 5.1 `_hasOrderPending` (**[fix]** rewired off static `config.truckSpawns`); `outboundDemandReservationProvider`; collision facts; battery/charger.

**Memory.** `currentJob` (PRTask payload: `destType {packStation|looseRack|caseRack|palletRack}`, `dropQty {1|12|48}`, path, ticks), cached `_PutawayDest` (decided once per pallet), `Job.reservations` (src staging slot + dest rack), `preemptAfterDrop`, replan/backoff counters.

**System trigger.** Pull; the emitter mints one `putaway` Job per pallet dropped into staging (level-counted, dedup by slotKey — **[fix]** unbounded duplicate minting).

**Decision policy.** `_determinePutawayDest` reused, excluding cells in `rackReservationProvider`, with fixes: 5.1 `_hasOrderPending(sku) && !_hasPalletInInventory(sku)` **only claims as many PRs as `outboundDemandReservationProvider[sku]` needs** (**[fix]** 3 PRs over-consumed a 1-pallet order), re-evaluated at drop time. 5.2/5.3 require the below-threshold rack to have **free capacity ≥ dropQty** (**[fix]** `.clamp(0,maxQuantity)` silently discarded 22 of 48 units); else split across cells or carry the remainder. Claim gates on battery-feasible round-trip.

**Action FSM.** `idle → claiming → navToStaging → pickAtStaging → navToDest → dropAtDest → (idle|returningToCharge) → charging | recovering | offline`. Movement verdict-gated; never strand cargo; on dest-invalidation while carrying, re-decide (5.2→5.3→5.4) or emergency-drop to nearest legal buffer (§6).

**Pack-station handoff — [fix, blocker].** `_applyDropToConfig` for `packStation` currently writes **no state** (the pallet evaporates). Fixed: a pack drop **writes a consumable artifact** into `outboundStageProvider` (a pack-ready line the `OutboundRobotBrain` claims) **and decrements the matching outbound Order**, and 5.1 Jobs are **parented to the outbound Order**, not the inbound one. `rackStockBySku` semantics are preserved so `scanReorder` is not thrown into a runaway.

**Order closure / UOM — [fix].** Rack drops raise `rackStockBySku`; `complete()` decrements the parent **inbound** Order by `kLoosePerPallet` loose-equiv **per pallet** (independent of destType/dropQty), closing on `<= 0`. This is the loop-closing write that stops `scanReorder` re-firing and, crucially, is the event that closes the inbound Order (§4.1) — putaway failure keeps the Order open (**[fix]** truck-depart no longer closes it early).

**Reservation hygiene [fix].** All-or-nothing acquisition (release rack if staging CAS fails); on any re-decide, release the prior dest-rack reservation first; centralize in `Job.releaseAllReservations()` called on every abort/re-decide/complete/offline. `robotCharge` event **raises** the seek threshold / forces immediate preempt (**[fix]** lowering was a no-op). Carrying-but-no-dest raises a distinct `RACKS_FULL`/`PUTAWAY_BLOCKED` backpressure and uses a designated overflow buffer so the unit can recharge (**[fix]** stuck-in-hand had no backpressure and couldn't charge).

**File/symbol changes.** New `putaway_robot_brain.dart`; lift `PRTask`/`PRTaskState`/`assignPutaway` body/`_determinePutawayDest` + helpers; `rackReservationProvider`, `outboundDemandReservationProvider`; `pendingOutboundBySku` view over jobBoard. Retire `PalletPutawayController._tasks`/`tick()`/`_hasOrderPending` static path; collapse pick/drop into `ActionApplier`.

---

### 4.6 `OutboundOrderGeneratorBrain` (`RandomOrderGenerator`) — demand (step 9b)

**Role.** The outbound "player": a non-physical, seeded-random demand source (Dart mirror of backend A4). Periodically mints multi-line `Order(outboundShip)` onto `jobBoardProvider`, WIP-capped, pausable/sabotageable.

**Memory.** `_rng=Random(kOutboundGenSeed)`, `_ticksSinceLastEmit`, `_nextEmitAtTick`, `_orderSeq`, `_emittedOrderIds` (with **local↔backend id map** — **[fix]** dual namespaces double-booked), `_seededSkus`/`_seededCustomers`/`_destinations`, knobs (`kOutboundOrderIntervalTicks`, jitter, `kOutboundOrdersPerBurstMax`, `kOutboundLinesPerOrderMax`, `kOutboundQtyPerLineMax`, `kMaxOpenOutboundOrders`), `enabled`, `stockWeighted`. FSM `disabled|armed|perceiving|emitting`; **constructs into `armed` and runs `armed.onEnter` to seed `_nextEmitAtTick = tick + interval ± jitter`** (**[fix]** undefined init could burst on tick 0).

**Decision policy.** Gates: disabled/paused; cooldown; **WIP cap computed from LOCAL jobBoard open/fulfilling outbound Orders only** (poll advisory) (**[fix]** stale async poll + manual-dialog undercount over-emitted); catalog non-empty. Burst: `nOrders = min(rng(1..burstMax), cap - currentWIP)` with **per-order recheck** (**[fix]** a burst overshot the cap); per order `nLines = min(rng(1..linesMax), seededSkus.length)` **distinct SKUs via shuffle-and-take** (**[fix]** reject-sampling hung when catalog < nLines); per line `{unitType, qty=max(1, rng)}`. **`Order.lines` preserves each line's `unitType`** for role routing; `looseEquiv` derived secondarily (**[fix]** normalizing unitType away broke §3 step-6 role routing).

**WIP reclamation — [fix, major].** On catalog refresh, **cancel** open outbound Orders whose `skuId` left the catalog (release the WIP slot); zero-stock loop-closure is bounded (cap simultaneous zero-stock orders) and made real by having `scanReorder` also scan open outbound lines for below-stock SKUs — so dead/unfulfillable orders can never monotonically fill the cap and silently stop demand.

**Poll filtering — [fix].** `getOrders(id,'OUTBOUND')` is filtered to open/fulfilling statuses; terminal orders never count toward WIP.

**Reset — [fix].** On sim reset: atomically `reseed(seed)`, `_orderSeq=0`, `_emittedOrderIds.clear()`, purge jobBoard outbound Orders; ids namespaced `OO-<epoch>-<seq>`. `DEMAND` markers get a TTL/clear-on-close sweep (**[fix]** raise-without-lower leak). `_emittedOrderIds` pruned on close (LRU).

**File/symbol changes.** New `RandomOrderGenerator` in `system_order_emitter.dart`; `Order`/`OrderKind.outboundShip`/`OrderStatus` in `job_board.dart`; consts + `WoisEventType.demandGenerated`; route `_OutboundOrderDialog` through the same append-to-jobBoard path (shared WIP + dedup).

---

### 4.7 `PickRobotBrain` — outbound retrieval (step 6)

**Role.** UOM-parameterized (`PickUom {pallet, casePick, loose}`). Claims one matching-UOM outbound line-slice, reserves a source rack face, A* to the pick face, picks (decrements rack), hauls to a free outbound-stage slot, drops (handoff to OutboundRobot), idles/recharges.

**Outbound-stage cell — [fix, blocker].** Introduce **`CellType.outboundStage`** (distinct from `palletStaging`/`packStation`/`outbound`). `_findOutboundStageSlot` scans **only** that type; a single assertion pins that PickRobot.drop target, the emitter's `packAndLoad` trigger, and OutboundRobot.pick source key on the *identical* cell set — and never returns an inbound `palletStaging` cell (**[fix]** the handoff could connect to nothing / poison inbound staging).

**Perception.** `board.unclaimedJobs(forRole: pickRobot, uom: myUom)` (ranked by Order age then priority); `WorldFacts.stockViews` + config cells of `sourceCellType` (rackPallet/rackCase/rackLoose); `pickFaceReservationProvider` (**counted**, so a large face serves several pickers concurrently — **[fix]** binary lock serialized); `outboundStageProvider` + reservation; collision facts; battery/charger.

**Decision policy.** Claim requires **both** a resolvable source face (`quantity ≥ qty` on a *single* reservation-free face **or**, if fragmentation splits stock, a multi-face pick trip / job re-sized to a single face's capacity — **[fix]** fragmentation starved otherwise) **and** a droppable outbound-stage slot; else leave the Job UNCLAIMED (backpressure). **Battery-feasibility gate** at claim time: `battery > estimateTicks(cur→rack→stage→nearest charger) * drain + margin` (**[fix]** claiming at 20.1 then dying mid-haul stranded cargo + double-decremented). Rank by composite FIFO+true-path-cost. On repeated block, stamp a per-unit cooldown so the same unit won't instantly re-claim the same unreachable Job (**[fix]** livelock).

**Action FSM.** `idle → claiming → navigatingToRack → pickingFromRack(kPickTicks) → navigatingToStage → droppingAtStage(kDropTicks) → completing → idle | returningToCharge | charging | recovering | offline`. Pack/load trigger is defined **per-staged-line/drain-as-you-go** (**[fix]** "all lines staged" deadlocked when distinct SKUs > outbound-stage cells; the trigger fires per line so cells drain before the whole order completes, or outbound-stage cell count ≥ max distinct SKUs/order is enforced at config-load).

**Inventory integrity — [fix, blocker].** Rack decrement carries `Job.idemKey`; on offline-while-carrying the Job is **not** re-minted against the rack — a `recovery` Job picks the in-hand unit off the hulk (or restores the qty to the rack before re-mint). `board.release`/`fail` restores `remainingUnits` or treats the in-hand unit as reserved-for-line so no double-decrement.

**Loop closure.** `_applyPickFromConfig` decrements the face (clears `skuId` at 0 — and updates `skuHomeRegistryProvider` so §4.1 still sees the SKU as OUT_OF_STOCK); `outboundStageProvider.drop` is the handoff; `complete()` decrements the order line. UOM-locked empty rack (case/loose empty, pallet full) escalates `OUT_OF_STOCK` **and** relies on the internal-replenishment driver in §4.5 (putaway 5.2/5.3 unwrap) — documented cross-brain dependency (**[fix]** the escalation otherwise had no consumer able to refill case/loose racks).

**Role assignment.** `RobotSpawn.functionalRole` derives `PickUom` (e.g., AGV→pallet, AMR→case/loose) — **[fix]** the layout carried no role.

**File/symbol changes.** New `pick_robot_brain.dart`, `PickUom`, `PickTaskState`, `pickFaceReservationProvider`, `outboundStageProvider`, `CellType.outboundStage`, `_findRackFaceWithStock`, `_findOutboundStageSlot`, `_applyPickFromConfig`, `PickEvent`. Reuses the PRTask FSM shape reversed (rack→stage).

---

### 4.8 `OutboundRobotBrain` — pack & load (steps 7–8)

**Role.** Pulls `packAndLoad` Jobs, packs a staged line at the pack station, loads it onto the docked outbound truck one unit at a time until full, then idles/recharges.

**Truck-load CAS — [fix, blocker].** Loading a truck consumes `truckLoadSlotProvider` — a Phase-1 CAS reservation of remaining capacity (mirroring bays/chargers). A robot may only enter `loading` if it holds a reserved slot; `acceptingLoad` clears the instant reserved+loaded == target (**[fix]** the load counter had no CAS → overshoot / last-slot race).

**Perception.** `board.unclaimedJobs(forRole: outboundRobot)`; `robotCargoProvider[self]`; bound Order + bound outbound truck entity (`status_actual`, `currentLoadUnits` vs `targetLoadUnits`, claimed outbound bay); `outboundStageProvider` (multi-SKU, capacity in lines — **[fix]** not the inbound single-SKU/max-5); `bayOccupancyProvider`; collision facts; battery/charger.

**Decision policy (a-ladder).** Energy first (§6, distance-aware). **Battery-feasibility before the pack-PICK** (**[fix]** picking at ~5 then dying mid-carry stranded a consumed stage unit → Order never closes): require `battery ≥ costToTruck + kDropTicks*drain + margin`, else charge first. Carrying → deliver to the bound truck; never claim a second Job while carrying (explicit `idleWithCargo` holding state — **[fix]** plain idle could claim and pick a second unit).

**Action FSM.** `idle → claiming → navigatingToPack → packing(kPackTicks) → navigatingToTruck → loading(kDropTicks) → (claiming|idle|idleWithCargo) → returningToCharge | charging | offline`.
- **Loading terminal-tick re-check [fix]:** confirm `status_actual==LOADING` and remaining capacity before applying the drop; if the truck departed (filled by a peer), transition to `idleWithCargo` and retarget/hold (**[fix]** dropping onto a departing/torn-down truck).
- **packReserve released at the PICK moment** (staged line consumed), not at load (**[fix]** the freed slot was locked through the whole carry, blocking restock).

**LOAD_COMPLETE ownership — [fix].** The brain **only increments load / holds the slot**; it does **not** enqueue `departTruck`. The `OutboundTruckBrain` owns depart via an idempotent `departRequested` CAS on the truck entity (**[fix]** duplicate/absent departTruck from two owners or two same-tick completions).

**UOM / partial — [fix].** `unitQty` is normalized to loose-equiv before decrementing the Order; a truck departing with `Order.remainingUnits>0` does **not** close the Order — the emitter requests a fresh outbound truck for the remainder (see §4.9).

**Idle-with-cargo backpressure [fix].** Bound truck never reaches LOADING → after a threshold raise `OUTBOUND_TRUCK_MISSING`/`PACK_STATION_FULL` (deduped) so the saturating-stage stall is observable and the emitter can request a truck.

**File/symbol changes.** New `outbound_robot_brain.dart`, `OutboundLoadState`, `JobKind.packAndLoad` payload, `outboundStageProvider`, `truckLoadSlotProvider`, `kPackTicks`, `OutboundLoadEvent`. Gate claiming on `Job.requiredRole==role`; drop `canClaim(Order)`.

---

### 4.9 `OutboundTruckBrain` — depart (step 9a)

**Role.** One brain per outbound truck entity; requests a free outbound bay, drives there, stands docked accepting load, departs when full, releases the bay, dispatches the order, idles/recycles. Greenfield.

**Perception.** Own entity from `outboundTruckRegistryProvider` (read from the **Phase-0 frozen snapshot** — **[fix]** live read tore other brains' frame and hurt determinism; 1-tick full-detection latency accepted); bound Order; readiness (`outboundStageProvider` holds packed units for this order); outbound bays via `bayOccupancyProvider`; collision facts; exit geometry; `WoisEventType.resolveGridlock`/force-dispatch flag.

**Memory.** `id`, `OutboundTruckLifecycle{spawning, requestingBay, drivingToBay, docking, loading, full, departing, closing, idle}`, authoritative `(row,col)+approach`, `claimedBayCell`, `boundOrderId`, `targetLoadUnits`, `currentLoadUnits`, `currentJob` (departTruck), stall/queue counters, `departDeadlineTick`, `forceDispatch`, battery pinned 100, `departRequested` idempotency flag.

**LOAD_COMPLETE contract — [fix, blocker].** `targetLoadUnits = min(order.remainingUnits, truckCapacityUnits)` and must be **> 0 before any completion check** (guard 0/null default — **[fix]** empty depart on tick 0). Depart when `currentLoadUnits >= target` **OR no more packable units for this order** (**[fix]** target aligned to pallet granularity so a 40-vs-48 mismatch can't livelock; overshoot capped by the load-slot CAS). On depart with `Order.remainingUnits > 0`, **do not close the Order** — `closing` does `order.remainingUnits -= currentLoadUnits` and only closes at 0; the emitter spawns a follow-on truck for the remainder (**[fix]** partial depart silently deleted demand).

**Egress deadlock — [fix, blocker].** Trucks in `departing`/egress **outrank** trucks in `requestingBay` for aisle CAS (a priority band above lexicographic id); queued trucks must yield off any cell on a departing truck's egress path; the arbiter reserves the whole approach/egress segment before a new claimant may enter (§4.3/§7). One-way lane rule where a 1-wide corridor is unavoidable. The bay is released **only after the truck physically vacates the bay cell**.

**Zero-load / SLA — [fix, blocker].** `loading` has an explicit rule `if tick >= departDeadlineTick → forceDispatch=true` (the SLA watcher is a real FSM rule, not just a memory field). At the deadline with `currentLoadUnits==0`: **release the bay and recycle/despawn** (never depart empty, never hold a finite bay on a zero-load stall). Forced depart requires `currentLoadUnits>0`.

**Undefined exit / bay partition — [fix].** A designated exit/sink road cell and entry cell are added; reachability from every outbound bay is validated at spawn (else auto-despawn+release). Outbound bays are partitioned **per-cell** to a distinct `CellType.outboundDock` (never the lumped `avgDockCol` average).

**departTruck binding — [fix].** `departTruck` Jobs are **bound to a specific truckId**; only the owning truck can claim (prefer self-mint/self-complete bookkeeping never placed on the open queue).

**Despawn safety — [fix].** Entity removal + brain unregister happen **atomically at Phase 3 commit**; `step()` no-ops if its own entity is missing (**[fix]** stepping a brain whose entity is gone crashed the tick). Recycle resets **all** per-shipment flags (`forceDispatch=false`, counters, deadline) (**[fix]** stale `forceDispatch` force-departed the next shipment empty). Spawn cell reserved via CAS / staggered (**[fix]** two trucks on one yard-entry cell).

**Energy.** No battery/fuel loop; `ActionApplier.driveTruck` never drains a truck; the §6 preemption clause is hard-bypassed and there is no `charging` state (**[fix]** a drained truck stalling mid-lane).

**File/symbol changes.** New `outbound_truck_brain.dart`, `OutboundTruckLifecycle`, `OutboundTruck` entity, `outboundTruckRegistryProvider`, `FloorPainter._drawOutboundTrucks`, `SystemOrderEmitter.spawnOutboundTruck`, `CellType.outboundDock`, consts (`kOutboundTruckCapacityUnits`, `kLoadStallTicks`, `kMaxBayQueueTicks`, `kTruckSegmentReserveLen`), events (`NO_OUTBOUND_DOCK`, `LOAD_STALL`, `PACK_STATION_EMPTY`, `EGRESS_BLOCKED`, `OUTBOUND_DEPARTED`).

---

### 4.10 `EnergyGovernor` + `ChargerDockArbiter` — charging subsystem (cross-cutting)

**Role.** (1) `EnergyGovernor` — a per-robot sub-brain mixed into every robot `UnitBrain` (scouts included; trucks excluded); owns the single authoritative battery, drains on work, self-interrupts low, routes to a charger, recharges, returns to the market. (2) `ChargerDockArbiter` — the finite-dock authority (`chargerOccupancyProvider`): enumerate/claim(CAS)/release/markFault, and the `WoisEventType.robotCharge` player channel.

**Fleet-vs-dock admission — [fix, blocker].** With ~6 docks and ~60 units, drain-only-on-action + no-drain-while-queued lets a synchronized dip (or `forceCharge`) freeze the fleet in a non-draining charger queue. Fixes: **cap the fraction of units allowed to leave work to charge at once** (leave enough workers to keep the loop live); stagger seek by battery rank; **scale charger count to fleet size at spawn**; a slow **trickle-drain while queued** so a wedged queue still resolves; explicit **zero-charger config → disable drain / no-charge mode** so the loop can never hard-stall.

**Stationary-unit collision + offline walls — [fix, blocker].** A charging/idle/picking/offline unit never registered a reservation and A* `occupied` is soft, so movers stepped onto them. Fixed at the substrate: the arbiter **pre-seeds `cellReservationProvider` with every non-moving unit's current cell each tick**, and offline hulks + charging/idle occupants are injected into A* **`walkable=false`** (hard block), reserving `occupied` for soft live-traffic bias only.

**Decision policy (F/G/H over A–E).** `battery ≤ kBatteryCritical(5)` and not charging → CRITICAL SEEK (top `priorityKey`, wins dock CAS; still finishes an in-hand drop to a legal cell). `battery < kBatteryLowThreshold(20)` OR `forceChargeEpoch` bumped → GRACEFUL SEEK (carrying: finish one legal drop, set `preemptAfterDrop`; empty: `board.release` UNCLAIMED). **Distance-aware threshold:** effective seek = `max(20, A*_cost_to_nearest_free_charger * drain * safetyFactor)` (**[fix]** fixed 20% died before reaching a far dock). **Critical carrier escape:** if `battery ≤ critical` and the assigned drop is beyond safe range, drop at the nearest legal buffer/staging cell, re-emit the remaining move as a fresh Job, then charge (**[fix]** "keep the far Job" drained to 0 mid-carry). Dock selection: nearest free *working* dock, tiebreak fast-preference then **`(row,col)` lexicographic** (**[fix]** determinism on symmetric layouts).

**Emergency-yield via arbiter — [fix].** A critical unit with no free dock posts a **yield request** to the arbiter, which grants **exactly one** best-charged holder (`≥ kBatterySafeYield=50`, gap fix: was ==20 → immediate re-seek churn) to vacate (**[fix]** independent self-reads made two holders both yield for one claimant). A charging unit above `kBatteryLowThreshold` may abandon charge to claim work only if no critical unit needs the dock (preemptible charging — **[fix]** an opportunistic top-up held the last dock past a critical unit).

**Action FSM.** `powered → seekCharger → routingToCharger → charging → vacate → idle`, plus `criticalSeek`, `dockInterrupted` (fault/yield), `offline`. **Vacate steps OFF the dock to an adjacent free cell before going idle** (`clearingDock` micro-state — **[fix]** an idle unit squatting a logically-free dock collided with the next claimant). Offline recovery re-enters via `seekCharger` + dock CAS (**[fix]** the tow bypassed the arbiter and double-occupied). Faulted-dock release clears `occupant` unconditionally (**[fix]** fault retained a stale occupant forever).

**`robotCharge` semantics — [fix].** Sets `energyPolicyProvider.forceChargeEpoch++` (a latched epoch consumed atomically in Phase 1) which **raises** the effective seek threshold (~50%) so healthy units also top up (**[fix]** lowering it recruited nobody / one-tick reset race). `BLOCK_CHARGER` flips a dock to `status=fault` locally, interrupting its occupant and removing it from the free pool.

**Determinism / priority rank — [fix].** `priorityKey` gives a **total order across every `UnitLifecycle`** (critical > returningToCharge > working > charging > idle > offline, `unitId` final) so iteration is reproducible. Battery persists across hot-reload via a provider (or reloads from backend `RobotState`) (**[fix]** reconstruction reset to 100).

**File/symbol changes.** New `energy_governor` (mixin) + `charger_dock_arbiter.dart` + `chargerOccupancyProvider` + `energyPolicyProvider`; `kBatteryCritical/kBatteryChargeFull/kFastChargerMultiplier/kBatterySafeYield`; wire the dead battery consts through `ActionApplier`; give `WoisEventType.robotCharge` a real body. Charger cells reuse `CellType.chargingFast/chargingSlow/charging` + `isCharger` (already folded into the domain getters — **no new charger CellType needed**).

---

### 4.11 `AisleTrafficArbiter` — traffic referee (Phase 1.5, cross-cutting)

**Role.** Singleton physics referee owning `cellReservationProvider` and the `priorityKey` tiebreak; runs once per tick between DECIDE and ACT; globally resolves all one-cell move requests so no two units collide, swap, or gridlock.

**Perception.** Frozen `WorldFacts` (positions, `occupiedCells`, `blockedCells`); the tick's `MoveRequest` set (`{unitId, fromCell, wantCell | wantSegment(trucks), priorityKey, battery, holdingCargo, lifecycle}`); each unit's cached path+pathIndex; static grid facts + a precomputed genuine **pull-over refuge index** (dead-end pockets / cells strictly off any other unit's shortest path — **[fix]** intersections from the charger heuristic are through-cells, not refuges, and are absent in 1-wide aisles); `bayOccupancyProvider`/`chargerOccupancyProvider`/staging cells as terminal (parked) traffic; `offlineObstacleProvider`.

**Memory.** `reservedTargets` (per-tick), `segmentReservations` + `yieldReservations` (**maneuver-scoped, NOT cleared per tick** — **[fix]** per-tick clearing let a third unit grab a refuge mid-back-out), `blockedTicks` (persistent), `priorityBoost` (aging, **strictly intra-tier** — never lifts a unit across the energy-critical/truck band — **[fix]** unbounded aging could preempt a critical unit or starve healthy traffic), `contentionHistory` (livelock detection), **`rerouteInjections` keyed to the blocker identity, persisted until cleared** (**[fix]** per-tick clearing re-picked the same route → oscillation), `offlineObstacles`, seeded RNG.

**Decision policy (global move-graph, once/tick).** Node=cell, edge=`from→want`. Effective priority = `priorityKey − priorityBoost` (lower acts first). (1) vertex contention → grant the single highest-priority claimant; (2) fixpoint grantability (a target grantable iff it will be empty at commit — chase/convoy advance together); (3) **cycle detection over cell-SETS**: 2-cycle swap DENIED (edge-crossing), ≥3 uncontested self-occupied cycle GRANTED atomically as a rotation; **trucks are represented by their full occupied+wanted cell-set** (**[fix]** a single-node truck missed mixed truck-robot edge crossings); (4) truck footprint atomic — deny the whole segment if any robot occupies it and issue that robot a deferred CLEAR (a **mid-pick/mid-drop robot is deferred, not force-cleared** — **[fix]**); (5) emit per-unit `MoveVerdict` GRANT / HOLD / DIRECTIVE (`yieldToBay`/`reverseOne`/`reroute`).

**Reroute safety — [fix].** A reroute directive **only recomputes the path and HOLDs this tick**; the new first step is submitted as next tick's `MoveRequest` and arbitrated then (**[fix]** stepping onto an un-arbitrated new cell created the very collision the arbiter prevents).

**Narrow-aisle / non-requesting occupant — [fix].** A bounded, stateful **back-out maneuver** (lower-priority unit reverses cell-by-cell to the nearest junction on a *reserved* reverse path, higher-priority passes, then resumes) guarantees termination; where a 1-wide bidirectional segment is unavoidable, a static **one-way-aisle direction rule** is enforced at config-load so head-on is impossible by construction. The arbiter may emit a **step-aside DIRECTIVE to a non-requesting idle/charging occupant** of a needed cell (idle/charging brains must accept it), or idle-parking on through-cells is forbidden (units retire to idle bays) (**[fix]** a non-requesting idle unit was an unaddressable wall).

**Stall detection on net progress — [fix].** Livelock/starvation is detected on **goal-distance not decreasing over N ticks**, not on the grant verdict (**[fix]** an oscillating-but-granted unit never accrued `blockedTicks`). `kDeadlockThreshold` crossing → aging boost / seeded-hash jitter so exactly one proceeds → deterministic.

**Offline / alerts — [fix].** On a unit going offline the arbiter adds its cell to `offlineObstacleProvider` (hard wall via `walkable`), **auto-calls `board.release(currentJob)`**, and (with §4.10) schedules autonomous recovery — operator `resolveGridlock` is a last resort, not the primary path. Traffic alerts go to the **namespaced `trafficAlertsProvider`** and are **resolved on COMMIT when the stall clears** (**[fix]** raise-without-resolve leak + clobbering functional `activeEvents`).

**All movers arbitrated — [fix].** Every position mutation (both ex-controllers, `ScoutBrain`, truck entities, residual D-pad) funnels through a `MoveVerdict`-gated `ActionApplier.move`; the unconditional `task.pathIndex++` becomes GRANT-gated. Backend polls are buffered and applied only at Phase 0 so identical seeds produce identical snapshots (**[fix]** off-tick poll timing broke determinism). The per-unit `cellReservation` CAS from the earlier contract is deleted; the arbiter is the **single writer** (**[fix]** double-specified ownership).

**File/symbol changes.** New `aisle_traffic_arbiter.dart`, `cellReservationProvider`, `offlineObstacleProvider`, `MoveRequest`/`MoveVerdict`/`MoveDirective`, `MoveGraph.resolveMoves`, `PassingBayIndex`, `WoisEventType.resolveGridlock` (+ a command-queue provider drained each tick, independent of manual-mode approval — **[fix]**), `trafficAlertsProvider`. Restructure `_tick()` to insert Phase 1.5; make `IRTask`/`PRTask` advance conditional on GRANT.

---

## 5. End-to-end loop walkthrough (self-propagation proof)

Every arrow is realized by exactly one `emit` or one `complete()→emit/close`. No step's trigger is "a controller decides to"; every trigger is a world-fact threshold (perceived by the emitter) or a preceding Job's completion.

| Step | Trigger (perceive) | Emitter action | Claimed by | `complete()`/close effect |
|---|---|---|---|---|
| **1 stock low** | `SkuStockView.status==LOW/OUT` (serviceability-gated) | `Order(inboundReplenish)` + `REPLENISHMENT_NEEDED`; pump: create truck (gated `truckId==null`) | — | — |
| **2 truck arrives** | entity appears in `inboundTruckRegistryProvider` | pump: mint `driveTruckToBay` (gated `truckId!=null && entity exists && no drive-Job`) | `InboundTruckBrain` | reaches WAITING |
| **3 route to bay** | `driveTruckToBay` | `BayAllocatorBrain` grants a per-cell inbound bay (or marker fallback) | truck drives | at WAITING → emit `unloadTruck` (one/pallet) |
| **4 unload** | `unloadTruck` + droppable slot | reuse `assignUnload` body | `InboundRobotBrain` | `stagingPalletsProvider.drop`; decrement `truckManifestProvider`; **one `putaway`/pallet**; manifest 0 → `departTruck` |
| **5 putaway** | staging slot filled | reuse `_determinePutawayDest` (5.1–5.4) | `PutawayRobotBrain` | rack `quantity += UOM`; **inbound Order `remainingUnits -= 48/pallet`, closes at 0** (loop-closing rack write); 5.1 → `outboundStageProvider` pack-ready line + outbound-Order decrement |
| **6 retrieval** | `outboundShip` line + matching-UOM stock | `pickToStage` per carry-unit (UOM-tagged) | `PickRobotBrain(uom)` | `_applyPickFromConfig` (rack−); `outboundStageProvider.drop`; line− |
| **7–8 pack&load** | outbound-stage holds a line + docked `acceptingLoad` truck | `packAndLoad` (per line) | `OutboundRobotBrain` | `truckLoadSlotProvider` reserve; `currentLoadUnits += unitQty` |
| **9a depart** | `currentLoadUnits ≥ target` OR no more packable | `OutboundTruckBrain` self-mints `departTruck` (idempotent) | truck | release bay; `remainingUnits -= load`; close at 0 else follow-on truck |
| **9b demand** | wall clock | `RandomOrderGenerator` burst (WIP-capped, multi-line) | — | closes loop: consumption → step 1 |

**Self-propagation invariant.** Rack stock rises at step 5 (stops step 1 re-firing) and falls at step 6/9 (re-arms step 1). The inbound Order closes precisely when rack stock reaches target (§4.5), so a stalled putaway keeps the Order open and cannot mask unmet demand. The outbound Order closes only when its lines reach 0, and partial truck departures spawn follow-on trucks — no demand is silently dropped.

**Deadlock/starvation safeguards proven end-to-end.** (a) Bays: CAS + lease + aging + `BAY_UNREACHABLE` + accelerate-outbound-departs. (b) Staging: counted reservations + `URGENT_STAGE_CLEAR`/`PUTAWAY_BLOCKED` backpressure + overflow buffer. (c) Aisles: global move-graph, swap/rotation handling, one-way rule, bounded back-out, hard offline walls, net-progress livelock detection. (d) Energy: distance-aware seek, admission control, arbiter-mediated yield, autonomous offline recovery. (e) Orders: every Order has an explicit close path *and* an abort/short-close path with restored remainder; no dedup lock survives without recovery.

---

## 6. Charging/energy + traffic/deadlock subsystems (detail)

### 6.1 Energy (see §4.10)

Charger docks reuse `isCharger` cells — **no new CellType**. Battery is the single owned field on each robot `UnitBrain`; drain lives only in `ActionApplier.move`/pick/drop (role-gated to skip trucks). The three dead consts + `RobotState.battery` are wired/retired into it. Admission control, distance-aware seek, cargo-safe preemption, arbiter-mediated yield, preemptible charging, and autonomous offline recovery are the six mechanisms that make the fleet-vs-dock ratio survivable and the loop non-stallable.

### 6.2 Traffic/deadlock (see §4.11)

Collision safety rests on two substrate fixes: (i) **hard walls via `walkable`** (`offlineObstacleProvider` + non-vacating occupants), `occupied` demoted to soft bias only; (ii) **stationary-cell pre-seeding of `cellReservationProvider`** each tick so a non-moving unit's cell is never a claimable target. On top, the global move-graph handles vertex contention, chase/convoy, swap denial, ≥3-cycle rotation, and atomic truck footprints; one-way aisles + bounded back-out + genuine refuge pockets resolve narrow corridors; net-progress detection + aging + seeded jitter break livelock deterministically.

### 6.3 New/changed grid + entity facts

- `warehouse_config.dart`: `RobotSpawn.functionalRole` (role/UOM), `CellType.outboundStage`, `CellType.outboundDock`; one-way-aisle direction attribute (optional per aisle); reuse `isCharger`/domain getters. Preserve the inbound `allDocks || inbound-marker` fallback.
- Truck entities are first-class in the two registry providers (position, approach, bay, load, fuel, statusActual, tombstone).

---

## 7. Tick / scheduler + determinism/perf (~60 units @ 400ms)

```
_tick():                                            // 400ms Timer.periodic, single-threaded
  # Phase 0 — SENSE + PLAYER
  applyBufferedBackendPolls()                       # backend results applied only here (determinism)
  drainPendingApiResults()                          # bind truckId/poId synchronously (no async blackboard writes)
  facts = JobBoard.snapshot()                       # freeze WorldFacts (positions, occupied, blocked, stockViews, trucks)
  BayAllocatorBrain.step(facts)                     # release→grant→starvation (grants visible this tick)
  SystemOrderEmitter.pump(facts)                    # scanReorder + RandomOrderGenerator; explode Orders→Jobs
  cellReservationProvider.clear()
  arbiter.preSeedStationaryCells(facts)             # every non-moving unit reserves its own cell

  # Phase 1 — DECIDE (read-only + CAS claims)
  units = unitRegistry.all().sortedBy(priorityKey)  # total order over lifecycles + unitId
  for u in units: u.perceiveAndDecide(facts)        # claim Job/bay/charger/staging/loadSlot; register MoveRequest

  # Phase 1.5 — ARBITRATE
  arbiter.resolve()                                 # global move-graph → per-unit MoveVerdict + reservedTargets

  # Phase 2 — ACT (verdict-gated)
  for u in units: u.act(applier)                    # one GRANTed move / one pick|drop tick; drain here

  # Phase 3 — COMMIT
  JobBoard.flushCompletions()                       # DONE decrements Orders, emits successors (visible next tick)
  registry.reap()                                   # atomic despawn + unregister (trucks)
  arbiter.persistState(); RobotScoutSimulation._flush()  # existing scout-report, unchanged
```

**Determinism.** Every decision is a pure function of the frozen `WorldFacts` + persistent memory + a seeded hash `(priorityKey, lexical unitId, hash(unitId, tick, seed))`. No wall-clock, no unordered-map iteration in decisions, backend polls buffered to Phase 0, JEPA-eval runs with the backend reconciler disabled/mocked. Given the same event seed the run is bit-reproducible — required for the JEPA watchdog eval.

**Perf.** ~60 brains × (A* only when a path is stale — cached in `Job.path/pathIndex`, recomputed on reservation-block) is cheap at 2.5 Hz. The move-graph resolution is O(requests + edges) with a bounded fixpoint; the arbiter is O(0) on a request-free tick. Battery/energy checks are O(1) per unit.

---

## 8. File-by-file change list

**New files (`lib/application/`):**
- `job_board.dart` — `Order`/`OrderLine`/`OrderKind`/`OrderStatus`, `Job`/`JobKind`/`JobStatus`, `WorldFacts`, `SkuStockView`, `ReservationSet`, `JobBoardNotifier`.
- `system_order_emitter.dart` — `SystemOrderEmitter{pump, scanReorder, spawnInboundTruck, bindTruckToOrder, spawnOutboundTruck}`, `StockMonitorBrain`, `RandomOrderGenerator`, `ReplenishLedgerEntry`.
- `brains/unit_brain.dart`, `brains/action_applier.dart` (`PickSpec`/`DropSpec`), `brains/energy_governor.dart`, `brains/charger_dock_arbiter.dart`, `brains/aisle_traffic_arbiter.dart`.
- `brains/scout_brain.dart`, `inbound_truck_brain.dart`, `bay_allocator_brain.dart`, `inbound_robot_brain.dart`, `putaway_robot_brain.dart`, `pick_robot_brain.dart`, `outbound_robot_brain.dart`, `outbound_truck_brain.dart`.

**`providers.dart`:** add `jobBoardProvider`, `unitRegistryProvider`, `inboundTruckRegistryProvider`, `outboundTruckRegistryProvider`, `truckManifestProvider`, `bayOccupancyProvider`, `bayRequestProvider`, `chargerOccupancyProvider`, `cellReservationProvider`, `offlineObstacleProvider`, `truckLoadSlotProvider`, `pickFaceReservationProvider`, `rackReservationProvider`, `outboundDemandReservationProvider`, `energyPolicyProvider`, `forceRescanRequestProvider`, `skuHomeRegistryProvider`, `trafficAlertsProvider`, `outboundStageProvider`; keep `inboundTrucksProvider` alive as reconciler-only; add `stagingReserve`/`stagingRelease` to `StagingNotifier`; `ActiveEventsNotifier` gets owner-namespaced raise/resolve.

**`robot_scout_simulation.dart`:** replace `_tick()` body with the 4-phase scheduler; retire the `isTruck` short-circuit and `ScoutBot.row/col` authority (`ScoutBrain` in the registry); keep `_flush()`.

**`inbound_ops_controller.dart` / `pallet_putaway_controller.dart`:** lift `IRTask`/`PRTask`/`_determinePutawayDest`/`assignUnload`/`assignPutaway` bodies + helpers into the brains; make the advance GRANT-gated; collapse `manual*`/`_execute*` into `ActionApplier`; rewire `_hasOrderPending` to live jobBoard; delete `_recordDiscoveriesAt` marker branch. Controllers demoted (subsumed by the registry).

**`floor_screen.dart`:** `_drawInboundTrucks`/`_truckAtLocal`/`_findDockedTruckAtCell` read `bayOccupancyProvider` + registry entities (delete round-robin + `_truckApproach` + `'DOCKED'`); add `_drawOutboundTrucks`; render truck position from entity `(row,col)/approach` (bay ledger only for hit-test); `TruckMoveButton`/`_OutboundOrderDialog` demoted to overrides routed through the shared paths.

**`warehouse_config.dart`:** `RobotSpawn.functionalRole`; `CellType.outboundStage`, `CellType.outboundDock`; one-way-aisle attribute; `skuHomeRegistry` seed at config-load; keep `isCharger`/domain getters.

**`sim_constants.dart`:** wire dead battery consts; add `kBatteryCritical=5.0`, `kBatteryChargeFull=95.0`, `kFastChargerMultiplier=2.0`, `kBatterySafeYield=50.0`, `kLoosePerCase=4`, `kTruckFuel*`, `kReorder*`, `kOutbound*`, `kPackTicks`, `kLoadStallTicks`, `kBlockedTicksMax`/`kReplanMax`/`kDeadlockThreshold`, `kBay*`.

**`event_bus.dart`:** real bodies for `WoisEventType.robotCharge` (`forceChargeEpoch++`) and new `WoisEventType.resolveGridlock`/`replenishScan`; repoint `inboundOrder` approve → `forceRescanRequestProvider`.

---

## 9. Phased rollout (each phase independently runnable LOCALLY)

Every phase is a demoable increment; earlier phases keep working as later ones land.

1. **P0 — Substrate.** `job_board.dart`, `unit_brain.dart`, `action_applier.dart`, `unitRegistryProvider`, position seeding, the 4-phase scheduler skeleton (arbiter as pass-through GRANT-all). No behavior change; scouts still move, now via `ScoutBrain`+`ActionApplier` (fog reveal from moves). *Verifies the plumbing.*
2. **P1 — One cart does putaway from a pre-seeded staged pallet.** Manually seed one `stagingPalletsProvider` slot; emitter mints one `putaway` Job; one `PutawayRobotBrain` claims, runs 5.1–5.4, deposits into a rack. *Smallest end-to-end demo of pull-claim + run-to-completion.*
3. **P2 — Unload.** `InboundRobotBrain` + `unloadTruck` Jobs fed by a pre-docked pretend truck (static WAITING entity); IR→PR handoff via staging. Now steps 4→5 chain.
4. **P3 — Inbound truck + bay loop.** `StockMonitorBrain` (serviceability-gated) + `InboundTruckBrain` + `BayAllocatorBrain` + `truckManifestProvider`. Steps 1→2→3→4→5 self-propagate; inbound Order closes on rack delivery.
5. **P4 — Outbound.** `RandomOrderGenerator` (multi-line, WIP-capped) → `PickRobotBrain(uom)` → `outboundStageProvider` → `OutboundRobotBrain` (load-slot CAS) → `OutboundTruckBrain` (depart, follow-on trucks). Steps 6→7→8→9, closing the full loop back to step 1.
6. **P5 — Charging.** `EnergyGovernor` + `ChargerDockArbiter` + admission control + `robotCharge`. Wire drain/charge; observe cargo-safe preemption and autonomous offline recovery.
7. **P6 — Traffic.** `AisleTrafficArbiter` global resolution (swaps, rotations, one-way aisles, back-out, hard walls, net-progress livelock detection). Turn the P0 pass-through into the real referee last, once ≥60 units are actually contending.

---

## 10. Test/verification plan + top risks

### 10.1 Verification

- **Unit tests (deterministic, seeded):** UOM normalization (a half-full mixed-UOM SKU sits *exactly* at reorder threshold; `kLoosePerCase=4`); inbound Order closes at exactly `remainingUnits==0` in loose-equiv per pallet; putaway 5.2/5.3 never over-fill past `maxQuantity` (no silent discard); pick idempotency (`idemKey` prevents double rack-decrement on re-mint); WIP cap computed from local jobBoard only; multi-line Order round-trips 1:1 with the backend payload.
- **CAS/arbiter property tests:** no two units ever share a cell across 10k random ticks; no head-on swap; ≥3-rotation advances atomically; a departing truck always clears a queued truck; a stalled/offline hulk is a hard wall (no unit paths onto it); a 1-wide bidirectional corridor never deadlocks (one-way rule / back-out terminates).
- **Loop closure integration:** run P4 for N sim-minutes; assert conservation (units picked == units shipped + in-flight + on-hand delta), no Order stuck open with rack ≥ target, no bay leaked (free-bay count recovers after every depart), no charger leaked (dock count constant), fleet never fully frozen at chargers.
- **Determinism harness:** two runs with the same event seed produce identical position/Order/Job traces (backend reconciler disabled) — the JEPA-eval prerequisite.
- **Backpressure/chaos:** inject `BLOCK_CHARGER`, sabotage bays, kill IR fleet mid-unload, publish a config with zero chargers / zero outbound bays — assert the sim degrades to a safe, self-describing state (alerts raised + resolved) and never hard-stalls.

### 10.2 Top risks + mitigations

| Risk | Mitigation |
|---|---|
| A* `occupied` mistaken for a hard block anywhere → collisions. | Single rule (§3.5): walls via `walkable`, `occupied` soft only; property test on 10k ticks. |
| Fleet-vs-dock ratio freezes the loop. | Admission control + charger scaling at spawn + trickle-drain + zero-charger no-charge mode (§4.10). |
| Async `ApiClient` futures tear the frozen frame / break determinism. | Pending-results queue drained at Phase 0; backend polls buffered to Phase 0; reconciler mocked in eval. |
| Order accounting drift (UOM / premature close / lost remainder on truck death). | Loose-equiv everywhere; inbound closes on rack delivery; every Order has abort/short-close restoring the remainder; conservation test. |
| Inbound-stage / outbound-stage cell-type confusion poisons the wrong buffer. | Distinct `CellType.outboundStage`/`outboundDock`; single assertion pinning producer/consumer cell sets. |
| Truck registry vs 5s poll clobber / zombie respawn. | Local registries authoritative; poll merges non-authoritative fields only; local-departed tombstone wins. |
| Narrow-aisle deadlock in real layouts. | One-way-aisle attribute validated at config-load + bounded back-out with reserved reverse path. |
| Determinism regressions from map iteration / wall-clock. | Total `priorityKey` order; seeded hash tiebreaks; lint against unordered iteration in decision code. |

**Frozen for v1.** Per-unit brains interlock solely through `jobBoardProvider`, the reservation providers, and `ActionApplier` — no brain references another brain — with every gap-hunt blocker, major, and minor resolved inline above.