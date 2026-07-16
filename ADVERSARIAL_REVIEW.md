# Adversarial Review — AUTONOMOUS_UNITS_DESIGN.md

**Method:** 6 of 7 adversarial lenses ran (concurrency/determinism, deadlock/livelock/starvation, loop-closure/conservation, energy, state-integrity, scope/contradictions; the codebase-fit lens and the automated verify+synthesis layers were cut off by a usage limit). 31 findings; verification done in-thread against the doc and the real code. Nearly all survive.

## Verdict

**Not buildable end-to-end as written — but salvageable.** The core substrate (JobBoard, pull-claim, single position authority, 4-phase scheduler) is sound. The failures cluster in three subsystems that are *named as solved but never actually wired*: **offline recovery**, **energy/charging**, and **order/UOM accounting**. Most damningly, the review found the exact "defined-but-never-called" pathology the redesign exists to kill — twice. **P0 needs one fix; P1 is nearly safe; P4 (outbound) and P5 (charging) need real doc rework before any code.**

---

## BLOCKERS — cannot be built as written

| ID | Issue | Why it blocks | Fix |
|---|---|---|---|
| **DLS-1** | The "designated overflow buffer" — the sole relief valve for the staging→putaway→bay chain *and* the critical-carrier cargo-dump — is referenced (§4.5, §4.10, §5b) but never defined. §8 adds only `outboundStage`/`outboundDock`. | An undefined resource can't be built; the central staging-deadlock escape rests on a phantom cell. | Define `CellType.overflowBuffer` + provider + capacity + a drain owner (who empties it back to racks), or replace the escape with a bounded "hold-in-place + backpressure" rule. |
| **DLS-2** | `JobKind.recovery` is minted, but **no role/brain ever claims it** (no `recovery` in `UnitRole`, no brain lists `unclaimedJobs(forRole: recovery)`), and "auto-tow" of a battery-0 hulk has no actor/provider. | This is *literally* the `assignUnload`-defined-but-never-called defect §2.1 says it fixes. Hulks become permanent hard walls; they only accumulate. | Add a recovery/tow actor (a charged robot claims recovery Jobs, or a system tow that relocates the hulk to a charger) and wire the claimer. |
| **SC-1** | `ScoutBrain` is registered, stepped, and **required by P0** ("scouts still move"), but has **no movement/target-selection spec** anywhere in §4. Old `ScoutBot._tick` movement is retired with nothing replacing it. | P0 — the first shippable increment — cannot move scouts → fog never reveals → P0 fails its own acceptance. | Port the old frontier/priority movement into `ScoutBrain.perceiveAndDecide` as an explicit exploration policy (no Job needed). |
| **SC-2** | `ChargerDockArbiter` is the sole writer of `chargerOccupancyProvider` and the yield/fault authority, but **§7's scheduler never invokes it** (it lists BayAllocator, emitter, AisleTrafficArbiter — not this). Not in `UnitRole`, so not swept in Phase 1 either. | Units CAS-claim docks but nothing ever releases them, services a yield request, or clears a fault → charger starvation. | Give it an explicit scheduler phase slot (alongside the other singletons). |
| **SC-3** | Contradiction: §4.7 pins the outbound handoff to `CellType.outboundStage` ("PickRobot drop = OutboundRobot pick = identical cell set"); §4.8 sends `OutboundRobot` to `CellType.packStation` to pack. | Built literally, OutboundRobot routes to an empty pack station while goods sit at outboundStage → outbound loop stalls at every order. | Pick one cell set; make §4.8 read `outboundStage`. |

---

## BREAKERS — build, then fail at runtime

