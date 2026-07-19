# DESIGN_AMENDMENTS_v2.md
## WIOS Warehouse Simulator — Amendments that supersede the flagged parts of AUTONOMOUS_UNITS_DESIGN.md

**Scope:** LOCAL sim only (per the standing no-prod-automation rule — no automation, AI, or agent loop runs in WIOS prod; prod is the app/API surface). This document amends the frozen v1 contract (`AUTONOMOUS_UNITS_DESIGN.md`) in response to the 31 verified findings in `ADVERSARIAL_REVIEW.md`.

**Precedence rule:** Where this v2 document conflicts with v1, **v2 wins**. v1 remains the base contract for everything not touched here (JobBoard substrate, pull-claim, single position authority via `manualRobotPositionsProvider`, the 4-phase barrier scheduler, `ActionApplier`, `AStarPathfinder`, the KEEP-verbatim FSMs). v2 does not re-open those; it repairs the three subsystems the review found "named as solved but never wired" — **offline recovery**, **energy/charging**, **order/UOM accounting** — plus a cross-cutting cleanup band.

**Ground rules honored throughout:** every fix names concrete providers, `CellType`s, `UnitRole`s, methods, and thresholds; every fix reuses existing machinery where it exists (truck-segment arbiter, putaway FSM, staging-reserve pattern, `_emittedOrderIds` LRU); every residual risk is stated honestly, never renamed away.

---

## 1. Preamble & findings-closure table

All 31 findings are closed by exactly one of four amendments. LCC-4 (idemKey backing store) is formally owned by Amendment C but is a hard dependency of Amendment A's recovery re-mint; the cross-dependency is flagged in both.

| # | ID | Severity | Closed by | One-line resolution |
|---|---|---|---|---|
| 1 | **DLS-1** | Blocker | **A** | `CellType.overflowBuffer` + `overflowBufferProvider` + counted reservation + `PutawayRobotBrain` as producer **and** drain owner |
| 2 | **DLS-2** | Blocker | **A** | `UnitRole.recovery` + battery-exempt `RecoveryTowBrain` (pool of 2) claims `JobKind.recovery`, tows the hulk to a pre-reserved dock |
| 3 | **SC-1** | Blocker | **D** | `ScoutBrain.perceiveAndDecide` ports the retired `ScoutBot` frontier policy (Down>Left>Right>Up, `_leadsToDark`, bounded `_history`); no Job |
| 4 | **SC-2** | Blocker | **B** | `ChargerDockArbiter.step(facts)` gets an explicit Phase-0 slot between `BayAllocatorBrain.step` and `SystemOrderEmitter.pump` |
| 5 | **SC-3** | Blocker | **D** | `CellType.outboundStage` is the ONLY outbound buffer; packing becomes an in-place `packingAtStage` dwell; `packStation` removed from routing |
| 6 | **LCC-1** | Breaker | **C** | Per-UOM `SkuPoolView` reorder signal + real `JobKind.rebalance` (rack→rack unwrap) driven by `PutawayRobotBrain` |
| 7 | **LCC-2** | Breaker | **C** | Monotonic partition counters (`retrieved/loaded/shipped`); outbound closes on `shipped>=ordered` only |
| 8 | **SC-5** | Breaker | **C** | Cross-dock CAS-reserves `outboundDemandReservationProvider`; pick-mint is a level count that subtracts the reservation |
| 9 | **SBI-2** | Breaker | **C** | `pickFaceReservationProvider` gains `reservedUnits`; claimable iff `onHandLoose - reservedUnits >= qty` |
| 10 | **SBI-1** | Breaker | **D** | Unload gates on local `TruckFact.lifecycle==waitingAtBay`, never the 5s-polled `status_actual`; `[]`-poll is NO-DATA |
| 11 | **EC-1** | Breaker | **B** | Hysteresis pair: seek at 20, resume-work at `kBatteryResumeWork=60`, vacate at 95; `kMinChargeCycleTicks` floor |
| 12 | **EC-3** | Breaker | **B** | Runtime `noChargeModeProvider = (workingDockCount==0)`; drain frozen while true; `CHARGER_ALL_DOWN` alert |
| 13 | **DLS-3** | Breaker | **B** | Trickle floor at critical(5), relative yield gate, graceful-only admission cap → dip degrades to reduced-but-live |
| 14 | **SC-6** | Breaker | **B** | `ActionApplier.trickleTick(id)` drains `kBatteryTrickleDrainPerTick=0.02`, floored at critical |
| 15 | **EC-2** | Breaker | **B** | Full-path reserve (cur→drop→dock) × congestion factor; carry-onto-dock `chargingWithCargo` terminal; carrier never HELD |
| 16 | **DLS-4** | Breaker | **D** | Classify a/b/c; on true wedge throttle the source + relief downstream, never rotate equally-blocked trucks |
| 17 | **SC-4** | Breaker | **A** | `offlineObstacleProvider` recomputed-from-truth each Phase-3 COMMIT + eager `clear(cell)` on attach |
| 18 | **CD-1** | Breaker | **D** | `TruckDispatchService` interface; `MockTruckDispatch` (seeded, synchronous) in eval; live queue drains by `(emittedTick,orderId)` |
| 19 | **EC-4** | Major | **B** | `validateChargerPlacement` articulation-point test → `chargerBypassProvider`; no-bypass docks one-wayed / rejected |
| 20 | **DLS-5** | Major | **D** | Progress-watchdog bay lease keyed on `bestDistanceSoFar` + `MoveVerdict.reason`; fixed-tick lease removed |
| 21 | **LCC-3** | Major | **C** | Cross-dock credits the inbound line's `divertedUnits`; inbound closes on `deliveredToRack + diverted >= ordered` |
| 22 | **LCC-4** | Major | **C** | `idemLedgerProvider` (Map idemKey→firstAppliedTick) guards every counter/rack write; recovery Jobs inherit the key |
| 23 | **SBI-3** | Major | **A** | `EnergyGovernor.goOffline` is the sole release owner; `release`/`failCarrying` idempotent under `Job.settled` |
| 24 | **SBI-4** | Major | **D** | `JobBoardNotifier.sweepTerminal(tick)` in Phase 3 + LRU sentinels; snapshot scans live WIP only |
| 25 | **SBI-5** | Major | **D** | Tombstones become `Map<truckId,int expiryTick>` with TTL `kTombstoneTtlTicks` + `kTombstoneCap` LRU |
| 26 | **SBI-6** | Major | **D** | Condition markers move to namespaced alerts; heartbeat re-assert + `AlertsNotifier.sweepExpired` auto-resolve |
| 27 | **SC-7** | Major | **D** | P2 gets `truckManifestProvider` + unload emission + `seedStaticWaitingTruck` fixture; lifecycle is the P2/P3 seam |
| 28 | **SC-8** | Major | **B** | `kRobotsPerCharger=8` + `validateChargerCapacity`; provision validated pockets or cap the fleet; fix `chargerCount` bug |
| 29 | **CD-2** | Major | **D** | Delete the "buffering ⇒ determinism" claim; determinism holds only with reconciler+dispatch mocked |
| 30 | **SC-9** | Minor | **C** | `UnitBrain.handledUom`; `canClaim` checks `j.uom == handledUom` for `pickRobot` |
| 31 | **CD-3** | Minor | **D** | Strict total-order tuple `(band, priorityKey-clamp(boost), seededHash, unitId)`; `kTierStride > kMaxPriorityBoost` |

---

## 2. Amendment A — Offline recovery & buffers

Closes **DLS-2, SC-4, DLS-1, SBI-3** (and supplies the recovery half of the LCC-4 idemKey dependency). This is the amendment that kills the redesign's own anti-pattern: a minted-but-unclaimable `JobKind.recovery` and a phantom "designated overflow buffer".

### A.1 Recovery is a real single-actor subsystem (DLS-2)

**New role & actor.** Add `UnitRole.recovery`. Add `RecoveryTowBrain` (`lib/application/brains/recovery_tow_brain.dart`), a battery-exempt pool sized `kRecoveryTowCount=2`, registered in `unitRegistryProvider` at config-load, idling at `recoveryHomeCell` near the charger bank. It is an ordinary MOVER stepped in the normal Phase-1 / Phase-1.5 / Phase-2 loop. `ActionApplier.towStep(id, r, c)` is **non-draining and role-gated exactly like `driveTruck`**, and it pins `battery=100` — so a tow can **never** itself go offline, which structurally kills the recovery recursion (a tow that could die would need a tow).

**Claim ownership (INV-R3).** `Job.requiredRole` maps `JobKind.recovery => UnitRole.recovery`; only `RecoveryTowBrain` claims via `board.unclaimedJobs(forRole: recovery)` + CAS. Recovery Jobs are **bound** (`Job.subjectUnitId = hulkId`, new field) so exactly one tow claims one hulk; FIFO + lexical id tiebreak for determinism. `JobBoard` rejects a recovery claim from any other role.

**Minting (single owner).** `EnergyGovernor.goOffline(hulk)` (the SBI-3 sole owner, §A.4) mints **exactly one** recovery Job per offline unit, guarded by `EnergyGovernor._recoveryJobFor: Map<unitId,jobId>` — a re-mint while one is live is a no-op. Mint is immediate: `kRecoveryMintDelayTicks=0` is safe because a battery-0 stationary hulk cannot self-revive, so there is nothing to wait for.

