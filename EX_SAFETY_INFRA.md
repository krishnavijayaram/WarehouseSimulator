# EX_SAFETY_INFRA — hard guarantees so WIOS can never impact EventXplore

> **DRAFT for review.** These are the infrastructure controls that turn
> "the sim shouldn't affect EX" into "WIOS *cannot* affect EX, by construction."
> **Do NOT apply blind.** WIOS shares the Postgres instance + `platform-env`
> with EX production — every change here must go through `app-infra/CLAUDE.md
> §13.7` with the EX owner's sign-off. Fill in the real role/flag names first.

## Context
- WIOS and EventXplore share **one Postgres instance** (`eventxplore` DB),
  isolated only by **schema-per-app**. Schema separation stops data corruption
  and app-crash coupling; it does **not** stop resource contention (connections,
  CPU, IOPS, WAL).
- The **application code** already guarantees the *simulation* writes nothing to
  the backend (`RobotScoutSimulation.backendSync = false`; brains make zero
  backend calls; verified by `test/ex_safety_test.dart`). So the sim adds **zero**
  incremental DB load. The controls below protect against the *pre-existing* WIOS
  app (login/config/heartbeat/orders) ever starving EX.

## Layer 1 — make starvation impossible (strongest belt)

### 1. Hard connection ceiling on WIOS's DB role
Guarantees WIOS can never consume more than `N` connections, leaving EX headroom.
```sql
-- Replace wios_app with the ACTUAL role WIOS connects as; pick N << instance max
-- leaving EX its full budget (confirm max_connections + EX's peak first).
ALTER ROLE wios_app CONNECTION LIMIT 10;
```

### 2. Statement timeout on WIOS's role
A runaway WIOS query can't hog CPU/IO on the shared instance.
```sql
ALTER ROLE wios_app SET statement_timeout = '5s';
ALTER ROLE wios_app SET idle_in_transaction_session_timeout = '10s';
```

### 3. Kill switch
One flag that instantly takes WIOS dark if EX shows any stress — EX untouched.
```
# platform-env (WIOS app service only — NOT shared): 
WIOS_ENABLED=false        # app checks on boot / per request; false => 503 + no DB
```
App-side: gate WIOS's DB-touching entrypoints on this flag so flipping it stops
all WIOS DB traffic without a redeploy.

## Layer 3 — the ultimate isolation (optional, bigger effort)
Move WIOS onto **its own Postgres instance**. Removes the shared-instance vector
entirely; the connection-limit belt above is the pragmatic stand-in until then.

## Deploy-day checklist
- [ ] Layers 1.1–1.3 applied via §13.7, EX owner signed off.
- [ ] Verified locally first (robots move — floor badge `tracked/moving`).
- [ ] Reviewed PR merged (not a direct push to `main`).
- [ ] Merge in EX **off-peak** window.
- [ ] Watch EX DB metrics through rollout: active connections, CPU, p95 latency.
- [ ] Rollback ready: previous image/tag redeployable in one step.
- [ ] Any EX blip → flip `WIOS_ENABLED=false`, investigate, then retry.