| ID | Issue | Trigger |
|---|---|---|
| **LCC-1** | Reorder point is a single **total-loose scalar** summed across pallet+case+loose homes, but picking is UOM-locked. Loose/case racks hit 0 while a full pallet rack keeps the total above reorder → **step 1 never re-fires**. The §4.7 "internal-replenishment driver" (rack→rack unwrap) **does not exist** (5.2/5.3 are staging→rack). Loose orders escalate `OUT_OF_STOCK` with no consumer, WIP cap fills, generator halts → **loop dies.** | SKU with full pallet rack + empty loose rack; an outbound loose line with no refill path. |
| **LCC-2** | Outbound Order is decremented **twice for the same units** (line at pick §5-step6, Order at depart §4.9) and closure is defined two contradictory ways → premature close orphans staged goods (rack decremented, nothing shipped). | Single-line order, 1 pallet; pick completes before any load. |
| **SC-5** | Outbound line **double-served**: putaway-5.1 cross-dock and PickRobot both decrement it; `outboundDemandReservationProvider` is read only by putaway, never by the pick side → over-retrieval, `remainingUnits` goes negative. | Open outbound order for X while an inbound X pallet is in 5.1 cross-dock. |
| **SBI-2** | Pick-side **over-consumption**: face reservation is *counted* (concurrency cap, by design) and stock is read from the *frozen* WorldFacts snapshot; nothing reserves actual units → two pickers each see `qty=48≥need` and both draw one 48-unit face → negative/corrupted stock, mis-fires `scanReorder`. | ≥2 orders for the same SKU whose total demand ≥ one face's on-hand. |
| **SBI-1** | Unload claim gates on the **5s-polled `status_actual==WAITING`**, not the authoritative local `lifecycle==waitingAtBay` (contradicts §3.3/§3.6). A truck docks and sits idle up to ~12 ticks; a transient `[]` poll blanks the field and **stalls the whole IR fleet**. | Any truck docking between two 5s polls (the normal case). |
| **EC-1** | Preemptible-charging abandon threshold (20) **==** graceful-seek threshold (20) → charge/work/charge **thrash** with dock churn. The doc fixed this exact `==20` bug for emergency-yield (`kBatterySafeYield=50`) but re-instantiated it here ungated. | Any charging robot rising just past 20 while a Job is claimable. |
| **EC-3** | Runtime loss of **all** working chargers (`BLOCK_CHARGER`/sabotage, which §10.1 explicitly tests) has **no fallback** — the "zero-charger → no-drain" safeguard is evaluated only at config-load → fleet drains to offline → hard stall. | Chaos test faults all ~6 docks during a run. |
| **DLS-3** | The fleet-freeze "fix" (admission cap + trickle-drain) converts a synchronized low-battery dip into a **permanent OFFLINE cascade**: criticals bypass the cap, trickle 5→0, and emergency-yield needs a holder ≥50 that doesn't exist during a synchronized dip. | ≥dock-count units cross <20 in a short window (or a `forceChargeEpoch`). |
| **SC-6** | "Trickle-drain while queued" (the mechanism meant to unwedge the charge queue) has **no ActionApplier entry point** — drain lives only in move/pick/drop, never idle/queued → mitigation is unbuildable, queue never resolves. | Synchronized dip / forceCharge sends >dock-count units into the non-draining queue. |
| **EC-2** | Robot can **die en route while carrying**: the distance-aware battery reserve covers cur→charger but a carrying graceful-seeker detours cur→drop→charger; congestion (unbounded HOLD/reroute) inflates real paths past the fixed margin; the critical-carrier escape isn't feasibility-checked. | Carrying seeker whose drop is far from the nearest charger, or rerouted mid-haul. |
| **DLS-4** | Staging-full wedge escalation only **rotates trucks** through the bay; when the block is downstream (putaway→rack), every queued truck is equally un-unloadable → **bay livelock**, contradicting §5's "cannot deadlock on starved staging." | Staging pinned at max 5 by blocked putaway while ≥2 full trucks wait. |
| **SC-4** | `offlineObstacleProvider` cells are added on offline but **never cleared on recovery** → monotonic hard-wall growth; aisles progressively close → gridlock. | Any battery-0 event over a long run. |
| **CD-1** | The pending-results queue pins *when* async results apply, not *what order* — `createInboundOrder` POSTs resolve in network order, and "reconciler disabled" is scoped to the 5s poll only → **JEPA determinism prerequisite fails** on the order-creation path. | Two SKUs cross reorder in one pass; both POSTs resolve within one inter-tick gap. |

---

## Majors & residual risks