**Tow substrate FSM.** `idle → claimingRecovery → reservingDock → navToHulk → attach → towing → dockHulk → detach → idle`:
- `reservingDock`: CAS a free WORKING dock for the hulk **through** `ChargerDockArbiter.claim(dock, onBehalfOf: hulkId)` **before** pathing — honoring SC-2 / §4.10 "no arbiter bypass / no double-occupy". The tow holds the reservation and hands it to the hulk on detach, so the hulk is *placed*, never separately `seekCharger`'d.
- `navToHulk`: single-cell arbitrated `MoveRequest`s to a cell adjacent to the hulk (reuse `_adjacentWalkable`).
- `attach → towing`: from the adjacent tick, tow+hulk register as ONE rigid 2-cell footprint via `MoveRequest.wantSegment`, **reusing the existing `AisleTrafficArbiter` truck-segment machinery** (§4.11 items 3–4: atomic occupied+wanted cell-set, deferred CLEAR of a mid-work robot). No new arbiter code — just a new segment *producer*. Tow+hulk outrank worker robots for aisle CAS (truck band). The hulk trails into the tow's vacated cell each step (train motion); any cargo on the hulk rides the body.
- `dockHulk → detach`: the final segment step pushes the hulk onto the reserved dock cell; the tow releases the segment; the hulk's lifecycle flips `offline → charging` holding the pre-reserved dock.

**Salvaged cargo.** If the hulk carried cargo, `EnergyGovernor` re-mints its FAILED original Job as a fresh delivery Job sourced at the dock cell (same kind/skuId/uom/dst and **same `idemKey`**); a normal-role worker repicks via `ActionApplier.pick(PickSpec.fromUnitCargo(hulkId))` which clears `robotCargoProvider[hulk]`. The pallet flows exactly once (idemKey-guarded, §C.5).

### A.2 offlineObstacle cleanup — two-layer (SC-4, INV-R1)

- **Primary (structural):** `offlineObstacleProvider` is **recomputed each Phase-3 COMMIT** as a pure function of live truth — `offlineObstacle = { u.cell : u.lifecycle==offline && !u.underTow }` (new `unit.underTow` flag). Monotonic hard-wall growth is impossible by construction; the set can only shrink when a hulk is towed or revived (reconcile-from-truth beats incremental remove). One O(units) pass.
- **Secondary (eager):** on `attach`, the hulk cell is removed immediately via `offlineObstacleProvider.clear(cell)` (idempotent `Set.remove`) because the hulk becomes a moving arbiter-tracked footprint, not a static wall. On `detach` it rests on a walkable charger cell, never re-added.

### A.3 Overflow buffer — a real cell/provider/capacity/drain-owner (DLS-1, INV-R5/R6/R8)

