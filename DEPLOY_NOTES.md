# DEPLOY_NOTES — Autonomous Units (WIOS sim)

Manifest to separate the **autonomous-units change** from the large body of
**unrelated uncommitted work** currently in this `WarehouseSimulator` working
tree, so a clean review/PR is possible before anything ships to `wios.co.in`.

Generated 2026-07-13. Status: **complete + verified locally — 12 passing tests.**

---

## ⚠️ Do NOT `git add . && push`

`WarehouseSimulator` is on `main` (synced with origin) but the working tree has
**~30 uncommitted files, most of which are NOT the autonomous-units change** and
were not authored as part of it. A blanket commit + push to `main` triggers the
frontend CI → `wios.co.in` **production**, shipping all of that unreviewed.

Two extra guardrails apply here:
- **No automation in WIOS prod** (standing rule): the deployed app runs this
  autonomous loop **client-side** and writes `pickTransaction`/`dropTransaction`
  into the **prod backend shared with EventXplore production**. Confirm safeguards
  (off-peak, rate caps, EX-owner aware, kill switch — per app-infra §13.7.5)
  before shipping, or ship a visual-only demo mode that doesn't post to the backend.
- **Never push directly to `main`** — reviewed PR only (per `WIOS/docs/DEV_TEST_PROD_CYCLE.md`).

---

## Files that ARE the autonomous-units change

**New — data model / resources (`lib/application/`):**
- `job_board.dart` — Orders/Jobs, CAS claim, single-counter accounting, idem ledger, sweep, recovery net
- `bay_resource.dart` — bay + charger + rack/stage/cell reservations (CAS)
- `outbound_stage.dart` — outbound stage occupancy

**New — brains (`lib/application/brains/`):**
- `unit_brain.dart` (base + registry + charging + offline/recovery + `occupiedByOthers`)
- `action_applier.dart` (move/tryStep/pick/drop/fog/drain surface)
- `unit_scheduler.dart` (4-phase tick + cell-reservation seeding)
- `scout_brain.dart`, `putaway_robot_brain.dart`, `inbound_robot_brain.dart`,
  `inbound_truck_brain.dart`, `stock_monitor_brain.dart`, `pick_robot_brain.dart`,
  `outbound_robot_brain.dart`, `outbound_truck_brain.dart`, `outbound_order_generator_brain.dart`

**Modified by this change (1 file):**
- `lib/application/robot_scout_simulation.dart` — `_tick()` now drives the
  `UnitScheduler` + registers `ScoutBrain`s + clears resource occupancy on reset
  (old `ScoutBot` movement retired; dead `_seedInitialReveal` removed).

**New — tests (`test/`):** `p1_putaway`, `p2_unload_chain`, `p3_inbound_loop`,
`p3_truck_bay`, `p4_outbound_loop`, `p4_pick`, `p5_charging`,
`regression_putaway_capacity`, `regression_multipicker`,
`regression_offline_recovery`, `regression_collision`.

**New — design docs (repo root):** `AUTONOMOUS_UNITS_DESIGN.md`,
`DESIGN_AMENDMENTS_v2.md`, `ADVERSARIAL_REVIEW.md`, and this file.

---

## Files that are NOT this change (pre-existing uncommitted work — needs its own owner/review)

**Modified, not authored here:** `lib/application/providers.dart` (+41/−17),
`lib/core/api_client.dart`, `lib/main.dart`, `lib/models/user.dart`,
`lib/screens/{about,chat,dashboard,floor,login,orders,warehouse_creator}_screen.dart`,
`lib/widgets/{adaptive_shell,my_apps_section,robot_card,wms_dashboard_panel}.dart`,
`android/app/src/main/AndroidManifest.xml`, `ios/Runner/Info.plist`.

**Untracked, not authored here:** `lib/application/inbound_ops_controller.dart`,
`lib/application/pallet_putaway_controller.dart`, `.dockerignore`, `Dockerfile.acr`.

> **Entanglement:** the autonomous-units change likely **depends** on this
> baseline (the modified `providers.dart` and the untracked controllers are
> referenced by `robot_scout_simulation.dart`). It is **not confirmed to compile
> in isolation** against `origin/main` — verify that when reconciling.

---

## Clean-PR recipe (once the baseline is sorted)

1. Whoever owns the pre-existing changes reviews + commits them (their own PR),
   so `origin/main` reflects a clean, reviewed baseline.
2. Branch: `git checkout -b feat/autonomous-units`.
3. Stage only the files in the manifest above, then `flutter analyze` +
   `flutter test test/` (expect 12 passing).
4. Open a PR → `main`. **Do not merge** until the no-automation-in-prod / shared-EX
   decision (safeguards or demo mode) is settled — the merge is what deploys.

## Run/verify locally (safe, zero blast radius)
```
& C:\Users\krish\.local\bin\flutter.cmd test test\     # 12 tests
& C:\Users\krish\.local\bin\flutter.cmd run            # watch it live
```