- **EC-4** — charger docks aren't validated off through-aisles; a ~94-tick charging occupant becomes a hard wall that can sever a 1-wide corridor (layout-dependent).
- **DLS-5** — bay lease "strictly greater than worst-case approach" is unsatisfiable under unbounded HOLD; leases expire mid-approach → reclaim churn → `BAY_UNREACHABLE` starves inbound throughput.
- **LCC-3** — 5.1 cross-dock parents a diverted inbound pallet to the *outbound* order; the inbound Order stays short-by-48 (rack under target) until watchdog abort — violates §5's "closes when rack reaches target."
- **LCC-4** — `idemKey` has **no backing store** (no consumed-key ledger in §3.3/§8); the §10.1 idempotency test asserts behavior nothing implements. Real protection is the recovery-source rewrite (which itself depends on the broken DLS-2).
- **SBI-3** — offline Job release is double-owned (robot FSM §4.4 + arbiter §4.11) with no idempotency guard → `remainingUnits` double-restore → phantom demand.
- **SBI-4** — terminal Orders/Jobs are never swept from `jobBoardProvider`; per-tick `snapshot()`/`unclaimedJobs` scan grows O(cumulative work) → degrades the long JEPA eval it exists to serve.
- **SBI-5** — departed-truck tombstone set grows unbounded (no TTL/LRU, unlike `_emittedOrderIds`).
- **SBI-6** — robot-raised functional markers (`PUTAWAY_BLOCKED`, `URGENT_STAGE_CLEAR`, …) have no resolve owner the emitter can observe → reintroduces the raise-without-resolve leak §2.1 claims to fix.
- **SC-7** — §9's "each phase independently runnable" is false for P2: `InboundRobotBrain` depends on `truckManifestProvider` + unload-emission ownership introduced only in P3.
- **SC-8** — "scale charger count to fleet at spawn" has no placement mechanism on a hand-authored fixed grid (and contradicts §6.1's "no new charger cells").
- **CD-2** — "buffered polls ⇒ identical snapshots" (§4.11) is an overclaim; buffering pins phase, not tick — the same 5s poll lands on tick 12 vs 13. (The real fix — disable the reconciler, §10.1 — exists; the §4.11 standalone claim is wrong.)

**Minors:** **SC-9** (`canClaim` role gate can't discriminate PickRobot UOM); **CD-3** (effective-priority `priorityKey − boost` can tie with no tiebreak/clamp).

---

## Impact on the phased rollout (§9)

| Phase | Blockers/breakers landing here | Safe to start? |
|---|---|---|
| **P0** substrate | SC-1 (ScoutBrain no movement) | **After the SC-1 fix** — small, self-contained. |
| **P1** one cart putaway | DLS-1 only if the dest rack is full | **Yes**, with a "dest-full → hold + backpressure" guard; pre-seeded single pallet + empty rack won't hit it. This is the fastest way to see the model live. |
| **P2** unload | SC-7 (phasing) | Needs the P2/P3 boundary redrawn. |
| **P3** inbound loop | SBI-1, DLS-4, DLS-5, LCC-3 | Rework bay + truck-waiting authority first. |
| **P4** outbound | **LCC-1, LCC-2, SC-3, SC-5, SBI-2** | **No — most blockers/breakers live here.** Reconcile order/UOM accounting before coding. |
| **P5** charging | **SC-2, EC-1, EC-2, EC-3, EC-4, DLS-3, SC-6, SC-8** | **No — the energy subsystem needs a rewrite.** |
| **P6** traffic | DLS-2, SC-4, CD-3 | Depends on a real offline-recovery subsystem. |

---

## Bottom line — fix these in the doc, in order, before building

1. **Wire the two phantom subsystems** (the redesign's own anti-pattern): a **recovery/tow claimer** (DLS-2) + clear `offlineObstacle` on recovery (SC-4), and the **overflow buffer** as a real cell/provider (DLS-1).
2. **Reconcile order/UOM accounting** into one authoritative counter with one decrement point, a **per-UOM** reorder signal, and either a real rack→rack rebalance driver or a changed reorder metric (LCC-1, LCC-2, LCC-3, SC-5, SBI-2).
3. **Rewrite the energy/charging subsystem**: schedule `ChargerDockArbiter` (SC-2), add hysteresis (EC-1), a runtime no-charge fallback (EC-3), a real queued-drain path (SC-6), and charger placement/validation (EC-4, SC-8, DLS-3).
4. **Fix the truck-waiting authority** — gate unload on local `lifecycle`, not the 5s-polled `status_actual` (SBI-1).
5. **Restore determinism** — make `createInboundOrder` synchronous/mocked with a pinned drain order; drop §4.11's "buffering suffices" claim (CD-1, CD-2).
6. **Housekeeping** — sweep terminal Orders/Jobs (SBI-4), bound tombstones (SBI-5), give robot-raised markers a resolve path (SBI-6), and give `idemKey` a backing store (LCC-4).

**Then P0 + P1 are green to build.** Everything above P1 waits on the doc amendments for its phase.