- **CellType:** add `CellType.overflowBuffer` to `warehouse_config.dart` (consistent with the already-design-added `outboundStage`/`outboundDock`), with label/color and a central, rack-aisle-reachable placement in `warehouse_template_factory`.
- **Provider:** `overflowBufferProvider` — a `StateNotifier<Map<CellKey, OverflowSlot>>` where `OverflowSlot{skuId?, pallets: List<PalletData>, cap}`. **Multi-SKU**, reusing the `outboundStageProvider` pattern (NOT the inbound single-SKU/max-5 `StagingNotifier`).
- **Capacity:** `kOverflowBufferSlotDepth=3` pallets/cell over `kOverflowBufferCells`; drops are CAS-reserved via `overflowReservationProvider` (counted, mirroring `stagingReserve`) so two putaway robots never race the last slot.
- **Producer (relief valve):** `PutawayRobotBrain` §4.5, in the carrying-but-no-legal-rack case (all candidate racks full, no split possible), calls `ActionApplier.drop(OverflowDropSpec)` → `overflowBufferProvider.drop`, preserving skuId/uom/original idemKey. The unit is now empty and enters `returningToCharge` — so a stuck putaway robot can always recharge (fixes v1's strand-in-hand). If overflow is ALSO full: bounded hold-in-place + namespaced `RACKS_FULL`/`OVERFLOW_FULL` backpressure (never an unbounded strand).
- **Drain owner (same brain):** the overflow buffer is just another putaway SOURCE. `SystemOrderEmitter.pump` (Phase 0) scans `overflowBufferProvider` every `kOverflowDrainScanTicks`; for each buffered pallet whose SKU now has a rack with free capacity (`_findBelowThresholdRack`/`_findAvailablePalletRack != null`) it mints a putaway Job **sourced at the buffer cell**, level-counted + deduped by `(bufferSlotKey, palletIndex, idemKey)` in `_overflowDrainMinted`. `PutawayRobotBrain` runs `_determinePutawayDest` normally (buffer→rack), reusing the entire putaway path — no new drain brain.
- **Stock visibility (required for correctness):** `WorldFacts.stockViews.onHandLoose` MUST fold in overflow-buffered pallets of each SKU (the Phase-0 snapshot includes `overflowBufferProvider` contents), else a parked pallet is invisible to `scanReorder`/`StockMonitor` → over-order.

### A.4 Idempotent single-owner offline release (SBI-3, INV-R4)

- **Single owner:** `EnergyGovernor.goOffline(unit)` is the SOLE transition-to-offline handler and the ONLY caller of any release/fail on the offline unit's `currentJob`. The §4.11 `AisleTrafficArbiter` clause "auto-calls `board.release(currentJob)`" is **REMOVED**; the arbiter (and any worker FSM in §4.4/§4.5/§4.7) instead only calls `EnergyGovernor.requestOffline(unit)` (sets a pending flag). Because the unit's own `goOffline` runs in Phase 2 ACT (single-threaded tick), the release executes exactly once, from one place.
- **Two explicit idempotent JobBoard methods:**
  - `JobBoardNotifier.release(jobId)` — empty-handed abandon (active/claimed → unclaimed, clear `claimedBy`, `Job.releaseAllReservations()`); **NO Order/line mutation** (an unclaimed Job still represents its demand).
  - `JobBoardNotifier.failCarrying(jobId)` — carrying case (→ failed, release reservations, and — the ONLY line-restore path — restore the in-hand reserved-for-line units EXACTLY ONCE).
  - Both guarded by new `bool Job.settled`: if status is already terminal/unclaimed OR `job.settled==true`, the call is a no-op. A second call from any stale caller yields byte-identical board state.
- **No re-release-to-unclaimed on offline-while-carrying:** we FAIL the original Job (never re-release), so no peer re-runs it; the pallet flows via the §A.1 recovery re-mint, idemKey-guarded.
- **`settled` reset:** enforced by always minting a FRESH Job id for salvage/recovery re-mints (never reusing a settled Job object), so a stale `settled=true` can never suppress a genuine new Job.

### A.5 Doc sections changed (v1 → v2)

§3.1 (add `UnitRole.recovery`); §3.2 (Job: add `subjectUnitId`, `settled`; requiredRole for `recovery`); §3.3 (`offlineObstacleProvider.clear()` + Phase-3 recompute; recovery Job ownership; add `overflowBufferProvider`/`overflowReservationProvider`); §3.7 (`ActionApplier.towStep` non-draining + `PickSpec.fromUnitCargo` + overflow `drop`); §4.4/§4.5/§4.7 (offline signals `EnergyGovernor`, does NOT call `board.release` locally; overflow producer/drain in 4.5); §4.10 (tow performs dock CAS on hulk's behalf; `goOffline` sole owner; `requestOffline` signal); §4.11 (REMOVE arbiter auto `board.release`; reuse truck-segment for tow footprint; offlineObstacle recompute at COMMIT); **new §4.12 `RecoveryTowBrain` spec**; §5 safeguard (b)/(d) become real; §8/§9 (P6 recovery subsystem is real).

### A.6 New risks (honest)

- **(a) Tow aisle-wedge:** a 2-cell rigid segment is wider than a single robot and wedges a 1-wide aisle worse; the arbiter's single-cell back-out cannot reverse a 2-cell segment out of a dead-end. *Mitigation:* restrict tow routes to ≥2-wide corridors validated at config-load (reuse the one-way-aisle attribute); cap simultaneous offlines via §4.10 energy admission control. A hulk in a genuine 1-wide dead-end is un-towable and raises `RECOVERY_UNREACHABLE` (degraded, not silent).
- **(b) Overflow bounded, not infinite:** if racks stay full and the drain never fires, overflow fills → putaway falls back to hold+`OVERFLOW_FULL` (throughput stall, not deadlock). Acceptable because `StockMonitor` headroom-bounded ordering (§4.1) won't order into a full warehouse.
- **(c) Cargo re-mint congestion:** re-sourcing a salvaged Job at the dock cell needs charger cells to have an adjacent walkable pick cell (shared dependency with EC-4 charger placement validation) and adds pick traffic near chargers.
- **(d) 1-tick latency:** `requestOffline` (Phase 1/1.5 detect) → `goOffline` (Phase 2 execute) adds one tick before the cell becomes a hard wall. Bounded because the hulk is already in `occupiedCells` and `offlineObstacle` applies at the very next COMMIT — planning staleness only, no correctness loss.

---

## 3. Amendment B — Energy & charging

Closes **SC-2, EC-1, SC-6, DLS-3, EC-3, EC-2, EC-4, SC-8**. The energy subsystem is rewritten, not patched.

### B.1 ChargerDockArbiter gets a Phase-0 scheduler slot (SC-2)

Add `UnitRole.chargerArbiter` (a `BayAllocatorBrain` sibling, energy-exempt, excluded from the priorityKey energy band). In §7 `_tick()`, insert `chargerDockArbiter.step(facts)` **immediately after `BayAllocatorBrain.step(facts)` and before `SystemOrderEmitter.pump(facts)`** so all dock releases/fault-evictions/yield grants are visible when robots perceive in Phase 1. `step()` runs four deterministic sweeps over docks iterated in `(row,col)` lexicographic order:
1. **RELEASE** — vacate any dock whose occupant is offline, absent from `unitRegistry`, has entered `clearingDock`, or has `battery >= kBatteryChargeFull(95)`; clear `chargerOccupancyProvider[cell].occupant`.
2. **FAULT** — drain `BLOCK_CHARGER` events; flip `status=fault`, evict occupant to `dockInterrupted`; heal flips back to `working`.
3. **YIELD** — service at most one `chargerYieldRequestProvider` entry per contended dock (eligibility per §B.4).
4. **ADMISSION/METRICS** — recompute `workingDockCount`; publish `chargingPopulationProvider` and `noChargeModeProvider` (§B.5).

Per-tick robot dock CAS-claims in Phase 1 route through the single-writer `ChargerDockArbiter.tryClaimDock(unitId, cell)` — still the sole writer of `chargerOccupancyProvider`. *New risk:* a second Phase-0 mutator — bounded by the fixed order (Bay → Charger → emitter) and lexicographic iteration, keeping the tick bit-reproducible for JEPA eval.

### B.2 Hysteresis threshold pair (EC-1, INV EC-1)

Split the single threshold: SEEK stays at `kBatteryLowThreshold=20` (distance-aware per §B.6); add `kBatteryResumeWork=60.0`. Once a unit enters `charging`/`returningToCharge` it may **not** abandon charge to claim a Job until `battery >= 60` (deadband [20,60)). Vacate-when-full stays at `kBatteryChargeFull=95`. The §4.10 preemptible-charging clause is rewritten: a charging unit may abandon its dock for work ONLY if `battery >= 60` AND no critical unit waits on that dock; below 60 it always keeps charging. A unit that dipped to 20 cannot re-enter the work market until it climbs 40 points — charge/work/charge thrash is impossible. `kMinChargeCycleTicks` is a defensive floor against single-tick flapping. *New risk:* the 40-point deadband keeps units on docks longer, shrinking the worker pool during a recovery wave — bounded by the graceful-only admission cap (§B.4) and the 95 vacate.

### B.3 Queued trickle-drain path (SC-6)

Add `ActionApplier.trickleTick(id)`, invoked in Phase 2 for every robot in `returningToCharge` that holds **no** claimed dock and issued **no** GRANTed move this tick (i.e., wedged in the charge queue). It drains `kBatteryTrickleDrainPerTick=0.02` (vs the 0.15 move drain) — the only non-move/pick/drop drain — and is **explicitly floored:** trickle NEVER takes battery below `kBatteryCritical(5)`. Queued units keep a strict battery ordering (so rank differentiates them and the queue provably resolves) but can never trickle to 0/offline.

### B.4 Cascade prevention — synchronized-dip liveness (DLS-3, INV DLS-3)

Three coupled parts:
- **(a) Trickle floor removes the 5→0 offline arm** entirely — a unit merely waiting for a dock can never go offline. Offline(0) is reachable only by a unit still MOVING below critical, which the FSM forbids (criticals stop taking work and seek).
- **(b) Relative yield gate** replaces the unsatisfiable absolute `holder>=kBatterySafeYield(50)` gate. `ChargerDockArbiter.grantYield(claimant)` grants a critical claimant (battery≤5, no free working dock) a dock from the current occupant with the HIGHEST battery, provided `occupant.battery >= claimant.battery + kYieldMarginBatt(15)` and the occupant is not itself critical. During a synchronized dip the first-docked units rise ~0.8/tick, so within ~19 ticks a holder crosses claimant+15 and rotates out. `kBatterySafeYield` survives only as a soft tiebreak. Per-dock `kYieldCooldownTicks` + "claimant strictly more critical than occupant" give a monotone (lowest-battery-served-first) that terminates.
- **(c) Admission cap applies ONLY to graceful seekers** (pre-critical, battery in [5,20)): a graceful seeker consults `chargingPopulationProvider`; if `population/fleet >= kMaxChargingFraction(0.5)` it defers seeking and keeps working until it goes critical. Criticals bypass the cap. Since criticals never go offline (floor) and always eventually win a dock (relative yield), and graceful seekers keep the loop staffed, the dip degrades to reduced-throughput-but-live.

*New risk:* relative yield can chain (A→B, then C→B), and the trickle floor can leave up to ~dockCount units parked at exactly critical(5) not working. Bounded by `kYieldCooldownTicks` + the strict lowest-battery-first monotone (terminates, no livelock); parked-at-5 units are soft occupants that can still move/yield, not offline hulks. Observable via `BATTERY_STARVATION`.

### B.5 Runtime no-charge fallback (EC-3, INV EC-3)

Move the zero-charger safeguard from config-load to a per-tick check owned by `ChargerDockArbiter`. Its Phase-0 step computes `workingDockCount = docks.where(status==working).length` and publishes `noChargeModeProvider = (workingDockCount == 0)`. `ActionApplier.move/pick/drop/trickleTick` read it; when true they **SKIP all battery drain** (battery frozen). Under `noChargeMode`, `EnergyGovernor` suppresses SEEK/CRITICAL_SEEK, reverts any in-flight `routingToCharger` unit to `powered`/work, and holds critical units in place. Persistent `CHARGER_ALL_DOWN` alert. When any dock returns to `working`, drain resumes and the (admission-capped) queue reforms; units already offline(0) before the blackout are handled by the recovery path (§A.1) once a dock exists. *New risk:* the fleet runs indefinitely with zero chargers (physically unrealistic infinite runtime) — accepted for a local sim as safe degradation over hard-stall, self-describing via `CHARGER_ALL_DOWN`.

### B.6 Carry-safe seek (EC-2, INV EC-2)

- **(1) Full-path reserve:** a carrying graceful seeker's feasibility is `battery >= (astar(cur→drop) + astar(drop→nearestFreeWorkingDock)) * kBatteryDrainPerTick * kSeekSafetyFactor(1.5)`, not just cur→charger.
- **(2) Congestion inflation:** multiply the reserve by `congestionFactor = 1 + clamp(AisleTrafficArbiter.congestionEstimate(), 0, kMaxCongestionInflation(1.0))`, where `congestionEstimate()` returns the rolling HOLD-per-move ratio over the last N ticks. Under congestion the effective seek threshold rises, so units break off earlier.
- **(3) Critical-carrier escape, feasibility-checked:** if the assigned drop is not reachable+dockable within reserve, drop at the nearest LEGAL buffer in range — priority: overflow buffer (§A.3, cross-dep) > nearest reservation-free compatible `palletStaging`/`outboundStage` slot > carry the pallet ONTO the dock and enter `chargingWithCargo` (cargo stays in `robotCargoProvider`; the original drop Job is HELD, resumes on vacate). The carry-onto-dock fallback guarantees no lost pallet and no death.
- **(4) Anti-inflation guarantee:** the moment a carrying unit's congestion-adjusted reserve is breached it is promoted to a `carrier-critical` sub-band in priorityKey and is **NEVER** issued a HOLD verdict by the arbiter — so its remaining path executes at 1 cell/tick and congestion can no longer inflate it. Claim-time gates in §4.4/§4.7/§4.8 adopt the same full-path+congestion reserve so a unit never claims a Job it cannot finish.

*New risk:* near-death carriers with top aisle priority can preempt other traffic/criticals — bounded by the total priorityKey order (carrier-critical is a narrow sub-band, ties broken lower-battery then unitId); at most a few strictly-ordered units get passage, no livelock.

### B.7 Charger placement validation (EC-4, INV EC-4)

`validateChargerPlacement(config)`: for every `isCharger` cell, run a local articulation-point test on the robot-domain walkable subgraph — temporarily block the charger cell and BFS to confirm its walkable neighbours stay mutually reachable (i.e., the cell is NOT a cut-vertex that severs a 1-wide corridor while its dock is occupied ~94 ticks). Publish `chargerBypassProvider: Map<chargerCell,bool hasBypass>`. No-bypass chargers raise `CHARGER_BLOCKS_AISLE(cell)`. Two enforcement layers: (a) authoring — extend `_canPlaceCharger` (`warehouse_creator_screen.dart`) with the same `_isArticulationCell` check so a corridor-severing charger cannot be painted; (b) runtime — the arbiter FORBIDS idle-parking on any no-bypass dock (force-vacate at 95, never loiter) and marks it one-way via the existing one-way-aisle attribute so `AisleTrafficArbiter` routes around it. Template-factory chargers on perimeter crossAisle rows r0/r1 and caseEnd cold pockets already pass. *New risk:* a layout that legitimately needs a corridor charger is rejected — mitigated by the one-way fallback (keep the charger, route around); only truly unbypassed 1-wide chargers with no one-way alternative are rejected.

### B.8 Charger count vs fleet ratio (SC-8, INV SC-8)

**Wording reconciliation:** §6.1 bans a new charger *CellType*, not additional cells of the EXISTING `chargingFast`/`chargingSlow` types placed at authoring time. Define `kRobotsPerCharger=8` and `validateChargerCapacity(config)`: `requiredDocks = ceil(robotSpawns.length / kRobotsPerCharger)`; `actualDocks = cells.where((c)=>c.type.isCharger).length`. This first fixes the real bug that `WarehouseConfig.chargingCount` (`warehouse_config.dart:673`) counts only legacy `CellType.charging` and misses fast/slow docks — **rename/replace it with `chargerCount` over `isCharger`.** Then two paths:
1. **PROVISION** — parameterize the template factory's charger step (`_placeChargersScaled(fleetSize)`) to emit `requiredDocks` chargers using the validated-pocket strategy (perimeter crossAisle rows r0/r1, caseEnd cold pockets, extended wall-aisle columns), each passing `_canPlaceCharger` + the EC-4 bypass check.
2. **FALLBACK** — if authoring cannot fit `requiredDocks` validated pockets, raise `INSUFFICIENT_CHARGERS(actual,required)` and cap the spawned fleet to `actualDocks * kRobotsPerCharger` (park/drop surplus `RobotSpawn`s) so `actualDocks >= ceil(activeFleet / kRobotsPerCharger)` holds by construction with zero runtime cell mutation.

*New risk:* capping the fleet on an under-provisioned dense grid reduces throughput — accepted and self-describing via `INSUFFICIENT_CHARGERS`; the ratio invariant is what makes the DLS-3 admission cap and non-stall guarantees hold.

---

## 4. Amendment C — Order & UOM accounting

Closes **LCC-1, LCC-2, LCC-3, SC-5, SBI-2, LCC-4, SC-9**. Collapses the contradictory counter model into one authoritative partition with a single decrement point, and makes the reorder signal per-UOM.

### C.1 Per-UOM reorder + real rebalance driver (LCC-1, INV-ACC-5)

**(A) Per-pool detection.** In `SystemOrderEmitter.scanReorder()`, split each SKU's `SkuStockView` into up to three `SkuPoolView{uom, onHandLoose, reorderPointLoose, targetLoose, homeCells, status}` keyed `(skuId, UnitType)`: `rackPallet`→PALLET pool, `rackCase`→CASE pool, `rackLoose`→LOOSE pool. onHand/reorder/target are computed **within each pool only**. Candidate = any pool with `onHandLoose < reorderPointLoose`. A full pallet pool no longer masks an empty loose pool.

**(B) Refill router (deterministic ladder, per candidate pool of granularity g):**
1. **INTERNAL UNWRAP first:** if a strictly coarser pool C (pallet for a case/loose deficit) has `onHandLoose > targetLoose + kRebalanceSurplusLoose` (≥1 full pallet of headroom above its own target) and no open rebalance ledger entry for `(sku,g)`, mint one `Job(kind: rebalance, uom: g, skuId, qtyUnits: one pallet in loose-equiv, srcCellType: rackPallet, dstCellType: rack-for-g)`. Claimed by `PutawayRobotBrain` (reuse: it already unwraps in `_determinePutawayDest` 5.2/5.3). Dedup via `_openRebalanceBySku[(sku,g)]`, cleared on rebalance complete; cap 1 concurrent per `(sku,g)`.
2. **EXTERNAL PO fallback:** only if NO coarser pool has surplus does `scanReorder` emit `Order(inboundReplenish)` whose `OrderLine.unitType = g`. `orderQtyLoose` stays clamped to pool g's real headroom.

**(C) Rebalance driver body (buildable from existing code).** `PutawayRobotBrain` gains a `rebalance` claim branch: `src = _findPalletRackWithStock(sku)` (new helper reusing the `_findAvailablePalletRack` scan with predicate `quantity>0`); `dst = _findBelowThresholdRack(CellType.rackLoose|rackCase, sku)` (exists). Robot picks 1 pallet from src (rack decrement via `ActionApplier.pick`), unwraps in-hand, hauls to dst, drops `kLoosePerPallet` loose / `kCasesPerPallet` cases capped at dst headroom (fixes the line-631 `.clamp` silent-discard by splitting/holding the remainder, same rule as putaway 5.2). Rebalance touches **NO** Order accounting — its only effect is pallet-pool onHand−− and loose/case-pool onHand++, which self-arms/disarms the per-pool scan. *New risk (rebalance↔PO thrash):* if the pallet pool hovers near target, a rebalance can drop it below reorder → external PO → putaway rebuilds surplus → re-trigger. Mitigated by the `kRebalanceSurplusLoose` hysteresis band + `_openRebalanceBySku` cooldown; a pathological tight-headroom config can still oscillate slowly (flagged for the chaos test).

### C.2 One authoritative counter model (LCC-2, LCC-3, SC-5)

**(1) OrderLine becomes a monotonic partition, not a mutable `remainingUnits`.**
- OUTBOUND line: `orderedUnits` (immutable), `retrievedUnits`, `loadedUnits`, `shippedUnits` with `shipped <= loaded <= retrieved <= ordered` enforced. Derived gates: `remainingToRetrieve = ordered - retrieved`; `stagedNotLoaded = retrieved - loaded`.
- INBOUND line: `orderedUnits`, `deliveredToRackUnits`, `divertedUnits`.
- **`Order.remainingUnits` scalar is REMOVED**; all logic reads the counters.

**(2) One increment point per counter, all applied in Phase-3 `JobBoardNotifier.flushCompletions()` only** (single-threaded), each guarded by the idem ledger (§C.5):
- `completePick(job)`: `outLine.retrievedUnits += job.qtyUnits`.
- `completeCrossDock(job)`: `outLine.retrievedUnits += q` AND `inLine[job.divertedFromInboundLineId].divertedUnits += q` AND `outboundDemandReservationProvider.release(job)`. (The pallet legitimately serves two roles — left the inbound pipeline, entered the outbound stage — writing ONE bucket in each order; not double-counting one order.)
- `completePutawayToRack(job)`: `inLine.deliveredToRackUnits += kLoosePerPallet`.
- `completeLoad(job)`: `outLine.loadedUnits += job.qtyUnits`.
- `departTruck/closeShipment(truck)`: `outLine.shippedUnits += unitsDepartedForLine`.

**(3) One closure condition each (INV-ACC-2):**
- OUTBOUND closes when `shippedUnits >= orderedUnits` (LCC-2: pick no longer closes; the depart-vs-pick double-decrement is gone because they write different counters).
- INBOUND closes when `deliveredToRackUnits + divertedUnits >= orderedUnits` (LCC-3: a diverted pallet is accounted via `divertedUnits`, so the inbound Order no longer sits short-by-48 to watchdog abort). Rack-to-TARGET is no longer one Order's job; the per-pool scan (§C.1) re-fires a fresh PO because the rack is still low after a divert — the standing target self-heals.

**(4) SC-5 double-serve fix.** Putaway 5.1 cross-dock CAS-reserves `min(palletLoose, remainingToRetrieve - alreadyReserved)` into `outboundDemandReservationProvider` keyed by `outboundLineId` **before** staging the pallet. The emitter's `pickToStage` minting is re-derived each pump as a LEVEL count (not edge): `pickDeficit = ordered - retrieved - Σ(open+claimed+active pickToStage.qty for line) - outboundDemandReservationProvider.reservedFor(lineId)`; mint only if `pickDeficit>0`. The pick side now subtracts the cross-dock reservation, so the line is served exactly once and `remainingToRetrieve` can never go negative.

**(5) Cross-dock re-parenting (LCC-3).** The 5.1 Job is parented to the OUTBOUND order for retrieval accounting AND carries `divertedFromInboundLineId`, resolved from the staged pallet's provenance. `StagingNotifier` slot metadata gains `StagingSlotMeta{skuId, sourceInboundOrderId, sourceInboundLineId}` stamped at unload-drop, so putaway can credit the correct inbound line's `divertedUnits`.

*New risk:* cross-dock + a follow-on fresh PO can transiently over-supply the rack (bounded by the `orderQtyLoose` headroom clamp — no unit lost, only a slightly larger inbound queue). Correctness now depends on `Job.releaseAllReservations()` firing on every terminal (complete/fail/release/offline) — covered by the arbiter property test.

### C.3 Per-unit pick reservation (SBI-2, INV-ACC-6)

Extend `pickFaceReservationProvider`'s value from `{holders:Set, cap:int}` to `{holders:Set<unitId>, cap:int, reservedUnits:int}`. The `PickRobotBrain` claim gate (§4.7) becomes a two-part Phase-1 CAS: a Job on face F is claimable iff `holders.length < cap` (physical bodies fit) AND `(F.onHandLoose - reservedUnits) >= job.qtyUnits` (uncommitted stock exists). On claim: `holders.add(self); reservedUnits += job.qtyUnits`. On `completePick`: `reservedUnits -= job.qtyUnits; holders.remove(self)`. On fail/release/offline: same release via `Job.releaseAllReservations()`. Two pickers, one 48-face, each needing 48: first reserves 48 (available→0); second sees 0 < 48, cannot claim → leaves the Job UNCLAIMED (backpressure) or targets another face. No negative stock, no spurious `scanReorder` misfire. The same `reservedUnits` check applies to the rebalance source pallet face (§C.1) so a rebalance and a pallet pick cannot both draw the last pallet. *New risk:* a missed release path leaves the face permanently reserved → false `OUT_OF_STOCK`. Bounded by centralizing release in `Job.releaseAllReservations()` and asserting `reservedUnits==0` for any face with empty `holders` in the §10 conservation sweep.

### C.4 idemKey backing store (LCC-4, INV-ACC-7)

Add `idemLedgerProvider`: a `StateNotifier<Map<String,int>>` (idemKey → firstAppliedTick). Every rack-decrementing / Order-counter-mutating apply in `flushCompletions()` (`completePick`, `completeCrossDock`, `completePutawayToRack`, `completeLoad`) first checks: `if (idemLedger.contains(job.idemKey)) return;` else applies and `idemLedger.put(job.idemKey, tick)`. idemKey is assigned once by the emitter when it slices an Order line into a Job: `idemKey = '<orderId>:<lineId>:<sliceSeq>'`. A **recovery Job COPIES `originalJob.idemKey`** (a constructor requirement — the recovery Job cannot be built without a source idemKey), so the rack already decremented at the original pick is not decremented again when the in-hand unit moves off the hulk; `retrievedUnits` credit is likewise guarded, so the physical unit is decremented once and credited once regardless of re-mints. **TTL/prune:** entries drop on parent Order close (`JobBoardNotifier.sweepClosedOrder`) and by an LRU cap `kIdemLedgerMax`. This is a SEPARATE store keyed by idemKey (NOT the Job object), so the SBI-4 job sweep (§D.4) never loses rack-decrement idempotency. *New risk:* if recovery Jobs are ever minted with a fresh idemKey by mistake, the guard fails open (double decrement) — mitigated by the constructor requirement and an INV asserting `Σ rack decrements attributable to a line == retrievedUnits`.

### C.5 UOM-aware claim gate (SC-9, INV-ACC-8)

Add to the `UnitBrain` base: `UnitType? get handledUom` — null for every non-pick role, set for `PickRobotBrain` from `RobotSpawn.functionalRole` (AGV→pallet, AMR→case/loose). Redefine the gate:

```dart
bool canClaim(Job j) {
  if (j.requiredRole != role) return false;
  if (role == UnitRole.pickRobot) return j.uom == handledUom;
  return true;
}
```

`Job.uom` already exists (§3.2 the role discriminator). This makes the base contract enforce what `board.unclaimedJobs(forRole:, uom:)` already filters — defense in depth so a mis-built query or a residual manual claim path cannot cross-assign UOM. `rebalance` Jobs (`requiredRole==putawayRobot`) are UOM-agnostic and unaffected. *New risk:* a `PickRobot` registered with null `handledUom` can claim no pick Job (silent starvation) — mitigated by a registration-time assertion `role==pickRobot => handledUom != null`.

### C.6 Doc sections changed

§3.1 (`UnitBrain.handledUom`, `canClaim` body); §3.2 (OrderLine partition counters; `Order.remainingUnits` removed; `Job.divertedFromInboundLineId`; JobKind `rebalance`; SkuStockView→per-pool; StagingSlotMeta); §3.3 (`idemLedgerProvider`; `outboundDemandReservationProvider` read by both putaway and emitter; pickFace `reservedUnits`; rebalance uses rack/pickFace reservations); §4.1 (per-pool ladder + refill router; inbound closure); §4.5 (rebalance branch; cross-dock reserve + `completeCrossDock`); §4.6/§4.8/§4.9 (`completeLoad`/depart→shipped; closure); §4.7 (two-part claim CAS; `completePick`→retrieved only); §5 steps 1,5–9; §8 (`JobKind.rebalance`, `idemLedgerProvider`, consts); §10.1.

---

## 5. Amendment D — Cross-cutting

Closes **SC-1, SC-3, SBI-1, SBI-4, SBI-5, SBI-6, DLS-4, DLS-5, SC-7, CD-1, CD-2, CD-3**.

### D.1 ScoutBrain movement (SC-1, INV-SC1)

`ScoutBrain extends UnitBrain` (role=`UnitRole.scout`, `currentJob` always null, `canClaim()==false` — scouts never touch the JobBoard). Port the retired `ScoutBot.step` frontier logic verbatim. `perceiveAndDecide(WorldFacts)` reads `facts.exploredCells` (NEW snapshot field, frozen from `exploredCellsProvider` at Phase 0) and computes `_targetCell` using the lifted priority table (Down→Left→Right→Up). A direction is desirable iff the neighbor is in `isScoutDomain` (NEW predicate = any non-blocked traversable floor/aisle cell) AND passes the ported `_leadsToDark(nr,nc,exploredCells)` (≥1 of its 8 neighbors still fogged) AND is not in the bounded `_history` ring (cap `kScoutHistory=8`). Fallback ladder: first dark+unvisited priority dir → any walkable unvisited dir → stay put (idle). Register a `MoveRequest{wantCell:_targetCell, priorityKey: scout/idle band, holdingCargo:false}` so scout motion is arbitrated (§4.11 "all movers arbitrated"). `act(applier)`: on GRANT call `ActionApplier.move(id, _targetCell)` — fog reveal (`exploredCellsProvider.markExplored` 3×3) is already the move side-effect, so no separate reveal path. On HOLD, re-target next tick against the shrunk frontier. `EnergyGovernor` is mixed in (scouts are robots) so a scout self-interrupts to charge. *New risk:* two scouts targeting the same dark cell — arbiter GRANTs one, the other re-targets next tick (bounded, no livelock, slight throughput loss). A scout boxed into a fully-explored pocket by hard offline-obstacle walls idles permanently (villager-idle semantics — acceptable).

### D.2 Single outbound handoff cell set (SC-3, INV-SC3)

`CellType.outboundStage` is the ONLY physical outbound buffer; `CellType.packStation` is removed from every autonomous routing path. Packing becomes an in-place dwell transform AT the outboundStage cell. §4.8 `OutboundRobotBrain` FSM changes from `navigatingToPack → packing(at packStation)` to `navigatingToStage → packingAtStage(kPackTicks) [in place, holding its bound line] → navigatingToTruck → loading`. §4.5 putaway rule-5.1's `_findPackStation` helper is redirected so 5.1's pack destination IS an `outboundStage` cell; `packStation` is deleted as a putaway destType. Single cross-brain assertion (mirroring §4.7): `{PickRobot.drop writes} == {putaway-5.1 pack writes} == {OutboundRobot pick-and-pack reads} == {emitter packAndLoad source} == config.cells.where(type==CellType.outboundStage)`. Config-load asserts ≥1 outboundStage cell when outbound is enabled; a legacy packStation-only layout is migrated via a `packStation→outboundStage` domain alias, or fails with `NO_OUTBOUND_STAGE`. *New risk:* a packStation-only layout silently loses its outbound loop unless migrated — mitigated by the mandatory assertion + idempotent alias.

### D.3 Truck-waiting authority (SBI-1, INV-SBI1)

The authoritative local `TruckLifecycle` is the sole gate for unload; the 5s-polled `status_actual` never enters control flow. (1) The emitter mints `unloadTruck` iff `entity.lifecycle==TruckLifecycle.waitingAtBay` (set by `InboundTruckBrain` on bay arrival in Phase 2, visible in next tick's frozen `WorldFacts`) AND a droppable staging slot exists. (2) `InboundRobotBrain` keys its truck-ready filter on `WorldFacts.inboundTrucks[id].lifecycle==waitingAtBay` via a NEW `TruckFact.lifecycle` field (snapshotted from the registry); the §4.4 "key on `status_actual==WAITING`" clause is deleted. `status_actual` is demoted to backend-reconcile-only. (3) `[]`-poll guard: the Phase-0 reconcile treats an empty/error poll as NO DATA — it merges only positive backend fields and never blanks `lifecycle`/`claimedBay`/`position`. Because IR no longer reads `status_actual`, a transient `[]` cannot stall the fleet. *New risk:* 1-tick latency between physical bay arrival and IR seeing `waitingAtBay` (negligible vs the ~12-tick poll lag removed); any code still cross-checking `status_actual` in a gate path must be grepped out.

### D.4 Terminal & tombstone sweeps (SBI-4, SBI-5, SBI-6)

**SBI-4 (INV-SBI4).** Add `JobBoardNotifier.sweepTerminal(tick)` after `flushCompletions` in Phase 3: any Job in `{done,failed}` whose successors are emitted and Order decremented is deleted from the jobs map; its id → bounded LRU `_recentlyClosedJobIds` (cap `kClosedJobIdCap`). Any Order in `{closed,aborted}` with no referencing Job is deleted; its id → LRU `_closedOrderIds` (cap `kClosedOrderIdCap`). `snapshot()` and `unclaimedJobs(forRole:)` then scan only `{unclaimed,claimed,active}` Jobs — O(live WIP) not O(cumulative). Any id lookup checks the live map then the LRU, returning an "already-closed" sentinel for swept ids. `kJobRetentionTicks` grace before delete. The **idemKey ledger (§C.4) is excluded** from this sweep (separate store). *New risk:* a dangling reference to a swept Job — guarded by the LRU sentinels; grace sized > max cross-phase reference lifetime.

**SBI-5 (INV-SBI5).** Represent tombstones as `Map<truckId,int expiryTick>` in each registry. TTL `kTombstoneTtlTicks = ceil(pollIntervalMs/tickMs)*safety` (~5000/400=13 × 3 ≈ 40 ticks); hard cap `kTombstoneCap` with LRU eviction. Phase-0 reconcile sweeps expired tombstones, then checks membership before seeding ANY truck entity from a poll (a still-in-window departed id is never respawned). *New risk:* a poll staler than `kTombstoneTtlTicks` reporting a just-departed truck as active could resurrect a zombie after expiry — mitigated by sizing TTL > worst-case poll staleness and the backend's own DEPARTED status becoming durable once observed.

**SBI-6 (INV-SBI6).** Robot-raised condition markers (`PUTAWAY_BLOCKED`, `URGENT_STAGE_CLEAR`, `RACKS_FULL`, `OUTBOUND_TRUCK_MISSING`, `PACK_STATION_FULL`, `PIPELINE_WEDGED`) get a heartbeat/TTL auto-resolve owned by the raiser and move OFF `activeEventsProvider` onto the namespaced alerts provider (`trafficAlertsProvider` or a sibling `conditionAlertsProvider`). Contract: each marker is keyed `(alertType, cellKey|skuId, raiserId)`; the raising brain RE-ASSERTS it (idempotent raise) every tick its condition holds; a marker not re-asserted for `kAlertStaleTicks` is auto-swept by `AlertsNotifier.sweepExpired(tick)` (Phase 3). Raises go through `ActionApplier.raiseAlert(key, ttlTicks)` in Phase 2 (Phase 1 stays read-only). Markers requiring emitter action (`OUTBOUND_TRUCK_MISSING`→spawn truck; `PUTAWAY_BLOCKED`→throttle inbound) are read as pulled Phase-0 facts. Publish a registry table `{alertKey → (raiser, condition, consumer, ttl)}`. *New risk:* a raiser going offline mid-condition stops re-asserting → marker TTL-resolves though the condition persists; the next brain to hit it re-raises (visibility recovers but can flicker) — `kAlertStaleTicks` sized > a few ticks to damp.

### D.5 Staging wedge relief (DLS-4, INV-DLS4)

Replace §4.2's truck-rotation escalation with downstream-aware relief. On `kUnloadStallTicks` with zero manifest progress, the `InboundTruckBrain`/emitter CLASSIFIES the block using pulled facts:
- **(a)** `stagingFreeBySku[sku]>0` (IR merely absent/busy) → keep bay; the Job will be claimed; optionally raise an IR-starvation alert.
- **(b)** `stagingFreeBySku[sku]==0` AND NOT `PUTAWAY_BLOCKED(sku)` (staging full but draining) → hold bay, transient wait.
- **(c)** `stagingFreeBySku[sku]==0` AND `PUTAWAY_BLOCKED(sku)` (true downstream wedge) → **DO NOT rotate trucks.** The emitter's Phase-0 backpressure scan reads NEW `WorldFacts.putawayBlockedSkus` (derived from `PUTAWAY_BLOCKED` alerts) and: (i) **throttles the source** — `StockMonitorBrain` holds new inbound Orders and inbound-truck creation for that SKU; (ii) **relieves downstream** — if an outbound Order exists for the maxed SKU, do not throttle outbound so picks drain the rack (self-resolving), else route the staged pallet to `CellType.overflowBuffer` via a putaway-to-overflow Job (**cross-dep on DLS-1 / §A.3**); (iii) if relief is structurally impossible (rack maxed, no outbound demand, no overflow) raise `PIPELINE_WEDGED(sku)` and bounded hold-in-place.

`BayAllocator`'s `BAY_DWELL_TIMEOUT`/`BAY_FORCE_RECLAIM` still reclaims a genuinely stuck bay, but reclaim **re-queues the SAME un-unloadable truck** rather than rotating to a different equally-stuck one — bays are never thrashed. §5 safeguard (b) becomes relief-of-downstream + source-throttle, not rotation. *New risk:* a genuinely maxed rack with no outbound demand and no overflow buffer correctly STOPS (throttled, `PIPELINE_WEDGED` observable) rather than livelocking — a graceful stall; the relief for case (c)-with-overflow is a hard cross-dependency on §A.3.

### D.6 Progress-watchdog bay lease (DLS-5, INV-DLS5)

Replace the unsatisfiable fixed "lease > worst-case approach ticks" with a progress watchdog that cannot expire during legitimate arbiter waits. `BayGrant` carries `{bayCell, grantTick, lastProgressTick, bestDistanceSoFar}`. In the Phase-0 RELEASE sweep: if `truck.distanceToBay` strictly beats `bestDistanceSoFar` → update both and refresh `lastProgressTick`. Reclaim ONLY when `(tick - lastProgressTick) > kBayApproachStallTicks` AND the truck's last `MoveVerdict.reason` was NOT an arbiter-induced wait. The arbiter exposes per-unit `MoveVerdict.reason {GRANT, HOLD_CONTENTION, HOLD_YIELD, REROUTE}` (persisted for the allocator via `arbiter.lastVerdictReason(unitId)`); a `HOLD_YIELD`/`HOLD_CONTENTION` verdict pauses the stall counter (the truck is legitimately deferring, and §4.11's aging boost guarantees it eventually GRANTs). Because `bestDistanceSoFar` must be strictly beaten to refresh, an oscillating truck never refreshes and is reclaimed after the stall window. Keep only an absolute `kBayHardCeilingTicks` (≫ any plausible approach) as a broken-progress-signal backstop; the old `kBayGrantLeaseTicks` fixed deadline is removed. After `kBayApproachAttemptsMax` true-stall reclaims → `BAY_UNREACHABLE`. *New risk:* the arbiter-HOLD exemption could be abused if the arbiter perpetually holds one truck — bounded by §4.11's aging boost (every held unit eventually GRANTs) and the hard ceiling.

### D.7 Phase boundary P2/P3 (SC-7, INV-SC7)

Redraw the P2/P3 seam using `entity.lifecycle==waitingAtBay` (the SBI-1 fix) as the swappable interface. **P2 (Unload) becomes self-contained:** it gains `truckManifestProvider`, `JobKind.unloadTruck`, the emitter's unload-emission rule (mint one `unloadTruck` per manifest pallet, gated on `lifecycle==waitingAtBay` + droppable slot), plus a fixture `seedStaticWaitingTruck(id,bayCell,manifest)` that injects a STATIC truck entity into `inboundTruckRegistryProvider` with `lifecycle=waitingAtBay` and `truckManifestProvider[id]=N` — NO StockMonitor, NO BayAllocator, NO InboundTruckBrain. `InboundRobotBrain` claims `unloadTruck`, unloads to staging, decrements the manifest, emits putaway → `PutawayRobotBrain` (from P1) chains. Steps 4→5 run against a hand-placed truck. **P3 (Inbound loop)** then adds ONLY the upstream producers of the `waitingAtBay` state — `StockMonitorBrain`, `InboundTruckBrain` (performs the lifecycle transitions incl. setting `waitingAtBay`), `BayAllocatorBrain`, the emitter create-truck/mint-`driveTruckToBay` handoff — and REPLACES the P2 static fixture with a real emitted+driven truck. The unload-emission rule is byte-identical across P2/P3 (it keys on `lifecycle`, faked statically in P2, set dynamically in P3). *New risk:* P2's static truck never departs (`departTruck` lands in P3), leaving an idle docked entity after manifest→0 — harmless, documented as a fixture (testers must not assert bay-release in P2).

### D.8 Determinism on order creation (CD-1, CD-2, INV-CD1/CD2)

**(CD-1)** Inject truck dispatch behind a `TruckDispatchService` interface with `LiveTruckDispatch` (real POST) and `MockTruckDispatch` (synchronous, seeded). In determinism/JEPA-eval mode the emitter calls `MockTruckDispatch` INLINE in the Phase-0 pump: it returns `{truck_id:'TRK-<seed>-<orderSeq>', po_id:'PO-<seed>-<orderSeq>'}` from a seeded counter with no network, so `truckId` binds in the SAME Phase-0 as emission — no pending-results queue at all. In live mode results still arrive async into the pending-results queue, but the queue drains in a PINNED order: sort by `(emittedTick, orderId lexicographic)` (the order Orders were emitted, NOT network-resolution order) before binding, so two POSTs resolving within one inter-tick gap still bind reproducibly. **(CD-2)** Delete §4.11's standalone claim that "backend polls are buffered and applied only at Phase 0 so identical seeds produce identical snapshots". Replace with the honest statement: buffering pins WHICH PHASE a poll applies in, not WHICH TICK it arrives on (the same 5s poll lands on tick 12 vs 13), so determinism is achieved by DISABLING/MOCKING the reconciler and dispatch entirely in eval, not by buffering. Correct §7's determinism paragraph. *New risk:* live and eval modes diverge in timing (live binds 1+ tick later; mock binds same tick) — intended; bit-reproducibility is claimed ONLY for determinism/eval mode. The JEPA watchdog eval MUST run in determinism mode; live is best-effort.

### D.9 Strict total-order priority tiebreak (CD-3, INV-CD3)

Make effective priority a strict total order with a clamped, tier-bounded boost. Clamp: `effective = priorityKey - min(priorityBoost, kMaxPriorityBoost)`, and space tiers so a boost reorders WITHIN a tier but never crosses a band: `kTierStride > kMaxPriorityBoost`, asserted at init. Total-order tiebreak reuses §7's seeded hash — the arbiter's contention comparator is the 4-key tuple `effectivePriorityKey(unit) = (band(unit), priorityKey - clamp(boost,0,kMaxPriorityBoost), hash(unitId,tick,seed), unitId)`. Because unitIds are unique, the final key guarantees no two units ever compare equal → vertex/segment contention always resolves to exactly one winner. Use the identical comparator in Phase-1 DECIDE ordering and Phase-1.5 ARBITRATE so decide-order and arbitrate-order are consistent. *New risk:* the seeded-hash tiebreak means the "fairest" unit isn't always chosen on an exact tie — fairness within a tier is handled by the bounded aging boost, and true starvation is caught by §4.11's net-progress detector.

---

## 6. New / changed symbols — consolidated delta vs v1 §3.3 / §8

### 6.1 Roles (`UnitRole`)
- **+ `UnitRole.recovery`** (RecoveryTowBrain) — Amendment A
- **+ `UnitRole.chargerArbiter`** (ChargerDockArbiter as a scheduled singleton) — Amendment B

### 6.2 CellTypes (`warehouse_config.dart`)
- **+ `CellType.overflowBuffer`** — Amendment A (label/color + template placement)
- **~ `CellType.packStation`** — DEPRECATED for autonomous routing; aliased to `outboundStage` for migration — Amendment D

### 6.3 New brains / services (files)
- `brains/recovery_tow_brain.dart` — `RecoveryTowBrain` (pool `kRecoveryTowCount=2`)
- `TruckDispatchService` interface + `LiveTruckDispatch` + `MockTruckDispatch` (in `system_order_emitter.dart`)

### 6.4 New providers
| Provider | Kind | Amendment |
|---|---|---|
| `overflowBufferProvider` (`Map<CellKey,OverflowSlot>`) | StateNotifier | A |
| `overflowReservationProvider` (counted) | StateNotifier | A |
| `chargerYieldRequestProvider` (`Map<cellKey,{claimant,tick}>`) | StateNotifier | B |
| `chargingPopulationProvider` (derived count) | derived | B |
| `noChargeModeProvider` (derived bool) | derived | B |
| `chargerBypassProvider` (`Map<chargerCell,bool>`) | config-load | B |
| `idemLedgerProvider` (`Map<String,int>`) | StateNotifier | C |
| `putawayBlockedSkus` folded into `WorldFacts` | snapshot field | D |
| `conditionAlertsProvider` (or reuse `trafficAlertsProvider`) | StateNotifier | D |

### 6.5 Changed provider shapes
- `pickFaceReservationProvider`: `{holders, cap}` → **`{holders:Set<String>, cap:int, reservedUnits:int}`** — C
- `offlineObstacleProvider`: add **`.clear(cell)`** + **`recomputeFromTruth()`** (Phase-3) — A
- `outboundDemandReservationProvider`: now read by **both** putaway and the emitter pick-mint; add `reservedFor(lineId)/reserve(lineId,q)/release(job)` — C
- inbound/outbound truck registries: tombstone becomes **`Map<truckId,int expiryTick>`** (TTL+cap) — D
- `StagingNotifier` slot: add **`StagingSlotMeta{skuId,sourceInboundOrderId,sourceInboundLineId}`** — C

### 6.6 Data-model field additions
- `Job`: **`subjectUnitId`** (recovery binding, A), **`settled` bool** (A), **`divertedFromInboundLineId`** (C); `idemKey` format pinned `'<orderId>:<lineId>:<sliceSeq>'` (C)
- `OrderLine` OUTBOUND: **`orderedUnits, retrievedUnits, loadedUnits, shippedUnits`** (C); INBOUND: **`orderedUnits, deliveredToRackUnits, divertedUnits`** (C); **`Order.remainingUnits` REMOVED** (C)
- `JobKind`: **+ `rebalance`** (C); `recovery` now has a real claimer (A)
- `UnitBrain`: **`UnitType? get handledUom`** (C)
- `unit`: **`underTow` flag** (A)
- `TruckFact`: **`lifecycle: TruckLifecycle`** (D)
- `WorldFacts`: **`exploredCells: Set<(int,int)>`** (D), **`putawayBlockedSkus: Set<String>`** (D)
- `SkuStockView` → per-pool **`SkuPoolView{uom,onHandLoose,reorderPointLoose,targetLoose,homeCells,status}`** (C)
- `MoveVerdict`: **`reason {GRANT,HOLD_CONTENTION,HOLD_YIELD,REROUTE}`** (D)
- `BayGrant`: **`lastProgressTick, bestDistanceSoFar`** (D)

### 6.7 New ActionApplier methods
- `towStep(id, r, c)` [non-draining] — A
- `drop(OverflowDropSpec)` / `pick(PickSpec.fromUnitCargo(hulkId))` — A
- `trickleTick(id)` — B
- `raiseAlert(key, ttlTicks)` — D

### 6.8 New JobBoard / emitter / arbiter methods
- `JobBoardNotifier.release(jobId)` / `failCarrying(jobId)` [idempotent] — A
- `JobBoardNotifier.completePick/completeCrossDock/completePutawayToRack/completeLoad/closeShipment` — C
- `JobBoardNotifier.sweepTerminal(tick)` / `sweepClosedOrder(orderId)` — C/D
- `EnergyGovernor.goOffline(unit)` [sole owner] / `requestOffline(unit)` / `_recoveryJobFor` / `feasibleRoundTrip(...)` / state `chargingWithCargo` — A/B
- `ChargerDockArbiter.step(WorldFacts)` / `tryClaimDock` / `release` / `markFault`/`heal` / `grantYield(claimant)` / `claim(dock, onBehalfOf:)` — B
- `AisleTrafficArbiter.congestionEstimate()` / `lastVerdictReason(unitId)` — B/D
- `PutawayRobotBrain._findPalletRackWithStock(sku)` + `rebalance` claim branch — C
- `SystemOrderEmitter._openRebalanceBySku`, `_overflowDrainMinted`, `throttleInboundFor(sku)` — C/D
- `validateChargerPlacement` / `validateChargerCapacity` / `_isArticulationCell` / `_placeChargersScaled(fleetSize)` — B
- `WarehouseConfig.chargerCount` (replaces buggy `chargingCount` at `warehouse_config.dart:673`) — B
- `AlertsNotifier.raise(key,ttlTicks)` / `sweepExpired(tick)` — D
- `seedStaticWaitingTruck(id,bayCell,manifest)` [P2 fixture] — D

### 6.9 New constants (`sim_constants.dart`)
`kRecoveryTowCount=2`, `kRecoveryMintDelayTicks=0`, `recoveryHomeCell`, `kOverflowBufferSlotDepth=3`, `kOverflowBufferCells`, `kOverflowDrainScanTicks`, `kBatteryResumeWork=60.0`, `kMinChargeCycleTicks`, `kBatteryTrickleDrainPerTick=0.02`, `kYieldMarginBatt=15.0`, `kYieldCooldownTicks`, `kMaxChargingFraction=0.5`, `kSeekSafetyFactor=1.5`, `kMaxCongestionInflation=1.0`, `kRobotsPerCharger=8`, `kRebalanceSurplusLoose`, `kMaxRebalancePerSku`, `kIdemLedgerMax`, `kClosedJobIdCap`, `kClosedOrderIdCap`, `kJobRetentionTicks`, `kTombstoneTtlTicks`, `kTombstoneCap`, `kAlertStaleTicks`, `kBayApproachStallTicks`, `kBayApproachAttemptsMax`, `kBayHardCeilingTicks` (replaces `kBayGrantLeaseTicks`), `kMaxPriorityBoost`, `kTierStride`, `kScoutHistory=8`.

### 6.10 New alerts / events
`RECOVERY_UNREACHABLE`, `RACKS_FULL`, `OVERFLOW_FULL`, `OVERFLOW_DWELL` (A); `BATTERY_STARVATION`, `CHARGER_ALL_DOWN`, `CHARGER_BLOCKS_AISLE`, `INSUFFICIENT_CHARGERS` (B); `PIPELINE_WEDGED`, `NO_OUTBOUND_STAGE` (D).

---

## 7. New invariants + tests (add to §10)

### 7.1 Invariants (consolidated)

**Recovery & buffers (A):**
- **INV-R1** (SC-4): after every Phase-3 COMMIT, `offlineObstacleProvider == { u.cell : u.lifecycle==offline && !u.underTow }` exactly; monotonic hard-wall growth is impossible.
- **INV-R2** (DLS-2): given ≥1 free/yielded working dock, every offline hulk is towed to a charger and enters charging in bounded ticks; un-towable hulks raise `RECOVERY_UNREACHABLE`.
- **INV-R3** (DLS-2): at most one `JobKind.recovery` Job per offline unit, bound by `subjectUnitId`, claimable only by `UnitRole.recovery`.
- **INV-R4** (SBI-3): applying `release`/`failCarrying` twice = byte-identical to once; a line's units restored at most once; conservation `Σ(rack + staging + overflow + on-hulk + shipped)` invariant across an offline+recovery cycle.
- **INV-R5** (DLS-1): `overflowBufferProvider` never exceeds `kOverflowBufferCells × kOverflowBufferSlotDepth`; every drop holds a counted reservation; `onHandLoose` includes overflow.
- **INV-R6** (DLS-1): a carrying PutawayRobot with no legal rack always has a terminal action (overflow-drop or bounded hold) and can always subsequently recharge.
- **INV-R7** (LCC-4): a salvaged/re-minted pallet's rack decrement occurs exactly once (consumedIdemKeys ledger).
- **INV-R8** (DLS-1): every overflow-buffered pallet is eventually consumed by a putaway Job sourced at the buffer once its SKU regains capacity — "defined-but-never-drained" is testably false.

**Energy (B):** SC-2 (arbiter runs once/tick in Phase 0, after Bay, before emitter; no dock holds an offline occupant at Phase-1 start); EC-1 hysteresis (seek 20 < resume 60; no charging→working below 60; no cycle within `kMinChargeCycleTicks`); EC-3 no-charge (drain non-decreasing while `workingDockCount==0`; no unit goes offline; resumes next tick when a dock returns); SC-6/DLS-3 trickle floor (a queue-only waiter never reaches 0); DLS-3 synchronized-dip liveness (inject ≥dockCount units <20 in one tick → within bounded T all rotate through a dock, zero go offline, throughput never 0); DLS-3 yield monotone (every yield strictly serves the lower-battery claimant; no revisit within cooldown); EC-2 carrier survival (no unit reaches 0 while carrying in an aisle; pallet count conserved); EC-2 reserve soundness (realized drain ≤ reserved; a breached carrier is never HELD); EC-4 placement (every isCharger cell passes the articulation validator or raises `CHARGER_BLOCKS_AISLE`; no idle-park on a no-bypass dock); SC-8 ratio (`actualDocks >= ceil(activeFleet/kRobotsPerCharger)`; `chargerCount` counts fast+slow+legacy).

**Order/UOM (C):** INV-ACC-1 (`0 <= shipped <= loaded <= retrieved <= ordered` at every commit; each advanced by exactly one JobKind's complete); INV-ACC-2 (outbound closes iff every line `shipped>=ordered`; inbound iff `deliveredToRack+diverted>=ordered`; no earlier close); INV-ACC-3 (rack-attributable + cross-docked units == retrieved; departed == shipped; no unit credited twice); INV-ACC-4 (a cross-docked pallet increments exactly one outbound `retrieved` + one inbound `diverted` + releases its reservation; never increments `deliveredToRack`); INV-ACC-5 (per-`(sku,uom)` pool below reorder → within `kReorderScanTicks` an open rebalance or UOM-targeted inbound line exists; a full pallet pool never masks a depleted case/loose pool); INV-ACC-6 (`reservedUnits <= onHandLoose`; empty holders ⇒ `reservedUnits==0`); INV-ACC-7 (idemKey mutation more than once = no-op); INV-ACC-8 (no PickRobot holds a Job whose `uom != handledUom`; every pickRobot has non-null `handledUom`).

**Cross-cutting (D):** INV-SC1 (every scout has a defined action; fog monotonically shrinks on a connected floor); INV-SC3 (single outbound handoff cell set; `packStation` never in routing); INV-SBI1 (no unload reads `status_actual`; `[]`-poll never mutates registry-owned fields); INV-SBI4 (hot-map size == live WIP; swept ids resolve via LRU sentinels; idemKey ledger untouched); INV-SBI5 (`|tombstones| <= cap`, age `<= ttl`; no departed truck respawned while its tombstone is live); INV-SBI6 (every condition marker re-asserted each tick it holds, auto-resolves within `kAlertStaleTicks`; owner-namespaced, no cell-key clobber); INV-DLS4 (under a putaway→rack wedge the source is throttled, no bay rotated; graceful bounded hold, conservation holds); INV-DLS5 (a grant is reclaimed only on best-distance non-improvement for `kBayApproachStallTicks` AND non-arbiter-HOLD last verdict; only `kBayHardCeilingTicks` overrides); INV-SC7 (P2 runs green with only the static-truck fixture set); INV-CD1 (determinism mode: synchronous seeded ids, same-Phase-0 bind, byte-identical traces; live: queue drains in `(emittedTick,orderId)` order); INV-CD2 (no test/doc asserts determinism from buffering alone); INV-CD3 (the 4-key tuple is a strict total order; `kTierStride>kMaxPriorityBoost`; contention yields exactly one winner).

### 7.2 New/changed tests for §10.1

- **Recovery cycle** (property, 10k ticks with injected battery-0 events): `|offlineObstacle|` tracks live stationary-hulk count and returns to 0 after all recovered; exactly one recovery Job per hulk; only `RecoveryTowBrain` claims it; a genuine 1-wide dead-end raises `RECOVERY_UNREACHABLE`.
- **Idempotent release**: apply `release`/`failCarrying` twice → identical board; `remainingToRetrieve` never negative; conservation across offline+recovery.
- **Overflow**: cap never exceeded; every drop reserved; `onHandLoose` folds overflow (no over-order); drain empties overflow once racks free up; double-count guard (single decrement point = buffer→rack drain complete).
- **Synchronized dip**: inject ≥dockCount units <20 in one tick (or `forceChargeEpoch`) → zero offline, throughput never 0, all rotate through a dock within T; yield monotone + cooldown (no churn).
- **No-charge chaos**: `BLOCK_CHARGER` all docks → drain frozen, no offline, `CHARGER_ALL_DOWN` raised; a dock returns → drain resumes next tick.
- **Carrier survival** (chaos): no unit reaches 0 while carrying in an aisle; each carrying critical drops-at-buffer+recharges or `chargingWithCargo`; pallet count conserved; breached carrier never HELD.
- **Per-pool reorder**: full pallet pool + empty loose pool → a rebalance (or UOM-targeted PO) fires; rebalance touches no Order accounting; rebalance↔PO thrash bounded by hysteresis.
- **Counter partition**: `0<=shipped<=loaded<=retrieved<=ordered`; outbound closes only on `shipped>=ordered`; inbound only on `deliveredToRack+diverted>=ordered`; cross-dock double-account (one outbound `retrieved` + one inbound `diverted`).
- **Per-unit pick reservation**: two orders, one 48-face, total demand ≥ face → second claim blocked (backpressure), no negative stock.
- **idemKey ledger**: re-minted recovery slice with inherited key never double-decrements a rack nor double-credits `retrieved`.
- **UOM claim gate**: an AMR (loose) never claims a pallet Job; a null-`handledUom` pickRobot fails the registration assertion.
- **Scout acceptance (P0)**: fog monotonically shrinks to no-reachable-dark; two scouts on one dark cell resolve deterministically.
- **Single handoff assertion**: the four cell-sets equal `config.cells(type==outboundStage)`; `packStation` absent from routing.
- **Truck-waiting**: unload materializes iff `lifecycle==waitingAtBay`; `[]`-poll leaves registry-owned fields byte-identical.
- **Bounded jobBoard / tombstones**: hot-map == live WIP after sweep; `|tombstones|<=cap`, age`<=ttl`, no respawn.
- **Marker heartbeat**: a marker auto-resolves within `kAlertStaleTicks` of the condition clearing; no cell-key clobber.
- **Bay progress-watchdog**: no lease expires during arbiter-induced HOLD; an oscillating truck is reclaimed after the stall window.
- **Determinism harness**: two eval-mode runs (reconciler+dispatch mocked) → byte-identical Order/truck-id/Job/position traces; live-mode queue drains in `(emittedTick,orderId)` order.
- **P2 independence**: P2 green with only `{seedStaticWaitingTruck, truckManifestProvider, unloadTruck emission, InboundRobotBrain, PutawayRobotBrain}`.

---

## 8. Revised phased rollout (corrected §9)

Each phase remains a demoable increment; earlier phases keep working. The green-light order below folds in the review's "fix the doc before building" ordering: the two phantom subsystems (A) and the accounting rewrite (C) are documented here and land physically only at their phases, but P0/P1 are green immediately.

| Phase | Adds | Resolved dependencies (was blocking in v1) | Green-light |
|---|---|---|---|
| **P0 — Substrate** | `job_board.dart`, `unit_brain.dart`, `action_applier.dart`, `unitRegistryProvider`, position seeding, 4-phase skeleton (arbiter pass-through GRANT-all), **`ScoutBrain` with the ported frontier policy (§D.1)** | **SC-1 closed** (ScoutBrain movement spec exists) | **GREEN NOW** |
| **P1 — One-cart putaway** | one pre-seeded staged pallet → one `PutawayRobotBrain` runs 5.1–5.4 → rack; **dest-full → overflow-drop OR bounded hold+`RACKS_FULL` (§A.3)** | **DLS-1 closed** for the dest-full case | **GREEN NOW** (pre-seeded pallet + empty rack won't even hit overflow) |
| **P2 — Unload (self-contained)** | `truckManifestProvider`, `JobKind.unloadTruck`, unload-emission rule, **`seedStaticWaitingTruck` fixture (§D.7)**, `InboundRobotBrain` | **SC-7 closed** (P2/P3 seam is `lifecycle==waitingAtBay`); **SBI-1** applied (gate on lifecycle) | GREEN after P0/P1 |
| **P3 — Inbound loop** | `StockMonitorBrain` (serviceability + per-pool §C.1), `InboundTruckBrain`, `BayAllocatorBrain`; replaces the P2 fixture with a driven truck | **SBI-1, DLS-4, DLS-5, LCC-3** closed (lifecycle authority; downstream-aware wedge relief; progress-watchdog lease; cross-dock `divertedUnits`) | GREEN after the D-band doc fixes land |
| **P4 — Outbound** | `RandomOrderGenerator` → `PickRobotBrain(uom)` → `outboundStageProvider` → `OutboundRobotBrain` (in-place pack, load-slot CAS) → `OutboundTruckBrain` | **LCC-1, LCC-2, SC-3, SC-5, SBI-2, SC-9, LCC-4** closed (Amendment C: per-UOM reorder + rebalance, partition counters, single handoff cell, cross-dock reservation, per-unit pick reservation, UOM gate, idemKey ledger) | GREEN after Amendment C |
| **P5 — Charging** | `EnergyGovernor` + `ChargerDockArbiter` (scheduled) + hysteresis + admission cap + trickle + no-charge mode + placement validation + carry-safe seek | **SC-2, EC-1, EC-2, EC-3, EC-4, DLS-3, SC-6, SC-8** closed (Amendment B) | GREEN after Amendment B |
| **P6 — Traffic + Recovery** | `AisleTrafficArbiter` real referee (swaps, rotations, one-way, back-out, hard walls, net-progress); **`RecoveryTowBrain` + `UnitRole.recovery` (§A.1)**; offlineObstacle recompute-from-truth | **DLS-2, SC-4, CD-3** closed (real recovery actor; truth-derived obstacle set; strict total-order tiebreak) | GREEN after Amendments A + D.9 |

**Cross-cutting doc fixes that gate multiple phases** (land in the doc first, per the review's bottom line):
1. **A** (recovery actor + offlineObstacle cleanup + overflow buffer) → unblocks P1 dest-full, P6 recovery.
2. **C** (one authoritative counter + per-UOM reorder + rebalance + reservations + idemKey ledger) → unblocks all of P4.
3. **B** (schedule ChargerDockArbiter + hysteresis + no-charge fallback + queued drain + placement/ratio validation + cascade prevention) → unblocks all of P5.
4. **D.3** (truck-waiting authority) → unblocks P2/P3.
5. **D.8** (deterministic mocked order creation) → unblocks the JEPA determinism prerequisite for every phase's eval.
6. **D.4** (terminal/tombstone sweeps) + **D.6** (bay lease) + **D.9** (priority tiebreak) → housekeeping that keeps the long eval bounded and reproducible.

**Green-light summary:** P0 and P1 are buildable now. P2/P3 wait on Amendment D.3 (+ D.5/D.6). P4 waits on Amendment C. P5 waits on Amendment B. P6 waits on Amendments A and D.9. With these amendments folded into `AUTONOMOUS_UNITS_DESIGN.md`, the sim is buildable end-to-end as a LOCAL simulation with no phantom subsystems remaining.

**Frozen for v2.** Per-unit brains still interlock solely through `jobBoardProvider`, the reservation/arbiter providers, and `ActionApplier` — no brain references another brain. Every blocker, breaker, major, and minor from `ADVERSARIAL_REVIEW.md` is closed above with a concrete, buildable mechanism and an honestly-stated residual risk.
